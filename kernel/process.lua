-- UniOS Process Manager
-- UNIX-style process table: fork, spawn, exit, wait.

local process = {}

local _procs  = {}   -- pid → process descriptor
local _next_pid = 1

-- ── Process descriptor ────────────────────────────────────────────────────────

--[[
  proc = {
    pid     : number
    ppid    : number
    name    : string
    thread  : coroutine
    state   : "running"|"sleeping"|"zombie"|"stopped"
    uid     : number
    gid     : number
    cwd     : string
    env     : table
    fds     : table   -- file descriptor table  { [n] = fd_obj }
    exit_code : number | nil
    children  : { pid, ... }
    signals   : { signal_name, ... }  -- pending signals
  }
]]

local function new_proc(name, thread, opts)
  opts = opts or {}
  local pid = _next_pid
  _next_pid = _next_pid + 1
  local proc = {
    pid       = pid,
    ppid      = opts.ppid or 0,
    name      = name,
    thread    = thread,
    state     = "running",
    uid       = opts.uid  or 1000,
    gid       = opts.gid  or 1000,
    cwd       = opts.cwd  or "/",
    env       = opts.env  or {},
    fds       = {},
    exit_code = nil,
    children  = {},
    signals   = {},
    priority  = opts.priority or 10,
    signal_handlers = {},
    _sleep_until = nil,
  }
  -- Standard streams (3 fds: stdin=0, stdout=1, stderr=2)
  -- Set by the spawner; defaults to nil (kernel will wire them up)
  proc.fds[0] = opts.stdin  or nil
  proc.fds[1] = opts.stdout or nil
  proc.fds[2] = opts.stderr or nil
  return proc
end

-- ── API ───────────────────────────────────────────────────────────────────────

function process.init()
  _procs = {}
  _next_pid = 1
  kernel.info("process: ready")
end

--- Spawn a new process from Lua source code string.
function process.spawn(src, name, opts)
  local fn, err = load(src, "=" .. (name or "?"), "t", _G)
  if not fn then
    error("process.spawn: " .. tostring(err), 2)
  end
  local thread = coroutine.create(fn)
  local proc = new_proc(name or "?", thread, opts or {})
  _procs[proc.pid] = proc
  if opts and opts.ppid then
    local parent = _procs[opts.ppid]
    if parent then
      parent.children[#parent.children + 1] = proc.pid
    end
  end
  kernel.info("process: spawned '" .. proc.name .. "' pid=" .. proc.pid)
  return proc
end

--- Fork the current process (call from within a coroutine).
function process.fork(current_pid)
  local parent = _procs[current_pid]
  if not parent then error("fork: no such process " .. tostring(current_pid)) end
  -- Deep-copy env
  local env_copy = {}
  for k, v in pairs(parent.env) do env_copy[k] = v end
  -- The child gets a fresh coroutine running the same function body.
  -- In OC we can't truly fork a coroutine, so we note it symbolically.
  local child = new_proc(parent.name, coroutine.create(function() end), {
    ppid = parent.pid,
    uid  = parent.uid,
    gid  = parent.gid,
    cwd  = parent.cwd,
    env  = env_copy,
  })
  _procs[child.pid] = child
  parent.children[#parent.children + 1] = child.pid
  return child.pid
end

--- Terminate a process.
function process.exit(pid, code)
  local proc = _procs[pid]
  if not proc then return end
  proc.state     = "zombie"
  proc.exit_code = code or 0
  kernel.info("process: pid=" .. pid .. " '" .. proc.name .. "' exited(" .. (code or 0) .. ")")
  -- Re-parent children to PID 1
  for _, cpid in ipairs(proc.children) do
    local child = _procs[cpid]
    if child then child.ppid = 1 end
  end
  -- Signal parent
  if proc.ppid and _procs[proc.ppid] then
    kernel.signal.send(proc.ppid, "SIGCHLD")
  end
end

--- Wait for any child of `pid` to become zombie.
function process.wait(pid)
  local proc = _procs[pid]
  if not proc then return nil end
  for _, cpid in ipairs(proc.children) do
    local child = _procs[cpid]
    if child and child.state == "zombie" then
      local code = child.exit_code
      _procs[cpid] = nil  -- reap
      return cpid, code
    end
  end
  return nil
end

--- Get a process descriptor.
function process.get(pid)
  return _procs[pid]
end

--- List all processes.
function process.list()
  local out = {}
  for pid, p in pairs(_procs) do
    out[#out + 1] = p
  end
  table.sort(out, function(a, b) return a.pid < b.pid end)
  return out
end

--- Kill (send signal) to a pid.
function process.kill(pid, sig)
  local proc = _procs[pid]
  if not proc then return false, "no such process" end
  kernel.signal.send(pid, sig or "SIGTERM")
  return true
end

--- Put process to sleep until `deadline` (computer.uptime()).
function process.sleep(pid, seconds)
  local proc = _procs[pid]
  if not proc then return end
  proc.state       = "sleeping"
  proc._sleep_until = computer.uptime() + seconds
end

--- Called by scheduler each tick to wake sleeping processes.
function process.tick()
  local now = computer.uptime()
  for pid, proc in pairs(_procs) do
    if proc.state == "sleeping" and proc._sleep_until and now >= proc._sleep_until then
      proc.state       = "running"
      proc._sleep_until = nil
    end
  end
end

return process
