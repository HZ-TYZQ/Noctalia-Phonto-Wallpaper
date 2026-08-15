--!nonstrict
-- Phonto video wallpaper — headless service.
-- This service handles active video wallpaper assignments and lifecycle.
-- Note: Noctalia plugin scripts run in an isolated sandbox without `require`.
-- Therefore, all logic (IPC, state management) must reside here.

noctalia.setUpdateInterval(1000)

-- ==============================================================================
-- ── PATHS AND STATE ────────────────────────────────────────────────────────
-- ==============================================================================

local CACHE_DIR = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")) .. "/noctalia/phonto"
local STATE_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia/phonto"
local STATE_FILE = STATE_DIR .. "/assignments.json"

local assignments = {}  -- Map of connector -> video path ("*" for all outputs)
local launchedAsSystemd = {} -- Map of connector -> boolean (true if launched as systemd)
local lastPresent = {}  -- Map of connector -> true (monitors seen last tick)
local isPaused = {}     -- Map of connector -> true (paused monitors)
local available = false -- Is the phonto binary installed?

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

-- Escapes POSIX ERE metacharacters so a literal string can be embedded in a
-- pkill -f pattern.
local function ereQuote(s)
  return (tostring(s):gsub("([%.%*%+%?%(%)%[%]%^%$|\\{}])", "\\%1"))
end

-- Returns the systemd unit name for a given connector.
-- E.g., "*" -> "phonto.scope", "DP-1" -> "phonto-DP-1.scope".
local function unitNameFor(connector)
  if connector == "*" then 
    return "phonto.scope" 
  end
  return "phonto-" .. connector:gsub("[^%w%-]", "_") .. ".scope"
end

-- Builds a precise pkill -f pattern that matches only the phonto instance this
-- plugin launched for the given connector:
--   - Single output: matches `phonto( .*)? --display <connector> ` (the optional
--     prefix leaves room for flags before --display; the trailing space prevents
--     partial matches, e.g., DP-1 accidentally matching DP-10).
--   - All outputs ("*"): phonto takes no connector argument, so the exact video
--     path (anchored at the end of the command line) is used instead. This keeps
--     user-launched `phonto` instances playing other videos untouched.
local function pkillPattern(connector, path)
  if connector == "*" then
    if type(path) ~= "string" or path == "" then return nil end
    return shellQuote("(^|/)phonto " .. ereQuote(path) .. "$")
  end
  return shellQuote("(^|/)phonto .* --display " .. ereQuote(connector) .. " ")
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

-- ==============================================================================
-- ── STATE PERSISTENCE ──────────────────────────────────────────────────────
-- ==============================================================================

local function persist()
  noctalia.runAsync("mkdir -p " .. shellQuote(STATE_DIR))
  noctalia.writeFile(STATE_FILE, noctalia.json.encode({
    assignments = assignments,
    launchedAsSystemd = launchedAsSystemd
  }) or "")
end

local function loadAssignments()
  local content = noctalia.readFile(STATE_FILE)
  if type(content) == "string" and content ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" then
      if decoded.assignments then
        assignments = decoded.assignments
        launchedAsSystemd = decoded.launchedAsSystemd or {}
      else
        assignments = decoded
      end
    end
  end
end

-- Publishes the internal state so the panel can read it (e.g., to render paused UI).
local function publish()
  noctalia.state.set("assignments", assignments)
  noctalia.state.set("available", available)
  noctalia.state.set("paused", isPaused)
end

-- ==============================================================================
-- ── COMMAND BUILDERS ───────────────────────────────────────────────────────
-- ==============================================================================

-- Builds the phonto command line for a connector:
--   - All outputs ("*"): `phonto VIDEO` (phonto applies it to every output).
--   - Single output:     `phonto --display OUTPUT VIDEO`.
local function phontoCommand(connector, path)
  if connector == "*" then
    return "phonto " .. shellQuote(path)
  end
  return "phonto --display " .. shellQuote(connector) .. " " .. shellQuote(path)
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

-- When systemd is disabled, we cannot freeze the process. We fallback to killing
-- the video and extracting a static frame to use as the Noctalia wallpaper.
local function extractStaticWallpaper(connector, videoPath)
  if not cfg("extract_last_frame") then
    forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
    return
  end

  noctalia.runAsync("mkdir -p " .. shellQuote(CACHE_DIR), function()
    local outPath = CACHE_DIR .. "/" .. connector:gsub("[^%w%-]", "_") .. "_static.jpg"
    local cmd = "ffmpeg -y -ss 1 -i " .. shellQuote(videoPath) .. " -frames:v 1 -q:v 2 " .. shellQuote(outPath)
    
    noctalia.runAsync(cmd, function(success)
      if success and noctalia.fileExists(outPath) then
        forEachOutput(connector, function(name)
          noctalia.setWallpaper(name, outPath)
          noctalia.setWallpaperEnabled(name, true)
        end)
      else
        forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
      end
    end)
  end)
end

-- ==============================================================================
-- ── PROCESS MANAGEMENT ─────────────────────────────────────────────────────
-- ==============================================================================

-- Kills the phonto process.
-- Note on pkill: The sandboxed noctalia.runAsync API does not return PIDs. Thus,
-- without systemd, matching by command line via pkill is the only reliable way to terminate it.
local function killPhonto(connector, path, callback, signal)
  local sig = (type(signal) == "number" and signal > 0) and signal or 15
  local killCmd
  local pattern = pkillPattern(connector, path)
  if launchedAsSystemd[connector] then
    local unitName = unitNameFor(connector)
    if isPaused[connector] then
      -- A frozen cgroup ignores SIGTERM. We must thaw it right before stopping.
      killCmd = "systemctl --user thaw " .. shellQuote(unitName) .. " ; systemctl --user stop " .. shellQuote(unitName)
    else
      killCmd = "systemctl --user stop " .. shellQuote(unitName)
    end
  elseif pattern == nil then
    -- Wildcard assignment without a video path: nothing precise to match.
    isPaused[connector] = false
    if callback then callback() end
    return
  elseif isPaused[connector] then
    -- A SIGSTOP'd process ignores SIGTERM. We must resume it right before killing.
    killCmd = "pkill -CONT -f -- " .. pattern .. " ; pkill -" .. sig .. " -f -- " .. pattern
  else
    killCmd = "pkill -" .. sig .. " -f -- " .. pattern
  end
  
  isPaused[connector] = false

  if callback then
    noctalia.runAsync(killCmd, callback)
  else
    noctalia.runAsync(killCmd)
  end
end

-- Spawns a new phonto instance for the given connector.
-- `previous` is the video previously assigned to this connector (if any), used to
-- target the old instance precisely in the wildcard case.
local function startPhonto(connector, path, previous)
  -- Temporarily set the cached thumbnail as the background to prevent black screens during startup.
  local thumb = CACHE_DIR .. "/" .. path:gsub("[^%w]", "_") .. ".jpg"
  if noctalia.fileExists(thumb) then
    forEachOutput(connector, function(name) 
      noctalia.setWallpaper(name, thumb) 
      noctalia.setWallpaperEnabled(name, true)
    end)
  end

  killPhonto(connector, previous, function()
    launchedAsSystemd[connector] = cfg("run_as_systemd")
    persist()
    local cmd = phontoCommand(connector, path)
    
    local nice = cfg("nice")
    if type(nice) == "number" and nice ~= 0 then
      cmd = "nice -n " .. tostring(nice) .. " " .. cmd
    end
    
    if launchedAsSystemd[connector] then
      local unitName = unitNameFor(connector)
      local propsCmd = ""
      for _, prop in ipairs(systemdProperties()) do
        propsCmd = propsCmd .. "--property=" .. shellQuote(prop) .. " "
      end
      cmd = "systemd-run --user --scope " .. propsCmd .. "--unit=" .. shellQuote(unitName) .. " " .. cmd
    end

    -- Run phonto in background
    noctalia.runAsync("exec " .. cmd .. " >/dev/null 2>&1 &", function() end)
    noctalia.runAsync("sleep 0.8", function()
      forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, false) end)
    end)
  end)
end

-- ==============================================================================
-- ── PAUSE / RESUME / TOGGLE ────────────────────────────────────────────────
-- ==============================================================================

local function freezePhonto(connector)
  isPaused[connector] = true
  if cfg("run_as_systemd") then
    local unitName = unitNameFor(connector)
    noctalia.runAsync("systemctl --user freeze " .. shellQuote(unitName))
  else
    -- Send SIGSTOP to freeze the process in place, preserving the last frame on screen.
    local pattern = pkillPattern(connector, assignments[connector])
    if pattern then noctalia.runAsync("pkill -STOP -f -- " .. pattern) end
  end
end

local function thawPhonto(connector)
  isPaused[connector] = false
  if cfg("run_as_systemd") then
    local unitName = unitNameFor(connector)
    noctalia.runAsync("systemctl --user thaw " .. shellQuote(unitName))
  else
    -- Send SIGCONT to resume the frozen process.
    local pattern = pkillPattern(connector, assignments[connector])
    if pattern then noctalia.runAsync("pkill -CONT -f -- " .. pattern) end
  end
end

local function togglePhonto(connector)
  if isPaused[connector] then
    thawPhonto(connector)
  else
    freezePhonto(connector)
  end
end

-- ==============================================================================
-- ── CORE ASSIGNMENT LOGIC ──────────────────────────────────────────────────
-- ==============================================================================

-- Clears an assigned video and restores the host wallpaper.
local function clearVideo(connector)
  if type(connector) ~= "string" or connector == "" then return end
  
  local path = assignments[connector]
  assignments[connector] = nil
  persist()
  
  killPhonto(connector, path, function()
    if path then 
      extractStaticWallpaper(connector, path) 
    else
      forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
    end
  end)
  
  publish()
end

-- Assigns a video to a specific monitor or globally ("*").
local function setVideo(connector, path)
  if not available or type(connector) ~= "string" or connector == "" or type(path) ~= "string" or path == "" then return end
  
  -- Resolve overlaps: clear specific assignments when applying globally, and vice versa.
  if connector == "*" then
    for conn in pairs(assignments) do
      if conn ~= "*" then clearVideo(conn) end
    end
  else
    if assignments["*"] then clearVideo("*") end
  end

  local previous = assignments[connector]
  assignments[connector] = path
  persist()
  
  startPhonto(connector, path, previous)
  
  publish()
end

-- ==============================================================================
-- ── LIFECYCLE ──────────────────────────────────────────────────────────────
-- ==============================================================================

-- Returns a quick dictionary of currently attached physical monitors.
local function presentOutputs()
  local present = {}
  for _, output in ipairs(noctalia.outputs()) do present[output.name] = true end
  return present
end

-- Applies saved video assignments upon plugin startup.
-- The assigned path doubles as the kill target so a stale instance left over
-- from a previous session is replaced instead of duplicated.
local function applyAll()
  for connector, path in pairs(assignments) do
    startPhonto(connector, path, path)
  end
end

function update() end

-- Triggers when a monitor connects or disconnects.
function onOutputsChanged()
  if not available then return end
  local present = presentOutputs()
  
  local newMonitor = false
  for conn in pairs(present) do
    if not lastPresent[conn] then newMonitor = true end
  end

  -- Automatically apply wildcard wallpaper to newly connected monitors.
  if newMonitor and assignments["*"] then
    startPhonto("*", assignments["*"], assignments["*"])
  end

  -- Relaunch specific assignments for monitors that just connected.
  for connector, path in pairs(assignments) do
    if connector ~= "*" then
      if present[connector] and not lastPresent[connector] then
        startPhonto(connector, path, path)
      end
    end
  end
  
  lastPresent = present
end

-- Called when the plugin is disabled, removed, or Noctalia is shutting down.
-- Terminates every active phonto instance so no orphan processes remain.
-- Handles both direct processes (pkill) and systemd scopes (systemctl stop),
-- including thawing frozen/paused instances before sending SIGTERM.
function onExit(signal)
  for connector, path in pairs(assignments) do
    killPhonto(connector, path, nil, signal)
  end
end

-- ==============================================================================
-- ── IPC (COMMUNICATION WITH PANEL) ─────────────────────────────────────────
-- ==============================================================================

function onIpc(event, payload)
  if event == "clear-all" then
    for connector, path in pairs(assignments) do
      killPhonto(connector, path, function()
        if path then 
          extractStaticWallpaper(connector, path) 
        else
          forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
        end
      end)
    end
    assignments = {}
    persist()
    publish()

  elseif event == "clear" then
    clearVideo(payload)

  elseif event == "pause" or event == "freeze" then
    if type(payload) == "string" and payload ~= "" then
      freezePhonto(payload)
    else
      for conn in pairs(assignments) do freezePhonto(conn) end
    end
    publish()

  elseif event == "resume" or event == "thaw" then
    if type(payload) == "string" and payload ~= "" then
      thawPhonto(payload)
    else
      for conn in pairs(assignments) do thawPhonto(conn) end
    end
    publish()

  elseif event == "toggle" then
    if type(payload) == "string" and payload ~= "" then
      togglePhonto(payload)
    else
      for conn in pairs(assignments) do togglePhonto(conn) end
    end
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
if available then
  lastPresent = presentOutputs()
  applyAll()
else
  noctalia.notifyError("Phonto Video Wallpaper", "phonto is not installed")
end

publish()

-- Called when any configuration setting is changed.
function onConfigChanged(key, value)
  applyAll()
end
