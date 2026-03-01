-- UniOS uninstall – remove UniOS files and optionally restore the original BIOS
-- Run from OpenOS (or UniOS shell) after you no longer want UniOS on the disk.
--
-- The file list is fetched dynamically from the GitHub API so it always matches
-- exactly what 'get --update' would have installed – no hardcoded list to forget.
-- Falls back to a built-in list if there is no internet card or the API is down.

local API_TREE = "https://api.github.com/repos/testingaccount132/Uni/git/trees/main?recursive=1"

-- ── Compat layer (works under both OpenOS and UniOS) ─────────────────────────

local _vfs = kernel and kernel.vfs
local _fs  = (not _vfs) and fs   -- OpenOS raw fs

local function file_exists(path)
  if _vfs then return _vfs.exists(path) end
  return _fs.exists(path)
end

local function file_remove(path)
  if _vfs then return _vfs.remove(path) end
  return _fs.remove(path)
end

local function dir_list(path)
  if _vfs then return _vfs.list(path) or {} end
  return _fs.list(path) or {}
end

local function is_dir(path)
  if _vfs then return _vfs.isdir(path) end
  return _fs.isDirectory(path)
end

local function read_file(path)
  if _vfs then return _vfs.readfile(path) end
  local h = io.open(path, "rb")
  if not h then return nil end
  local d = h:read("*a"); h:close(); return d
end

local function write_out(s) io.write(s) end
local function writeln(s)   io.write(tostring(s) .. "\n") end

-- Colour helpers (ANSI; stripped gracefully if unsupported)
local function c(code, s) return "\27[" .. code .. "m" .. s .. "\27[0m" end
local function ok(m)   writeln(c("32", "  ✓  ") .. m) end
local function err(m)  writeln(c("31", "  ✗  ") .. m) end
local function info(m) writeln(c("36", "  ·  ") .. m) end
local function warn(m) writeln(c("33", "  ⚠  ") .. m) end

-- ── GitHub API helpers ────────────────────────────────────────────────────────

local internet = nil
for a in component.list("internet") do internet = component.proxy(a); break end

local function http_get(url, timeout)
  if not internet then return nil, "no internet card" end
  local req, e = internet.request(url)
  if not req then return nil, tostring(e) end
  local deadline = computer.uptime() + (timeout or 30)
  local data = ""
  while computer.uptime() < deadline do
    local chunk, reason = req.read(65536)
    if chunk then
      data = data .. chunk
    elseif reason then
      req.close(); return nil, tostring(reason)
    else
      break
    end
  end
  req.close()
  return data ~= "" and data or nil, "empty"
end

local SKIP = { ["README.md"]=true, ["LICENSE"]=true, [".gitignore"]=true }
local function should_skip(path) return SKIP[path] or path:sub(1,1) == "." end

local function parse_tree(json)
  local files = {}
  for obj in json:gmatch("{([^}]+)}") do
    local ftype = obj:match('"type"%s*:%s*"([^"]+)"')
    if ftype == "blob" then
      local path = obj:match('"path"%s*:%s*"([^"]+)"')
      if path and not should_skip(path) then
        files[#files+1] = "/" .. path   -- add leading slash for local paths
      end
    end
  end
  table.sort(files)
  return files
end

-- Built-in fallback list (used if API is unreachable)
local FALLBACK_FILES = {
  "/eeprom/bios.lua","/eeprom/bios.min.lua","/eeprom/flash.lua",
  "/boot/init.lua",
  "/kernel/kernel.lua","/kernel/process.lua","/kernel/scheduler.lua",
  "/kernel/signal.lua","/kernel/syscall.lua",
  "/fs/vfs.lua","/fs/devfs.lua","/fs/tmpfs.lua",
  "/drivers/gpu.lua","/drivers/keyboard.lua","/drivers/disk.lua",
  "/lib/libc.lua","/lib/libio.lua","/lib/libpath.lua","/lib/libterm.lua","/lib/pkg.lua",
  "/bin/sh.lua","/bin/ls.lua","/bin/cat.lua","/bin/cp.lua","/bin/mv.lua","/bin/rm.lua",
  "/bin/mkdir.lua","/bin/echo.lua","/bin/pwd.lua","/bin/uname.lua","/bin/ps.lua",
  "/bin/kill.lua","/bin/grep.lua","/bin/df.lua","/bin/free.lua","/bin/uptime.lua",
  "/bin/wc.lua","/bin/head.lua","/bin/tail.lua","/bin/touch.lua","/bin/clear.lua",
  "/bin/reboot.lua","/bin/dmesg.lua","/bin/which.lua","/bin/env.lua","/bin/hostname.lua",
  "/etc/rc","/etc/profile","/etc/passwd",
  "/installer/install.lua","/installer/installer_eeprom.lua","/installer/installer_eeprom.min.lua",
  "/tools/bootstrap.lua","/tools/get.lua","/tools/uninstall.lua","/tools/minify.lua",
  "/sbin/init.lua",
}

-- Directories to try removing (deepest first so parents empty out)
local DIRS = {
  "/bin","/sbin","/boot","/kernel","/fs","/drivers",
  "/lib","/eeprom","/installer","/tools",
  "/usr/bin","/usr/lib","/usr/share","/usr",
  "/var/log","/var/run","/var",
  "/proc",
}

-- ── Prompt helper ─────────────────────────────────────────────────────────────

local function prompt(msg)
  write_out(msg)
  local ans = io.read()
  return (ans or ""):match("^%s*(.-)%s*$"):lower()
end

-- ── Banner ────────────────────────────────────────────────────────────────────

writeln("")
writeln(c("1;36", "╔══════════════════════════════════════╗"))
writeln(c("1;36", "║     UniOS Uninstaller  v1.0          ║"))
writeln(c("1;36", "╚══════════════════════════════════════╝"))
writeln("")
writeln("This will remove all UniOS system files from the disk.")
writeln(c("33", "  Your /etc/hostname, /root/, and /home/ are preserved."))
writeln("")

local answer = prompt("Type " .. c("1;31","yes") .. " to continue, anything else to cancel: ")
if answer ~= "yes" then
  warn("Aborted. No files were changed.")
  return 1
end

writeln("")

-- ── Fetch file list ───────────────────────────────────────────────────────────

local FILES
if internet then
  info("Fetching file list from GitHub API…")
  local json, api_err = http_get(API_TREE, 20)
  if json then
    FILES = parse_tree(json)
    ok("Got " .. #FILES .. " files from API")
  else
    warn("API unavailable (" .. tostring(api_err) .. ") — using built-in list")
    FILES = FALLBACK_FILES
  end
else
  warn("No internet card — using built-in file list")
  FILES = FALLBACK_FILES
end

writeln("")

-- ── Remove files ──────────────────────────────────────────────────────────────

info("Removing files…")
local removed, skipped, missing = 0, 0, 0

for _, path in ipairs(FILES) do
  if file_exists(path) then
    local ok_rm, rm_err = pcall(file_remove, path)
    if ok_rm then
      writeln(c("32","  rm") .. "  " .. path)
      removed = removed + 1
    else
      err("Cannot remove " .. path .. ": " .. tostring(rm_err))
      skipped = skipped + 1
    end
  else
    missing = missing + 1
  end
end

-- ── Remove empty directories ──────────────────────────────────────────────────

writeln("")
info("Cleaning up directories…")
for _, d in ipairs(DIRS) do
  if file_exists(d) and is_dir(d) then
    local entries = dir_list(d)
    if #entries == 0 then
      local ok_rm = pcall(file_remove, d)
      if ok_rm then
        writeln(c("32","  rmdir") .. "  " .. d)
      end
    else
      writeln(c("36","  keep") .. "  " .. d .. "  (" .. #entries .. " item(s) remaining)")
    end
  end
end

-- ── Summary ───────────────────────────────────────────────────────────────────

writeln("")
writeln(string.format(
  c("1","Results:") .. "  %s removed,  %s not found,  %s errors",
  c("32", tostring(removed)),
  c("36", tostring(missing)),
  skipped > 0 and c("31", tostring(skipped)) or c("32", "0")
))

-- ── EEPROM restore ────────────────────────────────────────────────────────────

writeln("")
local eeprom = nil
for a in component.list("eeprom") do eeprom = component.proxy(a); break end

if eeprom then
  local bak = read_file("/eeprom.bak")
  if bak then
    warn("EEPROM backup found at /eeprom.bak")
    local ans2 = prompt("Restore original BIOS from backup? [yes/no]: ")
    if ans2 == "yes" then
      local ok2, e2 = pcall(function() eeprom.set(bak) end)
      if ok2 then
        pcall(function() eeprom.setLabel("") end)
        ok("EEPROM restored from /eeprom.bak")
      else
        err("EEPROM restore failed: " .. tostring(e2))
      end
    else
      info("EEPROM left unchanged.")
    end
  else
    warn("No /eeprom.bak found. Restore the original BIOS manually before rebooting.")
  end
else
  warn("No EEPROM component detected.")
end

-- ── Done ──────────────────────────────────────────────────────────────────────

writeln("")
ok("Uninstall complete.")
writeln("You can now reboot into OpenOS (or flash another OS).")
writeln("")
return removed > 0 and 0 or 1
