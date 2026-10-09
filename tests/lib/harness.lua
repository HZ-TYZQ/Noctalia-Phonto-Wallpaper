-- Shared harness for the phonto_service.luau tests: a fake `noctalia` host API
-- plus small assertion helpers. Each suite supplies the executor that decides
-- what a runAsync shell command actually does (simulated or real).

local H = {}

local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- The code block both phonto_service.luau and panel.luau carry (the sandbox has no
-- `require`), and their shellQuote, which the block uses.
function H.sharedCode(path)
  local src = readFile(path)
  local block = src:match("(%-%- ── Shared by phonto_service%.luau and panel%.luau.-%-%- ── End of shared code ──)")
  local quote = src:match("(local function shellQuote%(s%)\n.-\nend)")
  return block, quote
end

-- Loads the shared block on its own; returns its thumbName and frameCommand.
function H.loadShared(path)
  local block, quote = H.sharedCode(path)
  local chunk = quote .. "\n" .. block .. "\nreturn thumbName, frameCommand"
  return assert((loadstring or load)(chunk, "@shared"))()
end

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = deepcopy(x) end
  return t
end

-- opts:
--   service          path to phonto_service.luau
--   exec(cmd)        runs one runAsync command, returns success
--   env              values for noctalia.getenv (HOME, XDG_STATE_HOME, XDG_CACHE_HOME)
--   outputs          initial output names
--   sync             run commands as soon as they are issued instead of queueing them
--   fileExists(p)    optional, defaults to a real filesystem check
--   transformSource  optional, rewrites the service source before loading it
function H.new(opts)
  local h = {
    outputs = opts.outputs,
    config = {},
    host = {},      -- output -> host wallpaper enabled
    hostImage = {}, -- output -> host wallpaper image
    published = {}, -- noctalia.state values
    files = {},
    watchers = {},
    queue = {},
    notifications = {}, -- noctalia.notifyError messages
    failures = 0,
    passes = 0,
  }
  local jsonStore, jsonN = {}, 0
  local stateFile = opts.env.XDG_STATE_HOME .. "/noctalia/phonto/assignments.json"

  local function run(cmd, cb)
    local ok = opts.exec(cmd)
    if cb then cb(ok) end
  end

  noctalia = {
    setUpdateInterval = function() end,
    getenv = function(k) return opts.env[k] end,
    getConfig = function(k) return h.config[k] end,
    runAsync = function(cmd, cb)
      if opts.sync then run(cmd, cb) else h.queue[#h.queue + 1] = { cmd = cmd, cb = cb } end
    end,
    writeFile = function(p, c) h.files[p] = c end,
    readFile = function(p) return h.files[p] end,
    fileExists = opts.fileExists or function(p)
      local f = io.open(p, "rb")
      if f then f:close() end
      return f ~= nil
    end,
    -- Values round-trip through a store (deep copies), like a real encode/decode.
    json = {
      encode = function(t)
        jsonN = jsonN + 1
        jsonStore[jsonN] = deepcopy(t)
        return "json#" .. jsonN
      end,
      decode = function(s)
        local n = tonumber(s:match("^json#(%d+)$"))
        return n and deepcopy(jsonStore[n])
      end,
    },
    state = {
      set = function(k, v) h.published[k] = deepcopy(v) end,
      watch = function(k, fn) h.watchers[k] = fn end,
    },
    outputs = function()
      local list = {}
      for i, name in ipairs(h.outputs) do list[i] = { name = name } end
      return list
    end,
    commandExists = function() return true end,
    log = function() end,
    notifyError = function(_, message) h.notifications[#h.notifications + 1] = message end,
    setWallpaper = function(name, path) h.hostImage[name] = path end,
    setWallpaperEnabled = function(name, on) h.host[name] = on end,
  }

  -- Runs the oldest queued runAsync command and its callback; false when idle.
  function h.step()
    local job = table.remove(h.queue, 1)
    if not job then return false end
    run(job.cmd, job.cb)
    return true
  end

  -- Runs queued runAsync commands (and the ones their callbacks issue) in order.
  function h.flush()
    local n = 0
    while #h.queue > 0 do
      local job = table.remove(h.queue, 1)
      run(job.cmd, job.cb)
      n = n + 1
      assert(n < 10000, "runaway runAsync queue")
    end
  end

  -- Loads the service and runs its boot, like a Noctalia (re)start. The state file
  -- written by a previous boot is kept.
  function h.boot()
    local f = assert(io.open(opts.service, "rb"))
    local src = f:read("*a")
    f:close()
    if opts.transformSource then src = opts.transformSource(src) end
    assert((loadstring or load)(src, "@phonto_service.luau"))()
    h.flush()
  end

  -- Host events, each followed by running the commands they cause.
  function h.pick(connector, path)
    h.watchers.command({ action = "set", connector = connector, path = path })
    h.flush()
  end
  function h.command(action, connector)
    h.watchers.command({ action = action, connector = connector })
    h.flush()
  end
  function h.ipc(event, payload)
    onIpc(event, payload)
    h.flush()
  end
  function h.plug(names)
    h.outputs = names
    onOutputsChanged()
    h.flush()
  end
  function h.setConfig(key, value)
    h.config[key] = value
    onConfigChanged(key, value)
    h.flush()
  end
  -- Lets `seconds` of the host's 1 s update() ticks pass.
  function h.tick(seconds)
    for _ = 1, seconds do
      update()
      h.flush()
    end
  end

  -- Writes a state file as an earlier plugin version would have left it.
  function h.writeState(state)
    jsonN = jsonN + 1
    jsonStore[jsonN] = deepcopy(state)
    h.files[stateFile] = "json#" .. jsonN
  end
  function h.readState()
    return noctalia.json.decode(h.files[stateFile] or "")
  end

  -- Prints failures (and passes with TEST_VERBOSE=1).
  function h.check(label, cond, detail)
    if not cond then
      print("FAIL " .. label .. (detail and ("  [" .. detail .. "]") or ""))
    elseif os.getenv("TEST_VERBOSE") == "1" then
      print("PASS " .. label)
    end
    if cond then h.passes = h.passes + 1 else h.failures = h.failures + 1 end
    return cond
  end

  -- The host wallpaper must be hidden exactly on the outputs phonto covers.
  function h.expectHost(label, covered)
    local cov = {}
    for _, name in ipairs(covered) do cov[name] = true end
    local bad = {}
    for _, name in ipairs(h.outputs) do
      if h.host[name] ~= not cov[name] then bad[#bad + 1] = name .. "=" .. tostring(h.host[name]) end
    end
    h.check(label .. ": host wallpaper hidden exactly on covered outputs", #bad == 0, table.concat(bad, ", "))
  end

  function h.summary(name)
    print(string.format("%s: %d passed, %d failed", name, h.passes, h.failures))
    return h.failures == 0
  end

  return h
end

return H
