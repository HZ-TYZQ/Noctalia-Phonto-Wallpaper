-- Runs phonto_service.luau against real processes: every runAsync command goes
-- through the shell, with fake_phonto (built by run.sh) as `phonto` first on PATH.
-- Covers what the simulation cannot: shell quoting of odd file names, pkill
-- patterns against real /proc command lines, signals, nice, and systemd scopes.
-- The scope name is swapped for $TEST_UNIT, so a real phonto.scope is never touched.
--
-- Usage: PATH=<tmpdir>/bin:$PATH TEST_UNIT=<name>.scope \
--          luajit service_shell.lua <phonto_service.luau> <tmpdir>

local here = arg[0]:match("^(.*)/") or "."
local H = dofile(here .. "/lib/harness.lua")
local SERVICE, ROOT = assert(arg[1]), assert(arg[2])
local UNIT = assert(os.getenv("TEST_UNIT"), "TEST_UNIT is not set")
local VERBOSE = os.getenv("TEST_VERBOSE") == "1"
local FAKE = ROOT .. "/bin/phonto"

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function sh(cmd)
  local r = os.execute(cmd)
  return r == 0 or r == true
end
local function read(cmd)
  local p = assert(io.popen(cmd))
  local s = p:read("*a")
  p:close()
  return (s:gsub("%s+$", ""))
end

-- Test videos (made by run.sh); one gets a name that breaks naive quoting.
local A = ROOT .. "/videos/a.mp4"
local B = ROOT .. "/videos/b.mp4"
local ODD = ROOT .. "/videos/it's a \"test\" $HOME `id` 视频 (1).mp4"
assert(sh("cp " .. q(B) .. " " .. q(ODD)))

-- Every live process running one of the test binaries.
local function processes()
  local list = {}
  for pid in read("pgrep -x 'phonto|xphonto'"):gmatch("%d+") do
    local exe = read("readlink /proc/" .. pid .. "/exe 2>/dev/null")
    local cmdline = io.open("/proc/" .. pid .. "/cmdline", "rb")
    local stat = io.open("/proc/" .. pid .. "/stat", "rb")
    if exe:sub(1, #ROOT + 1) == ROOT .. "/" and cmdline and stat then
      local argv = {}
      for a in cmdline:read("*a"):gmatch("([^%z]*)%z") do argv[#argv + 1] = a end
      local fields = {}
      for x in stat:read("*a"):match("%) (.*)$"):gmatch("%S+") do fields[#fields + 1] = x end
      if fields[1] ~= "Z" then
        list[#list + 1] = {
          pid = tonumber(pid),
          argv = argv,
          state = fields[1],          -- stat field 3: T when stopped
          nice = tonumber(fields[17]), -- stat field 19
          user = exe ~= FAKE,
          cgroup = read("cat /proc/" .. pid .. "/cgroup 2>/dev/null"),
        }
      end
    end
    if cmdline then cmdline:close() end
    if stat then stat:close() end
  end
  return list
end
local function ours()
  local list = {}
  for _, p in ipairs(processes()) do
    if not p.user then list[#list + 1] = p end
  end
  return list
end
local function describe(list)
  local out = {}
  for _, p in ipairs(list or {}) do
    out[#out + 1] = table.concat(p.argv, " ") .. " (" .. p.state .. ")"
  end
  return table.concat(out, " | ")
end
local function waitFor(fn)
  for _ = 1, 100 do
    if fn() then return true end
    os.execute("sleep 0.05")
  end
  return false
end
local function unitProp(unit, prop)
  return read("systemctl --user show -p " .. prop .. " --value " .. q(unit) .. " 2>/dev/null")
end

local h = H.new({
  service = SERVICE,
  exec = function(cmd)
    if VERBOSE then print("  $ " .. cmd) return sh(cmd) end
    return sh("{ " .. cmd .. "\n} >/dev/null 2>&1")
  end,
  env = { HOME = ROOT .. "/home", XDG_STATE_HOME = ROOT .. "/state", XDG_CACHE_HOME = ROOT .. "/cache" },
  outputs = { "TEST-1", "TEST-2" },
  transformSource = function(src)
    local out, n = src:gsub('local UNIT_NAME = "phonto%.scope"', 'local UNIT_NAME = "' .. UNIT .. '"')
    assert(n == 1, "UNIT_NAME constant not found; refusing to risk the real phonto.scope")
    return out
  end,
})
h.config.extract_last_frame = true

-- Expects exactly one phonto process running `phonto <tail...>` (or none), and the
-- host wallpaper hidden exactly on `covered`. Returns the process.
local function expect(label, tail, covered)
  local list
  local ok = waitFor(function()
    list = ours()
    if tail == nil then return #list == 0 end
    if #list ~= 1 or list[1].argv[1]:match("[^/]*$") ~= "phonto" or #list[1].argv ~= #tail + 1 then return false end
    for i, a in ipairs(tail) do
      if list[1].argv[i + 1] ~= a then return false end
    end
    return true
  end)
  h.check(label .. (tail and ": exactly one phonto process" or ": no phonto process"), ok, describe(list))
  h.expectHost(label, covered)
  local lookalikes = 0
  for _, p in ipairs(processes()) do
    if p.user then lookalikes = lookalikes + 1 end
  end
  h.check(label .. ": look-alike processes untouched", lookalikes == 2)
  return list and list[1]
end

local function killOurs()
  for _, p in ipairs(ours()) do sh("kill -CONT " .. p.pid .. " ; kill -KILL " .. p.pid) end
  waitFor(function() return #ours() == 0 end)
end

local function cleanup()
  for _, p in ipairs(processes()) do sh("kill -CONT " .. p.pid .. " ; kill -KILL " .. p.pid .. " 2>/dev/null") end
  for _, u in ipairs({ UNIT, "phonto-TEST-1.scope", "phonto-TEST-2.scope" }) do
    sh("systemctl --user thaw " .. q(u) .. " >/dev/null 2>&1 ; systemctl --user stop " .. q(u) .. " >/dev/null 2>&1")
  end
end

local function scenarios()
  local both = { "TEST-1", "TEST-2" }

  -- Processes a user could have started by hand: same name with extra flags, and
  -- a name that merely ends in "phonto". Neither may ever be killed.
  assert(sh("mkdir -p " .. q(ROOT .. "/user") .. " && cp " .. q(FAKE) .. " " .. q(ROOT .. "/user/phonto") ..
    " && cp " .. q(FAKE) .. " " .. q(ROOT .. "/user/xphonto")))
  sh(q(ROOT .. "/user/phonto") .. " --display TEST-1 " .. q(A) .. " --scale fit >/dev/null 2>&1 &")
  sh(q(ROOT .. "/user/xphonto") .. " --display TEST-1 " .. q(A) .. " >/dev/null 2>&1 &")

  h.boot()
  expect("boot with no state", nil, {})

  h.pick("TEST-1", A)
  expect("one output", { "--display", "TEST-1", A }, { "TEST-1" })
  h.pick("TEST-2", ODD)
  local p = expect("two outputs, odd file name", { "--display", "TEST-1", A, "--display", "TEST-2", ODD }, both)
  h.pick("TEST-2", ODD)
  local again = expect("re-apply", { "--display", "TEST-1", A, "--display", "TEST-2", ODD }, both)
  h.check("re-applying the current video restarts it", p and again and p.pid ~= again.pid)

  -- Pause is global: SIGSTOP/SIGCONT on the one process.
  h.command("freeze", "TEST-2")
  h.check("pause stops the process", waitFor(function() local o = ours() return o[1] and o[1].state == "T" end), describe(ours()))
  h.command("thaw", "TEST-1")
  h.check("resume continues it", waitFor(function() local o = ours() return o[1] and o[1].state ~= "T" end), describe(ours()))
  h.ipc("pause")
  h.pick("TEST-1", B)
  p = expect("restart while paused (SIGTERM needs SIGCONT first)", { "--display", "TEST-1", B, "--display", "TEST-2", ODD }, both)
  h.check("restart resumes playback", p and p.state ~= "T", describe(ours()))

  -- Clearing an output extracts a real static frame from the odd file name.
  h.command("clear", "TEST-2")
  expect("clear one output", { "--display", "TEST-1", B }, { "TEST-1" })
  local static = ROOT .. "/cache/noctalia/phonto/TEST-2_static.jpg"
  h.check("static frame extracted for the cleared output",
    h.hostImage["TEST-2"] == static and noctalia.fileExists(static), tostring(h.hostImage["TEST-2"]))

  h.pick("*", A)
  expect("all outputs", { A }, both)
  h.command("clear-all")
  expect("clear-all", nil, {})
  h.ipc("reapply")
  expect("reapply", { A }, both)

  h.setConfig("nice", 5)
  p = expect("nice", { A }, both)
  h.check("nice value applied", p and p.nice == 5, p and tostring(p.nice))

  if sh("systemd-run --user --scope --quiet true >/dev/null 2>&1") then
    h.config.cpu_quota = 50
    h.setConfig("run_as_systemd", true)
    p = expect("systemd mode", { A }, both)
    h.check("runs in the scope", p and p.cgroup:find("/" .. UNIT, 1, true) ~= nil, p and p.cgroup)
    h.check("CPU quota applied", unitProp(UNIT, "CPUQuotaPerSecUSec") == "500ms", unitProp(UNIT, "CPUQuotaPerSecUSec"))
    h.check("nice applied inside the scope", p and p.nice == 5, p and tostring(p.nice))
    h.ipc("pause")
    h.check("pause freezes the scope", unitProp(UNIT, "FreezerState") == "frozen", unitProp(UNIT, "FreezerState"))
    h.pick("TEST-1", A)
    p = expect("restart a frozen scope", { "--display", "TEST-1", A }, { "TEST-1" })
    h.check("new process in a running scope",
      p and p.cgroup:find("/" .. UNIT, 1, true) ~= nil and unitProp(UNIT, "FreezerState") == "running")
    h.config.cpu_quota = nil
    h.setConfig("run_as_systemd", false)
    p = expect("systemd -> plain", { "--display", "TEST-1", A }, { "TEST-1" })
    h.check("scope gone after leaving systemd mode",
      p and p.cgroup:find("/" .. UNIT, 1, true) == nil and unitProp(UNIT, "ActiveState") ~= "active")
  else
    print("SKIP systemd checks: systemd-run --user --scope is unavailable")
  end
  h.setConfig("nice", 0)

  -- Noctalia restarts
  h.pick("TEST-2", ODD)
  local tail = { "--display", "TEST-1", A, "--display", "TEST-2", ODD }
  onExit(15)
  h.flush()
  expect("onExit stops phonto", nil, both)
  h.boot()
  expect("boot after a clean exit", tail, both)
  h.ipc("pause")
  h.boot() -- Noctalia died without onExit and left a stopped phonto behind
  p = expect("boot with a stopped survivor", tail, both)
  h.check("survivor replaced by a running process", p and p.state ~= "T")

  -- Upgrades from the per-output layout of v0.2.0
  killOurs()
  sh("exec phonto --display TEST-1 " .. q(A) .. " >/dev/null 2>&1 &")
  sh("exec phonto --display TEST-2 " .. q(ODD) .. " >/dev/null 2>&1 &")
  waitFor(function() return #ours() == 2 end)
  for _, x in ipairs(ours()) do
    if x.argv[3] == "TEST-2" then sh("kill -STOP " .. x.pid) end
  end
  h.writeState({ assignments = { ["TEST-1"] = A, ["TEST-2"] = ODD }, launchedAsSystemd = { ["TEST-1"] = false, ["TEST-2"] = false } })
  h.boot()
  expect("upgrade from per-output processes", tail, both)

  if sh("systemd-run --user --scope --quiet true >/dev/null 2>&1") then
    killOurs()
    sh("systemd-run --user --scope --quiet --unit=phonto-TEST-1.scope phonto --display TEST-1 " .. q(A) .. " >/dev/null 2>&1 &")
    sh("systemd-run --user --scope --quiet --unit=phonto-TEST-2.scope phonto --display TEST-2 " .. q(ODD) .. " >/dev/null 2>&1 &")
    waitFor(function() return #ours() == 2 end)
    sh("systemctl --user freeze phonto-TEST-1.scope")
    h.writeState({ assignments = { ["TEST-1"] = A, ["TEST-2"] = ODD }, launchedAsSystemd = { ["TEST-1"] = true, ["TEST-2"] = true } })
    h.boot()
    expect("upgrade from per-output scopes", tail, both)
    h.check("old per-output scopes stopped",
      unitProp("phonto-TEST-1.scope", "ActiveState") ~= "active" and unitProp("phonto-TEST-2.scope", "ActiveState") ~= "active")
  end

  -- ── Regression tests for docs/known_issues.md ──────────────────────────────
  local CACHE = ROOT .. "/cache/noctalia/phonto/"
  local thumbName, frameCommand = H.loadShared(SERVICE)
  h.command("clear-all")

  -- #1 A phonto that fails at startup or dies later must not leave the outputs black.
  local BROKEN = ROOT .. "/videos/broken/x.mp4"
  assert(sh("mkdir -p " .. q(ROOT .. "/videos/broken") .. " && cp " .. q(A) .. " " .. q(BROKEN)))
  local notes = #h.notifications
  h.pick("TEST-1", BROKEN)
  expect("#1 launch failure", nil, {}) -- host wallpaper back on every output
  h.check("#1 launch failure is reported", #h.notifications == notes + 1)
  local log = read("cat " .. q(ROOT .. "/state/noctalia/phonto/phonto.log") .. " 2>/dev/null")
  h.check("#1 phonto's error output is kept in phonto.log", log:find("cannot play", 1, true) ~= nil, log)
  h.pick("TEST-1", A)
  p = expect("#1 retry after a launch failure", { "--display", "TEST-1", A }, { "TEST-1" })
  if p then sh("kill -KILL " .. p.pid) end
  h.tick(5)
  expect("#1 crash after startup", nil, {})
  h.check("#1 crash is reported", #h.notifications == notes + 2)

  -- #4 Thumbnails of different videos never share a cache file (generated the way
  -- the panel does, with the shared code).
  local SKY, SEA = ROOT .. "/videos/天空.mp4", ROOT .. "/videos/大海.mp4"
  assert(sh("cp " .. q(A) .. " " .. q(SKY) .. " && cp " .. q(B) .. " " .. q(SEA) .. " && mkdir -p " .. q(CACHE)))
  h.check("#4 thumbnails generated",
    sh(frameCommand(SKY, CACHE .. thumbName(SKY))) and sh(frameCommand(SEA, CACHE .. thumbName(SEA))))
  h.check("#4 two CJK-named videos get two different thumbnails",
    thumbName(SKY) ~= thumbName(SEA) and not sh("cmp -s " .. q(CACHE .. thumbName(SKY)) .. " " .. q(CACHE .. thumbName(SEA))))
  h.pick("TEST-1", SKY)
  h.pick("TEST-2", SEA)
  h.check("#4 restart cover uses each video's own thumbnail",
    h.hostImage["TEST-1"] == CACHE .. thumbName(SKY) and h.hostImage["TEST-2"] == CACHE .. thumbName(SEA),
    tostring(h.hostImage["TEST-1"]) .. " / " .. tostring(h.hostImage["TEST-2"]))

  -- #6 Frames of videos shorter than 1 s, and no stale frames after a failure.
  local static = CACHE .. "TEST-2_static.jpg"
  h.pick("TEST-2", ROOT .. "/videos/short.mp4")
  h.command("clear", "TEST-2")
  h.check("#6 static frame of a 0.4 s video", h.hostImage["TEST-2"] == static and sh("[ -s " .. q(static) .. " ]"),
    tostring(h.hostImage["TEST-2"]))
  local junk = ROOT .. "/videos/not-a-video.mp4"
  assert(sh("echo junk > " .. q(junk)))
  h.check("#6 a failed extraction fails and leaves no stale frame",
    not sh(frameCommand(junk, static)) and not sh("[ -e " .. q(static) .. " ]"))
  h.check("#6 a normal video still extracts", sh(frameCommand(A, static)) and sh("[ -s " .. q(static) .. " ]"))
end

local ok, err = pcall(scenarios)
cleanup()
if not ok then
  print("ERROR " .. tostring(err))
  h.failures = h.failures + 1
end
os.exit(h.summary("service against real processes") and 0 or 1)
