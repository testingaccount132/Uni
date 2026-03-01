-- UniOS TTY driver
-- Provides virtual terminal devices (/dev/tty0, /dev/tty1, ...).
-- Each TTY owns a screen buffer, input queue, and foreground process group.
-- tty0 is the physical console; additional TTYs are virtual.

local tty_drv = {}

local _ttys = {}
local _active = 0

local function new_tty(id, opts)
  opts = opts or {}
  local t = {
    id       = id,
    name     = "tty" .. id,
    input    = {},
    output   = {},
    fg_pid   = nil,
    echo     = true,
    raw      = false,
    line_buf = {},
    cols     = opts.cols or 80,
    rows     = opts.rows or 25,
    cx       = 1,
    cy       = 1,
    fg_color = 0xFFFFFF,
    bg_color = 0x000000,
  }

  function t.write(data)
    if not data then return true end
    data = tostring(data)
    for i = 1, #data do
      t.output[#t.output + 1] = data:sub(i, i)
    end
    -- If this is the active TTY, write to physical screen
    if t.id == _active then
      kernel.drivers.gpu.write(data)
    end
    return true
  end

  function t.read(n)
    n = n or 1
    if #t.input == 0 then return nil end
    local out = {}
    for i = 1, n do
      if #t.input == 0 then break end
      out[#out + 1] = table.remove(t.input, 1)
    end
    return #out > 0 and table.concat(out) or nil
  end

  function t.push_input(ch)
    t.input[#t.input + 1] = ch
    if t.echo and t.id == _active then
      kernel.drivers.gpu.write(ch)
    end
  end

  function t.readline()
    if t.id == _active then
      return kernel.drivers.keyboard.readline()
    end
    -- Non-active TTY: block until we have a line in input
    local line = {}
    while true do
      if #t.input > 0 then
        local ch = table.remove(t.input, 1)
        if ch == "\n" or ch == "\r" then
          return table.concat(line)
        end
        line[#line + 1] = ch
      else
        coroutine.yield()
      end
    end
  end

  function t.clear()
    t.output = {}
    t.cx, t.cy = 1, 1
    if t.id == _active then
      kernel.drivers.gpu.clear()
    end
  end

  return t
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function tty_drv.init()
  -- Create tty0 (physical console)
  _ttys[0] = new_tty(0)
  _active = 0

  -- Register /dev/tty0
  kernel.devfs.register("tty0", {
    read  = function(n) return _ttys[0].read(n) end,
    write = function(d) return _ttys[0].write(d) end,
  })

  -- Register /dev/console as alias
  kernel.devfs.register("console", {
    read  = function(n) return _ttys[_active].read(n) end,
    write = function(d) return _ttys[_active].write(d) end,
  })

  kernel.info("tty: console tty0 ready")
end

-- ── TTY management ────────────────────────────────────────────────────────────

function tty_drv.create(id, opts)
  if _ttys[id] then return _ttys[id] end
  _ttys[id] = new_tty(id, opts)

  kernel.devfs.register("tty" .. id, {
    read  = function(n) return _ttys[id].read(n) end,
    write = function(d) return _ttys[id].write(d) end,
  })

  kernel.info("tty: created tty" .. id)
  return _ttys[id]
end

function tty_drv.destroy(id)
  if id == 0 then return false end
  if _ttys[id] then
    kernel.devfs.unregister("tty" .. id)
    _ttys[id] = nil
    if _active == id then
      _active = 0
    end
    return true
  end
  return false
end

function tty_drv.get(id)
  return _ttys[id or _active]
end

function tty_drv.active()
  return _active
end

function tty_drv.switch(id)
  if not _ttys[id] then return false end
  _active = id
  -- Redraw the active TTY's content to screen
  if _ttys[id].id == 0 then
    -- tty0 is the physical console, nothing to redraw
  end
  return true
end

function tty_drv.list()
  local out = {}
  for id, t in pairs(_ttys) do
    out[#out + 1] = { id = id, name = t.name, fg_pid = t.fg_pid }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function tty_drv.hotplug(ev) end

return tty_drv
