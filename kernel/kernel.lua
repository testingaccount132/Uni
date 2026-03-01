-- UniOS Kernel  v1.1
-- Initialises all subsystems in dependency order, then hands off to PID 1.

local k = {}
_G.kernel = k

-- ── Version ───────────────────────────────────────────────────────────────────

k.VERSION   = "UniOS 1.0"
k.RELEASE   = "1.0.1"
k.CODENAME  = "Helix"
k.root_fs   = _G._root_fs
k.boot_addr = _G._root_addr

-- ── GPU helper (used early before drivers load) ───────────────────────────────
-- Returns a raw gpu proxy or nil.  Result is cached after first call.

local _gpu_cache = false   -- false = not yet resolved; nil = no GPU
local function gpu()
  if _gpu_cache ~= false then return _gpu_cache end
  for a in component.list("gpu") do
    local g = component.proxy(a)
    for s in component.list("screen") do g.bind(s); break end
    _gpu_cache = g
    return g
  end
  _gpu_cache = nil
  return nil
end

-- ── Kernel log ────────────────────────────────────────────────────────────────

local _klog   = {}
local _println = _G._println   -- injected by BIOS; may be nil

local LEVEL_COLORS = {
  INFO  = 0x4A9AFF,
  WARN  = 0xFFAA00,
  ERR   = 0xFF5555,
  PANIC = 0xFF0000,
}

function k.log(level, msg)
  local ts   = computer.uptime()
  local line = string.format("[%5.2f] %-5s %s", ts, level, tostring(msg))
  _klog[#_klog + 1] = { ts = ts, level = level, msg = tostring(msg) }
  if _println then
    _println(line, LEVEL_COLORS[level])
  end
end

function k.info(m)  k.log("INFO",  m) end
function k.warn(m)  k.log("WARN",  m) end
function k.err(m)   k.log("ERR",   m) end

--- Kernel panic: log, render full-screen error, halt forever.
function k.panic(m)
  k.log("PANIC", m)
  pcall(function()
    local g = gpu()
    if not g then return end
    local w, h = g.maxResolution()
    g.setResolution(w, h)

    -- Red header bar
    g.setBackground(0xAA0000); g.setForeground(0xFFFFFF)
    g.fill(1, 1, w, h, " ")
    g.fill(1, 1, w, 1, "█")
    g.fill(1, h, w, 1, "█")

    local title = "  KERNEL PANIC  "
    g.set(math.floor((w - #title) / 2) + 1, 1, title)

    -- Error body
    g.setBackground(0x0A0000); g.setForeground(0xFF5555)
    g.fill(1, 2, w, h - 2, " ")

    local row = 3
    for ln in (tostring(m) .. "\n"):gmatch("([^\n]*)\n") do
      g.set(3, row, ln:sub(1, w - 4))
      row = row + 1
      if row >= h - 2 then break end
    end

    -- Kernel log tail (last few entries)
    if #_klog > 0 then
      row = row + 1
      g.setForeground(0x884444)
      g.set(3, row, string.rep("─", w - 4)); row = row + 1
      local start = math.max(1, #_klog - (h - row - 2))
      for i = start, #_klog do
        local e = _klog[i]
        g.set(3, row, string.format("[%5.2f] %s", e.ts, e.msg):sub(1, w-4))
        row = row + 1
        if row >= h - 1 then break end
      end
    end

    g.setForeground(0x666666)
    g.set(3, h - 1, "System halted.  Reboot to recover.")
  end)
  while true do computer.pullSignal(1) end
end

--- Return a snapshot of the kernel log.
function k.klog() return _klog end

-- ── Module loader ─────────────────────────────────────────────────────────────

local _loaded = { kernel = k }

function k.require(mod)
  if _loaded[mod] ~= nil then return _loaded[mod] end

  local path = "/" .. mod:gsub("%.", "/") .. ".lua"
  local h, open_err = k.root_fs.open(path, "r")
  if not h then
    error(string.format("require '%s': not found (%s)", mod, open_err), 2)
  end

  local src = ""
  repeat
    local chunk = k.root_fs.read(h, math.huge)
    if chunk then src = src .. chunk end
  until not chunk
  k.root_fs.close(h)

  local fn, parse_err = load(src, "=" .. mod, "t", _G)
  if not fn then
    error(string.format("require '%s': parse error: %s", mod, parse_err), 2)
  end

  local ok2, result = xpcall(fn, function(e)
    return debug and debug.traceback(e, 2) or tostring(e)
  end)
  if not ok2 then
    error(string.format("require '%s': runtime error: %s", mod, result), 2)
  end

  _loaded[mod] = result ~= nil and result or true
  return _loaded[mod]
end

_G.require = k.require

-- ── Boot sequence ─────────────────────────────────────────────────────────────

local boot_start = computer.uptime()

k.info(k.VERSION .. " (" .. k.CODENAME .. ") starting")
k.info("Boot device: " .. tostring(k.boot_addr):sub(1, 12) .. "...")
k.info(string.format("Free memory: %dK / %dK",
  math.floor(computer.freeMemory() / 1024),
  math.floor(computer.totalMemory() / 1024)))

-- load_subsystem: require a module, optionally call an init function.
-- Panics with a descriptive message on any failure.
local function load_subsystem(name, mod_path, init_fn)
  k.info("Load " .. name)
  local ok2, result = pcall(k.require, mod_path)
  if not ok2 then
    k.panic("Failed to load " .. name .. ":\n" .. tostring(result))
  end
  if init_fn then
    local ok3, err3 = pcall(init_fn, result)
    if not ok3 then
      k.panic("Failed to init " .. name .. ":\n" .. tostring(err3))
    end
  end
  k.info("OK   " .. name)
  return result
end

-- 1. VFS
k.vfs = load_subsystem("VFS", "fs.vfs",
  function(m) m.init(k.root_fs, k.boot_addr) end)

-- 2. devfs → /dev
k.devfs = load_subsystem("devfs", "fs.devfs", function(m)
  m.init()
  k.vfs.mount("/dev", m)
end)

-- 3. tmpfs → /tmp
k.tmpfs = load_subsystem("tmpfs", "fs.tmpfs")
k.vfs.mount("/tmp", k.tmpfs.new())

-- 4. Drivers
k.drivers = {}
k.drivers.gpu      = load_subsystem("driver:gpu",      "drivers.gpu",      function(m) m.init() end)
k.drivers.keyboard = load_subsystem("driver:keyboard", "drivers.keyboard", function(m) m.init() end)
k.drivers.disk     = load_subsystem("driver:disk",     "drivers.disk",     function(m) m.init() end)
k.drivers.tty      = load_subsystem("driver:tty",      "drivers.tty",      function(m) m.init() end)
k.drivers.pty      = load_subsystem("driver:pty",      "drivers.pty",      function(m) m.init() end)

-- GPU is now managed by the driver; clear the early cache so driver owns it
_gpu_cache = false

-- 5. Kernel subsystems
k.process   = load_subsystem("process",   "kernel.process",   function(m) m.init() end)
k.scheduler = load_subsystem("scheduler", "kernel.scheduler", function(m) m.init() end)
k.signal    = load_subsystem("signal",    "kernel.signal",    function(m) m.init() end)
k.syscall   = load_subsystem("syscall",   "kernel.syscall",   function(m) m.init() end)

-- 5b. Populate os.* for compatibility (OpenOS scripts expect os.sleep etc.)
_G.os = _G.os or {}
function os.sleep(n)
  computer.pullSignal(n or 0)
end
function os.clock()
  return computer.uptime()
end
function os.time()
  return math.floor(computer.uptime())
end
function os.exit(code)
  error({_exit = code or 0})
end
function os.tmpname()
  return "/tmp/.lua_" .. tostring(math.floor(computer.uptime() * 1000))
end

-- 6. Standard libraries (non-fatal if missing)
for _, lib in ipairs({ "lib.libc", "lib.libio", "lib.libpath", "lib.libterm", "lib.pkg" }) do
  local ok2, err2 = pcall(k.require, lib)
  if ok2 then
    k.info("lib  " .. lib)
  else
    k.warn("lib  " .. lib .. " FAILED: " .. tostring(err2))
  end
end

-- 7. /etc/rc
k.info("Running /etc/rc")
local rc_src = k.vfs.readfile("/etc/rc")
if rc_src then
  local fn, rc_err = load(rc_src, "=/etc/rc", "t", _G)
  if fn then
    local ok2, err2 = xpcall(fn, function(e)
      return debug and debug.traceback(e, 2) or tostring(e)
    end)
    if not ok2 then k.warn("/etc/rc error: " .. tostring(err2)) end
  else
    k.warn("/etc/rc parse error: " .. tostring(rc_err))
  end
else
  k.warn("/etc/rc not found (non-fatal)")
end

-- 8. Hostname
local _hostname = (k.vfs.readfile("/etc/hostname") or "uni"):match("^%s*(.-)%s*$") or "uni"

-- 9. Spawn PID 1
k.info("Spawning PID 1")
local pid1_paths = { "/sbin/init.lua", "/bin/sh.lua" }
local pid1_src, pid1_path

for _, p in ipairs(pid1_paths) do
  pid1_src = k.vfs.readfile(p)
  if pid1_src then pid1_path = p; break end
end

if not pid1_src then
  k.panic("No PID-1 candidate found.\nTried: " .. table.concat(pid1_paths, ", "))
end

k.info("PID 1: " .. pid1_path)

local spawn_ok, spawn_err = pcall(k.process.spawn, pid1_src, "init", {
  uid  = 0, gid = 0,
  cwd  = "/root",
  env  = {
    PATH     = "/bin:/sbin:/usr/bin:/tools",
    HOME     = "/root",
    SHELL    = "/bin/sh",
    TERM     = "uni-vt",
    USER     = "root",
    HOSTNAME = _hostname,
    VERSION  = k.VERSION,
    RELEASE  = k.RELEASE,
  },
})
if not spawn_ok then
  k.panic("Failed to spawn PID 1: " .. tostring(spawn_err))
end

k.info(string.format("Kernel ready in %.2fs.", computer.uptime() - boot_start))
k.scheduler.run()
