-- UniOS Bootstrap Installer
-- Downloads and installs UniOS directly from GitHub.
--
-- Paste this one-liner into OpenOS with an internet card:
--
--   wget -fq https://raw.githubusercontent.com/testingaccount132/Uni/main/tools/bootstrap.lua /tmp/bs.lua && lua /tmp/bs.lua

local component = component or require("component")
local computer  = computer  or require("computer")

-- ── URL config ────────────────────────────────────────────────────────────────

local REPO = "https://raw.githubusercontent.com/testingaccount132/Uni/main"

-- Hardcoded file list — no GitHub API, no rate limits.
-- Only .min.lua for EEPROM files; skip README, LICENSE, .js and other non-runtime files.
local FILES = {
  "eeprom/bios.min.lua","eeprom/flash.lua",
  "boot/init.lua",
  "kernel/kernel.lua","kernel/process.lua","kernel/scheduler.lua",
  "kernel/signal.lua","kernel/syscall.lua",
  "fs/vfs.lua","fs/devfs.lua","fs/tmpfs.lua","fs/procfs.lua",
  "drivers/gpu.lua","drivers/keyboard.lua","drivers/disk.lua",
  "drivers/tty.lua","drivers/pty.lua",
  "lib/libc.lua","lib/libio.lua","lib/libpath.lua","lib/libterm.lua","lib/pkg.lua",
  "bin/sh.lua","bin/ls.lua","bin/cat.lua","bin/cp.lua","bin/mv.lua","bin/rm.lua",
  "bin/mkdir.lua","bin/echo.lua","bin/pwd.lua","bin/uname.lua","bin/ps.lua",
  "bin/kill.lua","bin/grep.lua","bin/df.lua","bin/free.lua","bin/uptime.lua",
  "bin/wc.lua","bin/head.lua","bin/tail.lua","bin/touch.lua","bin/clear.lua",
  "bin/reboot.lua","bin/dmesg.lua","bin/which.lua","bin/env.lua","bin/hostname.lua",
  "bin/nano.lua","bin/apt.lua",
  "etc/hostname","etc/passwd","etc/profile","etc/rc",
  "etc/apt/sources.list",
  "var/lib/apt/installed",
  "installer/install.lua","installer/installer_eeprom.min.lua",
  "tools/bootstrap.lua","tools/get.lua","tools/uninstall.lua",
}

-- ─────────────────────────────────────────────────────────────────────────────
-- ─────────────────────────────────────────────────────────────────────────────
-- Display setup
-- ─────────────────────────────────────────────────────────────────────────────

local gpu, screen
for a in component.list("gpu")    do gpu    = component.proxy(a); break end
for a in component.list("screen") do screen = component.proxy(a); break end
if gpu and screen then gpu.bind(screen.address) end

local W, H = 80, 25
if gpu then W, H = gpu.maxResolution() end

-- Colours
local BG     = 0x0A0E18   -- background
local HDR_BG = 0x001830   -- header bar bg
local HDR_FG = 0x00B4FF   -- header title
local SUB_FG = 0x336688   -- header subtitle
local TEXT   = 0xCCDDEE   -- normal text
local DIM    = 0x445566   -- dim/info
local OK     = 0x00CC66   -- success green
local WARN   = 0xFFAA00   -- warning amber
local ERR    = 0xFF4444   -- error red
local PB_FG  = 0x0088DD   -- progress fill
local PB_BG  = 0x0A1828   -- progress bg
local PB_MT  = 0x1A2838   -- progress empty

-- Row tracking for log area
local LOG_START = 4        -- first log row (after 3-row header)
local _log_row  = LOG_START
local _log_lines = {}
local LOG_MAX   = H - 5   -- leave 4 rows at bottom for progress+status

local function gset(x, y, s, f, b)
  if not gpu then io.write(tostring(s)); return end
  if f then gpu.setForeground(f) end
  if b then gpu.setBackground(b) end
  gpu.set(x, y, tostring(s))
end
local function gfill(x, y, w, h, ch, f, b)
  if not gpu then return end
  if f then gpu.setForeground(f) end
  if b then gpu.setBackground(b) end
  gpu.fill(x, y, w, h, ch)
end
local function center_str(s, width)
  local pad = math.max(0, math.floor((width - #s) / 2))
  return string.rep(" ", pad) .. s
end

local function draw_header()
  if not gpu then return end
  -- Full-width header bar
  gfill(1, 1, W, 1, " ", HDR_FG, HDR_BG)
  local title = "  UniOS Bootstrap Installer"
  local sub   = "github.com/testingaccount132/Uni  "
  gpu.setForeground(HDR_FG); gpu.setBackground(HDR_BG)
  gpu.set(1, 1, title)
  gpu.setForeground(SUB_FG)
  gpu.set(W - #sub + 1, 1, sub)
  -- Background fill
  gfill(1, 2, W, H - 1, " ", TEXT, BG)
end

-- Append a line to the scrolling log
local function log(msg, col)
  msg = tostring(msg):sub(1, W - 2)
  _log_lines[#_log_lines + 1] = { msg = msg, col = col or TEXT }
  if _log_row > LOG_MAX then
    -- Scroll: shift lines up
    gpu.copy(1, LOG_START + 1, W, LOG_MAX - LOG_START, 0, -1)
    gfill(1, LOG_MAX, W, 1, " ", TEXT, BG)
  else
    _log_row = _log_row + 1
  end
  local row = math.min(_log_row - 1, LOG_MAX)
  gset(2, row, msg, col or TEXT, BG)
end

local function log_ok(m)   log(" ok  " .. m, OK)   end
local function log_err(m)  log(" !!  " .. m, ERR)  end
local function log_info(m) log(" ..  " .. m, DIM)  end
local function log_warn(m) log(" **  " .. m, WARN) end

-- Bottom progress bar (second-to-last row)
local PROG_ROW = H - 2
local function progress(pct, label)
  if not gpu then return end
  local w      = W - 4
  local filled = math.floor(w * pct / 100)
  local empty  = w - filled
  gpu.setBackground(PB_BG); gpu.setForeground(PB_FG)
  if filled > 0 then gpu.set(3, PROG_ROW, string.rep("█", filled)) end
  gpu.setForeground(PB_MT)
  if empty  > 0 then gpu.set(3 + filled, PROG_ROW, string.rep("▒", empty)) end
  if label then
    local lx = 3 + math.floor((w - #label) / 2)
    gpu.setForeground(0xFFFFFF); gpu.set(lx, PROG_ROW, label)
  end
  -- Restore bg
  gpu.setBackground(BG)
end

-- Status bar (last row)
local function status(msg, col)
  if not gpu then return end
  gfill(1, H, W, 1, " ", col or DIM, HDR_BG)
  gpu.set(2, H, tostring(msg):sub(1, W - 2))
end

local function sep() end   -- kept for call-site compatibility, does nothing

-- ─────────────────────────────────────────────────────────────────────────────
-- Internet / filesystem helpers
-- ─────────────────────────────────────────────────────────────────────────────

local internet = nil
for a in component.list("internet") do internet = component.proxy(a); break end

local function http_get(url)
  if not internet then return nil, "no internet card" end
  local req, err = internet.request(url)
  if not req then return nil, tostring(err) end
  local data     = ""
  local deadline = computer.uptime() + 30
  while computer.uptime() < deadline do
    local chunk, reason = req.read(65536)
    if chunk then
      data = data .. chunk
    elseif reason then
      req.close()
      return nil, tostring(reason)
    else
      break  -- nil chunk + nil reason = done
    end
  end
  req.close()
  return data ~= "" and data or nil, data == "" and "empty response" or nil
end

-- Robust download with retry.
local function download(url, retries)
  retries = retries or 3
  for attempt = 1, retries do
    local data, err = http_get(url)
    if data then return data end
    if attempt < retries then
      log_warn("Retry "..attempt.."/"..retries.." ("..tostring(err)..")")
      os.sleep(1)
    else
      return nil, err
    end
  end
end

-- Ensure parent directories exist on the target filesystem
local function mkdirp(diskfs, path)
  local parts = {}
  for seg in path:gmatch("[^/]+") do parts[#parts+1] = seg end
  local built = ""
  for i = 1, #parts-1 do
    built = built .. "/" .. parts[i]
    if not diskfs.exists(built) then diskfs.makeDirectory(built) end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Disk selection
-- ─────────────────────────────────────────────────────────────────────────────

local function choose_target()
  local disks = {}
  for addr in component.list("filesystem") do
    local f     = component.proxy(addr)
    local label = (f.getLabel and f.getLabel()) or ""
    local total = (f.spaceTotal and f.spaceTotal()) or 0
    local lc    = label:lower()
    -- Exclude: read-only, any tmpfs/ramdisk label, and temporary filesystems
    -- Also exclude tiny volumes < 1 MB (real HDDs are at least 1 MB)
    local is_temp = f.isTemporary and f.isTemporary()
    if not f.isReadOnly()
      and not is_temp
      and not lc:find("tmpfs")
      and not lc:find("ramdisk")
      and not lc:find("tmp")
      and total >= 1024 * 1024
    then
      local disp = label ~= "" and label or "unlabeled"
      disks[#disks+1] = { addr=addr, fs=f, label=disp, kb=math.floor(total/1024) }
    end
  end

  if #disks == 0 then return nil, "No suitable disk found (need writable HDD ≥1 MB)" end
  if #disks == 1 then return disks[1] end

  -- Multiple disks — show numbered list and wait for keypress
  log("Multiple disks found. Choose target:", WARN)
  for i, d in ipairs(disks) do
    log(string.format("  [%d] %-18s  %d KB  %s", i, d.label:sub(1,18), d.kb, d.addr:sub(1,8)),
        i == 1 and OK or TEXT)
  end
  status("Press 1-" .. #disks .. " to select disk", WARN)

  while true do
    local ev, _, char = computer.pullSignal(0.1)
    if ev == "key_down" then
      local n = char - 48
      if n >= 1 and n <= #disks then return disks[n] end
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main install routine
-- ─────────────────────────────────────────────────────────────────────────────

local function run()
  if gpu then draw_header() end

  -- Check internet
  if not internet then
    log_err("No internet card detected!")
    log_warn("Install the internet card and rerun.")
    status("Fatal: no internet card.", ERR)
    if gpu then progress(100,"  FAILED  ") end
    return false
  end
  log_ok("Internet card ready")

  log_info("Source: "..REPO)

  -- Choose target
  status("Selecting install target…", DIM)
  local disk, disk_err = choose_target()
  if not disk then
    log_err("Disk error: "..(disk_err or "?"))
    status("Fatal: "..tostring(disk_err), ERR)
    if gpu then progress(100,"  FAILED  ") end
    return false
  end
  log_ok("Target: "..disk.label.." ("..disk.addr:sub(1,8).."…)")

  -- Confirmation warning
  log("")
  log("WARNING: This will overwrite files on "..disk.label.."!", WARN)
  log("All existing UniOS files will be replaced.", WARN)
  log("Press ENTER to continue or Q to cancel...", TEXT)
  status("Press ENTER to install, Q to cancel", WARN)

  while true do
    local ev, _, char, code = computer.pullSignal(0.1)
    if ev == "key_down" then
      if code == 28 then break end
      if char == 113 or char == 81 then
        log_warn("Installation cancelled by user.")
        status("Cancelled.", WARN)
        return false
      end
    end
  end

  log_ok("Installation confirmed")

  local total = #FILES
  local done  = 0
  log_info("Downloading "..total.." files…")
  status("Downloading UniOS…", DIM)
  if gpu then progress(5,"  Downloading…  ") end

  for _, rel_path in ipairs(FILES) do
    local url        = REPO.."/"..rel_path
    local local_path = "/"..rel_path
    local short      = rel_path:match("[^/]+$")
    log_info(short)

    local data, err = download(url, 3)
    if not data then
      log_err("FAIL: "..rel_path.." ("..tostring(err)..")")
      status("Error: "..tostring(err), ERR)
      if gpu then progress(100,"  FAILED  ") end
      return false
    end

    mkdirp(disk.fs, local_path)
    local h = disk.fs.open(local_path, "w")
    if h then
      disk.fs.write(h, data)
      disk.fs.close(h)
      log_ok(short.." ("..#data.."B)")
    else
      log_err("Write failed: "..local_path)
      status("Write error: "..local_path, ERR)
      if gpu then progress(100,"  FAILED  ") end
      return false
    end

    done = done + 1
    local pct = 5 + math.floor(done/total*83)
    if gpu then progress(pct, string.format("  %d / %d  ", done, total)) end
  end

  -- Write hostname
  if gpu then progress(90,"  Writing config…  ") end
  log_info("Writing /etc/hostname…")
  local hh = disk.fs.open("/etc/hostname","w")
  if hh then disk.fs.write(hh,"uni\n"); disk.fs.close(hh) end

  -- Create home dir
  if not disk.fs.exists("/root") then disk.fs.makeDirectory("/root") end
  local shrc = disk.fs.open("/root/.shrc","w")
  if shrc then disk.fs.write(shrc,"# UniOS shell rc\n"); disk.fs.close(shrc) end

  -- Create standard dirs
  for _, d in ipairs({"/tmp","/var","/usr","/usr/bin","/usr/lib","/sbin","/home"}) do
    if not disk.fs.exists(d) then disk.fs.makeDirectory(d) end
  end

  -- Flash EEPROM?
  local eeprom = nil
  for a in component.list("eeprom") do eeprom = component.proxy(a); break end

  if eeprom then
    if gpu then progress(93,"  Flashing EEPROM…  ") end
    log_info("Flashing EEPROM with UniOS BIOS…")
    -- Prefer pre-minified bios (smaller, safer); fall back to full source
    local bios_candidates = { "/eeprom/bios.min.lua", "/eeprom/bios.lua" }
    local bios, bios_file = nil, nil
    for _, bp in ipairs(bios_candidates) do
      local bh = disk.fs.open(bp, "r")
      if bh then
        bios = ""
        repeat
          local chunk = disk.fs.read(bh, math.huge)
          if chunk then bios = bios..chunk end
        until not chunk
        disk.fs.close(bh)
        bios_file = bp
        break
      end
    end
    if bios then
      local tag = bios_file:match("%.min%.lua$") and " [minified]" or ""
      log_info("Using "..bios_file..tag.." ("..#bios.."B)")
      local ok, err = pcall(function() eeprom.set(bios) end)
      if ok then
        pcall(function() eeprom.setLabel("UniOS BIOS 1.0") end)
        log_ok("EEPROM flashed! ("..#bios.." bytes)")
      else
        log_err("EEPROM flash failed: "..tostring(err))
      end
    else
      log_warn("bios.lua not found on target – skip EEPROM flash")
    end
  else
    log_warn("No EEPROM found – skipping flash")
  end

  log_ok("")
  log_ok("Installation complete!  Reboot to start UniOS.")
  status("Done! Reboot to start UniOS.", OK)
  if gpu then progress(100,"  Done!  ") end
  return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Entry
-- ─────────────────────────────────────────────────────────────────────────────

local ok = run()

if gpu then
  if ok then
    -- Auto-reboot countdown
    for sec = 5, 1, -1 do
      status("Rebooting in "..sec.."s... Press any key to cancel.", OK)
      local ev = computer.pullSignal(1)
      if ev == "key_down" then
        status("Auto-reboot cancelled. Type 'reboot' to start UniOS.", DIM)
        computer.pullSignal()
        gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
        gpu.fill(1, 1, W, H, " ")
        gpu.set(1, 1, "UniOS installed. Type 'reboot' to start.")
        return
      end
    end
    status("Rebooting now...", OK)
    os.sleep(0.5)
    computer.shutdown(true)
  else
    status("Press any key to exit…", DIM)
    computer.pullSignal()
    gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, W, H, " ")
    gpu.set(1, 1, "Bootstrap finished with errors. Check the log above.")
  end
end
