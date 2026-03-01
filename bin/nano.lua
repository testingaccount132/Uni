-- nano – terminal text editor for UniOS
-- A nano-style editor for UniOS (OpenComputers).

local CTRL_S, CTRL_Q, CTRL_G, CTRL_K, CTRL_U, CTRL_W, CTRL_C = 19, 17, 7, 11, 21, 23, 3

local gpu_drv = kernel.drivers.gpu
local gpu     = gpu_drv and gpu_drv.raw()
local kbd     = kernel.drivers.keyboard
local vfs     = kernel.vfs

if not gpu then
  if gpu_drv then gpu_drv.write("nano: no GPU available\n") end
  return 1
end

local W, H
local cwd

local function init_screen()
  W, H = gpu_drv.size()
  if not W or W < 10 then W, H = gpu.maxResolution() end
  gpu.setResolution(W, H)
end

-- Resolve path (use sys if available, else fallback)
local function resolve_path(path)
  if not path or path == "" then return nil end
  if path:sub(1, 1) == "/" then return vfs.resolve(path, "/") end
  local base = cwd or "/"
  return vfs.resolve(path, base)
end

-- Colors
local C_BG       = 0x1A1A2E
local C_HEADER_BG= 0x16213E
local C_HEADER_FG= 0x00B4FF
local C_LINENUM_FG= 0x4A5568
local C_LINENUM_BG= 0x1A1A2E
local C_TEXT_FG  = 0xE2E8F0
local C_TEXT_BG  = 0x1A1A2E
local C_STATUS_BG= 0x16213E
local C_CURSOR_BG= 0x252545
local C_HIGHLIGHT_BG = 0x2D4A6F

-- State
local lines      = { "" }
local filename   = nil
local abs_path   = nil
local modified   = false
local clipboard  = ""
local search_term= ""
local search_pos = nil
local row, col   = 1, 1
local scroll_y   = 1
local scroll_x   = 0
local status_msg = nil
local line_num_w = 5

local HEADER_H = 1
local FOOTER_H = 1

local function sanitize_display(s)
  if not s or s == "" then return "" end
  local out = {}
  for i = 1, #s do
    local b = s:byte(i)
    if b >= 32 and b <= 126 then
      out[#out + 1] = s:sub(i, i)
    else
      out[#out + 1] = "."
    end
  end
  return table.concat(out)
end

local function line_num_width()
  local n = #lines
  if n <= 0 then return 1 end
  local w = 0
  while n > 0 do w = w + 1; n = math.floor(n / 10) end
  return math.max(4, math.min(w + 1, 8))
end

local function text_area()
  local tw = W - line_num_w - 1
  local th = H - HEADER_H - FOOTER_H
  return line_num_w + 1, HEADER_H + 1, math.max(1, tw), math.max(1, th)
end

local function ensure_cursor_visible()
  local _, _, tw, th = text_area()
  if row < scroll_y then scroll_y = row end
  if row >= scroll_y + th then scroll_y = row - th + 1 end
  if col - 1 < scroll_x then scroll_x = math.max(0, col - 1) end
  if col - 1 >= scroll_x + tw then scroll_x = col - tw end
end

local function set_modified(m)
  modified = m
end

local function insert_char(r, c, ch)
  local ln = lines[r] or ""
  local left = ln:sub(1, c - 1)
  local right = ln:sub(c)
  lines[r] = left .. ch .. right
  set_modified(true)
end

local function delete_char(r, c)
  local ln = lines[r] or ""
  if c <= #ln then
    lines[r] = ln:sub(1, c - 1) .. ln:sub(c + 1)
    set_modified(true)
    return true
  end
  return false
end

local function backspace(r, c)
  if c > 1 then
    local ln = lines[r] or ""
    lines[r] = ln:sub(1, c - 2) .. ln:sub(c)
    set_modified(true)
    return true, c - 1
  elseif r > 1 then
    local prev = lines[r - 1] or ""
    local curr = lines[r] or ""
    table.remove(lines, r)
    lines[r - 1] = prev .. curr
    set_modified(true)
    return true, #prev + 1, r - 1
  end
  return false
end

local function delete_key(r, c)
  local ln = lines[r] or ""
  if c <= #ln then
    return delete_char(r, c)
  elseif r < #lines then
    local next_ln = lines[r + 1] or ""
    lines[r] = ln .. next_ln
    table.remove(lines, r + 1)
    set_modified(true)
    return true
  end
  return false
end

local function newline_at(r, c)
  local ln = lines[r] or ""
  local left = ln:sub(1, c - 1)
  local right = ln:sub(c)
  lines[r] = left
  table.insert(lines, r + 1, right)
  set_modified(true)
  return r + 1, 1
end

local function cut_line(r)
  clipboard = lines[r] or ""
  table.remove(lines, r)
  if #lines == 0 then lines[1] = "" end
  set_modified(true)
  if row > #lines then row = #lines end
  col = 1
  if row < 1 then row = 1 end
  local ln = lines[row] or ""
  col = math.min(col, #ln + 1)
end

local function paste_line(r)
  table.insert(lines, r, clipboard)
  set_modified(true)
  row = r
  col = 1
end

local function find_next(search, from_row, from_col, wrap)
  if not search or search == "" then return nil end
  local start_r, start_c = from_row, from_col + 1
  for r = start_r, #lines do
    local ln = lines[r] or ""
    local start_i = (r == start_r) and start_c or 1
    local idx = ln:find(search, start_i, true)
    if idx then return r, idx end
  end
  if wrap then
    for r = 1, from_row do
      local ln = lines[r] or ""
      local idx = ln:find(search, 1, true)
      if idx then return r, idx end
    end
  end
  return nil
end

local function draw_header(force)
  gpu.setForeground(C_HEADER_FG)
  gpu.setBackground(C_HEADER_BG)
  local title = " nano " .. (filename or "New Buffer") .. (modified and " *" or "") .. " "
  local pad = (" "):rep(math.max(0, W - #title))
  gpu.set(1, 1, title .. pad)
end

local function draw_footer(force)
  gpu.setForeground(C_TEXT_FG)
  gpu.setBackground(C_STATUS_BG)
  local help = " ^S Save  ^Q Quit  ^G Goto  ^K Cut  ^U Paste  ^W Search "
  if #help > W then help = help:sub(1, W) end
  gpu.set(1, H, help .. (" "):rep(math.max(0, W - #help)))
end

local function draw_status(msg)
  status_msg = msg
  gpu.setForeground(C_HEADER_FG)
  gpu.setBackground(C_STATUS_BG)
  local s = " " .. (msg or "") .. " "
  if #s > W then s = s:sub(1, W) end
  gpu.set(1, H, s .. (" "):rep(math.max(0, W - #s)))
end

local function clear_status()
  status_msg = nil
  draw_footer()
end

local function draw_line_num(y_draw, line_idx)
  gpu.setForeground(C_LINENUM_FG)
  gpu.setBackground(C_LINENUM_BG)
  local num = tostring(line_idx)
  local pad = (" "):rep(line_num_w - #num) .. num
  gpu.set(1, y_draw, pad)
end

local function draw_line(y_draw, line_idx, cursor_on_line, cursor_col)
  local ln = lines[line_idx] or ""
  local disp = sanitize_display(ln)
  local _, _, tw, _ = text_area()
  local visible = disp:sub(scroll_x + 1, scroll_x + tw)
  local cx, cy = line_num_w + 1, y_draw

  local search_len = #search_term
  local highlight_pos = nil
  if search_term ~= "" and search_pos and search_pos[1] == line_idx then
    local sr, sc = search_pos[1], search_pos[2]
    if sc >= scroll_x + 1 and sc <= scroll_x + tw then
      highlight_pos = sc - scroll_x
    end
  end

  if cursor_on_line then
    gpu.setBackground(C_CURSOR_BG)
  else
    gpu.setBackground(C_TEXT_BG)
  end
  gpu.setForeground(C_TEXT_FG)

  if highlight_pos then
    local pre = visible:sub(1, highlight_pos - 1)
    local hi  = visible:sub(highlight_pos, highlight_pos + search_len - 1)
    local post = visible:sub(highlight_pos + search_len)
    if #pre > 0 then gpu.set(cx, cy, pre); cx = cx + #pre end
    gpu.setBackground(C_HIGHLIGHT_BG)
    if #hi > 0 then gpu.set(cx, cy, hi); cx = cx + #hi end
    gpu.setBackground(cursor_on_line and C_CURSOR_BG or C_TEXT_BG)
    if #post > 0 then gpu.set(cx, cy, post) end
  else
    gpu.set(cx, cy, visible)
  end

  local clear_w = tw - #visible
  if clear_w > 0 then
    gpu.set(cx + #visible, cy, (" "):rep(clear_w))
  end
end

local function redraw_all()
  line_num_w = line_num_width()
  local _, ty, tw, th = text_area()

  gpu.setBackground(C_BG)
  gpu.setForeground(C_TEXT_FG)
  gpu.fill(1, 1, W, H, " ")

  draw_header()
  for i = 1, th do
    local line_idx = scroll_y + i - 1
    if line_idx <= #lines then
      draw_line_num(ty + i - 1, line_idx)
      local cursor_on = (line_idx == row)
      local cursor_col = cursor_on and col or 0
      draw_line(ty + i - 1, line_idx, cursor_on, cursor_col)
    else
      gpu.setForeground(C_LINENUM_FG)
      gpu.setBackground(C_LINENUM_BG)
      gpu.set(1, ty + i - 1, (" "):rep(line_num_w))
      gpu.setBackground(C_TEXT_BG)
      gpu.set(line_num_w + 1, ty + i - 1, (" "):rep(tw))
    end
  end
  draw_footer()

  local cursor_screen_col = line_num_w + (col - scroll_x)
  local cursor_screen_row = ty + (row - scroll_y)
  if row >= scroll_y and row < scroll_y + th and col >= scroll_x + 1 and col <= scroll_x + tw then
    gpu_drv.set_cursor(cursor_screen_col, cursor_screen_row)
  end
end

local function redraw_lines(from_idx, to_idx)
  line_num_w = line_num_width()
  local _, ty, tw, th = text_area()
  for i = 1, th do
    local line_idx = scroll_y + i - 1
    if line_idx >= from_idx and line_idx <= to_idx and line_idx <= #lines then
      draw_line_num(ty + i - 1, line_idx)
      draw_line(ty + i - 1, line_idx, (line_idx == row), (line_idx == row) and col or 0)
    end
  end
  local cursor_screen_col = line_num_w + (col - scroll_x)
  local cursor_screen_row = ty + (row - scroll_y)
  if row >= scroll_y and row < scroll_y + th and col >= scroll_x + 1 and col <= scroll_x + tw then
    gpu_drv.set_cursor(cursor_screen_col, cursor_screen_row)
  end
end

local function redraw_cursor_line()
  redraw_lines(row, row)
end

local function prompt_input(prompt_text, default)
  kbd.set_raw(true)
  gpu.setForeground(C_HEADER_FG)
  gpu.setBackground(C_STATUS_BG)
  local _, ty, tw, th = text_area()
  local py = HEADER_H + th
  if py >= H then py = H - 1 end
  gpu.set(1, py, (" "):rep(W))
  gpu.set(1, py, prompt_text .. (default or ""))
  gpu_drv.set_cursor(#prompt_text + #tostring(default or "") + 1, py)

  local input = default or ""
  local pos = #input + 1

  while true do
    local ch = kbd.getchar()
    if ch == "\3" then
      kbd.set_raw(false)
      return nil
    elseif ch == "\n" or ch == "\r" then
      kbd.set_raw(false)
      draw_footer()
      return input
    elseif ch == "\8" or ch == "\127" then
      if pos > 1 then
        input = input:sub(1, pos - 2) .. input:sub(pos)
        pos = pos - 1
        gpu.set(1, py, (" "):rep(W))
        gpu.set(1, py, prompt_text .. input)
        gpu_drv.set_cursor(#prompt_text + pos, py)
      end
    elseif ch == "left" then
      if pos > 1 then pos = pos - 1; gpu_drv.set_cursor(#prompt_text + pos, py) end
    elseif ch == "right" then
      if pos <= #input then pos = pos + 1; gpu_drv.set_cursor(#prompt_text + pos, py) end
    elseif ch == "home" then
      pos = 1; gpu_drv.set_cursor(#prompt_text + 1, py)
    elseif ch == "end" then
      pos = #input + 1; gpu_drv.set_cursor(#prompt_text + pos, py)
    elseif type(ch) == "string" and #ch == 1 then
      local b = ch:byte(1)
      if b ~= CTRL_S and b ~= CTRL_Q and b ~= CTRL_G and b ~= CTRL_K and b ~= CTRL_U and b ~= CTRL_W then
        input = input:sub(1, pos - 1) .. ch .. input:sub(pos)
        pos = pos + 1
        gpu.set(1, py, (" "):rep(W))
        gpu.set(1, py, prompt_text .. input)
        gpu_drv.set_cursor(#prompt_text + pos, py)
      end
    end
  end
end

local function do_save()
  if not abs_path then
    local fn = prompt_input("File Name to Write: ", filename or "")
    if not fn then return false end
    abs_path = resolve_path(fn)
    filename = fn
  end
  if not abs_path then
    draw_status("No file name")
    return false
  end
  local data = table.concat(lines, "\n") .. "\n"
  local ok, err = vfs.writefile(abs_path, data)
  if ok then
    set_modified(false)
    draw_status("Saved")
    return true
  else
    draw_status("Error: " .. tostring(err))
    return false
  end
end

local function do_quit()
  if modified then
    local a = prompt_input("Save modified buffer? (Y/N/C) ", "")
    if not a then return false end
    a = a:lower():sub(1, 1)
    if a == "y" then
      if not do_save() then return false end
    elseif a == "c" then
      return false
    end
  end
  return true
end

local function do_goto_line()
  local inp = prompt_input("Go to line: ", tostring(row))
  if not inp then return end
  local n = tonumber(inp)
  if n and n >= 1 and n <= #lines then
    row = n
    col = 1
    ensure_cursor_visible()
    redraw_all()
  else
    draw_status("Invalid line number")
  end
end

local function do_search()
  local inp = prompt_input("Search: ", search_term)
  if not inp then return end
  search_term = inp
  if search_term == "" then
    search_pos = nil
    redraw_all()
    return
  end
  local r, idx = find_next(search_term, row, col, true)
  if r then
    row, col = r, idx
    search_pos = { row, col }
    ensure_cursor_visible()
    redraw_all()
    draw_status("Found")
  else
    search_pos = nil
    draw_status("Not found")
  end
end

local function do_search_next()
  if search_term == "" then return do_search() end
  local from_c = (search_pos and search_pos[1] == row and search_pos[2] == col) and col or col - 1
  local r, idx = find_next(search_term, row, from_c, true)
  if r then
    row, col = r, idx
    search_pos = { row, col }
    ensure_cursor_visible()
    redraw_all()
    draw_status("Found")
  else
    draw_status("Not found")
  end
end

local function load_file(path)
  abs_path = (path and path ~= "") and resolve_path(path) or nil
  filename = (path and path ~= "") and path or "New Buffer"
  lines = { "" }
  if abs_path and vfs.exists(abs_path) then
    local data = vfs.readfile(abs_path)
    if data then
      lines = {}
      for line in (data .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
      end
      if #lines == 0 then lines[1] = "" end
      set_modified(false)
    else
      draw_status("Cannot read file")
    end
  else
    set_modified(false)
  end
  row, col = 1, 1
  scroll_y, scroll_x = 1, 0
  search_pos = nil
end

local function handle_key(ch)
  if status_msg then clear_status() end
  local b = type(ch) == "string" and #ch == 1 and ch:byte(1) or nil

  if b == CTRL_Q then
    if do_quit() then return "quit" end
    return nil
  end

  if b == CTRL_S then
    do_save()
    return nil
  end

  if b == CTRL_G then
    do_goto_line()
    return nil
  end

  if b == CTRL_K then
    cut_line(row)
    redraw_all()
    return nil
  end

  if b == CTRL_U then
    paste_line(row)
    redraw_all()
    return nil
  end

  if b == CTRL_W then
    do_search()
    return nil
  end

  if ch == "up" then
    if row > 1 then
      row = row - 1
      col = math.min(col, #(lines[row] or "") + 1)
      ensure_cursor_visible()
      redraw_all()
    end
    return nil
  end

  if ch == "down" then
    if row < #lines then
      row = row + 1
      col = math.min(col, #(lines[row] or "") + 1)
      ensure_cursor_visible()
      redraw_all()
    end
    return nil
  end

  if ch == "left" then
    if col > 1 then
      col = col - 1
      ensure_cursor_visible()
      redraw_cursor_line()
      gpu_drv.set_cursor(line_num_w + (col - scroll_x), HEADER_H + (row - scroll_y))
    end
    return nil
  end

  if ch == "right" then
    local ln = lines[row] or ""
    if col <= #ln then
      col = col + 1
      ensure_cursor_visible()
      redraw_cursor_line()
      gpu_drv.set_cursor(line_num_w + (col - scroll_x), HEADER_H + (row - scroll_y))
    end
    return nil
  end

  if ch == "home" then
    col = 1
    ensure_cursor_visible()
    redraw_cursor_line()
    gpu_drv.set_cursor(line_num_w + 1, HEADER_H + (row - scroll_y))
    return nil
  end

  if ch == "end" then
    col = #(lines[row] or "") + 1
    ensure_cursor_visible()
    redraw_cursor_line()
    gpu_drv.set_cursor(line_num_w + (col - scroll_x), HEADER_H + (row - scroll_y))
    return nil
  end

  if ch == "pageup" then
    local _, _, _, th = text_area()
    row = math.max(1, row - th)
    col = math.min(col, #(lines[row] or "") + 1)
    scroll_y = math.max(1, scroll_y - th)
    ensure_cursor_visible()
    redraw_all()
    return nil
  end

  if ch == "pagedown" then
    local _, _, _, th = text_area()
    row = math.min(#lines, row + th)
    col = math.min(col, #(lines[row] or "") + 1)
    scroll_y = math.max(1, math.min(#lines - th + 1, scroll_y + th))
    ensure_cursor_visible()
    redraw_all()
    return nil
  end

  if ch == "\8" or ch == "\127" then
    local ok, new_col, new_row = backspace(row, col)
    if ok then
      col = new_col or col
      if new_row then row = new_row end
      ensure_cursor_visible()
      redraw_all()
    end
    return nil
  end

  if ch == "delete" then
    if delete_key(row, col) then
      ensure_cursor_visible()
      redraw_all()
    end
    return nil
  end

  if ch == "\n" or ch == "\r" then
    row, col = newline_at(row, col)
    ensure_cursor_visible()
    redraw_all()
    return nil
  end

  if ch == "\t" then
    insert_char(row, col, "  ")
    col = col + 2
    ensure_cursor_visible()
    redraw_all()
    return nil
  end

  if type(ch) == "string" and #ch == 1 then
    local bc = ch:byte(1)
    if bc >= 32 and bc <= 126 then
      insert_char(row, col, ch)
      col = col + 1
      ensure_cursor_visible()
      redraw_all()
    end
    return nil
  end

  return nil
end

-- Main
local function main()
  cwd = "/"
  pcall(function() if sys then cwd = sys("getcwd") or cwd end end)
  init_screen()
  kbd.set_raw(true)
  gpu_drv.set_cursor_blink(false)

  local file_arg = arg and arg[1]
  load_file(file_arg)

  redraw_all()

  while true do
    coroutine.yield()
    local ch = kbd.getchar()
    local action = handle_key(ch)
    if action == "quit" then break end
  end

  kbd.set_raw(false)
  gpu_drv.set_cursor_blink(true)
  gpu_drv.clear()
  return 0
end

local ok, err = pcall(main)
kbd.set_raw(false)
pcall(function() gpu_drv.set_cursor_blink(true) end)
pcall(function() gpu_drv.clear() end)
if not ok then
  pcall(function()
    gpu_drv.write("nano: " .. tostring(err) .. "\n")
  end)
  return 1
end
return 0
