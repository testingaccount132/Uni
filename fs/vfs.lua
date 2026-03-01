-- UniOS Virtual Filesystem (VFS)
-- UNIX-style mount table. All filesystem operations go through here.
-- Each mounted filesystem must expose:
--   open(path,mode), close(fd), read(fd,n), write(fd,d),
--   list(path), stat(path), isdir(path), exists(path),
--   mkdir(path), remove(path), rename(src,dst)

local vfs = {}

-- Mount table: { mountpoint → fs_object }
local _mounts  = {}
local _root_fs = nil

-- ── Path helpers (inline to avoid circular dep on libpath) ───────────────────

local function normalize(path)
  if not path or path == "" then return "/" end
  local abs = path:sub(1,1) == "/"
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif seg ~= "." then
      parts[#parts+1] = seg
    end
  end
  local r = table.concat(parts, "/")
  if abs then r = "/" .. r end
  return r == "" and "/" or r
end

--- Resolve a path to absolute form relative to `cwd`.
function vfs.resolve(path, cwd)
  if not path or path == "" then return normalize(cwd or "/") end
  if path:sub(1,1) == "/" then return normalize(path) end
  return normalize((cwd or "/") .. "/" .. path)
end

--- Find the deepest mount point that is a prefix of `abs_path`.
--- Returns: fs_object, relative_path_within_fs
local function find_mount(abs_path)
  local best_mp  = "/"
  local best_fs  = _root_fs
  local best_len = 1

  for mp, fs in pairs(_mounts) do
    local len = #mp
    if len > best_len and abs_path:sub(1, len) == mp then
      -- Ensure we don't match /foo against /foobar
      if len == #abs_path or abs_path:sub(len + 1, len + 1) == "/" then
        best_mp  = mp
        best_fs  = fs
        best_len = len
      end
    end
  end

  local rel = abs_path:sub(best_len + 1)
  if rel == "" then rel = "/" end
  if rel:sub(1, 1) ~= "/" then rel = "/" .. rel end
  return best_fs, rel
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function vfs.init(root_fs, root_addr)
  _root_fs = vfs._wrap_oc_fs(root_fs, root_addr)
  _mounts["/"] = _root_fs
  kernel.info("vfs: root mounted from " .. tostring(root_addr):sub(1, 8))
end

--- Mount `fs_obj` at `mountpoint` (absolute path).
function vfs.mount(mountpoint, fs_obj)
  _mounts[mountpoint] = fs_obj
  kernel.info("vfs: mounted " .. mountpoint)
end

function vfs.umount(mountpoint)
  if mountpoint == "/" then return false, "cannot unmount root" end
  _mounts[mountpoint] = nil
  return true
end

function vfs.mounts()
  local out = {}
  for mp, fs in pairs(_mounts) do out[mp] = fs end
  return out
end

-- ── Wrap an OpenComputers filesystem proxy ────────────────────────────────────
-- OC fs proxies use a different API; we normalise them to our interface.

function vfs._wrap_oc_fs(fs, addr)
  local w = { _addr = addr, _raw = fs }

  function w.open(path, mode)
    local h, err = fs.open(path, mode or "r")
    if not h then return nil, err end
    return {
      _h   = h,
      _fs  = fs,
      read  = function(self, n) return fs.read(self._h, n) end,
      write = function(self, d) return fs.write(self._h, d) end,
      seek  = function(self, w, o) return fs.seek(self._h, w, o) end,
      close = function(self) fs.close(self._h) end,
    }
  end

  function w.close(fd) fd:close() end
  function w.read(fd, n) return fd:read(n) end
  function w.write(fd, d) return fd:write(d) end

  function w.list(path)
    return fs.list(path)
  end

  function w.stat(path)
    if not fs.exists(path) then return nil end
    return {
      isdir    = fs.isDirectory(path),
      size     = fs.size(path),
      modified = fs.lastModified(path),
      readonly = fs.isReadOnly(),
      path     = path,
    }
  end

  function w.isdir(path)
    return fs.isDirectory(path)
  end

  function w.exists(path)
    return fs.exists(path)
  end

  function w.mkdir(path)
    return fs.makeDirectory(path)
  end

  function w.remove(path)
    return fs.remove(path)
  end

  function w.rename(src, dst)
    return fs.rename(src, dst)
  end

  return w
end

-- ── VFS operations ────────────────────────────────────────────────────────────

function vfs.open(abs_path, mode)
  local fs, rel = find_mount(abs_path)
  if not fs then return nil, "no filesystem" end
  return fs.open(rel, mode)
end

function vfs.close(fd)
  fd:close()
end

function vfs.read(fd, n)
  return fd:read(n)
end

function vfs.write(fd, data)
  return fd:write(data)
end

function vfs.list(abs_path)
  local fs, rel = find_mount(abs_path)
  if not fs then return nil, "no filesystem" end
  return fs.list(rel)
end

function vfs.stat(abs_path)
  local fs, rel = find_mount(abs_path)
  if not fs then return nil end
  return fs.stat(rel)
end

function vfs.isdir(abs_path)
  local fs, rel = find_mount(abs_path)
  if not fs then return false end
  return fs.isdir(rel)
end

function vfs.exists(abs_path)
  local fs, rel = find_mount(abs_path)
  if not fs then return false end
  return fs.exists(rel)
end

function vfs.mkdir(abs_path)
  local fs, rel = find_mount(abs_path)
  if not fs then return false, "no filesystem" end
  return fs.mkdir(rel)
end

function vfs.remove(abs_path)
  local fs, rel = find_mount(abs_path)
  if not fs then return false, "no filesystem" end
  return fs.remove(rel)
end

function vfs.rename(src, dst)
  local fs1, r1 = find_mount(src)
  local fs2, r2 = find_mount(dst)
  if fs1 ~= fs2 then return false, "cross-device rename not supported" end
  return fs1.rename(r1, r2)
end

--- Read an entire file as a string (convenience).
function vfs.readfile(abs_path)
  local fd, err = vfs.open(abs_path, "r")
  if not fd then return nil, err end
  local data = ""
  repeat
    local chunk = vfs.read(fd, math.huge)
    if chunk then data = data .. chunk end
  until not chunk
  vfs.close(fd)
  return data
end

--- Write a string to a file (convenience).
function vfs.writefile(abs_path, data, append)
  local mode = append and "a" or "w"
  local fd, err = vfs.open(abs_path, mode)
  if not fd then return false, err end
  local ok, err2 = vfs.write(fd, data)
  vfs.close(fd)
  return ok, err2
end

return vfs
