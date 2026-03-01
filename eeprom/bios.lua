-- UniOS BIOS  v1.1
-- Finds a bootable filesystem, loads /boot/init.lua, and transfers control.
-- Must fit within 4 096 bytes when minified (eeprom/bios.min.lua).

local VER       = "UniOS BIOS 1.1"
local BOOT_FILE = "/boot/init.lua"

-- ── Early GPU setup ───────────────────────────────────────────────────────────

local gpu, W, H, row = nil, 80, 25, 3

do
  local g, s
  for a in component.list("gpu")    do g = component.proxy(a); break end
  for a in component.list("screen") do s = component.proxy(a); break end
  if g and s then
    g.bind(s.address)
    W, H = g.maxResolution()
    g.setResolution(W, H)
    g.setBackground(0x050D18); g.setForeground(0xBBCCDD)
    g.fill(1, 1, W, H, " ")
    g.setBackground(0x0D1E30); g.setForeground(0x00B4FF)
    g.fill(1, 1, W, 1, " ")
    g.set(2, 1, VER)
    g.setForeground(0x4A6070); g.set(W - 9, 1, "BIOS boot")
    g.setBackground(0x050D18)
    gpu = g
  end
end

-- ── println ───────────────────────────────────────────────────────────────────

local function println(msg, color)
  if not gpu then return end
  if color then gpu.setForeground(color) end
  if row > H - 1 then
    gpu.copy(1, 2, W, H - 2, 0, -1)
    gpu.setBackground(0x050D18)
    gpu.fill(1, H - 1, W, 1, " ")
    row = H - 1
  end
  gpu.setBackground(0x050D18)
  gpu.set(2, row, tostring(msg))
  gpu.setForeground(0xBBCCDD)
  row = row + 1
end

_G._println = println

-- ── Panic (halt) ──────────────────────────────────────────────────────────────

local function halt(msg)
  if gpu then
    gpu.setBackground(0xAA0000); gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, W, H, " ")
    gpu.set(2, 2, "[ BIOS PANIC ]")
    gpu.setBackground(0x050D18); gpu.setForeground(0xFF5555)
    local r = 4
    for ln in (tostring(msg) .. "\n"):gmatch("([^\n]*)\n") do
      gpu.set(2, r, ln:sub(1, W - 2)); r = r + 1
      if r > H - 2 then break end
    end
    gpu.setForeground(0x4A6070)
    gpu.set(2, H - 1, "System halted.  Check hardware and reboot.")
  end
  while true do computer.pullSignal(1) end
end

-- ── Find boot filesystem ──────────────────────────────────────────────────────

println("Scanning for boot device...", 0x4A6070)

local boot_fs, boot_addr

-- Prefer a filesystem that already has BOOT_FILE
for addr in component.list("filesystem") do
  local fs = component.proxy(addr)
  if fs.exists(BOOT_FILE) then
    boot_fs = fs; boot_addr = addr; break
  end
end

-- Fallback: any writable filesystem
if not boot_fs then
  for addr in component.list("filesystem") do
    local fs = component.proxy(addr)
    if not fs.isReadOnly() then
      boot_fs = fs; boot_addr = addr; break
    end
  end
end

if not boot_fs then
  halt("No bootable filesystem found.\n\nInsert the UniOS disk and reboot.\nRun the installer if this is a fresh install.")
end

println("Boot device: " .. boot_addr:sub(1, 8) .. "...", 0x4A6070)

if not boot_fs.exists(BOOT_FILE) then
  halt("Boot file not found: " .. BOOT_FILE .. "\n\nThe disk does not have UniOS installed.\nRun the installer.")
end

-- ── Read and execute /boot/init.lua ──────────────────────────────────────────

local h, err = boot_fs.open(BOOT_FILE, "r")
if not h then halt("Cannot open " .. BOOT_FILE .. ":\n" .. tostring(err)) end

local src = ""
repeat
  local chunk = boot_fs.read(h, math.huge)
  if chunk then src = src .. chunk end
until not chunk
boot_fs.close(h)

println(string.format("Loaded %s (%d B)", BOOT_FILE, #src), 0x4A6070)

-- Syntax check before executing
local test_fn, syn_err = load(src, "=init", "t")
if not test_fn then
  halt("Syntax error in " .. BOOT_FILE .. ":\n" .. tostring(syn_err))
end

println("Booting " .. VER:gsub("BIOS ", "") .. "...", 0x00B4FF)

-- Hand off: give init access to boot context
local env = setmetatable({}, { __index = _G })
env.boot_fs       = boot_fs
env.boot_addr     = boot_addr
env._BIOS_VERSION = VER
env._UNI_VERSION  = "UniOS 1.0"
env._root_fs      = boot_fs
env._root_addr    = boot_addr

local init_fn = load(src, "=init", "t", env)

local ok, run_err = xpcall(init_fn, function(e)
  return debug and debug.traceback(e, 2) or tostring(e)
end)

if not ok then
  halt("init.lua crashed:\n" .. tostring(run_err))
end
