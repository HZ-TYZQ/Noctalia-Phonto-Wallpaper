-- Logic tests for phonto_service.luau with simulated outputs and processes.
-- A model process table stands in for the system: `exec` spawns, pkill and
-- systemctl act on it, and real `grep -E` evaluates the pkill patterns. This is
-- where multi-monitor behavior is covered, since it needs no real monitors.
--
-- Usage: luajit service_sim.lua <phonto_service.luau> <tmpdir>

local here = arg[0]:match("^(.*)/") or "."
local H = dofile(here .. "/lib/harness.lua")
local SERVICE, TMP = assert(arg[1]), assert(arg[2])

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- Splits a POSIX shell command into words (single quotes and backslash escapes).
local function words(cmd)
  local out, cur, quoted, inq, i = {}, {}, false, false, 1
  while i <= #cmd do
    local c = cmd:sub(i, i)
    if inq then
      if c == "'" then inq = false else cur[#cur + 1] = c end
    elseif c == "'" then
      inq, quoted = true, true
    elseif c == "\\" then
      i = i + 1
      cur[#cur + 1] = cmd:sub(i, i)
    elseif c:match("%s") then
      if #cur > 0 or quoted then out[#out + 1] = table.concat(cur) end
      cur, quoted = {}, false
    else
      cur[#cur + 1] = c
    end
    i = i + 1
  end
  if #cur > 0 or quoted then out[#out + 1] = table.concat(cur) end
  return out
end

-- Model of the processes, systemd scopes and files the service touches. Videos
-- under /broken/ make phonto fail at startup and ffmpeg fail; ffmpeg seeking past
-- the end of a "short" video exits 0 without writing anything, like the real one.
local function newSystem()
  local sys = { procs = {}, units = {}, execs = 0, ffmpeg = {}, fs = {} }
  local nextPid = 100

  function sys.spawn(argv, unit, user)
    nextPid = nextPid + 1
    sys.procs[#sys.procs + 1] = { pid = nextPid, cmdline = table.concat(argv, " "), unit = unit, user = user }
    return sys.procs[#sys.procs]
  end

  local function matching(pattern)
    local f = assert(io.open(TMP .. "/cmdlines", "w"))
    for _, p in ipairs(sys.procs) do f:write(p.cmdline, "\n") end
    f:close()
    local hits = {}
    local grep = io.popen("grep -En -e " .. q(pattern) .. " " .. q(TMP .. "/cmdlines") .. " 2>&1")
    for line in grep:lines() do
      local n = assert(line:match("^(%d+):"), "grep error: " .. line)
      hits[#hits + 1] = sys.procs[tonumber(n)]
    end
    grep:close()
    return hits
  end

  local function remove(p)
    for i, x in ipairs(sys.procs) do
      if x == p then table.remove(sys.procs, i) return end
    end
  end

  -- A stopped process keeps SIGTERM pending until it is continued.
  local function signal(p, sig)
    if sig == "STOP" then
      p.stopped = true
    elseif sig == "CONT" then
      p.stopped = false
      if p.pendingTerm then remove(p) end
    elseif p.stopped and sig ~= "9" then
      p.pendingTerm = true
    else
      remove(p)
    end
  end

  -- Runs one simple command; returns its success.
  local function execOne(cmd)
    local w = {}
    for _, word in ipairs(words(cmd)) do
      if not word:match("^%d?>") and word ~= "&" then w[#w + 1] = word end -- drop redirections
    end
    if w[1] == "exec" then
      table.remove(w, 1)
      local unit
      if w[1] == "systemd-run" then
        table.remove(w, 1)
        while w[1] and w[1]:sub(1, 2) == "--" do
          unit = w[1]:match("^%-%-unit=(.*)$") or unit
          table.remove(w, 1)
        end
        assert(not (sys.units[unit] and sys.units[unit].live), "unit already active: " .. tostring(unit))
      end
      if w[1] == "nice" then
        for _ = 1, 3 do table.remove(w, 1) end
      end
      assert(w[1] == "phonto", "unexpected exec: " .. cmd)
      sys.execs = sys.execs + 1
      if table.concat(w, " "):find("/broken/", 1, true) then return true end -- exits at once
      if unit then
        w[1] = "/usr/bin/phonto" -- systemd-run starts it by its full path
        sys.units[unit] = { live = true, frozen = false }
      end
      sys.spawn(w, unit)
    elseif w[1] == "pkill" then
      assert(w[3] == "-f" and w[4] == "--", "unexpected pkill: " .. cmd)
      for _, p in ipairs(matching(w[5])) do signal(p, w[2]:sub(2)) end
    elseif w[1] == "pgrep" then
      assert(w[2] == "-f" and w[3] == "--", "unexpected pgrep: " .. cmd)
      return #matching(w[4]) > 0
    elseif w[1] == "rm" then
      sys.fs[w[3]] = nil
    elseif w[1] == "[" then
      assert(w[2] == "-s" and w[4] == "]", "unexpected test: " .. cmd)
      return sys.fs[w[3]] == true
    elseif w[1] == "systemctl" then
      local verb, u = w[3], sys.units[w[4]]
      if u and u.live then
        if verb == "freeze" then
          u.frozen = true
        elseif verb == "thaw" then
          u.frozen = false
        elseif verb == "stop" and not u.frozen then -- a frozen cgroup ignores SIGTERM
          u.live = false
          for i = #sys.procs, 1, -1 do
            if sys.procs[i].unit == w[4] then table.remove(sys.procs, i) end
          end
        end
      end
    elseif w[1] == "ffmpeg" then
      local seek, input = false, nil
      for i, word in ipairs(w) do
        if word == "-ss" then seek = true end
        if word == "-i" then input = w[i + 1] end
      end
      sys.ffmpeg[#sys.ffmpeg + 1] = input
      if input:find("/broken/", 1, true) then return false end
      if not (seek and input:find("short", 1, true)) then sys.fs[w[#w]] = true end
    elseif w[1] ~= "sleep" and w[1] ~= "mkdir" then
      error("unexpected command: " .. cmd)
    end
    return true
  end

  -- Runs `a ; b || c ; ...`; returns the success of the last command.
  function sys.exec(cmd)
    local ok = true
    for part in (cmd .. " ; "):gmatch("(.-) ; ") do
      local left, right = part:match("^(.-) || (.*)$")
      ok = execOne(left or part)
      if not ok and right then ok = execOne(right) end
    end
    return ok
  end

  -- phonto crashes (or is killed) behind the service's back.
  function sys.crash()
    for i = #sys.procs, 1, -1 do
      if not sys.procs[i].user then table.remove(sys.procs, i) end
    end
  end

  function sys.ours()
    local list = {}
    for _, p in ipairs(sys.procs) do
      if not p.user then list[#list + 1] = p end
    end
    return list
  end

  function sys.describe()
    local list = {}
    for _, p in ipairs(sys.procs) do
      list[#list + 1] = p.cmdline .. (p.unit and (" @" .. p.unit) or "") ..
        (p.stopped and " (stopped)" or "") .. (p.user and " (user)" or "")
    end
    return table.concat(list, " | ")
  end

  return sys
end

local function suite(mode)
  print("-- " .. mode .. " callbacks")
  local sys = newSystem()
  local thumbnailsCached = true
  local h = H.new({
    service = SERVICE,
    exec = sys.exec,
    sync = mode == "sync",
    env = { HOME = "/h", XDG_STATE_HOME = "/h/.local/state", XDG_CACHE_HOME = "/h/.cache" },
    outputs = { "DP-1", "HDMI-A-1" },
    -- Every thumbnail is cached; static frames exist once ffmpeg wrote them.
    fileExists = function(p) return sys.fs[p] or (thumbnailsCached and p:match("%.jpg$") ~= nil and not p:match("_static%.jpg$")) end,
  })
  h.config.extract_last_frame = true

  -- A phonto the user started by hand must never be killed.
  sys.spawn({ "phonto", "--display", "DP-1", "/v/a.mp4", "--scale", "fit" }, nil, true)

  -- Expects exactly the given phonto command line (or none) and the host wallpaper
  -- hidden exactly on `covered`.
  local function expect(label, cmdline, covered)
    local o = sys.ours()
    if cmdline then
      h.check(label .. ": exactly one phonto process", #o == 1 and o[1].cmdline == cmdline, sys.describe())
    else
      h.check(label .. ": no phonto process", #o == 0, sys.describe())
    end
    h.expectHost(label, covered)
    local userAlive = false
    for _, p in ipairs(sys.procs) do userAlive = userAlive or p.user == true end
    h.check(label .. ": user's own phonto untouched", userAlive)
  end
  local function pid()
    local o = sys.ours()
    return o[1] and o[1].pid
  end
  local both = { "DP-1", "HDMI-A-1" }

  h.boot()
  expect("boot with no state", nil, {})
  h.ipc("reapply")
  expect("reapply with no history", nil, {})

  -- Per-output videos share one process.
  h.pick("DP-1", "/v/a.mp4")
  expect("one output", "phonto --display DP-1 /v/a.mp4", { "DP-1" })
  h.pick("HDMI-A-1", "/v/b.mp4")
  expect("two outputs", "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/b.mp4", both)
  h.pick("DP-1", "/v/c 'quoted' (1).mp4")
  expect("change one output, odd file name", "phonto --display DP-1 /v/c 'quoted' (1).mp4 --display HDMI-A-1 /v/b.mp4", both)
  local before = pid()
  h.pick("DP-1", "/v/c 'quoted' (1).mp4")
  h.check("re-applying the current video restarts it", pid() ~= before)

  -- Pause is global.
  h.command("freeze", "HDMI-A-1")
  h.check("pause stops the process", sys.ours()[1].stopped == true)
  h.check("pause shows on every output", h.published.paused["DP-1"] and h.published.paused["HDMI-A-1"])
  h.ipc("toggle", "DP-1")
  h.check("toggle resumes", not sys.ours()[1].stopped and next(h.published.paused) == nil)
  h.ipc("pause")
  h.pick("DP-1", "/v/a.mp4")
  expect("restart while paused", "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/b.mp4", both)
  h.check("restart resumes playback", not sys.ours()[1].stopped and next(h.published.paused) == nil)

  sys.ffmpeg = {}
  h.command("clear", "HDMI-A-1")
  expect("clear one output", "phonto --display DP-1 /v/a.mp4", { "DP-1" })
  h.check("static frame extracted for the cleared output", sys.ffmpeg[1] == "/v/b.mp4", sys.ffmpeg[1])

  -- Hotplug
  h.pick("HDMI-A-1", "/v/b.mp4")
  h.plug({ "HDMI-A-1" })
  expect("unplug an assigned output", "phonto --display HDMI-A-1 /v/b.mp4", { "HDMI-A-1" })
  h.plug({})
  expect("unplug every output", nil, {})
  h.plug({ "DP-1", "HDMI-A-1" })
  expect("replug", "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/b.mp4", both)
  before = pid()
  h.plug({ "DP-1", "HDMI-A-1", "DP-2" })
  expect("plug an unassigned output", "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/b.mp4", both)
  h.check("plugging an unassigned output keeps the process", pid() == before)

  -- All outputs (mirror)
  h.pick("*", "/v/m.mp4")
  expect("all outputs", "phonto /v/m.mp4", { "DP-1", "HDMI-A-1", "DP-2" })
  before = pid()
  h.plug({ "DP-1", "HDMI-A-1", "DP-2", "DP-3" })
  expect("mirror hotplug", "phonto /v/m.mp4", { "DP-1", "HDMI-A-1", "DP-2", "DP-3" })
  h.check("mirror hotplug keeps the process (phonto attaches it)", pid() == before)
  h.plug({ "DP-1", "HDMI-A-1" })
  expect("mirror unplug", "phonto /v/m.mp4", both)
  h.pick("DP-1", "/v/a.mp4")
  expect("all outputs -> one output", "phonto --display DP-1 /v/a.mp4", { "DP-1" })
  h.pick("HDMI-A-1", "/v/b.mp4")

  -- clear-all / reapply
  h.command("clear-all")
  expect("clear-all", nil, {})
  h.ipc("clear-all")
  h.check("a second clear-all keeps the reapply snapshot", h.readState().lastAssignments["HDMI-A-1"] == "/v/b.mp4")
  h.ipc("reapply")
  expect("reapply restores", "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/b.mp4", both)
  before = pid()
  h.ipc("reapply")
  expect("reapply while running", "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/b.mp4", both)
  h.check("reapply while running restarts it", pid() ~= before)

  -- A burst of changes before any command has run (only meaningful when deferred).
  local execsBefore = sys.execs
  h.watchers.command({ action = "set", connector = "DP-1", path = "/v/x.mp4" })
  h.watchers.command({ action = "set", connector = "HDMI-A-1", path = "/v/y.mp4" })
  h.watchers.command({ action = "clear", connector = "HDMI-A-1" })
  h.watchers.command({ action = "set", connector = "HDMI-A-1", path = "/v/z.mp4" })
  h.flush()
  expect("burst of changes", "phonto --display DP-1 /v/x.mp4 --display HDMI-A-1 /v/z.mp4", both)
  if mode == "deferred" then
    h.check("burst coalesced into one launch", sys.execs - execsBefore == 1, (sys.execs - execsBefore) .. " launches")
  end

  -- systemd mode
  h.config.cpu_quota, h.config.nice = 50, 5
  h.setConfig("run_as_systemd", true)
  expect("systemd mode", "/usr/bin/phonto --display DP-1 /v/x.mp4 --display HDMI-A-1 /v/z.mp4", both)
  h.check("runs in phonto.scope", sys.ours()[1].unit == "phonto.scope")
  h.ipc("pause")
  h.check("systemd pause freezes the scope", sys.units["phonto.scope"].frozen)
  h.pick("DP-1", "/v/a.mp4")
  expect("restart a frozen scope", "/usr/bin/phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/z.mp4", both)
  h.config.nice = nil
  h.setConfig("run_as_systemd", false)
  expect("systemd -> plain", "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/z.mp4", both)

  -- Noctalia restarts
  onExit(15)
  h.flush()
  expect("onExit stops phonto", nil, both) -- the host wallpaper stays hidden until the next boot
  h.boot()
  expect("boot after a clean exit", "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/z.mp4", both)
  h.ipc("pause")
  h.boot() -- Noctalia died without onExit and left a frozen phonto behind
  expect("boot with a frozen survivor", "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/z.mp4", both)

  -- Upgrades from the per-output layout of v0.2.0
  local function legacyBoot(label, state, setup, cmdline, covered)
    for i = #sys.procs, 1, -1 do
      if not sys.procs[i].user then table.remove(sys.procs, i) end
    end
    setup()
    h.writeState(state)
    h.boot()
    expect(label, cmdline, covered)
  end
  legacyBoot("upgrade from per-output processes",
    { assignments = { ["DP-1"] = "/v/a.mp4", ["HDMI-A-1"] = "/v/b.mp4" }, launchedAsSystemd = { ["DP-1"] = false, ["HDMI-A-1"] = false } },
    function()
      sys.spawn({ "phonto", "--display", "DP-1", "/v/a.mp4" })
      sys.spawn({ "phonto", "--display", "HDMI-A-1", "/v/b.mp4" }).stopped = true
    end,
    "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/b.mp4", both)
  legacyBoot("upgrade from per-output scopes",
    { assignments = { ["DP-1"] = "/v/a.mp4", ["HDMI-A-1"] = "/v/b.mp4" }, launchedAsSystemd = { ["DP-1"] = true, ["HDMI-A-1"] = true } },
    function()
      sys.units["phonto-DP-1.scope"] = { live = true, frozen = true }
      sys.spawn({ "/usr/bin/phonto", "--display", "DP-1", "/v/a.mp4" }, "phonto-DP-1.scope")
      sys.units["phonto-HDMI-A-1.scope"] = { live = true, frozen = false }
      sys.spawn({ "/usr/bin/phonto", "--display", "HDMI-A-1", "/v/b.mp4" }, "phonto-HDMI-A-1.scope")
    end,
    "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/b.mp4", both)
  legacyBoot("upgrade from an all-outputs scope",
    { assignments = { ["*"] = "/v/m.mp4" }, launchedAsSystemd = { ["*"] = true } },
    function()
      sys.units["phonto.scope"] = { live = true, frozen = false }
      sys.spawn({ "/usr/bin/phonto", "/v/m.mp4" }, "phonto.scope")
    end,
    "phonto /v/m.mp4", both)

  -- ── Regression tests for docs/known_issues.md ──────────────────────────────
  local CACHE = "/h/.cache/noctalia/phonto/"
  local twoVideos = "phonto --display DP-1 /v/a.mp4 --display HDMI-A-1 /v/b.mp4"
  h.command("clear-all")
  h.pick("DP-1", "/v/a.mp4")
  h.pick("HDMI-A-1", "/v/b.mp4")

  -- #1 A phonto that fails at startup or dies later must not leave the outputs black.
  local notes = #h.notifications
  h.pick("DP-1", "/v/broken/x.mp4")
  expect("#1 launch failure", nil, {}) -- host wallpaper back on every output
  h.check("#1 launch failure is reported", #h.notifications == notes + 1)
  h.check("#1 assignment kept for a retry", h.readState().assignments["DP-1"] == "/v/broken/x.mp4")
  h.pick("DP-1", "/v/a.mp4")
  expect("#1 retry after a launch failure", twoVideos, both)
  h.tick(12)
  expect("#1 a healthy phonto survives the liveness checks", twoVideos, both)
  sys.crash()
  h.tick(5)
  expect("#1 crash after startup", nil, {})
  h.check("#1 crash is reported", #h.notifications == notes + 2)
  h.ipc("reapply")
  expect("#1 reapply after a crash", twoVideos, both)

  if mode == "deferred" then
    -- A newly selected video may not have a thumbnail yet. Keep the existing
    -- host wallpaper visible until the replacement process passes its check.
    thumbnailsCached = false
    h.watchers.command({ action = "set", connector = "DP-1", path = "/v/uncached.mp4" })
    h.expectHost("#1 restart without cached thumbnails keeps the host visible", {})
    h.flush()
    expect("#1 uncached video starts", "phonto --display DP-1 /v/uncached.mp4 --display HDMI-A-1 /v/b.mp4", both)
    thumbnailsCached = true
    h.pick("DP-1", "/v/a.mp4")
  end

  -- #2 A restart resumes playback, and the panel has to show that.
  h.ipc("pause")
  h.setConfig("nice", 0) -- any config change restarts phonto
  h.check("#2 restart by config change resumes playback", not sys.ours()[1].stopped)
  h.check("#2 ... and the panel no longer shows paused", next(h.published.paused) == nil)
  h.ipc("pause")
  h.plug({ "DP-1" })
  h.check("#2 restart by unplugging resumes playback", not sys.ours()[1].stopped)
  h.check("#2 ... and the panel no longer shows paused", next(h.published.paused) == nil)
  h.ipc("pause")
  h.plug({})
  h.check("#2 a restart that only stops phonto clears the paused panel too", next(h.published.paused) == nil)
  h.plug({ "DP-1", "HDMI-A-1" })
  expect("#2 replug", twoVideos, both)

  -- #3 A pause requested while phonto restarts must not be lost, nor stop the new
  -- process before its first frame.
  if mode == "deferred" then
    local changed = "phonto --display DP-1 /v/c.mp4 --display HDMI-A-1 /v/b.mp4"
    h.watchers.command({ action = "set", connector = "DP-1", path = "/v/c.mp4" })
    onIpc("pause") -- the old process is still being stopped
    h.check("#3 the panel shows the requested pause right away", h.published.paused["DP-1"] == true)
    h.flush()
    expect("#3 pause while stopping the old process", changed, both)
    h.check("#3 ... is applied to the new process", sys.ours()[1].stopped == true)
    h.ipc("resume")
    h.check("#3 resume", not sys.ours()[1].stopped and next(h.published.paused) == nil)

    local execs = sys.execs
    h.watchers.command({ action = "set", connector = "DP-1", path = "/v/a.mp4" })
    while sys.execs == execs and h.step() do end -- launched, startup check pending
    onIpc("pause")
    -- A real SIGSTOP would land at once, long before the 0.8 s startup check.
    local stopIssued = false
    for _, job in ipairs(h.queue) do stopIssued = stopIssued or job.cmd:find("pkill -STOP", 1, true) ~= nil end
    h.check("#3 pause before the startup check waits for it", not stopIssued)
    h.flush()
    expect("#3 pause before the startup check", twoVideos, both)
    h.check("#3 ... is applied once phonto is up", sys.ours()[1].stopped == true)
    h.ipc("toggle")
    h.check("#3 toggle resumes", not sys.ours()[1].stopped)
  end

  -- #4 Thumbnails of different videos never share a cache file.
  local panelPath = SERVICE:gsub("phonto_service%.luau$", "panel.luau")
  local svcBlock, svcQuote = H.sharedCode(SERVICE)
  local panelBlock, panelQuote = H.sharedCode(panelPath)
  h.check("#4 service and panel carry the same shared code", svcBlock ~= nil and svcBlock == panelBlock)
  h.check("#4 ... and the same shellQuote", svcQuote ~= nil and svcQuote == panelQuote)
  local thumbName = H.loadShared(SERVICE)
  h.check("#4 CJK names no longer collide", thumbName("/v/天空.mp4") ~= thumbName("/v/大海.mp4"))
  h.check("#4 names are stable and file-system safe",
    thumbName("/v/天空.mp4") == thumbName("/v/天空.mp4") and thumbName("/v/天空.mp4"):match("^%x+%.jpg$") ~= nil)
  h.pick("DP-1", "/v/天空.mp4")
  h.pick("HDMI-A-1", "/v/大海.mp4")
  h.check("#4 restart cover uses each video's own thumbnail",
    h.hostImage["DP-1"] == CACHE .. thumbName("/v/天空.mp4") and h.hostImage["HDMI-A-1"] == CACHE .. thumbName("/v/大海.mp4"),
    tostring(h.hostImage["DP-1"]) .. " / " .. tostring(h.hostImage["HDMI-A-1"]))

  -- #5 IPC `clear <connector>` on an all-outputs wallpaper stops just that output.
  h.pick("*", "/v/m.mp4")
  sys.ffmpeg = {}
  h.ipc("clear", "HDMI-A-1")
  expect("#5 clear one output of an all-outputs wallpaper", "phonto --display DP-1 /v/m.mp4", { "DP-1" })
  h.check("#5 ... with a static frame for it", sys.ffmpeg[1] == "/v/m.mp4" and h.hostImage["HDMI-A-1"] == CACHE .. "HDMI-A-1_static.jpg")
  local state = h.readState().assignments
  h.check("#5 ... and the rest kept as per-output assignments", state["*"] == nil and state["DP-1"] == "/v/m.mp4")
  h.pick("*", "/v/m.mp4")
  local before = pid()
  h.ipc("clear", "DP-9")
  expect("#5 clearing an absent output changes nothing", "phonto /v/m.mp4", both)
  h.check("#5 ... not even a restart", pid() == before)

  -- #6 Static frames of videos shorter than 1 s, and no stale frames.
  h.pick("DP-1", "/v/short.mp4")
  h.ipc("clear", "DP-1")
  h.check("#6 static frame of a short video", h.hostImage["DP-1"] == CACHE .. "DP-1_static.jpg" and sys.fs[CACHE .. "DP-1_static.jpg"],
    tostring(h.hostImage["DP-1"]))
  h.pick("DP-1", "/v/broken/y.mp4")
  h.hostImage["DP-1"] = nil
  h.ipc("clear", "DP-1")
  h.check("#6 a failed extraction never shows the previous static frame",
    h.hostImage["DP-1"] == nil and not sys.fs[CACHE .. "DP-1_static.jpg"] and h.host["DP-1"] == true)

  return h.summary("service logic (" .. mode .. ")")
end

local ok = suite("deferred")
ok = suite("sync") and ok
os.exit(ok and 0 or 1)
