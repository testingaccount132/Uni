-- UniOS Installer  v1.0
-- Full TUI installer.  Run from OpenOS, a live floppy, or the installer EEPROM.
--
-- Screens:
--   1. Welcome
--   2. Disk selection
--   3. Options  (hostname, flash EEPROM y/n)
--   4. Confirm
--   5. Installation progress
--   6. Done / error

local component = component
local computer  = computer

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Terminal bootstrap
-- ─────────────────────────────────────────────────────────────────────────────

local gpu, screen
for a in component.list("gpu")    do gpu    = component.proxy(a); break end
for a in component.list("screen") do screen = component.proxy(a); break end
if gpu and screen then gpu.bind(screen.address) end

local W, H = 80, 25
if gpu then W, H = gpu.maxResolution(); gpu.setResolution(W, H) end

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Colour palette
-- ─────────────────────────────────────────────────────────────────────────────

local C = {
  bg        = 0x050D18,
  bg2       = 0x0A1628,
  panel     = 0x0D1E30,
  panel2    = 0x112234,
  border    = 0x1A3A5C,
  border2   = 0x254A70,
  accent    = 0x00B4FF,
  accent2   = 0x0077CC,
  title     = 0xFFFFFF,
  text      = 0xBBCCDD,
  dim       = 0x4A6070,
  muted     = 0x2A3A4A,
  success   = 0x00CC66,
  warn      = 0xFFAA00,
  danger    = 0xFF4444,
  highlight = 0x153050,
  sel_fg    = 0x00D4FF,
  sel_bg    = 0x0E2A44,
  prog      = 0x0099EE,
  prog_bg   = 0x0A1E30,
  key_fg    = 0x00AAFF,
  key_bg    = 0x0A2030,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Drawing primitives
-- ─────────────────────────────────────────────────────────────────────────────

local function fg(c) if gpu then gpu.setForeground(c) end end
local function bg(c) if gpu then gpu.setBackground(c) end end
local function at(x, y, s, f, b)
  if not gpu then return end
  if f then gpu.setForeground(f) end
  if b then gpu.setBackground(b) end
  gpu.set(x, y, s)
end
local function fill(x, y, w, h, ch, f, b)
  if not gpu then return end
  if f then gpu.setForeground(f) end
  if b then gpu.setBackground(b) end
  gpu.fill(x, y, w, h, ch or " ")
end

-- Box characters
local B = {
  TL="╔",TR="╗",BL="╚",BR="╝",H="═",V="║",
  ML="╠",MR="╣",TT="╦",TB="╩",
  -- thin
  tl="┌",tr="┐",bl="└",br="┘",h="─",v="│",
  ml="├",mr="┤",
}

local function box(x, y, w, h, bcol, fcol, thin)
  local c = thin and {B.tl,B.tr,B.bl,B.br,B.h,B.v,B.ml,B.mr}
                  or {B.TL,B.TR,B.BL,B.BR,B.H,B.V,B.ML,B.MR}
  fg(bcol or C.border); bg(fcol or C.panel)
  at(x,   y,   c[1] .. string.rep(c[5], w-2) .. c[2])
  at(x,   y+h-1, c[3] .. string.rep(c[5], w-2) .. c[4])
  for r = y+1, y+h-2 do
    at(x,   r, c[6])
    fill(x+1, r, w-2, 1, " ")
    at(x+w-1, r, c[6])
  end
end

local function hline(x, y, w, bcol, fcol, thin)
  local ml = thin and B.ml or B.ML
  local mr = thin and B.mr or B.MR
  local h  = thin and B.h  or B.H
  fg(bcol or C.border); bg(fcol or C.panel)
  at(x, y, ml .. string.rep(h, w-2) .. mr)
end

local function center(x, y, w, s, f, b)
  local pad = math.max(0, math.floor((w - #s) / 2))
  at(x + pad, y, s, f, b)
end

local function rjust(x, y, w, s, f, b)
  at(x + w - #s, y, s, f, b)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Screen layout constants
-- ─────────────────────────────────────────────────────────────────────────────

local PW, PH = math.min(W, 72), math.min(H, 22)
local PX = math.floor((W - PW) / 2) + 1
local PY = math.floor((H - PH) / 2) + 1

-- Inner content area
local CX = PX + 2
local CW = PW - 4

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Static chrome (drawn once, persists across screens)
-- ─────────────────────────────────────────────────────────────────────────────

local LOGO_LINES = {
  "  ██╗   ██╗███╗  ██╗██╗      ██████╗  ███████╗",
  "  ██║   ██║████╗ ██║██║     ██╔═══██╗██╔════╝",
  "  ██║   ██║██╔██╗██║██║     ██║   ██║╚══███╔╝ ",
  "  ██║   ██║██║╚████║██║     ██║   ██║  ███╔╝  ",
  "  ╚██████╔╝██║ ╚███║███████╗╚██████╔╝███████╗ ",
  "   ╚═════╝ ╚═╝  ╚══╝╚══════╝ ╚═════╝ ╚══════╝",
}

local function draw_background()
  fill(1, 1, W, H, " ", C.bg2, C.bg)
  -- Subtle grid pattern
  fg(0x080F1C); bg(C.bg)
  for r = 1, H, 2 do
    gpu.set(1, r, string.rep("·", W))
  end
end

local function draw_panel_chrome()
  box(PX, PY, PW, PH, C.border2, C.panel)

  -- Logo strip at top
  fill(PX+1, PY+1, PW-2, #LOGO_LINES, " ", C.accent, C.panel)
  for i, line in ipairs(LOGO_LINES) do
    local grad = i <= 3 and C.accent or C.accent2
    center(PX+1, PY+i, PW-2, line, grad, C.panel)
  end

  -- Title bar separator
  hline(PX, PY + #LOGO_LINES + 1, PW, C.border2, C.panel)

  -- Sub-title
  center(PX+1, PY + #LOGO_LINES + 2, PW-2,
    "Installation Wizard  ·  v1.0", C.dim, C.panel)

  -- Bottom function-key bar
  hline(PX, PY+PH-3, PW, C.border2, C.panel)
  local keys = { {"↑↓","Navigate"}, {"Enter","Select"}, {"Tab","Next"}, {"Q","Quit"} }
  local bx = CX
  for _, k in ipairs(keys) do
    at(bx, PY+PH-2, "["..k[1].."]", C.key_fg, C.key_bg)
    at(bx + #k[1] + 2, PY+PH-2, k[2], C.dim, C.panel)
    bx = bx + #k[1] + #k[2] + 4
  end
end

-- Content area Y start (below logo + headers)
local CONT_Y = PY + #LOGO_LINES + 3   -- first usable content row
local CONT_H = PH - #LOGO_LINES - 6   -- rows available for content

local function clear_content()
  fill(CX, CONT_Y, CW, CONT_H, " ", C.text, C.panel)
end

-- Step indicator  (e.g.  ●──●──○──○──○──○)
local STEPS = { "Welcome", "Disk", "Options", "Confirm", "Install", "Done" }
local function draw_steps(current)
  local sy = PY + #LOGO_LINES + 2
  -- Re-draw the separator first
  hline(PX, sy-1, PW, C.border2, C.panel)
  local total = #STEPS
  local cell  = math.floor((PW - 4) / total)
  for i, name in ipairs(STEPS) do
    local sx = PX + 2 + (i-1) * cell
    local done    = i < current
    local active  = i == current
    local dot_ch  = done and "●" or (active and "◉" or "○")
    local dot_fg  = done and C.success or (active and C.accent or C.dim)
    at(sx, sy, dot_ch, dot_fg, C.panel)
    if i < total then
      local line_fg = done and C.success or C.muted
      at(sx+1, sy, string.rep("─", cell-1), line_fg, C.panel)
    end
    -- label below dot
    local lx = sx - math.floor(#name / 2) + 1
    at(lx, sy+1, name:sub(1, cell),
      active and C.accent or (done and C.success or C.dim), C.panel)
  end
end

-- Status bar  (second from bottom row)
local function status(msg, color)
  fill(CX, PY+PH-4, CW, 1, " ", C.text, C.panel)
  at(CX, PY+PH-4, msg:sub(1, CW), color or C.dim)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Input helper
-- ─────────────────────────────────────────────────────────────────────────────

-- Key codes
local KEY = { enter=28, tab=15, up=200, down=208, left=203, right=205,
              backspace=14, esc=1, space=57, del=211 }

local function read_key()
  while true do
    local ev, _, char, code = computer.pullSignal(0.05)
    if ev == "key_down" then
      return char, code
    end
  end
end

local function wait_enter()
  while true do
    local _, code = read_key()
    if code == KEY.enter or code == KEY.space then return end
    if code == KEY.esc then return "esc" end
  end
end

-- Inline text input widget
local function input_field(x, y, w, default, label)
  local buf = default or ""
  if label then at(x, y-1, label, C.dim, C.panel) end
  local function render()
    fill(x, y, w, 1, " ", C.title, C.sel_bg)
    at(x, y, buf:sub(1,w), C.title, C.sel_bg)
    -- Cursor
    local cx = x + #buf
    if cx <= x+w-1 then at(cx, y, "█", C.accent, C.sel_bg) end
  end
  render()
  while true do
    local char, code = read_key()
    if code == KEY.enter then break end
    if code == KEY.esc   then buf = default or ""; break end
    if code == KEY.backspace then
      if #buf > 0 then buf = buf:sub(1,-2) end
    elseif char and char >= 32 and char < 127 then
      if #buf < w - 1 then buf = buf .. string.char(char) end
    end
    render()
  end
  fill(x, y, w, 1, " ", C.text, C.panel)
  at(x, y, buf:sub(1,w), C.text, C.panel)
  return buf
end

-- Yes/No toggle widget; returns true/false
local function yesno(x, y, default, label)
  if label then at(x, y, label, C.text, C.panel) end
  local val = default
  local function render()
    local yc = val and C.success or C.dim
    local nc = val and C.dim     or C.danger
    at(x + #label + 2, y, "[ Yes ]", yc, val and C.sel_bg or C.panel)
    at(x + #label + 11, y, "[ No ]", nc, (not val) and C.sel_bg or C.panel)
  end
  render()
  while true do
    local _, code = read_key()
    if code == KEY.enter or code == KEY.tab then break end
    if code == KEY.left  or code == KEY.right or
       code == KEY.up    or code == KEY.down  then
      val = not val; render()
    end
    if code == KEY.esc then val = default; break end
  end
  return val
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Progress bar widget
-- ─────────────────────────────────────────────────────────────────────────────

local function progress_bar(x, y, w, pct, label, show_pct)
  local inner = w - 2
  local filled = math.floor(inner * pct / 100)
  local empty  = inner - filled
  at(x, y, "▕", C.border2, C.panel)
  if filled > 0 then
    fill(x+1, y, filled, 1, "█", C.prog, C.prog_bg)
  end
  if empty > 0 then
    fill(x+1+filled, y, empty, 1, "░", C.muted, C.prog_bg)
  end
  at(x+w-1, y, "▏", C.border2, C.panel)
  if label then
    local lx = x + math.floor((w - #label) / 2)
    at(lx, y, label, C.title, C.prog_bg)
  end
  if show_pct then
    rjust(x, y, w, string.format(" %3d%% ", pct), C.title, C.prog_bg)
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Scrollable list widget
-- ─────────────────────────────────────────────────────────────────────────────

local function list_widget(x, y, w, h, items, selected, title)
  if title then
    at(x, y-1, title, C.dim, C.panel)
    y = y  -- title is above
  end
  local function render(sel)
    local start = math.max(1, sel - h + 1)
    if sel < start then start = sel end
    for i = 0, h-1 do
      local idx = start + i
      local item = items[idx]
      if item then
        local line = (type(item) == "table") and item.label or tostring(item)
        line = line:sub(1, w-2)
        if idx == sel then
          fill(x, y+i, w, 1, " ", C.sel_fg, C.sel_bg)
          at(x, y+i, " ▶ " .. line, C.sel_fg, C.sel_bg)
        else
          fill(x, y+i, w, 1, " ", C.text, C.panel)
          at(x, y+i, "   " .. line, C.text, C.panel)
        end
      else
        fill(x, y+i, w, 1, " ", C.text, C.panel)
      end
    end
    -- Scrollbar
    if #items > h then
      local bar_h = math.max(1, math.floor(h * h / #items))
      local bar_y = math.floor((sel-1) / #items * (h - bar_h))
      for i = 0, h-1 do
        local ch = (i >= bar_y and i < bar_y + bar_h) and "▐" or "│"
        at(x+w-1, y+i, ch, i >= bar_y and i < bar_y+bar_h and C.accent or C.muted, C.panel)
      end
    end
  end

  render(selected)
  while true do
    local _, code = read_key()
    if code == KEY.up   then
      if selected > 1 then selected = selected - 1 end; render(selected)
    elseif code == KEY.down then
      if selected < #items then selected = selected + 1 end; render(selected)
    elseif code == KEY.enter then
      return selected
    elseif code == KEY.esc then
      return nil
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. Screen implementations
-- ─────────────────────────────────────────────────────────────────────────────

local function redraw_base(step)
  draw_background()
  draw_panel_chrome()
  draw_steps(step)
end

-- ── Screen 1: Welcome ─────────────────────────────────────────────────────────

local function screen_welcome()
  redraw_base(1)
  clear_content()

  local lines = {
    { "Welcome to the UniOS Installer!", C.accent,   true  },
    { "",                                C.text,     false },
    { "This wizard will guide you through installing UniOS",  C.text, false },
    { "onto an OpenComputers hard drive and optionally",      C.text, false },
    { "flashing the UniOS BIOS onto your EEPROM chip.",       C.text, false },
    { "",                                C.text,     false },
    { "Before continuing, make sure you have:",               C.dim,  false },
    { "  ● An unformatted or empty hard drive installed",     C.text, false },
    { "  ● The UniOS installer disk in a drive",              C.text, false },
    { "  ● An EEPROM chip (if you want auto-boot)",           C.text, false },
    { "",                                C.text,     false },
    { "Press  Enter  to begin.",         C.success,  true  },
  }

  for i, l in ipairs(lines) do
    local row = CONT_Y + i - 1
    if row >= CONT_Y + CONT_H then break end
    fill(CX, row, CW, 1, " ", l[2], C.panel)
    if l[3] then
      center(CX, row, CW, l[1], l[2], C.panel)
    else
      at(CX, row, l[1]:sub(1, CW), l[2], C.panel)
    end
  end

  status("Press Enter to continue, Q to quit.", C.dim)
  local k = wait_enter()
  if k == "esc" then return false end
  return true
end

-- ── Screen 2: Disk Selection ──────────────────────────────────────────────────

local function screen_disk()
  redraw_base(2)
  clear_content()

  center(CX, CONT_Y, CW, "Select Installation Target", C.accent, C.panel)
  at(CX, CONT_Y+1, string.rep("─", CW), C.muted, C.panel)

  -- Scan filesystems
  local disks = {}
  for addr in component.list("filesystem") do
    local fs = component.proxy(addr)
    local label = (fs.getLabel and fs.getLabel()) or "unlabeled"
    local ro    = fs.isReadOnly() and " [READ-ONLY]" or ""
    local total = fs.spaceTotal and fs.spaceTotal() or 0
    local used  = fs.spaceUsed  and fs.spaceUsed()  or 0
    local kb    = math.floor(total / 1024)
    local pct   = total > 0 and math.floor(used/total*100) or 0
    disks[#disks+1] = {
      label  = string.format("%-18s  %5dKB  %3d%% used  %s%s",
        label:sub(1,18), kb, pct, addr:sub(1,8), ro),
      addr   = addr,
      fs     = fs,
      ro     = fs.isReadOnly(),
      total  = total,
    }
  end

  if #disks == 0 then
    center(CX, CONT_Y+3, CW, "No filesystems found!", C.danger, C.panel)
    center(CX, CONT_Y+4, CW, "Insert a hard drive and restart.", C.dim, C.panel)
    status("No disk found. Press any key.", C.danger)
    read_key(); return nil
  end

  -- Filter hint
  at(CX, CONT_Y+2, "Writable disks are shown. Read-only disks cannot be installed to.", C.dim, C.panel)

  local sel = list_widget(CX, CONT_Y+3, CW, CONT_H-3, disks, 1,
    "Available filesystems:")

  if not sel then return nil end
  local chosen = disks[sel]
  if chosen.ro then
    status("That disk is read-only. Choose another.", C.danger)
    os.sleep(1.5)
    return screen_disk()
  end
  return chosen
end

-- ── Screen 3: Options ─────────────────────────────────────────────────────────

local function screen_options(disk)
  redraw_base(3)
  clear_content()

  center(CX, CONT_Y, CW, "Installation Options", C.accent, C.panel)
  at(CX, CONT_Y+1, string.rep("─", CW), C.muted, C.panel)

  local oy = CONT_Y + 3

  -- Hostname
  at(CX, oy, "Hostname:", C.dim, C.panel)
  local hostname = input_field(CX+12, oy, 24, "uni")
  if hostname == "" then hostname = "uni" end

  oy = oy + 2

  -- Flash EEPROM?
  local has_eeprom = false
  for _ in component.list("eeprom") do has_eeprom = true; break end

  local flash_eeprom = false
  if has_eeprom then
    flash_eeprom = yesno(CX, oy, true, "Flash EEPROM:  ")
    oy = oy + 2
  else
    at(CX, oy, "Flash EEPROM:   No EEPROM detected – skipping.", C.dim, C.panel)
    oy = oy + 2
  end

  -- Create home dir
  local make_home = yesno(CX, oy, true, "Create /root:  ")
  oy = oy + 2

  -- Wipe disk first?
  local wipe = yesno(CX, oy, false, "Wipe disk:     ")
  if wipe then
    at(CX, oy+1, "  ⚠  All existing data will be erased!", C.warn, C.panel)
  end

  status("Press Enter to continue.", C.dim)
  wait_enter()

  return {
    hostname     = hostname,
    flash_eeprom = flash_eeprom and has_eeprom,
    make_home    = make_home,
    wipe         = wipe,
  }
end

-- ── Screen 4: Confirm ─────────────────────────────────────────────────────────

local function screen_confirm(disk, opts)
  redraw_base(4)
  clear_content()

  center(CX, CONT_Y, CW, "Confirm Installation", C.accent, C.panel)
  at(CX, CONT_Y+1, string.rep("─", CW), C.muted, C.panel)

  local rows = {
    { "Target disk:",  disk.label:match("^[^%s]+") or "?",     C.text },
    { "Disk addr:",    disk.addr:sub(1,12) .. "...",            C.dim  },
    { "Disk size:",    math.floor(disk.total/1024) .. " KB",    C.text },
    { "Hostname:",     opts.hostname,                           C.accent },
    { "Flash EEPROM:", opts.flash_eeprom and "Yes" or "No",
        opts.flash_eeprom and C.success or C.dim },
    { "Create /root:", opts.make_home and "Yes" or "No",        C.text },
    { "Wipe disk:",    opts.wipe and "YES – ALL DATA LOST!" or "No",
        opts.wipe and C.danger or C.text },
  }

  for i, row in ipairs(rows) do
    local y = CONT_Y + 2 + i
    at(CX,    y, row[1], C.dim, C.panel)
    at(CX+16, y, row[2], row[3], C.panel)
  end

  at(CX, CONT_Y+2+#rows+2, string.rep("─", CW), C.muted, C.panel)
  center(CX, CONT_Y+2+#rows+3, CW,
    "Press Enter to install, Esc to go back.", C.warn, C.panel)

  status("Last chance to cancel!", C.warn)
  local k = wait_enter()
  return k ~= "esc"
end

-- ── Screen 5: Install Progress ────────────────────────────────────────────────

-- Log widget (scrolling, inside the panel)
local _log = {}
local LOG_Y_START = CONT_Y + 2
local LOG_ROWS    = CONT_H - 5

local function log_line(msg, color)
  _log[#_log+1] = { msg = msg, color = color or C.text }
  -- Render last LOG_ROWS lines
  local start = math.max(1, #_log - LOG_ROWS + 1)
  for i = 0, LOG_ROWS-1 do
    local entry = _log[start + i]
    local row   = LOG_Y_START + i
    fill(CX, row, CW, 1, " ", C.text, C.panel)
    if entry then
      at(CX, row, entry.msg:sub(1, CW), entry.color, C.panel)
    end
  end
end

local _prog_y = CONT_Y + CONT_H - 2  -- progress bar row

local function set_prog(pct, label)
  progress_bar(CX, _prog_y, CW, pct, label, true)
end

-- Utility: copy all files from src_fs to dst_fs, recursively
local function copy_tree(src_fs, dst_fs, src_dir, dst_dir, on_file)
  local entries = src_fs.list(src_dir)
  if not entries then return end
  -- Ensure destination directory exists
  if not dst_fs.exists(dst_dir) then dst_fs.makeDirectory(dst_dir) end
  for _, name in ipairs(entries) do
    local src_path = src_dir .. "/" .. name
    local dst_path = dst_dir .. "/" .. name
    if src_fs.isDirectory(src_path) then
      copy_tree(src_fs, dst_fs, src_path, dst_path, on_file)
    else
      if on_file then on_file(src_path) end
      -- Copy file
      local h_in = src_fs.open(src_path, "r")
      if h_in then
        if dst_fs.exists(dst_path) then dst_fs.remove(dst_path) end
        local h_out = dst_fs.open(dst_path, "w")
        if h_out then
          repeat
            local chunk = src_fs.read(h_in, 4096)
            if chunk then dst_fs.write(h_out, chunk) end
          until not chunk
          dst_fs.close(h_out)
        end
        src_fs.close(h_in)
      end
    end
  end
end

-- Count total files in a tree
local function count_tree(fs, dir)
  local n = 0
  local entries = fs.list(dir) or {}
  for _, name in ipairs(entries) do
    local path = dir .. "/" .. name
    if fs.isDirectory(path) then
      n = n + count_tree(fs, path)
    else
      n = n + 1
    end
  end
  return n
end

local function screen_install(disk, opts)
  redraw_base(5)
  clear_content()

  center(CX, CONT_Y, CW, "Installing UniOS…", C.accent, C.panel)
  at(CX, CONT_Y+1, string.rep("─", CW), C.muted, C.panel)

  status("Installation in progress. Do NOT power off!", C.warn)
  set_prog(0, "  Starting…  ")

  local dst = disk.fs
  local errors = {}

  -- ── Step 1: Find installer source ──────────────────────────────────────────
  log_line("Locating installer source disk…", C.dim)
  set_prog(2, "  Locating source…  ")

  local src_fs = nil
  local src_addr = nil

  -- We prefer a disk that has /boot/init.lua (the UniOS source disk)
  for addr in component.list("filesystem") do
    if addr ~= disk.addr then
      local fs = component.proxy(addr)
      if fs.exists("/boot/init.lua") and fs.exists("/kernel/kernel.lua") then
        src_fs   = fs
        src_addr = addr
        break
      end
    end
  end

  -- Fallback: look for /uni/boot/init.lua
  if not src_fs then
    for addr in component.list("filesystem") do
      if addr ~= disk.addr then
        local fs = component.proxy(addr)
        if fs.exists("/uni/boot/init.lua") then
          src_fs   = fs
          src_addr = addr
          -- We'll need to adjust source path below
          break
        end
      end
    end
  end

  if not src_fs then
    -- Last resort: use the target disk itself (if it already has files)
    if dst.exists("/boot/init.lua") then
      log_line("  Source = target disk (already installed)", C.warn)
      src_fs   = dst
      src_addr = disk.addr
    else
      log_line("✗ Cannot find UniOS source files!", C.danger)
      log_line("  Insert the UniOS installer disk and retry.", C.dim)
      set_prog(100, "  FAILED  ")
      status("Error: source disk not found.", C.danger)
      return false, {"Source disk not found"}
    end
  end

  local src_root = "/"
  if src_fs ~= dst and src_fs.exists("/uni/boot/init.lua") then
    src_root = "/uni"
  end

  log_line("✓ Source: " .. src_addr:sub(1,8) .. " (root=" .. src_root .. ")", C.success)
  set_prog(5, "  Scanning files…  ")

  -- ── Step 2: Wipe ───────────────────────────────────────────────────────────
  if opts.wipe then
    log_line("Wiping target disk…", C.warn)
    set_prog(8, "  Wiping…  ")
    local entries = dst.list("/") or {}
    for _, name in ipairs(entries) do
      -- Recursive remove
      local function rm_r(path)
        if dst.isDirectory(path) then
          for _, c in ipairs(dst.list(path) or {}) do rm_r(path.."/"..c) end
          dst.remove(path)
        else
          dst.remove(path)
        end
      end
      rm_r("/" .. name)
    end
    log_line("✓ Disk wiped.", C.success)
  end

  set_prog(10, "  Counting files…  ")

  -- ── Step 3: Count files ────────────────────────────────────────────────────
  local total_files = count_tree(src_fs, src_root)
  log_line("Files to copy: " .. total_files, C.dim)
  set_prog(12, "  Copying files…  ")

  -- ── Step 4: Copy tree ──────────────────────────────────────────────────────
  local copied  = 0
  local last_pct = 12
  log_line("Copying filesystem tree…", C.dim)

  copy_tree(src_fs, dst, src_root, "/", function(path)
    copied = copied + 1
    local pct = 12 + math.floor(copied / math.max(total_files,1) * 60)
    if pct ~= last_pct then
      set_prog(pct, string.format("  Copying… %d/%d  ", copied, total_files))
      last_pct = pct
    end
    local short = path:match("[^/]+$") or path
    log_line("  + " .. short, C.dim)
  end)

  log_line(string.format("✓ Copied %d files.", copied), C.success)
  set_prog(73, "  Writing config…  ")

  -- ── Step 5: Write /etc/hostname ────────────────────────────────────────────
  log_line("Writing /etc/hostname…", C.dim)
  if not dst.exists("/etc") then dst.makeDirectory("/etc") end
  local hh = dst.open("/etc/hostname", "w")
  if hh then dst.write(hh, opts.hostname .. "\n"); dst.close(hh) end
  log_line("✓ Hostname: " .. opts.hostname, C.success)
  set_prog(76, "  Config written  ")

  -- ── Step 6: Create /root ───────────────────────────────────────────────────
  if opts.make_home then
    if not dst.exists("/root") then
      dst.makeDirectory("/root")
      log_line("✓ Created /root", C.success)
    end
    -- Write a minimal ~/.shrc
    local rc = dst.open("/root/.shrc", "w")
    if rc then
      dst.write(rc, "# UniOS user shell rc\nexport PS1='\\u@\\h:\\w\\$ '\n")
      dst.close(rc)
    end
  end
  set_prog(80, "  Directories…  ")

  -- ── Step 7: Ensure standard dirs ───────────────────────────────────────────
  log_line("Creating standard directories…", C.dim)
  local std = {"/bin","/lib","/etc","/tmp","/var","/usr","/usr/bin","/usr/lib","/sbin"}
  for _, d in ipairs(std) do
    if not dst.exists(d) then dst.makeDirectory(d); log_line("  mkdir " .. d, C.dim) end
  end
  set_prog(85, "  Directories OK  ")

  -- ── Step 8: Install /sbin/init ─────────────────────────────────────────────
  -- /sbin/init is just a symlink stub pointing sh to be PID 1
  if not dst.exists("/sbin/init.lua") and dst.exists("/bin/sh.lua") then
    log_line("Creating /sbin/init.lua stub…", C.dim)
    local si = dst.open("/sbin/init.lua", "w")
    if si then
      dst.write(si, '-- UniOS /sbin/init (stub)\n'
        .. 'local src = kernel.vfs.readfile("/bin/sh.lua")\n'
        .. 'if src then\n'
        .. '  local fn = load(src,"=sh","t",_G)\n'
        .. '  if fn then fn() end\n'
        .. 'end\n')
      dst.close(si)
      log_line("✓ /sbin/init.lua written", C.success)
    end
  end
  set_prog(88, "  Init written  ")

  -- ── Step 9: Flash EEPROM ───────────────────────────────────────────────────
  if opts.flash_eeprom then
    log_line("Flashing EEPROM…", C.accent)
    set_prog(90, "  Flashing EEPROM…  ")
    local eeprom = nil
    for a in component.list("eeprom") do eeprom = component.proxy(a); break end

    if not eeprom then
      log_line("  ⚠ No EEPROM found – skipping.", C.warn)
    else
      -- Find bios image — prefer .min.lua (pre-minified), fall back to full source
      local bios_src = nil
      local bios_paths = {
        "/eeprom/bios.min.lua",
        "/eeprom/bios.lua",
        "/bios.min.lua",
        "/bios.lua",
      }
      for _, bp in ipairs(bios_paths) do
        if dst.exists(bp) then
          local bh = dst.open(bp, "r")
          if bh then
            bios_src = ""
            repeat
              local c = dst.read(bh, math.huge)
              if c then bios_src = bios_src .. c end
            until not c
            dst.close(bh)
            local tag = bp:match("%.min%.lua$") and " [minified]" or ""
            log_line("  BIOS: " .. bp .. " (" .. #bios_src .. "B)" .. tag, C.dim)
            break
          end
        end
      end

      if not bios_src then
        log_line("  ⚠ bios.lua not found on target – skipping.", C.warn)
        errors[#errors+1] = "EEPROM not flashed (bios.lua not found)"
      elseif #bios_src > eeprom.getSize() then
        log_line("  ⚠ BIOS too large for EEPROM – skipping.", C.warn)
        errors[#errors+1] = "BIOS too large for EEPROM"
      else
        local ok2, e2 = pcall(function() eeprom.set(bios_src) end)
        if ok2 then
          pcall(function() eeprom.setLabel("UniOS BIOS 1.0") end)
          log_line("✓ EEPROM flashed!", C.success)
        else
          log_line("✗ EEPROM flash error: " .. tostring(e2), C.danger)
          errors[#errors+1] = "EEPROM flash failed: " .. tostring(e2)
        end
      end
    end
  end

  set_prog(98, "  Finalising…  ")
  log_line("", C.text)
  log_line("✓ Installation complete!", C.success)
  set_prog(100, "  Done!  ")

  return true, errors
end

-- ── Screen 6: Done ────────────────────────────────────────────────────────────

local function screen_done(success, errors)
  redraw_base(6)
  clear_content()

  if success then
    center(CX, CONT_Y,   CW, "Installation Complete!", C.success, C.panel)
    center(CX, CONT_Y+1, CW, "UniOS has been installed successfully.", C.text, C.panel)
    at(CX, CONT_Y+3, "What to do next:", C.dim, C.panel)
    local steps = {
      "1. Remove the installer disk from the drive.",
      "2. Make sure the UniOS disk is installed.",
      "3. Reboot the computer.",
      "4. The UniOS BIOS will load and boot the OS.",
    }
    if not false then -- always show
      for i, s in ipairs(steps) do
        at(CX, CONT_Y+4+i, s, C.text, C.panel)
      end
    end
    if #errors > 0 then
      at(CX, CONT_Y+4+#steps+2, "Warnings:", C.warn, C.panel)
      for i, e in ipairs(errors) do
        at(CX, CONT_Y+4+#steps+2+i, "  ⚠ " .. e, C.warn, C.panel)
      end
    end
    status("Press Enter to reboot, Esc to stay.", C.success)
    center(CX, CONT_Y+10, CW, "[ Press Enter to reboot ]", C.accent, C.panel)
  else
    center(CX, CONT_Y,   CW, "Installation Failed", C.danger, C.panel)
    at(CX, CONT_Y+2, "Errors:", C.dim, C.panel)
    for i, e in ipairs(errors or {}) do
      at(CX, CONT_Y+2+i, "  ✗ " .. e, C.danger, C.panel)
    end
    at(CX, CONT_Y+6, "Check the installer disk is inserted and try again.", C.text, C.panel)
    status("Press any key to exit.", C.danger)
  end

  local k = wait_enter()
  if success and k ~= "esc" then
    -- Reboot
    computer.shutdown(true)
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. Main flow
-- ─────────────────────────────────────────────────────────────────────────────

local function main()
  -- Welcome
  local ok = screen_welcome()
  if not ok then
    if gpu then
      gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
      gpu.fill(1,1,W,H," ")
    end
    return
  end

  -- Disk selection
  local disk
  while true do
    disk = screen_disk()
    if disk then break end
    -- If nil was returned (esc), go back to welcome
    ok = screen_welcome()
    if not ok then return end
  end

  -- Options
  local opts = screen_options(disk)
  if not opts then return end

  -- Confirm
  local confirmed = screen_confirm(disk, opts)
  if not confirmed then
    -- Go back to start
    return main()
  end

  -- Install
  local success, errors = screen_install(disk, opts)

  -- A moment to read logs
  status("Installation " .. (success and "complete" or "failed") .. ". Press any key…",
    success and C.success or C.danger)
  read_key()

  -- Done screen
  screen_done(success, errors)

  -- Restore terminal
  if gpu then
    gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
    gpu.fill(1,1,W,H," ")
    gpu.set(1,1,"UniOS installer finished.")
  end
end

main()
