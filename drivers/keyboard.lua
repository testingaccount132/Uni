-- UniOS Keyboard Driver
-- Buffers raw key_down events from OpenComputers and provides
-- character-level and line-level read APIs.

local kbd = {}

local _buf    = {}   -- pending character queue
local _raw    = false  -- raw mode (no echo, no line buffering)

-- OC key code → special name mapping
local KEYS = {
  [200] = "up",   [208] = "down",
  [203] = "left", [205] = "right",
  [211] = "delete", [199] = "home", [207] = "end",
  [201] = "pageup",  [209] = "pagedown",
  [28]  = "\n",   -- Enter
  [14]  = "\8",   -- Backspace
  [15]  = "\t",   -- Tab
  [1]   = nil,    -- Escape (ignored unless raw)
}

function kbd.init()
  _buf = {}
  _raw = false
  kernel.info("keyboard: ready")
end

--- Called by signal.dispatch for key_down events.
function kbd.push(ev)
  local char = ev[3]
  local code = ev[4]

  if KEYS[code] ~= nil then
    local mapped = KEYS[code]
    if mapped then
      _buf[#_buf + 1] = mapped
    end
    return
  end

  if char and char > 0 and char < 256 then
    local c = string.char(char)
    _buf[#_buf + 1] = c
  end
end

--- Push a control character from signal dispatch.
function kbd.push_ctrl(name)
  if name == "C" then
    _buf[#_buf + 1] = "\3"
  elseif name == "D" then
    _buf[#_buf + 1] = "\4"
  elseif name == "Z" then
    _buf[#_buf + 1] = "\26"
  end
end

--- Read up to `n` raw characters (non-blocking; returns nil if none ready).
function kbd.read(n)
  n = n or 1
  if #_buf == 0 then return nil end
  local out = {}
  for i = 1, n do
    if _buf[1] then
      out[#out + 1] = table.remove(_buf, 1)
    else
      break
    end
  end
  return table.concat(out)
end

--- Read one character, blocking until available.
function kbd.getchar()
  while #_buf == 0 do
    local ev = { computer.pullSignal(0.05) }
    if ev[1] == "key_down" then
      kbd.push(ev)
    end
    coroutine.yield()
  end
  return table.remove(_buf, 1)
end

--- Read a full line with echo (blocking).  Returns the line without newline.
function kbd.readline(prompt, echo)
  if echo == nil then echo = true end
  local line = {}
  if prompt then kernel.drivers.gpu.write(prompt) end

  while true do
    local ch = kbd.getchar()
    if ch == "\n" or ch == "\r" then
      if echo then kernel.drivers.gpu.write("\n") end
      break
    elseif ch == "\8" or ch == "\127" then
      -- Backspace
      if #line > 0 then
        table.remove(line)
        if echo then kernel.drivers.gpu.write("\8 \8") end
      end
    elseif ch == "\3" then
      -- Ctrl-C
      if echo then kernel.drivers.gpu.write("^C\n") end
      kernel.signal.send(kernel.signal.fg() or 1, "SIGINT")
      line = {}
      break
    else
      line[#line + 1] = ch
      if echo then kernel.drivers.gpu.write(ch) end
    end
  end

  return table.concat(line)
end

--- Set raw mode (no echo, no line buffering; used by interactive apps).
function kbd.set_raw(enabled)
  _raw = enabled
end

function kbd.is_raw()
  return _raw
end

function kbd.hotplug(ev)
  -- Nothing to do for keyboard hotplug
end

return kbd
