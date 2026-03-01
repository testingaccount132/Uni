-- UniOS Installer EEPROM  v1.1
-- Flash this onto an EEPROM chip to create a bootable installer disk.
-- On boot it finds /installer/install.lua on any attached filesystem and runs it.
-- Must fit within 4 096 bytes when minified (installer/installer_eeprom.min.lua).

-- ── GPU setup ─────────────────────────────────────────────────────────────────

local gpu, W, H = nil, 80, 25
do
  local g, s
  for a in component.list("gpu")    do g = component.proxy(a); break end
  for a in component.list("screen") do s = component.proxy(a); break end
  if g and s then
    g.bind(s.address)
    W, H = g.maxResolution()
    g.setResolution(W, H)
    g.setBackground(0x050D18); g.setForeground(0x00B4FF)
    g.fill(1, 1, W, H, " ")
    gpu = g
  end
end

local function put(row, msg, col)
  if not gpu then return end
  gpu.setForeground(col or 0xBBCCDD)
  gpu.set(2, row, msg)
end

-- ── Header ────────────────────────────────────────────────────────────────────

put(1, "╔══════════════════════════════════╗", 0x1A3A5C)
put(2, "║   UniOS Installer EEPROM  v1.1   ║", 0x00B4FF)
put(3, "╚══════════════════════════════════╝", 0x1A3A5C)
put(5, "Searching for installer disk...",      0x4A6070)

-- ── Find installer ────────────────────────────────────────────────────────────

local PATHS = {
  "/installer/install.lua",
  "/install.lua",
  "/uni/installer/install.lua",
}

local inst_fs, inst_path

for addr in component.list("filesystem") do
  local fs = component.proxy(addr)
  for _, p in ipairs(PATHS) do
    if fs.exists(p) then
      inst_fs   = fs
      inst_path = p
      break
    end
  end
  if inst_fs then break end
end

if not inst_fs then
  put(7,  "!  Installer disk not found!",          0xFF4444)
  put(9,  "Insert the UniOS installer disk and reboot.", 0xFFAA00)
  put(11, "Expected one of:",                      0x4A6070)
  for i, p in ipairs(PATHS) do put(11 + i, "  " .. p, 0x4A6070) end
  put(16, "Halted.", 0xFF4444)
  while true do computer.pullSignal(1) end
end

put(7, "OK  Found: " .. inst_path, 0x00CC66)
put(9, "Loading installer...",      0x4A6070)

-- ── Load and run installer ────────────────────────────────────────────────────

local h, err = inst_fs.open(inst_path, "r")
if not h then
  put(11, "!  Cannot open: " .. tostring(err), 0xFF4444)
  while true do computer.pullSignal(1) end
end

local src = ""
repeat
  local chunk = inst_fs.read(h, math.huge)
  if chunk then src = src .. chunk end
until not chunk
inst_fs.close(h)

put(11, string.format("OK  %d bytes loaded. Starting...", #src), 0x00CC66)
computer.pullSignal(0.4)

local env = setmetatable({}, { __index = _G })
env._installer_fs   = inst_fs
env._installer_path = inst_path

local fn, perr = load(src, "=installer", "t", env)
if not fn then
  put(13, "!  Parse error:", 0xFF4444)
  put(14, "   " .. tostring(perr), 0xFF4444)
  while true do computer.pullSignal(1) end
end

local ok, run_err = xpcall(fn, function(e)
  return (debug and debug.traceback or tostring)(e)
end)

if not ok then
  if gpu then
    gpu.setBackground(0x050D18); gpu.setForeground(0xFF4444)
    gpu.fill(1, 1, W, H, " ")
    gpu.setForeground(0xFF0000)
    gpu.set(2, 2, "INSTALLER CRASHED")
    gpu.setForeground(0xBBCCDD)
    local row = 4
    for ln in tostring(run_err):gmatch("[^\n]+") do
      gpu.set(2, row, ln:sub(1, W - 3)); row = row + 1
      if row > H - 2 then break end
    end
    gpu.setForeground(0x4A6070)
    gpu.set(2, H - 1, "Halted. Reboot to try again.")
  end
  while true do computer.pullSignal(1) end
end
