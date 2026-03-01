-- UniOS libpath – UNIX path utilities

local libpath = {}

--- Normalise a path: collapse . and .., remove double slashes.
function libpath.normalize(path)
  if not path or path == "" then return "/" end
  local abs = path:sub(1, 1) == "/"
  local parts = {}
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif segment ~= "." then
      parts[#parts + 1] = segment
    end
  end
  local result = table.concat(parts, "/")
  if abs then result = "/" .. result end
  if result == "" then result = "/" end
  return result
end

--- Resolve `path` against `cwd` (which must be absolute).
function libpath.resolve(path, cwd)
  if not path or path == "" then return libpath.normalize(cwd or "/") end
  if path:sub(1, 1) == "/" then
    return libpath.normalize(path)
  end
  return libpath.normalize((cwd or "/") .. "/" .. path)
end

--- Return the directory part of a path.
function libpath.dirname(path)
  path = libpath.normalize(path)
  if path == "/" then return "/" end
  local dir = path:match("^(.*)/[^/]+$")
  if not dir or dir == "" then return "/" end
  return dir
end

--- Return the filename part of a path.
function libpath.basename(path)
  path = libpath.normalize(path)
  if path == "/" then return "/" end
  return path:match("[^/]+$") or path
end

--- Return the file extension (e.g. ".lua"), or "" if none.
function libpath.extname(path)
  local base = libpath.basename(path)
  return base:match("(%.[^.]+)$") or ""
end

--- Join path segments together.
function libpath.join(...)
  local parts = { ... }
  return libpath.normalize(table.concat(parts, "/"))
end

--- Check if `path` is absolute.
function libpath.isabs(path)
  return type(path) == "string" and path:sub(1, 1) == "/"
end

--- Split a PATH-style colon-separated string into a list.
function libpath.split_path(pathenv)
  local dirs = {}
  for d in (pathenv or ""):gmatch("[^:]+") do
    dirs[#dirs + 1] = d
  end
  return dirs
end

--- Search for `cmd` in each directory in `path_list`.
--- Returns the full path if found, nil otherwise.
function libpath.which(cmd, path_list)
  if cmd:sub(1, 1) == "/" then
    -- Absolute path
    if kernel.vfs.exists(cmd) then return cmd end
    if kernel.vfs.exists(cmd .. ".lua") then return cmd .. ".lua" end
    return nil
  end
  for _, dir in ipairs(path_list or {}) do
    local full = dir .. "/" .. cmd
    if kernel.vfs.exists(full) then return full end
    local fullua = full .. ".lua"
    if kernel.vfs.exists(fullua) then return fullua end
  end
  return nil
end

_G.libpath = libpath
return libpath
