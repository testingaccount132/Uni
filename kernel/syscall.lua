-- UniOS System Call Interface
-- Userland code calls kernel.syscall.call(name, ...) to perform
-- privileged operations safely.

local syscall = {}

local _table = {}

local function def(name, fn)
  _table[name] = fn
end

function syscall.init()
  -- ── Process ──────────────────────────────────────────────────────────────────
  def("getpid", function()
    return kernel.scheduler.current_pid()
  end)

  def("getppid", function()
    local pid = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    return proc and proc.ppid or 0
  end)

  def("fork", function()
    return kernel.process.fork(kernel.scheduler.current_pid())
  end)

  def("exit", function(code)
    kernel.process.exit(kernel.scheduler.current_pid(), code or 0)
    coroutine.yield()  -- Don't return to caller
  end)

  def("wait", function()
    return kernel.process.wait(kernel.scheduler.current_pid())
  end)

  def("kill", function(pid, sig)
    return kernel.process.kill(pid, sig)
  end)

  def("sleep", function(sec)
    kernel.process.sleep(kernel.scheduler.current_pid(), sec or 0)
    coroutine.yield({ "sleep", sec })
  end)

  -- ── Environment ───────────────────────────────────────────────────────────────
  def("getenv", function(key)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    if not proc then return nil end
    if key then return proc.env[key] end
    return proc.env
  end)

  def("setenv", function(key, val)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    if proc then proc.env[key] = val end
  end)

  def("getcwd", function()
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    return proc and proc.cwd or "/"
  end)

  def("chdir", function(path)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    if not proc then return false, "no process" end
    local abs = kernel.vfs.resolve(path, proc.cwd)
    if not kernel.vfs.isdir(abs) then
      return false, "not a directory: " .. abs
    end
    proc.cwd = abs
    return true
  end)

  -- ── Filesystem ────────────────────────────────────────────────────────────────
  def("open", function(path, mode)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    if not proc then return nil, "no process" end
    local abs = kernel.vfs.resolve(path, proc.cwd)
    local fd, err = kernel.vfs.open(abs, mode or "r")
    if not fd then return nil, err end
    -- Allocate fd number
    local n = 3
    while proc.fds[n] do n = n + 1 end
    proc.fds[n] = fd
    return n
  end)

  def("close", function(n)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    if not proc then return false end
    local fd = proc.fds[n]
    if not fd then return false, "bad fd" end
    kernel.vfs.close(fd)
    proc.fds[n] = nil
    return true
  end)

  def("read", function(n, count)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    if not proc then return nil end
    local fd = proc.fds[n]
    if not fd then return nil, "bad fd" end
    return kernel.vfs.read(fd, count or math.huge)
  end)

  def("write", function(n, data)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    if not proc then return false end
    local fd = proc.fds[n]
    if not fd then return false, "bad fd" end
    return kernel.vfs.write(fd, data)
  end)

  def("stat", function(path)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    local abs  = kernel.vfs.resolve(path, proc and proc.cwd or "/")
    return kernel.vfs.stat(abs)
  end)

  def("list", function(path)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    local abs  = kernel.vfs.resolve(path, proc and proc.cwd or "/")
    return kernel.vfs.list(abs)
  end)

  def("mkdir", function(path)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    local abs  = kernel.vfs.resolve(path, proc and proc.cwd or "/")
    return kernel.vfs.mkdir(abs)
  end)

  def("remove", function(path)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    local abs  = kernel.vfs.resolve(path, proc and proc.cwd or "/")
    return kernel.vfs.remove(abs)
  end)

  def("rename", function(src, dst)
    local pid  = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    local cwd  = proc and proc.cwd or "/"
    return kernel.vfs.rename(kernel.vfs.resolve(src, cwd), kernel.vfs.resolve(dst, cwd))
  end)

  -- ── Terminal ──────────────────────────────────────────────────────────────────
  def("write_stdout", function(data)
    kernel.drivers.gpu.write(tostring(data))
  end)

  def("read_line", function()
    return kernel.drivers.keyboard.readline()
  end)

  -- ── Spawn (with TTY/PTY support) ───────────────────────────────────────────
  def("spawn", function(path, name, opts)
    opts = opts or {}
    local pid = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    local cwd = (proc and proc.cwd) or "/"
    local abs = kernel.vfs.resolve(path, cwd)
    local src = kernel.vfs.readfile(abs)
    if not src then return nil, "file not found: " .. abs end
    local child = kernel.process.spawn(src, name or abs:match("[^/]+$") or "?", {
      ppid = pid,
      uid  = opts.uid or (proc and proc.uid) or 0,
      gid  = opts.gid or (proc and proc.gid) or 0,
      cwd  = opts.cwd or cwd,
      env  = opts.env or (proc and proc.env) or {},
      stdin  = opts.stdin,
      stdout = opts.stdout,
      stderr = opts.stderr,
    })
    return child.pid
  end)

  -- ── Exec (replace current process) ─────────────────────────────────────────
  def("exec", function(path, args)
    local pid = kernel.scheduler.current_pid()
    local proc = kernel.process.get(pid)
    if not proc then return false, "no process" end
    local abs = kernel.vfs.resolve(path, proc.cwd)
    local src = kernel.vfs.readfile(abs)
    if not src then return false, "file not found: " .. abs end
    local fn, err = load(src, "=" .. abs, "t", _G)
    if not fn then return false, err end
    _G.arg = args or {}
    local ok, result = pcall(fn)
    if not ok then return false, result end
    return true, result
  end)

  -- ── TTY/PTY ────────────────────────────────────────────────────────────────
  def("tty_create", function(id, opts)
    return kernel.drivers.tty.create(id, opts)
  end)

  def("tty_switch", function(id)
    return kernel.drivers.tty.switch(id)
  end)

  def("tty_list", function()
    return kernel.drivers.tty.list()
  end)

  def("pty_create", function(opts)
    local master, slave = kernel.drivers.pty.create(opts)
    return master, slave
  end)

  kernel.info("syscall: " .. (function()
    local n = 0; for _ in pairs(_table) do n = n + 1 end; return n
  end)() .. " syscalls registered")
end

--- Invoke a system call by name.
function syscall.call(name, ...)
  local fn = _table[name]
  if not fn then
    error("syscall: unknown call '" .. tostring(name) .. "'", 2)
  end
  return fn(...)
end

-- Expose as a global convenience
_G.sys = syscall.call

return syscall
