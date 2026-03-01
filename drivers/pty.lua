-- UniOS PTY (pseudo-terminal) driver
-- Creates master/slave pairs for running processes in virtual terminals.
-- The compositor holds the master (reads output, writes input).
-- The process holds the slave (reads input, writes output).

local pty_drv = {}

local _ptys = {}
local _next_id = 0

function pty_drv.init()
  _ptys = {}
  _next_id = 0
  kernel.info("pty: ready")
end

--- Create a new PTY pair. Returns master, slave tables.
--- master: { read() → get process output, write(data) → send input to process }
--- slave:  { read() → get user input, write(data) → send output to user }
function pty_drv.create(opts)
  opts = opts or {}
  local id = _next_id
  _next_id = _next_id + 1

  local input_buf  = {}  -- master writes → slave reads (user input to process)
  local output_buf = {}  -- slave writes → master reads (process output to user)

  local master = {
    id = id,
    name = "ptm" .. id,

    read = function(n)
      if #output_buf == 0 then return nil end
      n = n or math.huge
      local out = {}
      for i = 1, n do
        if #output_buf == 0 then break end
        out[#out + 1] = table.remove(output_buf, 1)
      end
      return #out > 0 and table.concat(out) or nil
    end,

    write = function(data)
      if not data then return true end
      data = tostring(data)
      for i = 1, #data do
        input_buf[#input_buf + 1] = data:sub(i, i)
      end
      return true
    end,

    has_output = function()
      return #output_buf > 0
    end,

    close = function()
      _ptys[id] = nil
      kernel.devfs.unregister("ptm" .. id)
      kernel.devfs.unregister("pts" .. id)
    end,
  }

  local slave = {
    id = id,
    name = "pts" .. id,

    read = function(n)
      if #input_buf == 0 then return nil end
      n = n or math.huge
      local out = {}
      for i = 1, n do
        if #input_buf == 0 then break end
        out[#out + 1] = table.remove(input_buf, 1)
      end
      return #out > 0 and table.concat(out) or nil
    end,

    write = function(data)
      if not data then return true end
      data = tostring(data)
      for i = 1, #data do
        output_buf[#output_buf + 1] = data:sub(i, i)
      end
      return true
    end,

    readline = function()
      local line = {}
      while true do
        if #input_buf > 0 then
          local ch = table.remove(input_buf, 1)
          if ch == "\n" or ch == "\r" then
            return table.concat(line)
          elseif ch == "\8" or ch == "\127" then
            if #line > 0 then table.remove(line) end
          else
            line[#line + 1] = ch
          end
        else
          coroutine.yield()
        end
      end
    end,

    has_input = function()
      return #input_buf > 0
    end,

    close = function()
      _ptys[id] = nil
    end,
  }

  _ptys[id] = { master = master, slave = slave }

  -- Register devices
  kernel.devfs.register("ptm" .. id, {
    read  = function(n) return master.read(n) end,
    write = function(d) return master.write(d) end,
  })
  kernel.devfs.register("pts" .. id, {
    read  = function(n) return slave.read(n) end,
    write = function(d) return slave.write(d) end,
  })

  kernel.info("pty: created pair ptm" .. id .. "/pts" .. id)
  return master, slave
end

function pty_drv.get(id)
  return _ptys[id]
end

function pty_drv.list()
  local out = {}
  for id in pairs(_ptys) do out[#out + 1] = id end
  table.sort(out)
  return out
end

function pty_drv.hotplug(ev) end

return pty_drv
