-- UniOS libio – I/O stream abstraction
-- Provides file-like objects backed by VFS file descriptors,
-- and the standard streams stdin / stdout / stderr.

local libio = {}

-- ── Stream object ─────────────────────────────────────────────────────────────

local Stream = {}
Stream.__index = Stream

function Stream.new(fd, mode)
  return setmetatable({ _fd = fd, _mode = mode or "r", _closed = false, _buf = "" }, Stream)
end

function Stream:read(fmt)
  if self._closed then return nil, "closed" end
  fmt = fmt or "*l"
  if fmt == "*l" or fmt == "l" then
    -- Read a line
    while true do
      local nl = self._buf:find("\n")
      if nl then
        local line = self._buf:sub(1, nl - 1)
        self._buf = self._buf:sub(nl + 1)
        return line
      end
      local chunk = kernel.vfs.read(self._fd, 256)
      if not chunk then
        if self._buf ~= "" then
          local line = self._buf; self._buf = ""; return line
        end
        return nil
      end
      self._buf = self._buf .. chunk
    end
  elseif fmt == "*a" or fmt == "a" then
    local out = self._buf
    self._buf = ""
    while true do
      local chunk = kernel.vfs.read(self._fd, math.huge)
      if not chunk then break end
      out = out .. chunk
    end
    return out
  elseif fmt == "*n" or fmt == "n" then
    local line = self:read("*l")
    return tonumber(line)
  elseif type(fmt) == "number" then
    if #self._buf >= fmt then
      local out = self._buf:sub(1, fmt)
      self._buf = self._buf:sub(fmt + 1)
      return out
    end
    while #self._buf < fmt do
      local chunk = kernel.vfs.read(self._fd, fmt - #self._buf)
      if not chunk then break end
      self._buf = self._buf .. chunk
    end
    if self._buf == "" then return nil end
    local out = self._buf:sub(1, fmt)
    self._buf = self._buf:sub(fmt + 1)
    return out
  end
  return nil, "unknown format"
end

function Stream:write(...)
  if self._closed then return nil, "closed" end
  for i = 1, select("#", ...) do
    local s = tostring(select(i, ...))
    kernel.vfs.write(self._fd, s)
  end
  return self
end

function Stream:lines()
  return function()
    return self:read("*l")
  end
end

function Stream:close()
  if not self._closed then
    kernel.vfs.close(self._fd)
    self._closed = true
  end
end

function Stream:flush() end  -- no-op (VFS writes are immediate)

-- ── Terminal streams ──────────────────────────────────────────────────────────
-- stdin / stdout / stderr are special objects that talk to the GPU/keyboard.

local function make_terminal_stream(mode)
  local s = setmetatable({}, {
    __index = {
      _closed = false,
      read = function(self, fmt)
        fmt = fmt or "*l"
        if fmt == "*l" or fmt == "l" then
          return kernel.drivers.keyboard.readline()
        elseif type(fmt) == "number" then
          local out = ""
          while #out < fmt do
            local ch = kernel.drivers.keyboard.getchar()
            if not ch then break end
            out = out .. ch
            if ch == "\n" then break end
          end
          return out ~= "" and out or nil
        end
        return nil
      end,
      write = function(self, ...)
        for i = 1, select("#", ...) do
          kernel.drivers.gpu.write(tostring(select(i, ...)))
        end
        return self
      end,
      lines = function(self)
        return function() return self:read("*l") end
      end,
      close = function() end,
      flush = function() end,
    }
  })
  return s
end

libio.stdin  = make_terminal_stream("r")
libio.stdout = make_terminal_stream("w")
libio.stderr = make_terminal_stream("w")

-- ── io.open ───────────────────────────────────────────────────────────────────

function libio.open(path, mode)
  local pid  = kernel.scheduler.current_pid()
  local proc = kernel.process.get(pid)
  local cwd  = proc and proc.cwd or "/"
  local abs  = kernel.vfs.resolve(path, cwd)
  local fd, err = kernel.vfs.open(abs, mode or "r")
  if not fd then return nil, err end
  return Stream.new(fd, mode or "r")
end

function libio.lines(path)
  local f, err = libio.open(path, "r")
  if not f then error(tostring(err), 2) end
  return f:lines()
end

function libio.read(...)  return libio.stdin:read(...) end
function libio.write(...) return libio.stdout:write(...) end

-- ── Install as global `io` ────────────────────────────────────────────────────

_G.io = libio
-- Also override print to use our GPU
_G.print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  kernel.drivers.gpu.write(table.concat(parts, "\t") .. "\n")
end

return libio
