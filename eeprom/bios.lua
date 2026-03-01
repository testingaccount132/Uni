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

-- ── Recovery mode ────────────────────────────────────────────────────────────
-- If critical boot files are missing, offer to download the bootstrap installer

local function try_recovery()
  println("", 0xFF5555)
  println("RECOVERY MODE", 0xFF5555)
  println("Critical boot files missing!", 0xFFAA00)
  println("", 0xBBCCDD)

  -- Check for internet card
  local inet = nil
  for a in component.list("internet") do
    inet = component.proxy(a); break
  end

  if not inet then
    println("No internet card found.", 0xFF5555)
    println("Install an internet card and reboot to recover.", 0x4A6070)
    println("", 0x4A6070)
    println("Alternatively, download the bootstrap on another", 0x4A6070)
    println("computer and transfer it to this disk.", 0x4A6070)
    while true do computer.pullSignal(1) end
  end

  println("Internet card detected.", 0x00CC66)
  println("", 0xBBCCDD)
  println("Options:", 0xBBCCDD)
  println("  [1] Download & run bootstrap installer", 0x00B4FF)
  println("  [2] Reboot", 0x4A6070)
  println("  [3] Halt (wait for manual intervention)", 0x4A6070)
  println("", 0xBBCCDD)
  println("Press 1, 2, or 3...", 0xBBCCDD)

  while true do
    local ev, _, char = computer.pullSignal(0.5)
    if ev == "key_down" then
      if char == 49 then -- '1'
        println("", 0x00B4FF)
        println("Downloading bootstrap installer...", 0x00B4FF)

        local BS_URL = "https://raw.githubusercontent.com/testingaccount132/Uni/main/tools/bootstrap.lua"
        local req, re = inet.request(BS_URL)
        if not req then
          println("Download failed: " .. tostring(re), 0xFF5555)
          println("Press any key to reboot.", 0x4A6070)
          computer.pullSignal()
          computer.shutdown(true)
          return
        end

        -- Wait for connection
        local deadline = computer.uptime() + 30
        while computer.uptime() < deadline do
          local ok, err = req.finishConnect()
          if ok then break end
          if ok == nil then
            println("Connection failed: " .. tostring(err), 0xFF5555)
            computer.pullSignal()
            computer.shutdown(true)
            return
          end
          computer.pullSignal(0.1)
        end

        local chunks = {}
        while computer.uptime() < deadline do
          local chunk, reason = req.read(65536)
          if chunk then
            chunks[#chunks + 1] = chunk
          elseif reason then
            println("Download error: " .. tostring(reason), 0xFF5555)
            break
          else
            if #chunks > 0 then break end
            computer.pullSignal(0.1)
          end
        end
        req.close()
        local bs_src = table.concat(chunks)

        if #bs_src < 100 then
          println("Downloaded file too small (" .. #bs_src .. "B). Aborting.", 0xFF5555)
          computer.pullSignal()
          computer.shutdown(true)
          return
        end

        println("Downloaded bootstrap (" .. #bs_src .. "B)", 0x00CC66)
        println("Launching installer...", 0x00B4FF)

        -- Save to /tmp/bootstrap.lua on boot_fs first
        if boot_fs then
          pcall(function()
            if not boot_fs.exists("/tmp") then boot_fs.makeDirectory("/tmp") end
            local fh = boot_fs.open("/tmp/bootstrap.lua", "w")
            if fh then boot_fs.write(fh, bs_src); boot_fs.close(fh) end
          end)
        end

        -- Execute bootstrap
        local fn, perr = load(bs_src, "=bootstrap", "t", _G)
        if not fn then
          println("Parse error: " .. tostring(perr), 0xFF5555)
          computer.pullSignal()
          computer.shutdown(true)
          return
        end

        local ok2, run_err2 = pcall(fn)
        if not ok2 then
          println("Bootstrap error: " .. tostring(run_err2), 0xFF5555)
        end
        println("", 0xBBCCDD)
        println("Press any key to reboot.", 0xBBCCDD)
        computer.pullSignal()
        computer.shutdown(true)
        return

      elseif char == 50 then -- '2'
        computer.shutdown(true)
        return
      elseif char == 51 then -- '3'
        println("Halted. Reboot manually.", 0x4A6070)
        while true do computer.pullSignal(1) end
      end
    end
  end
end

if not boot_fs.exists(BOOT_FILE) then
  -- Check other critical files
  local missing = {}
  local critical = { "/boot/init.lua", "/kernel/kernel.lua", "/bin/sh.lua" }
  for _, f in ipairs(critical) do
    if not boot_fs.exists(f) then missing[#missing + 1] = f end
  end

  if #missing > 0 then
    println("Missing files:", 0xFF5555)
    for _, f in ipairs(missing) do
      println("  " .. f, 0xFFAA00)
    end
    try_recovery()
    return
  end
end

-- ── Read and execute /boot/init.lua ──────────────────────────────────────────

local h, err = boot_fs.open(BOOT_FILE, "r")
if not h then halt("Cannot open " .. BOOT_FILE .. ":\n" .. tostring(err)) end

local chunks = {}
repeat
  local chunk = boot_fs.read(h, math.huge)
  if chunk then chunks[#chunks + 1] = chunk end
until not chunk
boot_fs.close(h)
local src = table.concat(chunks)

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
