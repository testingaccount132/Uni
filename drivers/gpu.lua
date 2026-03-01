-- UniOS GPU Driver
-- Wraps the OpenComputers GPU component.
-- Provides a terminal-style interface: cursor tracking, scrolling,
-- ANSI colour codes (subset), and raw GPU access.

local gpu_drv = {}

local _gpu    = nil
local _screen = nil
local _w, _h  = 80, 25
local _cx, _cy = 1, 1          -- cursor position (1-based)
local _fg = 0xFFFFFF
local _bg = 0x000000

-- ANSI colour palette (16-colour)
local ANSI_FG = {
  [30]=0x000000, [31]=0xAA0000, [32]=0x00AA00, [33]=0xAA5500,
  [34]=0x0000AA, [35]=0xAA00AA, [36]=0x00AAAA, [37]=0xAAAAAA,
  [90]=0x555555, [91]=0xFF5555, [92]=0x55FF55, [93]=0xFFFF55,
  [94]=0x5555FF, [95]=0xFF55FF, [96]=0x55FFFF, [97]=0xFFFFFF,
}
local ANSI_BG = {}
for k, v in pairs(ANSI_FG) do ANSI_BG[k + 10] = v end

-- ── Init ──────────────────────────────────────────────────────────────────────

function gpu_drv.init()
  for addr in component.list("gpu") do
    _gpu = component.proxy(addr)
    break
  end
  for addr in component.list("screen") do
    _screen = component.proxy(addr)
    break
  end
  if not _gpu then
    kernel.warn("gpu: no GPU found")
    return
  end
  if _screen then _gpu.bind(_screen.address) end
  _w, _h = _gpu.maxResolution()
  _gpu.setResolution(_w, _h)
  _gpu.setBackground(_bg)
  _gpu.setForeground(_fg)
  -- Don't clear screen — preserve the BIOS boot log already on display.
  -- Start cursor below any existing content (row 1 = safe default).
  _cx, _cy = 1, 1

  kernel.info("gpu: " .. _w .. "x" .. _h .. " initialised")
end

-- ── Scroll ────────────────────────────────────────────────────────────────────

local function scroll(lines)
  lines = lines or 1
  _gpu.copy(1, lines + 1, _w, _h - lines, 0, -lines)
  _gpu.fill(1, _h - lines + 1, _w, lines, " ")
end

-- ── Newline handling ──────────────────────────────────────────────────────────

local function newline()
  _cx = 1
  _cy = _cy + 1
  if _cy > _h then
    scroll(1)
    _cy = _h
  end
end

-- ── ANSI escape parser ────────────────────────────────────────────────────────

local function apply_ansi(seq)
  -- seq is the content between ESC[ and the final letter
  local cmd = seq:sub(-1)
  local args_str = seq:sub(1, -2)
  local args = {}
  for n in (args_str .. ";"):gmatch("(%d*);") do
    args[#args + 1] = tonumber(n) or 0
  end

  if cmd == "m" then
    -- SGR: colours / attributes
    for _, code in ipairs(args) do
      if code == 0 then
        _fg = 0xFFFFFF; _bg = 0x000000
        if _gpu then _gpu.setForeground(_fg); _gpu.setBackground(_bg) end
      elseif ANSI_FG[code] then
        _fg = ANSI_FG[code]
        if _gpu then _gpu.setForeground(_fg) end
      elseif ANSI_BG[code] then
        _bg = ANSI_BG[code]
        if _gpu then _gpu.setBackground(_bg) end
      end
    end
  elseif cmd == "H" or cmd == "f" then
    -- Cursor position
    _cy = math.max(1, math.min(_h, args[1] or 1))
    _cx = math.max(1, math.min(_w, args[2] or 1))
  elseif cmd == "A" then _cy = math.max(1, _cy - (args[1] or 1))
  elseif cmd == "B" then _cy = math.min(_h, _cy + (args[1] or 1))
  elseif cmd == "C" then _cx = math.min(_w, _cx + (args[1] or 1))
  elseif cmd == "D" then _cx = math.max(1, _cx - (args[1] or 1))
  elseif cmd == "J" then
    if (args[1] or 0) == 2 then
      if _gpu then _gpu.fill(1, 1, _w, _h, " ") end
      _cx, _cy = 1, 1
    end
  elseif cmd == "K" then
    if _gpu then _gpu.fill(_cx, _cy, _w - _cx + 1, 1, " ") end
  end
end

-- ── Core write ────────────────────────────────────────────────────────────────

local _ansi_buf = nil  -- buffer while inside escape sequence

function gpu_drv.write(text)
  if not _gpu then return end
  if _cursor_shown then gpu_drv.hide_cursor() end
  text = tostring(text)
  local i = 1
  while i <= #text do
    local ch = text:sub(i, i)

    if _ansi_buf ~= nil then
      _ansi_buf = _ansi_buf .. ch
      -- Check for end of escape sequence (a letter terminates CSI)
      if ch:match("%a") then
        apply_ansi(_ansi_buf:sub(3))  -- strip ESC[
        _ansi_buf = nil
      end
      i = i + 1

    elseif ch == "\27" then
      -- ESC
      local next = text:sub(i + 1, i + 1)
      if next == "[" then
        _ansi_buf = "\27["
        i = i + 2
      else
        i = i + 1
      end

    elseif ch == "\n" then
      newline()
      i = i + 1

    elseif ch == "\r" then
      _cx = 1
      i = i + 1

    elseif ch == "\8" or ch == "\127" then
      -- Backspace
      if _cx > 1 then
        _cx = _cx - 1
        _gpu.set(_cx, _cy, " ")
      end
      i = i + 1

    elseif ch == "\t" then
      -- Tab stop every 8
      local next_tab = math.ceil(_cx / 8) * 8 + 1
      local spaces = math.min(next_tab - _cx, _w - _cx + 1)
      _gpu.set(_cx, _cy, string.rep(" ", spaces))
      _cx = _cx + spaces
      i = i + 1

    else
      -- Printable character – write as many as possible in one gpu.set call
      local run_start = i
      while i <= #text do
        local c = text:sub(i, i)
        if c == "\27" or c == "\n" or c == "\r" or c == "\8" or c == "\127" or c == "\t" then
          break
        end
        i = i + 1
        if _cx + (i - run_start) - 1 >= _w then break end
      end
      local run = text:sub(run_start, i - 1)
      if #run > 0 then
        _gpu.set(_cx, _cy, run)
        _cx = _cx + #run
        if _cx > _w then
          newline()
        end
      end
    end
  end
end

function gpu_drv.writeln(text)
  gpu_drv.write(tostring(text) .. "\n")
end

-- ── Cursor ────────────────────────────────────────────────────────────────────

function gpu_drv.set_cursor(x, y)
  _cx = math.max(1, math.min(_w, x))
  _cy = math.max(1, math.min(_h, y))
end

function gpu_drv.get_cursor()
  return _cx, _cy
end

-- ── Cursor rendering ────────────────────────────────────────────────────────
local _cursor_blink   = true
local _cursor_shown   = false
local _cursor_sx, _cursor_sy = nil, nil   -- position where cursor was drawn
local _cursor_char    = nil
local _cursor_cfg     = nil
local _cursor_cbg     = nil

function gpu_drv.show_cursor()
  if not _gpu or not _cursor_blink then return end
  if _cursor_shown then return end
  _cursor_sx, _cursor_sy = _cx, _cy
  local ch, fg, bg = _gpu.get(_cx, _cy)
  _cursor_char = ch or " "
  _cursor_cfg  = fg or _fg
  _cursor_cbg  = bg or _bg
  _gpu.setForeground(0x000000)
  _gpu.setBackground(0xFFFFFF)
  _gpu.set(_cx, _cy, _cursor_char)
  _gpu.setForeground(_fg)
  _gpu.setBackground(_bg)
  _cursor_shown = true
end

function gpu_drv.hide_cursor()
  if not _gpu or not _cursor_shown then return end
  _gpu.setForeground(_cursor_cfg or _fg)
  _gpu.setBackground(_cursor_cbg or _bg)
  _gpu.set(_cursor_sx or _cx, _cursor_sy or _cy, _cursor_char or " ")
  _gpu.setForeground(_fg)
  _gpu.setBackground(_bg)
  _cursor_shown = false
  _cursor_sx, _cursor_sy = nil, nil
end

function gpu_drv.set_cursor_blink(enabled)
  _cursor_blink = enabled
  if not enabled then gpu_drv.hide_cursor() end
end

function gpu_drv.clear()
  if not _gpu then return end
  if _cursor_shown then _cursor_shown = false end
  _w, _h = _gpu.getResolution()
  _fg = 0xFFFFFF; _bg = 0x000000
  _gpu.setForeground(_fg)
  _gpu.setBackground(_bg)
  _gpu.fill(1, 1, _w, _h, " ")
  _cx, _cy = 1, 1
end

-- ── Raw GPU access ────────────────────────────────────────────────────────────

function gpu_drv.raw()
  return _gpu
end

function gpu_drv.size()
  return _w, _h
end

function gpu_drv.hotplug(ev)
  if ev[1] == "component_added" and ev[3] == "gpu" then
    gpu_drv.init()
  end
end

return gpu_drv
