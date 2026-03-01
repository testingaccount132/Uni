-- UniOS libterm – Terminal / ANSI helper library

local libterm = {}

-- ── ANSI escape sequences ─────────────────────────────────────────────────────

libterm.ESC = "\27"
libterm.CSI = "\27["

function libterm.clear()           return "\27[2J\27[H" end
function libterm.reset()           return "\27[0m" end
function libterm.bold()            return "\27[1m" end
function libterm.dim()             return "\27[2m" end
function libterm.underline()       return "\27[4m" end
function libterm.blink()           return "\27[5m" end
function libterm.reverse()         return "\27[7m" end

function libterm.fg(r, g, b)
  if type(r) == "number" and not g then
    -- 256-colour / preset index
    return string.format("\27[38;5;%dm", r)
  end
  return string.format("\27[38;2;%d;%d;%dm", r, g, b)
end

function libterm.bg(r, g, b)
  if type(r) == "number" and not g then
    return string.format("\27[48;5;%dm", r)
  end
  return string.format("\27[48;2;%d;%d;%dm", r, g, b)
end

-- Named 16-colour shortcuts
local _c = {
  black=30, red=31, green=32, yellow=33, blue=34,
  magenta=35, cyan=36, white=37,
  bright_black=90, bright_red=91, bright_green=92, bright_yellow=93,
  bright_blue=94, bright_magenta=95, bright_cyan=96, bright_white=97,
}
for name, code in pairs(_c) do
  libterm[name] = function() return "\27[" .. code .. "m" end
  libterm["bg_" .. name:gsub("bright_", "bright_")] = function()
    return "\27[" .. (code + 10) .. "m"
  end
end

function libterm.move(row, col)
  return string.format("\27[%d;%dH", row, col)
end

function libterm.move_up(n)    return string.format("\27[%dA", n or 1) end
function libterm.move_down(n)  return string.format("\27[%dB", n or 1) end
function libterm.move_right(n) return string.format("\27[%dC", n or 1) end
function libterm.move_left(n)  return string.format("\27[%dD", n or 1) end

function libterm.erase_line()  return "\27[2K\r" end
function libterm.erase_end()   return "\27[K" end

-- ── Convenience writers (write directly to stdout) ────────────────────────────

local function write(s) kernel.drivers.gpu.write(s) end

function libterm.print(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  write(table.concat(parts, "\t") .. "\n")
end

function libterm.printf(fmt, ...)
  write(string.format(fmt, ...))
end

function libterm.color_print(color_esc, msg)
  write(color_esc .. tostring(msg) .. libterm.reset() .. "\n")
end

-- ── Box drawing ───────────────────────────────────────────────────────────────

function libterm.box(x, y, w, h, title)
  local gpu = kernel.drivers.gpu
  local top    = "┌" .. string.rep("─", w - 2) .. "┐"
  local bottom = "└" .. string.rep("─", w - 2) .. "┘"
  local mid    = "│" .. string.rep(" ", w - 2) .. "│"
  if title and #title < w - 4 then
    top = "┌─ " .. title .. " " .. string.rep("─", w - 5 - #title) .. "┐"
  end
  gpu.set_cursor(x, y)
  gpu.write(top)
  for row = 1, h - 2 do
    gpu.set_cursor(x, y + row)
    gpu.write(mid)
  end
  gpu.set_cursor(x, y + h - 1)
  gpu.write(bottom)
end

-- ── Spinner ───────────────────────────────────────────────────────────────────

local _spinner_chars = { "⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏" }
local _spinner_idx   = 1

function libterm.spinner()
  local ch = _spinner_chars[_spinner_idx]
  _spinner_idx = (_spinner_idx % #_spinner_chars) + 1
  return ch
end

_G.libterm = libterm
return libterm
