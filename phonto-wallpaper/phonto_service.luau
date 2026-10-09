--!nonstrict
-- Phonto video wallpaper — headless service.
-- This service handles active video wallpaper assignments and lifecycle.
-- A single phonto process renders every assigned output: `phonto VIDEO` mirrors one
-- video on all outputs, `phonto --display A a.mp4 --display B b.mp4` pins one per
-- output. phonto has no runtime control, so any change to its command line restarts it.
-- Note: Noctalia plugin scripts run in an isolated sandbox without `require`.
-- Therefore, all logic (IPC, state management) must reside here.

noctalia.setUpdateInterval(1000)

-- ==============================================================================
-- ── PATHS AND STATE ────────────────────────────────────────────────────────
-- ==============================================================================

local CACHE_DIR = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")) .. "/noctalia/phonto"
local STATE_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia/phonto"
local STATE_FILE = STATE_DIR .. "/assignments.json"
local LOG_FILE = STATE_DIR .. "/phonto.log" -- output of the last launched phonto
local UNIT_NAME = "phonto.scope" -- systemd scope wrapping the phonto process
local HEALTH_INTERVAL = 5 -- update() ticks (seconds) between liveness checks of phonto

local assignments = {}  -- Map of connector -> video path ("*" for all outputs)
local lastAssignments = {} -- Map of connector -> video path last applied (feeds IPC "reapply")
local instance = nil    -- The launched phonto process: { argv = {...}, systemd = bool, ready = bool }
local paused = false    -- Is the phonto process frozen? (one process, so pause is global)
local pauseIntent = nil -- Pause/resume requested while phonto was (re)starting; applied once it is up
local available = false -- Is the phonto binary installed?
local legacyLayout = false -- State file predates the single-process layout (v0.2.0 and earlier)

local reconciling = false -- A restart is in flight (waiting for the old process to stop)
local pendingForce = nil  -- nil, or the `force` flag of a reconcile queued behind it
local launchGen = 0       -- Bumped by every reconcile; stale startup checks compare it
local healthTicks = 0

-- ==============================================================================
-- ── HELPERS ────────────────────────────────────────────────────────────────
-- ==============================================================================

local function cfg(key)
  return noctalia.getConfig(key)
end

-- Safely quotes strings for shell execution to prevent injection.
local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- ── Shared by phonto_service.luau and panel.luau: keep both copies identical (tests check) ──

-- Cache file name of a video's thumbnail: two 32-bit polynomial hashes of the full
-- path, so different videos never share a file (replacing non-alphanumerics with
-- "_" made e.g. every two-character CJK name collide). The arithmetic stays below
-- 2^53, so it is exact in any Lua number type.
local function thumbName(path)
  local a, b = 5381, 0
  for i = 1, #path do
    local c = path:byte(i)
    a = (a * 33 + c) % 4294967291
    b = (b * 131 + c) % 4294967279
  end
  return string.format("%08x%08x.jpg", a, b)
end

-- Shell command that writes one frame of a video to a JPEG: the frame at 1s, or the
-- first frame when the video is shorter than that. It succeeds only if the image
-- really exists (ffmpeg can exit 0 without writing one) and never leaves a stale file.
local function frameCommand(videoPath, outPath)
  local input, out = shellQuote(videoPath), shellQuote(outPath)
  local grab = " -frames:v 1 -q:v 2 " .. out .. " >/dev/null 2>&1"
  return "rm -f " .. out .. " ; ffmpeg -y -ss 1 -i " .. input .. grab ..
    " ; [ -s " .. out .. " ] || ffmpeg -y -i " .. input .. grab .. " ; [ -s " .. out .. " ]"
end

-- ── End of shared code ──

-- Escapes POSIX ERE metacharacters so a literal string can be embedded in a
-- pkill -f pattern.
local function ereQuote(s)
  return (tostring(s):gsub("([%.%*%+%?%(%)%[%]%^%$|\\{}])", "\\%1"))
end

-- Builds a pkill -f pattern matching exactly the command line of a launched phonto
-- process (anchored at both ends), so user-launched `phonto` instances are left
-- untouched. argv[1] may show up as a full path under systemd-run, hence `(^|/)`.
local function killPattern(argv)
  local parts = {}
  for i, arg in ipairs(argv) do parts[i] = ereQuote(arg) end
  return shellQuote("(^|/)" .. table.concat(parts, " ") .. "$")
end

-- Executes a function for every affected physical output.
-- Avoids massive code duplication for wildcard ("*") assignments.
local function forEachOutput(connector, fn)
  if connector == "*" then
    for _, output in ipairs(noctalia.outputs()) do
      fn(output.name)
    end
  else
    fn(connector)
  end
end

-- Returns a quick dictionary of currently attached physical monitors.
local function presentOutputs()
  local present = {}
  for _, output in ipairs(noctalia.outputs()) do present[output.name] = true end
  return present
end

local function sameArgv(a, b)
  if a == nil or b == nil then return a == b end
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- ==============================================================================
-- ── STATE PERSISTENCE ──────────────────────────────────────────────────────
-- ==============================================================================

local function persist()
  noctalia.runAsync("mkdir -p " .. shellQuote(STATE_DIR))
  noctalia.writeFile(STATE_FILE, noctalia.json.encode({
    assignments = assignments,
    lastAssignments = lastAssignments,
    instance = instance
  }) or "")
end

local function loadAssignments()
  local content = noctalia.readFile(STATE_FILE)
  if type(content) == "string" and content ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" then
      if decoded.assignments then
        assignments = decoded.assignments
        lastAssignments = decoded.lastAssignments or {}
        instance = decoded.instance
        if type(instance) ~= "table" or type(instance.argv) ~= "table" then
          instance = nil
        else
          instance.ready = nil -- a process from an earlier session is only a target to stop
        end
        if decoded.launchedAsSystemd ~= nil then
          legacyLayout = true
          -- The old "*" instance had the same command line and unit as today's
          -- mirror process, so the regular stop path handles it.
          if assignments["*"] then
            instance = { argv = { "phonto", assignments["*"] }, systemd = decoded.launchedAsSystemd["*"] == true }
          end
        end
      else
        assignments = decoded
        legacyLayout = true
      end
    end
  end
end

-- The pause state the user sees: a request made while phonto was (re)starting
-- counts, since it is applied as soon as phonto is up.
local function effectivePaused()
  if pauseIntent ~= nil then return pauseIntent end
  return paused
end

-- Publishes the internal state so the panel can read it (e.g., to render paused UI).
-- Pause is global, so every assigned output reports the same paused state.
local function publish()
  local pausedMap = {}
  if effectivePaused() then
    for connector in pairs(assignments) do pausedMap[connector] = true end
  end
  noctalia.state.set("assignments", assignments)
  noctalia.state.set("available", available)
  noctalia.state.set("paused", pausedMap)
end

-- ==============================================================================
-- ── COMMAND BUILDERS ───────────────────────────────────────────────────────
-- ==============================================================================

-- Computes the phonto argv the current assignments call for, plus the outputs it
-- covers:
--   - All outputs ("*"): `phonto VIDEO` (phonto mirrors it and attaches hotplugged outputs).
--   - Per output:        `phonto --display A VIDEO_A --display B VIDEO_B ...`.
-- Only present outputs are pinned: phonto exits when none of its pinned outputs
-- exist, and each pinned entry costs a decoder. Returns nil when there is nothing
-- to render.
local function desiredArgv()
  local present = presentOutputs()
  if assignments["*"] then
    local covered = {}
    for name in pairs(present) do table.insert(covered, name) end
    if #covered == 0 then return nil, covered end
    return { "phonto", assignments["*"] }, covered
  end

  local covered = {}
  for connector in pairs(assignments) do
    if present[connector] then table.insert(covered, connector) end
  end
  if #covered == 0 then return nil, covered end
  table.sort(covered)
  local argv = { "phonto" }
  for _, connector in ipairs(covered) do
    table.insert(argv, "--display")
    table.insert(argv, connector)
    table.insert(argv, assignments[connector])
  end
  return argv, covered
end

-- Turns an argv into a shell command line, quoting every argument that needs it.
local function commandLine(argv)
  local parts = {}
  for i, arg in ipairs(argv) do
    parts[i] = arg:match("^[%w%-]+$") and arg or shellQuote(arg)
  end
  return table.concat(parts, " ")
end

-- Collects systemd-specific cgroup properties (e.g., CPUQuota).
local function systemdProperties()
  local props = {}
  local cpu_quota = cfg("cpu_quota")
  if type(cpu_quota) == "number" and cpu_quota > 0 then table.insert(props, "CPUQuota=" .. tostring(cpu_quota) .. "%") end

  local allowed_cpus = cfg("allowed_cpus")
  if type(allowed_cpus) == "string" and allowed_cpus ~= "" then table.insert(props, "AllowedCPUs=" .. allowed_cpus) end

  local memory_max = cfg("memory_max")
  if type(memory_max) == "string" and memory_max ~= "" then table.insert(props, "MemoryMax=" .. memory_max) end

  local cpu_weight = cfg("cpu_weight")
  if type(cpu_weight) == "number" and cpu_weight > 0 then table.insert(props, "CPUWeight=" .. tostring(cpu_weight)) end

  return props
end

-- ==============================================================================
-- ── THUMBNAILS & FRAME EXTRACTION ──────────────────────────────────────────
-- ==============================================================================

-- Extract a static fallback when playback is cleared, in either launch mode.
local function extractStaticWallpaper(connector, videoPath)
  if not cfg("extract_last_frame") then
    forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
    return
  end

  noctalia.runAsync("mkdir -p " .. shellQuote(CACHE_DIR), function()
    local outPath = CACHE_DIR .. "/" .. connector:gsub("[^%w%-]", "_") .. "_static.jpg"

    noctalia.runAsync(frameCommand(videoPath, outPath), function(success)
      local extracted = success and noctalia.fileExists(outPath)
      forEachOutput(connector, function(name)
        -- A video assigned again while ffmpeg ran owns the output now.
        if assignments[name] ~= nil or assignments["*"] ~= nil then return end
        if extracted then noctalia.setWallpaper(name, outPath) end
        noctalia.setWallpaperEnabled(name, true)
      end)
    end)
  end)
end

-- Show the host wallpaper while restarting, using a cached thumbnail when one
-- exists and keeping its current image otherwise.
local function coverWithThumbnails(covered)
  for _, name in ipairs(covered) do
    local thumb = CACHE_DIR .. "/" .. thumbName(assignments[name] or assignments["*"])
    if noctalia.fileExists(thumb) then
      noctalia.setWallpaper(name, thumb)
    end
    noctalia.setWallpaperEnabled(name, true)
  end
end

-- ==============================================================================
-- ── PROCESS MANAGEMENT ─────────────────────────────────────────────────────
-- ==============================================================================

-- Builds the command that terminates a launched phonto process. It may be frozen
-- (pause), possibly by an earlier session, and a frozen cgroup or SIGSTOP'd process
-- ignores SIGTERM, so it is always thawed/resumed right before.
-- Note on pkill: The sandboxed noctalia.runAsync API does not return PIDs. Thus,
-- without systemd, matching by command line via pkill is the only reliable way to terminate it.
local function killCommand(running, signal)
  if running.systemd then
    local unit = shellQuote(UNIT_NAME)
    return "systemctl --user thaw " .. unit .. " ; systemctl --user stop " .. unit
  end
  local sig = (type(signal) == "number" and signal > 0) and signal or 15
  local pattern = killPattern(running.argv)
  return "pkill -CONT -f -- " .. pattern .. " ; pkill -" .. sig .. " -f -- " .. pattern
end

-- Stops the launched phonto process (if any), then runs the callback.
local function stopInstance(callback)
  local running = instance
  instance = nil
  paused = false
  persist()

  if running == nil then
    if callback then callback() end
    return
  end
  noctalia.runAsync(killCommand(running), callback or function() end)
end

-- Freezes or resumes the running phonto process. One process serves every
-- output, so this always applies to all of them.
local function applyPause(wantPaused)
  paused = wantPaused
  if instance.systemd then
    noctalia.runAsync("systemctl --user " .. (wantPaused and "freeze " or "thaw ") .. shellQuote(UNIT_NAME))
  else
    -- SIGSTOP freezes the process in place, preserving the last frame on screen;
    -- SIGCONT resumes it.
    noctalia.runAsync("pkill -" .. (wantPaused and "STOP" or "CONT") .. " -f -- " .. killPattern(instance.argv))
  end
end

-- phonto exited on its own (unplayable or missing video, decoder or GPU failure,
-- crash): show the host wallpaper again instead of leaving the outputs black, and
-- point at its output. The assignments stay, so reapply or a new pick retries.
local function instanceDied(dead)
  if instance ~= dead then return end
  instance = nil
  paused = false
  pauseIntent = nil
  persist()
  forEachOutput("*", function(name) noctalia.setWallpaperEnabled(name, true) end)
  noctalia.notifyError("Phonto Video Wallpaper", "phonto stopped unexpectedly, see " .. LOG_FILE)
  publish()
end

-- Once phonto has had time to map its surfaces, checks that it is still running:
-- if so, hides the host wallpaper on the covered outputs and applies a pause
-- requested meanwhile; if not, reports the failure. A later reconcile invalidates
-- the check, so it never acts on a process that is being replaced.
local function confirmRunning(covered)
  local gen, launched = launchGen, instance
  if launched == nil then return end
  noctalia.runAsync("sleep 0.8 ; pgrep -f -- " .. killPattern(launched.argv) .. " >/dev/null", function(running)
    if gen ~= launchGen or instance ~= launched then return end
    if not running then
      instanceDied(launched)
      return
    end
    launched.ready = true
    for _, name in ipairs(covered) do noctalia.setWallpaperEnabled(name, false) end
    if pauseIntent ~= nil then
      local want = pauseIntent
      pauseIntent = nil
      applyPause(want)
    end
    publish()
  end)
end

-- Spawns phonto for the given argv.
local function launch(argv, covered)
  instance = { argv = argv, systemd = cfg("run_as_systemd") == true }
  persist()

  local cmd = commandLine(argv)
  local nice = cfg("nice")
  if type(nice) == "number" and nice ~= 0 then
    cmd = "nice -n " .. tostring(nice) .. " " .. cmd
  end

  if instance.systemd then
    local propsCmd = ""
    for _, prop in ipairs(systemdProperties()) do
      propsCmd = propsCmd .. "--property=" .. shellQuote(prop) .. " "
    end
    cmd = "systemd-run --user --scope " .. propsCmd .. "--unit=" .. shellQuote(UNIT_NAME) .. " " .. cmd
  end

  -- Run phonto in background; its output is kept for diagnosing failures.
  noctalia.runAsync("mkdir -p " .. shellQuote(STATE_DIR) .. " ; exec " .. cmd .. " >" .. shellQuote(LOG_FILE) .. " 2>&1 &", function() end)
  confirmRunning(covered)
end

-- Up to v0.2.0 every output ran its own `phonto --display <connector> <path>` process
-- (or `phonto-<connector>.scope`). Stops those once so they don't linger next to the
-- single process, then runs the callback.
local function stopLegacyInstances(callback)
  local cmds = {}
  if legacyLayout then
    for connector, path in pairs(assignments) do
      if connector ~= "*" then
        local unit = shellQuote("phonto-" .. connector:gsub("[^%w%-]", "_") .. ".scope")
        local pattern = killPattern({ "phonto", "--display", connector, path })
        table.insert(cmds, "systemctl --user thaw " .. unit .. " ; systemctl --user stop " .. unit ..
          " ; pkill -CONT -f -- " .. pattern .. " ; pkill -15 -f -- " .. pattern)
      end
    end
  end
  if #cmds == 0 then
    callback()
    return
  end
  noctalia.runAsync(table.concat(cmds, " ; "), function() callback() end)
end

-- Brings the phonto process in line with the assignments and the present outputs.
-- An unchanged command line keeps the running process (e.g. a monitor plugged in
-- while mirroring, which phonto attaches by itself); otherwise the process is
-- restarted, or only stopped when nothing is left to render. `force` restarts an
-- unchanged process too (config change, reapply, boot). Calls made while a restart
-- is in flight are queued and run once it completes.
local function reconcile(force)
  launchGen = launchGen + 1
  if reconciling then
    pendingForce = pendingForce or force or false
    return
  end

  local argv, covered = desiredArgv()

  -- Outputs phonto does not cover show the host wallpaper.
  local coveredSet = {}
  for _, name in ipairs(covered) do coveredSet[name] = true end
  for name in pairs(presentOutputs()) do
    if not coveredSet[name] then noctalia.setWallpaperEnabled(name, true) end
  end

  if not force and sameArgv(argv, instance and instance.argv) then
    confirmRunning(covered)
    return
  end

  reconciling = true
  coverWithThumbnails(covered)
  stopInstance(function()
    -- Recompute: the assignments may have changed while the old process stopped.
    local latest, latestCovered = desiredArgv()
    if latest and available then launch(latest, latestCovered) end
    reconciling = false
    if pendingForce ~= nil then
      local queued = pendingForce
      pendingForce = nil
      reconcile(queued)
    elseif instance == nil then
      pauseIntent = nil -- nothing left to pause
    end
    -- A restart resumes playback: never leave the panel showing a stale "paused".
    publish()
  end)
end

-- ==============================================================================
-- ── PAUSE / RESUME / TOGGLE ────────────────────────────────────────────────
-- ==============================================================================

-- Pauses or resumes playback on every output. While phonto is being (re)started
-- the request is kept and applied once it is up: stopping it before its first
-- frame would leave the outputs black, and a stop/launch in flight would lose it.
local function setPaused(wantPaused)
  if reconciling or (instance ~= nil and not instance.ready) then
    pauseIntent = wantPaused
  elseif instance ~= nil then
    applyPause(wantPaused)
  end
end

-- ==============================================================================
-- ── CORE ASSIGNMENT LOGIC ──────────────────────────────────────────────────
-- ==============================================================================

-- Remembers the live assignments as the "last applied" set for the IPC
-- "reapply" verb. Skipped when empty so repeated clears never overwrite it.
-- The copy matters: clearVideo mutates `assignments` in place.
local function snapshotAssignments()
  if next(assignments) == nil then return end
  lastAssignments = {}
  for k, v in pairs(assignments) do lastAssignments[k] = v end
end

-- Clears an assigned video and restores the host wallpaper. The other outputs
-- keep playing, but phonto restarts to drop this one.
local function clearVideo(connector)
  if type(connector) ~= "string" or connector == "" then return end

  snapshotAssignments()
  local path = assignments[connector]
  if path == nil and connector ~= "*" and assignments["*"] ~= nil then
    -- One output of an all-outputs wallpaper (IPC; the panel only offers stopping
    -- all of them): the other present outputs keep the video as their own
    -- assignments, which also means monitors plugged in later stay untouched.
    local present = presentOutputs()
    if not present[connector] then return end
    path = assignments["*"]
    assignments = {}
    for name in pairs(present) do
      if name ~= connector then assignments[name] = path end
    end
  else
    assignments[connector] = nil
  end
  persist()

  if path then
    extractStaticWallpaper(connector, path)
  else
    forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
  end
  reconcile()

  publish()
end

-- Assigns a video to a specific monitor or globally ("*").
local function setVideo(connector, path)
  if not available or type(connector) ~= "string" or connector == "" or type(path) ~= "string" or path == "" then return end

  -- Re-applying the current video restarts it (and revives a dead process).
  local reapplied = assignments[connector] == path

  -- Resolve overlaps: a global assignment replaces the specific ones, and vice versa.
  if connector == "*" then
    assignments = {}
  else
    assignments["*"] = nil
  end
  assignments[connector] = path
  persist()

  reconcile(reapplied)

  publish()
end

-- ==============================================================================
-- ── LIFECYCLE ──────────────────────────────────────────────────────────────
-- ==============================================================================

-- Called every second. Every few seconds, checks that the launched phonto is still
-- alive, so a crash after startup restores the host wallpaper too.
function update()
  healthTicks = healthTicks + 1
  if healthTicks < HEALTH_INTERVAL or reconciling or instance == nil or not instance.ready then return end
  healthTicks = 0
  local checked = instance
  noctalia.runAsync("pgrep -f -- " .. killPattern(checked.argv) .. " >/dev/null", function(running)
    if not running then instanceDied(checked) end
  end)
end

-- Triggers when a monitor connects or disconnects.
function onOutputsChanged()
  if not available then return end
  reconcile()
end

-- Called when the plugin is disabled, removed, or Noctalia is shutting down.
-- Terminates the phonto process so no orphan remains, whether it runs directly
-- (pkill) or in a systemd scope (systemctl stop), and even when frozen/paused.
-- The persisted `instance` is kept so the next boot can stop a survivor.
function onExit(signal)
  if instance then
    noctalia.runAsync(killCommand(instance, signal))
  end
end

-- ==============================================================================
-- ── IPC (COMMUNICATION WITH PANEL) ─────────────────────────────────────────
-- ==============================================================================

-- pause/resume/toggle accept a connector for compatibility but always act on the
-- single phonto process, i.e. on every output.
function onIpc(event, payload)
  if event == "clear-all" then
    snapshotAssignments()
    for connector, path in pairs(assignments) do
      extractStaticWallpaper(connector, path)
    end
    assignments = {}
    persist()
    reconcile()
    publish()

  elseif event == "clear" then
    clearVideo(payload)

  elseif event == "reapply" then
    if not available then
      noctalia.log("phonto: reapply requested but phonto is not installed")
      return
    end
    -- Nothing currently assigned (e.g. a lock hook ran clear-all): restore the
    -- last applied set. Copy, never alias — `assignments` is mutated in place
    -- elsewhere (picker apply) and must not corrupt the snapshot.
    if next(assignments) == nil then
      assignments = {}
      for k, v in pairs(lastAssignments) do assignments[k] = v end
      persist()
    end
    reconcile(true)
    publish()

  elseif event == "pause" or event == "freeze" then
    setPaused(true)
    publish()

  elseif event == "resume" or event == "thaw" then
    setPaused(false)
    publish()

  elseif event == "toggle" then
    setPaused(not effectivePaused())
    publish()
  end
end

-- Listen to the panel UI commands.
noctalia.state.watch("command", function(cmd)
  if type(cmd) ~= "table" then return end
  if cmd.action == "set" then setVideo(cmd.connector, cmd.path)
  elseif cmd.action == "clear" then clearVideo(cmd.connector)
  elseif cmd.action == "clear-all" then onIpc("clear-all", nil)
  elseif cmd.action == "freeze" then onIpc("freeze", cmd.connector)
  elseif cmd.action == "thaw" then onIpc("thaw", cmd.connector)
  elseif cmd.action == "toggle" then onIpc("toggle", cmd.connector) end
end)

-- ==============================================================================
-- ── BOOT ───────────────────────────────────────────────────────────────────
-- ==============================================================================

noctalia.runAsync("mkdir -p '" .. STATE_DIR:gsub("'", "'\\''") .. "'")
loadAssignments()

available = noctalia.commandExists("phonto")
if not available then
  noctalia.notifyError("Phonto Video Wallpaper", "phonto is not installed")
end

-- Start from a clean slate: stop whatever the previous session left running
-- (forced reconcile), including the per-output processes of the old layout.
stopLegacyInstances(function()
  reconcile(true)
  publish()
end)

publish()

-- Called when any configuration setting is changed.
function onConfigChanged(key, value)
  reconcile(true)
end
