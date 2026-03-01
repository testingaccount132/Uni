-- UniOS EEPROM Flasher
-- Run this from any existing OC environment (OpenOS, etc.) to flash
-- the UniOS BIOS onto an EEPROM chip.
--
-- Usage:
--   flash.lua                 → flash bios.lua from same directory
--   flash.lua /path/to/bios   → flash a custom bios file
--   flash.lua --verify        → verify only, don't write
--   flash.lua --dump          → dump current EEPROM to stdout

local component = component or require("component")
local computer  = computer  or require("computer")

-- ── Minimal GPU/terminal bootstrap ───────────────────────────────────────────
-- We may be running under OpenOS or UniOS; handle both.

local gpu, screen
for a in component.list("gpu")    do gpu    = component.proxy(a); break end
for a in component.list("screen") do screen = component.proxy(a); break end

if gpu and screen then gpu.bind(screen.address) end

local W, H = 80, 25
if gpu then W, H = gpu.maxResolution() end

-- ── Colour palette ────────────────────────────────────────────────────────────

local C = {
  bg        = 0x0A0E1A,
  panel     = 0x101828,
  border    = 0x1E3A5F,
  accent    = 0x00AAFF,
  accent2   = 0x0066CC,
  title     = 0xFFFFFF,
  text      = 0xCCDDEE,
  dim       = 0x556677,
  success   = 0x00CC66,
  warn      = 0xFFAA00,
  danger    = 0xFF4444,
  progress  = 0x0088DD,
  prog_bg   = 0x1A2A3A,
}

local function set_fg(c) if gpu then gpu.setForeground(c) end end
local function set_bg(c) if gpu then gpu.setBackground(c) end end
local function gset(x, y, s) if gpu then gpu.set(x, y, s) end end
local function gfill(x, y, w, h, c) if gpu then gpu.fill(x, y, w, h, c) end end

local function cls()
  set_bg(C.bg); set_fg(C.text)
  if gpu then gfill(1, 1, W, H, " ") end
end

-- ── Box drawing ───────────────────────────────────────────────────────────────

local BOX = {
  tl="╔", tr="╗", bl="╚", br="╝",
  h="═",  v="║",
  ml="╠", mr="╣",
  ts="╦", bs="╩",
}

local function draw_box(x, y, w, h, color, fill_color)
  set_fg(color or C.border)
  set_bg(fill_color or C.panel)
  gset(x, y,         BOX.tl .. string.rep(BOX.h, w-2) .. BOX.tr)
  gset(x, y+h-1,     BOX.bl .. string.rep(BOX.h, w-2) .. BOX.br)
  for row = y+1, y+h-2 do
    gset(x,       row, BOX.v)
    gfill(x+1,    row, w-2, 1, " ")
    gset(x+w-1,   row, BOX.v)
  end
end

local function draw_hline(x, y, w, color)
  set_fg(color or C.border); set_bg(C.panel)
  gset(x, y, BOX.ml .. string.rep(BOX.h, w-2) .. BOX.mr)
end

local function center_text(x, y, w, text, fg, bg)
  set_fg(fg or C.text); set_bg(bg or C.panel)
  local pad = math.floor((w - #text) / 2)
  gset(x + pad, y, text)
end

local function text_at(x, y, s, fg, bg)
  set_fg(fg or C.text); set_bg(bg or C.panel)
  gset(x, y, s)
end

-- ── Progress bar ──────────────────────────────────────────────────────────────

local function draw_progress(x, y, w, pct, label)
  local filled = math.floor((w - 2) * pct / 100)
  local empty  = (w - 2) - filled
  set_fg(C.border); set_bg(C.panel)
  gset(x, y, "▕")
  set_fg(C.progress); set_bg(C.prog_bg)
  if filled > 0 then gset(x+1, y, string.rep("█", filled)) end
  set_fg(C.dim); set_bg(C.prog_bg)
  if empty > 0 then gset(x+1+filled, y, string.rep("░", empty)) end
  set_fg(C.border); set_bg(C.panel)
  gset(x+w-1, y, "▏")
  if label then
    local lx = x + math.floor((w - #label) / 2)
    set_fg(C.title); set_bg(C.prog_bg)
    gset(lx, y, label)
  end
end

-- ── Log area ─────────────────────────────────────────────────────────────────

local LOG_X, LOG_Y, LOG_W, LOG_H = 0, 0, 0, 0
local log_lines = {}

local function log_setup(x, y, w, h)
  LOG_X, LOG_Y, LOG_W, LOG_H = x, y, w, h
end

local function log_push(msg, color)
  log_lines[#log_lines+1] = { msg = msg, color = color or C.text }
  -- Trim to fit
  while #log_lines > LOG_H do table.remove(log_lines, 1) end
  -- Redraw log area
  for i, entry in ipairs(log_lines) do
    set_bg(C.panel)
    gfill(LOG_X, LOG_Y + i - 1, LOG_W, 1, " ")
    text_at(LOG_X, LOG_Y + i - 1,
      entry.msg:sub(1, LOG_W), entry.color)
  end
end

-- ── Spinner ───────────────────────────────────────────────────────────────────

local SPIN = {"⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"}
local spin_i = 1
local function spinner()
  local c = SPIN[spin_i]; spin_i = (spin_i % #SPIN) + 1; return c
end

-- ── Main UI layout ────────────────────────────────────────────────────────────
-- Panel: centred 64×22

local PW, PH = 64, 22
local PX = math.floor((W - PW) / 2) + 1
local PY = math.floor((H - PH) / 2) + 1

local function draw_chrome()
  cls()

  -- Background pattern
  set_fg(0x0D1525); set_bg(C.bg)
  for row = 1, H do
    if row % 2 == 0 then gset(1, row, string.rep("·", W)) end
  end

  -- Main panel
  draw_box(PX, PY, PW, PH, C.border, C.panel)

  -- Title bar
  set_fg(C.accent2); set_bg(C.panel)
  gfill(PX+1, PY+1, PW-2, 1, " ")
  center_text(PX+1, PY+1, PW-2,
    "  ██╗   ██╗███╗  ██╗██╗     ", C.accent, C.panel)

  set_fg(C.accent); set_bg(C.panel)
  gset(PX + math.floor((PW - 28)/2), PY+1,
    "UniOS EEPROM Flasher  v1.0")

  -- Separator
  draw_hline(PX, PY+2, PW, C.border)

  -- Sub-title
  center_text(PX+1, PY+3, PW-2,
    "Flash the UniOS BIOS onto your EEPROM chip", C.dim)

  -- Separator before log
  draw_hline(PX, PY+5, PW, C.border)

  -- Log header
  text_at(PX+2, PY+6, " Activity Log ", C.dim)

  -- Log area setup (inside panel)
  log_setup(PX+2, PY+7, PW-4, PH - 10)

  -- Bottom bar
  draw_hline(PX, PY+PH-4, PW, C.border)
end

-- ── Status line ───────────────────────────────────────────────────────────────

local function set_status(msg, color)
  set_bg(C.panel)
  gfill(PX+2, PY+PH-3, PW-4, 1, " ")
  text_at(PX+2, PY+PH-3, msg:sub(1, PW-4), color or C.text)
end

local function set_progress(pct, label)
  draw_progress(PX+2, PY+PH-2, PW-4, pct, label)
end

-- ── EEPROM helpers ────────────────────────────────────────────────────────────

local function find_eeprom()
  for addr in component.list("eeprom") do
    return component.proxy(addr)
  end
  return nil
end

local function find_fs_with_file(path)
  for addr in component.list("filesystem") do
    local fs = component.proxy(addr)
    if fs.exists(path) then return fs, addr end
  end
  return nil
end

local function read_file(fs, path)
  local h, err = fs.open(path, "r")
  if not h then return nil, err end
  local data = ""
  repeat
    local chunk = fs.read(h, math.huge)
    if chunk then data = data .. chunk end
  until not chunk
  fs.close(h)
  return data
end

-- ── Verify ────────────────────────────────────────────────────────────────────

local function verify_eeprom(eeprom, expected)
  local current = eeprom.get()
  if current == expected then return true end
  -- Find first mismatch byte
  for i = 1, math.max(#current, #expected) do
    if current:sub(i,i) ~= expected:sub(i,i) then
      return false, i
    end
  end
  return false, 0
end

-- ── Flash sequence ────────────────────────────────────────────────────────────

local function do_flash(bios_path, verify_only)
  -- Step 1: find EEPROM
  log_push("Scanning for EEPROM...", C.dim)
  set_progress(5, "  Scanning...  ")
  local eeprom = find_eeprom()
  if not eeprom then
    log_push("✗ No EEPROM component found!", C.danger)
    set_status("ERROR: No EEPROM detected. Insert an EEPROM chip.", C.danger)
    set_progress(100, "  FAILED  ")
    return false
  end
  log_push("✓ EEPROM found: " .. eeprom.address:sub(1,12) .. "...", C.success)
  set_progress(15, "  Found EEPROM  ")

  local eeprom_size = eeprom.getSize()
  log_push("  Capacity: " .. eeprom_size .. " bytes", C.dim)

  -- Step 2: find BIOS source
  -- Prefer .min.lua (smaller = safer for EEPROM), fall back to full .lua
  log_push("Looking for BIOS image...", C.dim)
  set_progress(25, "  Finding BIOS  ")

  -- Build candidate list: .min.lua variants first, then originals, then legacy paths
  local function min_path(p)
    return p:gsub("%.lua$", ".min.lua")
  end
  local candidates = {
    min_path(bios_path),
    bios_path,
    "/eeprom/bios.min.lua",
    "/eeprom/bios.lua",
    "/bios.min.lua",
    "/bios.lua",
    "/uni/eeprom/bios.min.lua",
    "/uni/eeprom/bios.lua",
  }

  local src_fs, src_addr = nil, nil
  for _, candidate in ipairs(candidates) do
    src_fs, src_addr = find_fs_with_file(candidate)
    if src_fs then
      bios_path = candidate
      break
    end
  end

  if not src_fs then
    log_push("✗ BIOS file not found on any disk!", C.danger)
    set_status("ERROR: Cannot find bios.lua. Is the UniOS disk inserted?", C.danger)
    set_progress(100, "  FAILED  ")
    return false
  end

  local is_minified = bios_path:match("%.min%.lua$") ~= nil
  log_push("✓ Found on disk " .. src_addr:sub(1,8) .. ": " .. bios_path
    .. (is_minified and "  [minified]" or ""), C.success)
  set_progress(35, "  Loading BIOS  ")

  -- Step 3: read BIOS
  log_push("Reading BIOS image...", C.dim)
  local bios_data, err = read_file(src_fs, bios_path)
  if not bios_data then
    log_push("✗ Read error: " .. tostring(err), C.danger)
    set_status("ERROR: " .. tostring(err), C.danger)
    set_progress(100, "  FAILED  ")
    return false
  end

  log_push(string.format("✓ Read %d bytes (cap %d)", #bios_data, eeprom_size), C.success)
  set_progress(45, "  Validating  ")

  -- Step 4: size check
  if #bios_data > eeprom_size then
    log_push(string.format("✗ BIOS too large: %d > %d bytes", #bios_data, eeprom_size), C.danger)
    set_status("ERROR: BIOS image exceeds EEPROM capacity.", C.danger)
    set_progress(100, "  FAILED  ")
    return false
  end

  -- Step 5: syntax check
  log_push("Checking Lua syntax...", C.dim)
  local fn, syntax_err = load(bios_data, "=bios", "t")
  if not fn then
    log_push("✗ Syntax error: " .. tostring(syntax_err), C.danger)
    set_status("ERROR: BIOS has syntax errors.", C.danger)
    set_progress(100, "  FAILED  ")
    return false
  end
  log_push("✓ Syntax OK", C.success)
  set_progress(55, "  Syntax OK  ")

  if verify_only then
    -- Verify current EEPROM against expected
    log_push("Verifying current EEPROM contents...", C.dim)
    set_progress(70, "  Verifying  ")
    local ok, mismatch = verify_eeprom(eeprom, bios_data)
    if ok then
      log_push("✓ EEPROM matches BIOS image perfectly.", C.success)
      set_status("VERIFIED: EEPROM is up to date.", C.success)
      set_progress(100, "  VERIFIED  ")
    else
      log_push(string.format("✗ Mismatch at byte %d", mismatch or 0), C.warn)
      set_status("MISMATCH: EEPROM differs. Run without --verify to flash.", C.warn)
      set_progress(100, "  MISMATCH  ")
    end
    return ok
  end

  -- Step 6: backup current EEPROM
  log_push("Backing up current EEPROM...", C.dim)
  set_progress(60, "  Backing up  ")
  local current_data = eeprom.get()
  -- Try to write backup to disk
  local backup_written = false
  for addr in component.list("filesystem") do
    local bk_fs = component.proxy(addr)
    if not bk_fs.isReadOnly() then
      local bh = bk_fs.open("/eeprom.bak", "w")
      if bh then
        bk_fs.write(bh, current_data)
        bk_fs.close(bh)
        log_push("✓ Backup saved: /eeprom.bak on " .. addr:sub(1,8), C.success)
        backup_written = true
        break
      end
    end
  end
  if not backup_written then
    log_push("  (no writable disk for backup – continuing)", C.warn)
  end
  set_progress(70, "  Writing...  ")

  -- Step 7: flash!
  log_push("⚡ Flashing EEPROM...", C.accent)
  set_status("Writing… do NOT power off!", C.warn)

  -- Write in small steps so we can animate progress
  -- OC eeprom.set() writes all at once, but we simulate chunks for UX
  local ok2, flash_err = pcall(function()
    eeprom.set(bios_data)
  end)

  if not ok2 then
    log_push("✗ Flash error: " .. tostring(flash_err), C.danger)
    set_status("ERROR: Flash failed! " .. tostring(flash_err), C.danger)
    set_progress(100, "  FAILED  ")
    return false
  end

  set_progress(85, "  Verifying  ")
  log_push("Verifying write...", C.dim)

  -- Step 8: verify
  local vok, vmis = verify_eeprom(eeprom, bios_data)
  if not vok then
    log_push(string.format("✗ Verify failed at byte %d!", vmis), C.danger)
    set_status("ERROR: Verify failed. EEPROM may be corrupted.", C.danger)
    set_progress(100, "  VERIFY FAILED  ")
    return false
  end

  set_progress(95, "  Setting label  ")

  -- Step 9: set EEPROM label
  pcall(function() eeprom.setLabel("UniOS BIOS 1.0") end)
  log_push("✓ Label set: 'UniOS BIOS 1.0'", C.success)

  set_progress(100, "  DONE!  ")
  log_push("", C.text)
  log_push("✓✓ Flash complete! Reboot to run UniOS.", C.success)
  set_status("SUCCESS: EEPROM flashed. Reboot the computer to boot UniOS.", C.success)
  return true
end

-- ── Dump mode ─────────────────────────────────────────────────────────────────

local function do_dump()
  local eeprom = find_eeprom()
  if not eeprom then
    io.write("No EEPROM found.\n"); return
  end
  local data = eeprom.get()
  io.write(string.format("-- EEPROM dump (%d bytes, label=%s)\n",
    #data, tostring(eeprom.getLabel and eeprom.getLabel())))
  io.write(data)
  io.write("\n")
end

-- ── Argument parsing ──────────────────────────────────────────────────────────

local verify_only = false
local dump_mode   = false
-- Default: prefer pre-minified version; do_flash() will find it automatically
local bios_path   = "/eeprom/bios.min.lua"

for i = 1, #arg do
  if arg[i] == "--verify" or arg[i] == "-v" then
    verify_only = true
  elseif arg[i] == "--dump" or arg[i] == "-d" then
    dump_mode = true
  elseif arg[i]:sub(1,1) ~= "-" then
    bios_path = arg[i]
  end
end

-- ── Entry point ───────────────────────────────────────────────────────────────

if dump_mode then
  do_dump()
  return
end

draw_chrome()

-- Info line (show "auto" since do_flash will search for .min.lua automatically)
text_at(PX+2, PY+4, "BIOS: ", C.dim)
text_at(PX+8, PY+4, bios_path .. "  (auto-selects .min.lua if available)", C.accent)
if verify_only then
  text_at(PX+PW-14, PY+4, "[ VERIFY ]", C.warn)
end

set_progress(0, "  Ready  ")
set_status("Press any key to begin, or Q to cancel...", C.dim)

-- Wait for keypress
local function wait_key()
  while true do
    local ev, _, char = computer.pullSignal(0.1)
    if ev == "key_down" then
      return string.char(char or 0)
    end
  end
end

local key = wait_key()
if key == "q" or key == "Q" then
  set_status("Cancelled.", C.warn)
  set_progress(0, "  Cancelled  ")
  os.sleep(1)
  -- restore terminal
  if gpu then
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, W, H, " ")
  end
  return
end

local ok = do_flash(bios_path, verify_only)

-- Final keypress to exit
set_status((ok and "Done! " or "Failed. ") .. "Press any key to exit.", ok and C.success or C.danger)
wait_key()

-- Restore terminal
if gpu then
  gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, W, H, " ")
end
