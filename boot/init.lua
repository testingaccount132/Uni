-- UniOS Stage-1 Boot Init
-- Runs inside the BIOS sandbox.
-- Sets up the global environment, mounts the root filesystem,
-- then loads and runs the kernel.

local VERSION = "UniOS 1.0"

-- ── Basic globals ─────────────────────────────────────────────────────────────

_G._UNI_VERSION = VERSION
_G._UNI_BOOT_FS = boot_fs   -- injected by BIOS
_G._UNI_BOOT_ADDR = boot_addr

local println = _G._println or function() end

println("[init] Stage-1 boot, UniOS " .. VERSION)

-- ── Component proxy cache ─────────────────────────────────────────────────────

local function proxy(kind)
  for addr in component.list(kind) do
    return component.proxy(addr)
  end
end

-- ── Module loader (simple require for boot stage) ─────────────────────────────
-- Full require is set up by the kernel; here we have a minimal one
-- that reads directly from boot_fs.

local loaded = {}

local function boot_require(path)
  if loaded[path] then return loaded[path] end
  local fpath = "/" .. path:gsub("%.", "/") .. ".lua"
  local h = boot_fs.open(fpath, "r")
  if not h then
    error("boot_require: cannot find '" .. fpath .. "'", 2)
  end
  local src = ""
  repeat
    local chunk = boot_fs.read(h, math.huge)
    if chunk then src = src .. chunk end
  until not chunk
  boot_fs.close(h)
  local fn, err = load(src, "=" .. path, "t", _G)
  if not fn then error("boot_require: " .. tostring(err), 2) end
  local result = fn()
  loaded[path] = result or true
  return loaded[path]
end

_G.boot_require = boot_require

-- ── Mount root filesystem ─────────────────────────────────────────────────────

println("[init] Mounting root filesystem...")

-- The boot_fs IS the root filesystem in OpenComputers.
-- We expose it as a structured mount table so the kernel VFS can pick it up.
_G._root_fs   = boot_fs
_G._root_addr = boot_addr

-- ── Load the kernel ───────────────────────────────────────────────────────────

println("[init] Loading kernel...")

local h, err = boot_fs.open("/kernel/kernel.lua", "r")
if not h then
  error("[init] FATAL: Cannot open /kernel/kernel.lua: " .. tostring(err))
end

local src = ""
repeat
  local chunk = boot_fs.read(h, math.huge)
  if chunk then src = src .. chunk end
until not chunk
boot_fs.close(h)

println("[init] Executing kernel (" .. #src .. " bytes)...")

local kernel_fn, err = load(src, "=kernel", "t", _G)
if not kernel_fn then
  error("[init] FATAL: Kernel parse error: " .. tostring(err))
end

kernel_fn()
