-- UniOS tmpfs
-- In-memory filesystem for /tmp.  Each call to tmpfs.new() returns
-- an independent filesystem instance (multiple /tmp mounts are possible).

local tmpfs = {}

function tmpfs.new()
  -- inode table: path → { data=string, isdir=bool, children={name,...} }
  local _inodes = { ["/"] = { isdir = true, children = {}, data = nil } }

  local fs = {}

  -- ── Internal helpers ────────────────────────────────────────────────────────

  local function canon(path)
    if path == "" or path == nil then return "/" end
    path = path:gsub("//+", "/")
    if path ~= "/" and path:sub(-1) == "/" then
      path = path:sub(1, -2)
    end
    return path
  end

  local function parent_and_name(path)
    path = canon(path)
    local parent = path:match("^(.*)/[^/]+$") or "/"
    if parent == "" then parent = "/" end
    local name   = path:match("[^/]+$") or ""
    return parent, name
  end

  local function ensure_dir(path)
    local n = _inodes[path]
    return n and n.isdir
  end

  -- ── Filesystem interface ────────────────────────────────────────────────────

  function fs.exists(path)
    return _inodes[canon(path)] ~= nil
  end

  function fs.isdir(path)
    local n = _inodes[canon(path)]
    return n and n.isdir or false
  end

  function fs.stat(path)
    local n = _inodes[canon(path)]
    if not n then return nil end
    return {
      isdir    = n.isdir,
      size     = n.data and #n.data or 0,
      readonly = false,
      path     = path,
    }
  end

  function fs.list(path)
    local n = _inodes[canon(path)]
    if not n or not n.isdir then return nil, "not a directory" end
    local out = {}
    for _, child in ipairs(n.children) do
      out[#out + 1] = child
    end
    return out
  end

  function fs.mkdir(path)
    path = canon(path)
    if _inodes[path] then return false, "exists" end
    local parent, name = parent_and_name(path)
    if not ensure_dir(parent) then return false, "parent not found" end
    _inodes[path] = { isdir = true, children = {}, data = nil }
    local pnode = _inodes[parent]
    pnode.children[#pnode.children + 1] = name
    return true
  end

  function fs.remove(path)
    path = canon(path)
    local n = _inodes[path]
    if not n then return false, "not found" end
    if n.isdir and #n.children > 0 then return false, "directory not empty" end
    local parent, name = parent_and_name(path)
    local pnode = _inodes[parent]
    if pnode then
      for i, c in ipairs(pnode.children) do
        if c == name then table.remove(pnode.children, i); break end
      end
    end
    _inodes[path] = nil
    return true
  end

  function fs.rename(src, dst)
    src, dst = canon(src), canon(dst)
    if not _inodes[src] then return false, "not found" end
    local parent_dst, name_dst = parent_and_name(dst)
    if not ensure_dir(parent_dst) then return false, "dest parent not found" end
    -- remove old name from old parent
    local parent_src, name_src = parent_and_name(src)
    local psrc = _inodes[parent_src]
    if psrc then
      for i, c in ipairs(psrc.children) do
        if c == name_src then table.remove(psrc.children, i); break end
      end
    end
    -- add new name to new parent
    local pdst = _inodes[parent_dst]
    pdst.children[#pdst.children + 1] = name_dst
    _inodes[dst] = _inodes[src]
    _inodes[src] = nil
    return true
  end

  -- ── File handles ───────────────────────────────────────────────────────────

  function fs.open(path, mode)
    path = canon(path)
    mode = mode or "r"
    local n = _inodes[path]

    if mode == "r" then
      if not n then return nil, "not found: " .. path end
      if n.isdir then return nil, "is a directory" end
      local pos = 1
      local data = n.data or ""
      return {
        read  = function(self, count)
          if pos > #data then return nil end
          local chunk = data:sub(pos, pos + count - 1)
          pos = pos + #chunk
          return chunk ~= "" and chunk or nil
        end,
        write = function() return false, "read-only handle" end,
        close = function() end,
      }

    elseif mode == "w" then
      _inodes[path] = _inodes[path] or { isdir = false, data = "" }
      local inode = _inodes[path]
      inode.data = ""
      if not n then
        local parent, name = parent_and_name(path)
        local pn = _inodes[parent]
        if not pn then return nil, "parent not found" end
        pn.children[#pn.children + 1] = name
      end
      return {
        read  = function() return nil end,
        write = function(self, d) inode.data = inode.data .. d; return true end,
        close = function() end,
      }

    elseif mode == "a" then
      if not n then
        local parent, name = parent_and_name(path)
        local pn = _inodes[parent]
        if not pn then return nil, "parent not found" end
        pn.children[#pn.children + 1] = name
        _inodes[path] = { isdir = false, data = "" }
      end
      local inode = _inodes[path]
      return {
        read  = function() return nil end,
        write = function(self, d) inode.data = (inode.data or "") .. d; return true end,
        close = function() end,
      }
    end

    return nil, "unknown mode: " .. tostring(mode)
  end

  function fs.close(fd) fd:close() end
  function fs.read(fd, n)  return fd:read(n) end
  function fs.write(fd, d) return fd:write(d) end

  return fs
end

return tmpfs
