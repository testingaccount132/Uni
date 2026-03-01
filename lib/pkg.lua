-- UniOS pkg – Package / module loader
-- Provides require() with proper search paths and a simple package registry.

local pkg = {}

-- Search path segments (Lua-style: "?" is replaced with the module name)
pkg.path = {
  "/lib/?.lua",
  "/lib/?/init.lua",
  "/usr/lib/?.lua",
  "/usr/lib/?/init.lua",
}

local _cache   = {}  -- module name → result
local _loading = {}  -- module name → true (cycle detection)

--- Find the filesystem path for a module name.
function pkg.find(modname)
  local rel = modname:gsub("%.", "/")
  for _, tmpl in ipairs(pkg.path) do
    local path = tmpl:gsub("%?", rel)
    if kernel.vfs.exists(path) then return path end
  end
  return nil
end

--- Load a module.  Returns the module value (or true if it returned nothing).
function pkg.require(modname)
  if _cache[modname] ~= nil then return _cache[modname] end

  -- Built-in: kernel modules
  if modname == "kernel" then return kernel end

  if _loading[modname] then
    error("pkg.require: circular dependency: " .. modname, 2)
  end
  _loading[modname] = true

  local path = pkg.find(modname)
  if not path then
    -- Fall back to kernel.require (which searches from root)
    local ok, val = pcall(kernel.require, modname)
    _loading[modname] = nil
    if ok then
      _cache[modname] = val
      return val
    end
    error("pkg.require: module not found: '" .. modname .. "'", 2)
  end

  local src, err = kernel.vfs.readfile(path)
  if not src then
    _loading[modname] = nil
    error("pkg.require: cannot read '" .. path .. "': " .. tostring(err), 2)
  end

  local fn, perr = load(src, "=" .. modname, "t", _G)
  if not fn then
    _loading[modname] = nil
    error("pkg.require: parse error in '" .. modname .. "': " .. tostring(perr), 2)
  end

  local result = fn()
  _loading[modname] = nil
  _cache[modname] = result ~= nil and result or true
  return _cache[modname]
end

--- Preload a module value without executing any file.
function pkg.preload(modname, value)
  _cache[modname] = value
end

--- Unload a cached module (forces reload on next require).
function pkg.unload(modname)
  _cache[modname] = nil
end

--- List loaded modules.
function pkg.loaded()
  local out = {}
  for k in pairs(_cache) do out[#out+1] = k end
  table.sort(out)
  return out
end

-- Override global require
_G.require = pkg.require

_G.pkg = pkg
return pkg
