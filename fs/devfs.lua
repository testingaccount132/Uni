-- UniOS devfs  (/dev)
-- Virtual filesystem that exposes hardware devices as files.
-- Mounted at /dev by the kernel.

local devfs = {}

local _devices = {}   -- name → device_object

-- ── Minimal FS interface ──────────────────────────────────────────────────────
-- devfs mounts as an in-kernel FS, so it exposes the vfs driver interface.

local _meta = {}

function _meta.open(path, mode)
  -- Strip leading slash
  local name = path:gsub("^/+", "")
  local dev  = _devices[name]
  if not dev then return nil, "/dev/" .. name .. ": no such device" end
  return dev.open and dev.open(mode) or { _dev = dev,
    read  = function(self, n) return self._dev.read  and self._dev.read(n)  or nil end,
    write = function(self, d) return self._dev.write and self._dev.write(d) or false end,
    close = function(self) if self._dev.close then self._dev.close() end end,
  }
end

function _meta.close(fd) fd:close() end
function _meta.read(fd, n)  return fd:read(n) end
function _meta.write(fd, d) return fd:write(d) end

function _meta.list(_)
  local out = {}
  for name in pairs(_devices) do out[#out + 1] = name end
  table.sort(out)
  return out
end

function _meta.stat(path)
  local name = path:gsub("^/+", "")
  if path == "/" or path == "" then
    return { isdir = true, size = 0, readonly = true }
  end
  if _devices[name] then
    return { isdir = false, size = 0, readonly = false }
  end
  return nil
end

function _meta.isdir(path)
  return path == "/" or path == ""
end

function _meta.exists(path)
  local name = path:gsub("^/+", "")
  return path == "/" or _devices[name] ~= nil
end

function _meta.mkdir(_)  return false, "devfs: read-only" end
function _meta.remove(_) return false, "devfs: read-only" end
function _meta.rename()  return false, "devfs: read-only" end

-- ── Device registration ───────────────────────────────────────────────────────

--- Register a device at /dev/<name>.
--- `dev` must have optional fields: read(n), write(data), open(mode), close()
function devfs.register(name, dev)
  _devices[name] = dev
  kernel.info("devfs: registered /dev/" .. name)
end

function devfs.unregister(name)
  _devices[name] = nil
end

function devfs.get(name)
  return _devices[name]
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function devfs.init()
  -- /dev/null
  devfs.register("null", {
    read  = function() return nil end,
    write = function() return true end,
  })

  -- /dev/zero
  devfs.register("zero", {
    read  = function(n) return string.rep("\0", n or 1) end,
    write = function() return true end,
  })

  -- /dev/random (OC uses math.random)
  devfs.register("random", {
    read = function(n)
      n = n or 1
      local out = {}
      for i = 1, n do out[i] = string.char(math.random(0, 255)) end
      return table.concat(out)
    end,
    write = function() return true end,
  })

  kernel.info("devfs: initialised (/dev/null, /dev/zero, /dev/random)")
end

-- Return the FS interface (for vfs.mount)
return setmetatable(devfs, { __index = _meta })
