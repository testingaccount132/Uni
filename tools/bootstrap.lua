-- UniOS Bootstrap Installer
-- Downloads and installs UniOS directly from GitHub.
--
-- Paste this one-liner into OpenOS with an internet card:
--
--   wget -fq https://raw.githubusercontent.com/testingaccount132/Uni/main/tools/bootstrap.lua /tmp/bs.lua && lua /tmp/bs.lua

local component = component or require("component")
local computer  = computer  or require("computer")
local fs        = fs        or (pcall(require,"filesystem") and require("filesystem") or nil)

-- ── URL config ────────────────────────────────────────────────────────────────

local OWNER  = "testingaccount132"
local REPON  = "Uni"
local BRANCH = "main"

local REPO     = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPON .. "/" .. BRANCH
local API_TREE = "https://api.github.com/repos/" .. OWNER .. "/" .. REPON .. "/git/trees/" .. BRANCH .. "?recursive=1"

-- Files to skip (docs, git files, etc.)
local SKIP = { ["README.md"]=true, ["LICENSE"]=true, [".gitignore"]=true }
local function should_skip(path)
  return SKIP[path] or path:sub(1,1) == "."
end

-- Parse blob paths from the GitHub tree API JSON response.
-- Scans for consecutive "path" and "type" fields within each tree entry.
-- Works without a JSON library by matching field patterns directly.
local function parse_tree(json)
  local files = {}
  -- Each tree entry looks like: {"path":"...","mode":"...","type":"blob",...}
  -- We extract path+type pairs by scanning "path":"VALUE" then nearby "type":"VALUE"
  local pos = 1
  while true do
    -- Find next "path" field
    local ps, pe, path = json:find('"path"%s*:%s*"([^"]*)"', pos)
    if not ps then break end
    -- Look for "type" field within the next 300 chars of this entry
    local window = json:sub(pe + 1, pe + 300)
    local ftype  = window:match('"type"%s*:%s*"([^"]*)"')
    if ftype == "blob" and not should_skip(path) then
      files[#files+1] = path
    end
    pos = pe + 1
  end
  table.sort(files)
  return files
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Terminal helpers (works under OpenOS)
-- ─────────────────────────────────────────────────────────────────────────────

local gpu, screen
for a in component.list("gpu")    do gpu    = component.proxy(a); break end
for a in component.list("screen") do screen = component.proxy(a); break end
if gpu and screen then gpu.bind(screen.address) end

local W, H = 80, 25
if gpu then W, H = gpu.maxResolution() end

-- Colour palette
local C = {
  bg      = 0x050D18, panel   = 0x0D1E30, border  = 0x1A3A5C,
  accent  = 0x00B4FF, accent2 = 0x0077CC, title   = 0xFFFFFF,
  text    = 0xBBCCDD, dim     = 0x4A6070, muted   = 0x1A2A3A,
  ok      = 0x00CC66, warn    = 0xFFAA00, err     = 0xFF4444,
  prog    = 0x0099EE, prog_bg = 0x0A1E30,
}

local function fg(c) if gpu then gpu.setForeground(c) end end
local function bg(c) if gpu then gpu.setBackground(c) end end
local function gset(x,y,s,f,b)
  if not gpu then io.write(s); return end
  if f then gpu.setForeground(f) end
  if b then gpu.setBackground(b) end
  gpu.set(x, y, s)
end
local function fill(x,y,w,h,ch,f,b)
  if not gpu then return end
  if f then gpu.setForeground(f) end
  if b then gpu.setBackground(b) end
  gpu.fill(x,y,w,h,ch or " ")
end
local function center(x,y,w,s,f,b)
  gset(x + math.max(0, math.floor((w-#s)/2)), y, s, f, b)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- UI Layout
-- ─────────────────────────────────────────────────────────────────────────────

local PW = math.min(W, 68)
local PH = math.min(H, 20)
local PX = math.floor((W-PW)/2)+1
local PY = math.floor((H-PH)/2)+1
local CX = PX+2
local CW = PW-4

local function draw_frame()
  fill(1,1,W,H," ",C.dim,C.bg)
  -- background dots
  fg(0x080F1C); bg(C.bg)
  for r=1,H,2 do gpu.set(1,r,string.rep("·",W)) end
  -- panel
  fill(PX,PY,PW,PH," ",C.text,C.panel)
  -- border
  fg(C.border); bg(C.panel)
  gpu.set(PX, PY,     "╔"..string.rep("═",PW-2).."╗")
  gpu.set(PX, PY+PH-1,"╚"..string.rep("═",PW-2).."╝")
  for r=PY+1,PY+PH-2 do
    gpu.set(PX,r,"║"); fill(PX+1,r,PW-2,1," "); gpu.set(PX+PW-1,r,"║")
  end
  -- title
  center(PX+1,PY+1,PW-2,"UniOS Bootstrap Installer",C.accent,C.panel)
  center(PX+1,PY+2,PW-2,"github.com/testingaccount132/Uni",C.dim,C.panel)
  fg(C.border); bg(C.panel)
  gpu.set(PX,PY+3,"╠"..string.rep("═",PW-2).."╣")
end

-- Scrolling log
local _log_lines = {}
local LOG_Y = PY+4
local LOG_H = PH-8

local function log(msg, col)
  _log_lines[#_log_lines+1] = {msg=tostring(msg), col=col or C.text}
  local start = math.max(1, #_log_lines-LOG_H+1)
  for i=0,LOG_H-1 do
    local e = _log_lines[start+i]
    fill(CX, LOG_Y+i, CW, 1, " ", C.text, C.panel)
    if e then gset(CX, LOG_Y+i, e.msg:sub(1,CW), e.col, C.panel) end
  end
end

local function log_ok(m)   log("  ✓  "..m, C.ok)   end
local function log_err(m)  log("  ✗  "..m, C.err)  end
local function log_info(m) log("  ·  "..m, C.dim)  end
local function log_warn(m) log("  ⚠  "..m, C.warn) end

-- Progress bar
local PROG_Y = PY+PH-4
local function progress(pct, label)
  local inner = CW-2
  local filled = math.floor(inner*pct/100)
  fill(CX,   PROG_Y, 1, 1, "▕", C.border, C.panel)
  fill(CX+1, PROG_Y, filled,      1, "█", C.prog,    C.prog_bg)
  fill(CX+1+filled, PROG_Y, inner-filled, 1, "░", C.muted, C.prog_bg)
  fill(CX+inner+1, PROG_Y, 1, 1, "▏", C.border, C.panel)
  if label then
    local lx = CX + math.floor((CW-#label)/2)
    gset(lx, PROG_Y, label, C.title, C.prog_bg)
  end
end

-- Status line
local function status(msg, col)
  fill(CX, PY+PH-2, CW, 1, " ", C.text, C.panel)
  gset(CX, PY+PH-2, msg:sub(1,CW), col or C.dim, C.panel)
end

local function sep()
  fg(C.border); bg(C.panel)
  gpu.set(PX, PY+PH-5, "╠"..string.rep("═",PW-2).."╣")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Internet / filesystem helpers
-- ─────────────────────────────────────────────────────────────────────────────

local internet = nil
for a in component.list("internet") do internet = component.proxy(a); break end

local function http_get(url)
  if not internet then return nil, "no internet card" end
  local req, err = internet.request(url)
  if not req then return nil, tostring(err) end
  local data    = ""
  local deadline = computer.uptime() + 30
  while computer.uptime() < deadline do
    local chunk, reason = req.read(8192)
    if chunk then
      data = data .. chunk
    elseif reason then
      req.close()
      return nil, tostring(reason)
    else
      -- nil chunk + nil reason = response complete
      break
    end
    os.sleep(0)
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
  -- Collect writable filesystems, excluding tmpfs and tiny (<512 KB) volumes
  local disks = {}
  for addr in component.list("filesystem") do
    local f = component.proxy(addr)
    if not f.isReadOnly() then
      local label = (f.getLabel and f.getLabel()) or "unlabeled"
      local total = (f.spaceTotal and f.spaceTotal()) or 0
      local kb    = math.floor(total / 1024)
      -- Skip in-memory / tmpfs (label "tmpfs" or capacity < 512 KB)
      if label:lower() ~= "tmpfs" and total >= 512 * 1024 then
        disks[#disks+1] = { addr=addr, fs=f, label=label, kb=kb }
      end
    end
  end

  if #disks == 0 then return nil, "No suitable writable disk found (need ≥512 KB HDD/floppy)" end
  if #disks == 1 then return disks[1] end

  -- Multiple disks: show a simple numbered menu
  fill(CX, LOG_Y, CW, LOG_H, " ", C.text, C.panel)
  gset(CX, LOG_Y, "Multiple writable disks found. Choose install target:", C.accent, C.panel)
  for i, d in ipairs(disks) do
    local line = string.format("  [%d] %-20s  %d KB  %s", i, d.label:sub(1,20), d.kb, d.addr:sub(1,8))
    gset(CX, LOG_Y+i, line, i==1 and C.ok or C.text, C.panel)
  end
  status("Press 1-"..#disks.." to select target disk", C.warn)

  while true do
    local ev, _, char = computer.pullSignal(0.1)
    if ev == "key_down" then
      local n = char - 48  -- ASCII '0'=48
      if n >= 1 and n <= #disks then
        fill(CX, LOG_Y, CW, LOG_H, " ", C.text, C.panel)
        return disks[n]
      end
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main install routine
-- ─────────────────────────────────────────────────────────────────────────────

local function run()
  if gpu then draw_frame(); sep() end

  -- Check internet
  if not internet then
    log_err("No internet card detected!")
    log_warn("Install the internet card and rerun.")
    status("Fatal: no internet card.", C.err)
    if gpu then progress(100,"  FAILED  ") end
    return false
  end
  log_ok("Internet card ready")

  log_info("Source: "..REPO)

  -- Choose target
  status("Selecting install target…", C.dim)
  local disk, disk_err = choose_target()
  if not disk then
    log_err("Disk error: "..(disk_err or "?"))
    status("Fatal: "..tostring(disk_err), C.err)
    if gpu then progress(100,"  FAILED  ") end
    return false
  end
  log_ok("Target: "..disk.label.." ("..disk.addr:sub(1,8).."…)")

  -- Fetch file list from GitHub API
  local FILES
  status("Fetching file list from GitHub…", C.dim)
  if gpu then progress(2,"  Fetching list…  ") end
  log_info("Querying GitHub API for file list…")
  local tree_json, tree_err = http_get(API_TREE)
  if tree_json then
    FILES = parse_tree(tree_json)
    log_ok("Found "..#FILES.." files in repo")
  else
    log_warn("API error: "..tostring(tree_err)..". Using built-in fallback list.")
  end

  if not FILES then
    -- Minimal fallback so the installer still works if the API is rate-limited
    FILES = {
      "eeprom/bios.lua","eeprom/bios.min.lua","eeprom/flash.lua","boot/init.lua",
      "kernel/kernel.lua","kernel/process.lua","kernel/scheduler.lua",
      "kernel/signal.lua","kernel/syscall.lua",
      "fs/vfs.lua","fs/devfs.lua","fs/tmpfs.lua",
      "drivers/gpu.lua","drivers/keyboard.lua","drivers/disk.lua",
      "lib/libc.lua","lib/libio.lua","lib/libpath.lua","lib/libterm.lua","lib/pkg.lua",
      "bin/sh.lua","bin/ls.lua","bin/cat.lua","bin/cp.lua","bin/mv.lua","bin/rm.lua",
      "bin/mkdir.lua","bin/echo.lua","bin/pwd.lua","bin/uname.lua","bin/ps.lua",
      "bin/kill.lua","bin/grep.lua","bin/df.lua","bin/free.lua","bin/uptime.lua",
      "bin/wc.lua","bin/head.lua","bin/tail.lua","bin/touch.lua","bin/clear.lua",
      "bin/reboot.lua","bin/dmesg.lua","bin/which.lua","bin/env.lua","bin/hostname.lua",
      "etc/hostname","etc/passwd","etc/profile","etc/rc",
      "installer/install.lua","installer/installer_eeprom.lua",
      "installer/installer_eeprom.min.lua",
      "tools/bootstrap.lua","tools/get.lua","tools/uninstall.lua","tools/minify.lua",
    }
  end

  local total = #FILES
  local done  = 0
  log_info("Downloading "..total.." files from "..REPO.."…")
  status("Downloading UniOS…", C.dim)
  if gpu then progress(5,"  Downloading…  ") end

  local failed = {}

  for _, rel_path in ipairs(FILES) do
    local url   = REPO.."/"..rel_path
    local local_path = "/"..rel_path

    local short = rel_path:match("[^/]+$")
    log_info(short)

    local data, err = download(url, 3)
    if not data then
      log_err("FAIL: "..rel_path.." ("..tostring(err)..")")
      failed[#failed+1] = rel_path
    else
      -- Write to target filesystem
      mkdirp(disk.fs, local_path)
      local h = disk.fs.open(local_path, "w")
      if h then
        disk.fs.write(h, data)
        disk.fs.close(h)
        log_ok(short.." ("..#data.."B)")
      else
        log_err("Write failed: "..local_path)
        failed[#failed+1] = rel_path
      end
    end

    done = done + 1
    local pct = 5 + math.floor(done/total*78)
    if gpu then progress(pct, string.format("  %d / %d  ", done, total)) end
  end

  if #failed > 0 then
    log_warn(#failed.." file(s) failed to download:")
    for _, f in ipairs(failed) do log_err("  "..f) end
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

  if gpu then progress(100,"  Done!  ") end

  if #failed == 0 then
    log_ok("")
    log_ok("Installation complete!  Reboot to start UniOS.")
    status("Done! Reboot to start UniOS.", C.ok)
    return true
  else
    log_warn("Installed with "..#failed.." error(s).")
    status("Partial install. Check errors above.", C.warn)
    return false
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Entry
-- ─────────────────────────────────────────────────────────────────────────────

local ok = run()

-- Wait for keypress (only in GPU/interactive mode)
if gpu then
  fg(C.dim); bg(C.panel)
  gpu.set(CX, PY+PH-2, "Press any key to exit…")
  computer.pullSignal()
end

-- Restore terminal
if gpu then
  gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
  gpu.fill(1,1,W,H," ")
  if ok then
    gpu.set(1,1,"UniOS installed. Type 'reboot' to restart.")
  else
    gpu.set(1,1,"Bootstrap finished with errors. Check the log above.")
  end
end
