-- apt – package manager for UniOS
-- Supports install, remove, update, upgrade, list, search, info, and show
-- with full dependency resolution (topological sort).

local gpu   = kernel.drivers.gpu
local vfs   = kernel.vfs
local lp    = kernel.require("lib.libpath")

local function write(s)   gpu.write(tostring(s))        end
local function writeln(s) gpu.write(tostring(s) .. "\n") end

-- ── ANSI helpers ─────────────────────────────────────────────────────────────

local function bold(s)   return "\27[1m"  .. s .. "\27[0m" end
local function green(s)  return "\27[32m" .. s .. "\27[0m" end
local function red(s)    return "\27[31m" .. s .. "\27[0m" end
local function cyan(s)   return "\27[36m" .. s .. "\27[0m" end
local function yellow(s) return "\27[33m" .. s .. "\27[0m" end
local function dim(s)    return "\27[90m" .. s .. "\27[0m" end

-- ── Paths ────────────────────────────────────────────────────────────────────

local SOURCES_FILE  = "/etc/apt/sources.list"
local INDEX_CACHE   = "/var/lib/apt/packages.idx"
local INSTALLED_DB  = "/var/lib/apt/installed"

-- ── Network ──────────────────────────────────────────────────────────────────

local internet = nil
for a in component.list("internet") do
  internet = component.proxy(a); break
end

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
  return data ~= "" and data or nil, "empty response"
end

-- ── Filesystem helpers ───────────────────────────────────────────────────────

local function mkdirp(path)
  local parts = {}
  for seg in path:gmatch("[^/]+") do parts[#parts + 1] = seg end
  local cur = ""
  for _, seg in ipairs(parts) do
    cur = cur .. "/" .. seg
    if not vfs.exists(cur) then vfs.mkdir(cur) end
  end
end

local function write_file(path, data)
  local dir = path:match("^(.+)/[^/]+$")
  if dir then mkdirp(dir) end
  local fd, e = vfs.open(path, "w")
  if not fd then return false, e end
  local ok, w_err = vfs.write(fd, data)
  vfs.close(fd)
  if not ok and w_err then return false, w_err end
  return true
end

local function safe_file_path(path)
  if path:find("%.%.", 1, true) then return false end
  if path:sub(1, 1) == "/" then return false end
  return true
end

local function read_file(path)
  return vfs.readfile(path)
end

-- ── Package Index Parser ─────────────────────────────────────────────────────
-- Format:
--   @name version description
--   depends: dep1 dep2 ...
--   files: path1 path2 ...

local function parse_index(raw)
  local packages = {}
  local current = nil

  for line in (raw .. "\n"):gmatch("(.-)\n") do
    line = line:match("^%s*(.-)%s*$")

    if line == "" or line:sub(1, 1) == "#" then
      if current then
        packages[current.name] = current
        current = nil
      end
    elseif line:sub(1, 1) == "@" then
      if current then packages[current.name] = current end
      local name, ver, desc = line:match("^@(%S+)%s+(%S+)%s+(.*)$")
      if name then
        current = {
          name = name,
          version = ver,
          description = desc or "",
          depends = {},
          files = {},
        }
      end
    elseif current and line:match("^depends:") then
      local deps_str = line:match("^depends:%s*(.*)$") or ""
      for dep in deps_str:gmatch("%S+") do
        current.depends[#current.depends + 1] = dep
      end
    elseif current and line:match("^files:") then
      local files_str = line:match("^files:%s*(.*)$") or ""
      for f in files_str:gmatch("%S+") do
        current.files[#current.files + 1] = f
      end
    end
  end
  if current then packages[current.name] = current end

  return packages
end

-- ── Installed DB ─────────────────────────────────────────────────────────────
-- Simple format: one "name version" per line

local function load_installed()
  local db = {}
  local raw = read_file(INSTALLED_DB)
  if not raw then return db end
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    local name, ver = line:match("^(%S+)%s+(%S+)")
    if name then db[name] = ver end
  end
  return db
end

local function save_installed(db)
  local lines = {}
  local sorted_keys = {}
  for k in pairs(db) do sorted_keys[#sorted_keys + 1] = k end
  table.sort(sorted_keys)
  for _, k in ipairs(sorted_keys) do
    lines[#lines + 1] = k .. " " .. db[k]
  end
  mkdirp("/var/lib/apt")
  local data = table.concat(lines, "\n") .. "\n"
  local ok, err = write_file(INSTALLED_DB, data)
  if not ok then
    writeln(red("E:") .. " Failed to save installed DB: " .. tostring(err))
  end
end

-- ── Source URLs ──────────────────────────────────────────────────────────────

local function load_sources()
  local raw = read_file(SOURCES_FILE)
  if not raw then return {} end
  local sources = {}
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      sources[#sources + 1] = line
    end
  end
  return sources
end

-- ── Load index (cached or from network) ──────────────────────────────────────

local function load_index()
  local raw = read_file(INDEX_CACHE)
  if raw and #raw > 10 then return parse_index(raw) end
  return nil, "no index (run 'apt update' first)"
end

-- ── Dependency Resolution ────────────────────────────────────────────────────
-- Topological sort with cycle detection

local function resolve_deps(packages, names, installed)
  local order = {}
  local visited = {}
  local in_stack = {}
  local errors = {}

  local function visit(name)
    if visited[name] then return true end
    if in_stack[name] then
      errors[#errors + 1] = "circular dependency: " .. name
      return false
    end

    local pkg = packages[name]
    if not pkg then
      errors[#errors + 1] = "package not found: " .. name
      return false
    end

    in_stack[name] = true

    for _, dep in ipairs(pkg.depends) do
      if not installed[dep] then
        if not visit(dep) then
          in_stack[name] = nil
          return false
        end
      end
    end

    in_stack[name] = nil
    visited[name] = true
    order[#order + 1] = name
    return true
  end

  for _, name in ipairs(names) do
    if not installed[name] then
      visit(name)
    end
  end

  return order, errors
end

-- ── Reverse dependency lookup ────────────────────────────────────────────────

local function reverse_deps(packages, pkg_name)
  local rdeps = {}
  for name, pkg in pairs(packages) do
    for _, dep in ipairs(pkg.depends) do
      if dep == pkg_name then
        rdeps[#rdeps + 1] = name
        break
      end
    end
  end
  return rdeps
end

-- ── Commands ─────────────────────────────────────────────────────────────────

local function cmd_update()
  local sources = load_sources()
  if #sources == 0 then
    writeln(red("E:") .. " No sources configured in " .. SOURCES_FILE)
    return 1
  end

  local all_raw = ""
  for _, src in ipairs(sources) do
    local url = src .. "/packages.idx"
    write(dim("Get: ") .. url .. " ... ")
    local data, e = http_get(url, 20)
    if data then
      writeln(green("OK") .. dim(" (" .. #data .. "B)"))
      all_raw = all_raw .. "\n" .. data
    else
      writeln(red("FAILED") .. " " .. tostring(e))
    end
  end

  if #all_raw < 10 then
    writeln(red("E:") .. " Failed to fetch any package index.")
    return 1
  end

  mkdirp("/var/lib/apt")
  write_file(INDEX_CACHE, all_raw)
  local packages = parse_index(all_raw)
  local count = 0
  for _ in pairs(packages) do count = count + 1 end
  writeln(green("Updated") .. " package index: " .. bold(tostring(count)) .. " packages available.")
  return 0
end

local function cmd_install(names)
  if #names == 0 then
    writeln(red("E:") .. " No package names specified.")
    writeln("Usage: apt install <pkg1> [pkg2] ...")
    return 1
  end

  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end

  local installed = load_installed()

  for _, name in ipairs(names) do
    if not packages[name] then
      writeln(red("E:") .. " Package '" .. name .. "' not found.")
      writeln("  Run 'apt update' to refresh, or 'apt search " .. name .. "' to find it.")
      return 1
    end
  end

  local order, errs = resolve_deps(packages, names, installed)

  if #errs > 0 then
    for _, err_msg in ipairs(errs) do
      writeln(red("E:") .. " " .. err_msg)
    end
    return 1
  end

  if #order == 0 then
    writeln(green("All requested packages are already installed."))
    return 0
  end

  -- Show what will be installed
  local new_pkgs = {}
  local dep_pkgs = {}
  local name_set = {}
  for _, n in ipairs(names) do name_set[n] = true end

  for _, pkg_name in ipairs(order) do
    if name_set[pkg_name] then
      new_pkgs[#new_pkgs + 1] = pkg_name
    else
      dep_pkgs[#dep_pkgs + 1] = pkg_name
    end
  end

  writeln(bold("The following packages will be installed:"))
  if #dep_pkgs > 0 then
    writeln("  " .. dim("dependencies:") .. " " .. table.concat(dep_pkgs, " "))
  end
  writeln("  " .. green(table.concat(new_pkgs, " ")))

  local total_files = 0
  for _, pkg_name in ipairs(order) do
    total_files = total_files + #packages[pkg_name].files
  end
  writeln(dim(string.format("  %d package(s), %d file(s) to download", #order, total_files)))
  writeln("")

  if not internet then
    writeln(red("E:") .. " No internet card detected.")
    return 1
  end

  -- Load sources for base URL
  local sources = load_sources()
  local base_url = sources[1]
  if not base_url then
    writeln(red("E:") .. " No source URL configured.")
    return 1
  end
  local file_base = base_url:gsub("/$", "")

  local done = 0
  local failed = 0

  for _, pkg_name in ipairs(order) do
    local pkg = packages[pkg_name]
    write(cyan("[" .. pkg_name .. "]") .. " " .. pkg.version)

    if #pkg.files == 0 then
      writeln("  " .. dim("(meta-package, no files)"))
    else
      writeln("")
    end

    local pkg_failed = false
    for _, file_path in ipairs(pkg.files) do
      if not safe_file_path(file_path) then
        writeln("  " .. red("REJECTED") .. " " .. file_path .. " (unsafe path)")
        failed = failed + 1
        pkg_failed = true
      else
        local url = file_base .. "/" .. file_path
        write("  " .. dim("GET ") .. file_path .. " ... ")
        local data, dl_err = http_get(url, 30)
        if data then
          local dir = ("/" .. file_path):match("^(.+)/[^/]+$")
          if dir then mkdirp(dir) end
          local ok, w_err = write_file("/" .. file_path, data)
          if ok then
            writeln(green("OK") .. dim(" (" .. #data .. "B)"))
            done = done + 1
          else
            writeln(red("WRITE FAILED") .. " " .. tostring(w_err))
            failed = failed + 1
            pkg_failed = true
          end
        else
          writeln(red("FAILED") .. " " .. tostring(dl_err))
          failed = failed + 1
          pkg_failed = true
        end
      end
    end

    if not pkg_failed then
      installed[pkg_name] = pkg.version
      save_installed(installed)
    end
  end

  writeln("")
  if failed == 0 then
    writeln(green("Done.") .. string.format(" %d package(s) installed, %d file(s) downloaded.", #order, done))
  else
    writeln(yellow("Warning:") .. string.format(" %d file(s) failed to download.", failed))
  end
  return failed == 0 and 0 or 1
end

local function cmd_remove(names)
  if #names == 0 then
    writeln(red("E:") .. " No package names specified.")
    return 1
  end

  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end

  local installed = load_installed()

  for _, name in ipairs(names) do
    if not installed[name] then
      writeln(yellow("W:") .. " Package '" .. name .. "' is not installed.")
      return 1
    end
  end

  -- Check reverse dependencies
  for _, name in ipairs(names) do
    local rdeps = reverse_deps(packages, name)
    local blocking = {}
    for _, rd in ipairs(rdeps) do
      if installed[rd] then
        local is_being_removed = false
        for _, n in ipairs(names) do
          if n == rd then is_being_removed = true; break end
        end
        if not is_being_removed then
          blocking[#blocking + 1] = rd
        end
      end
    end
    if #blocking > 0 then
      writeln(red("E:") .. " Cannot remove '" .. name .. "': required by " .. table.concat(blocking, ", "))
      writeln("  Remove those packages first, or use: apt remove " .. table.concat(blocking, " ") .. " " .. name)
      return 1
    end
  end

  writeln(bold("The following packages will be removed:"))
  writeln("  " .. red(table.concat(names, " ")))
  writeln("")

  local removed_files = 0
  for _, name in ipairs(names) do
    local pkg = packages[name]
    if pkg then
      for _, file_path in ipairs(pkg.files) do
        local abs = "/" .. file_path
        if vfs.exists(abs) then
          vfs.remove(abs)
          removed_files = removed_files + 1
          writeln("  " .. dim("rm ") .. abs)
        end
      end
    end
    installed[name] = nil
  end
  save_installed(installed)

  writeln("")
  writeln(green("Done.") .. string.format(" %d package(s) removed, %d file(s) deleted.", #names, removed_files))
  return 0
end

local function cmd_upgrade()
  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end

  local installed = load_installed()
  local upgradable = {}

  for name, ver in pairs(installed) do
    local pkg = packages[name]
    if pkg and pkg.version ~= ver then
      upgradable[#upgradable + 1] = name
    end
  end

  if #upgradable == 0 then
    writeln(green("All packages are up to date."))
    return 0
  end

  writeln(bold(#upgradable .. " package(s) can be upgraded:"))
  for _, name in ipairs(upgradable) do
    local old = installed[name]
    local new = packages[name].version
    writeln("  " .. cyan(name) .. " " .. dim(old) .. " -> " .. green(new))
  end
  writeln("")

  return cmd_install(upgradable)
end

local function cmd_list()
  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end

  local installed = load_installed()
  local sorted = {}
  for name in pairs(packages) do sorted[#sorted + 1] = name end
  table.sort(sorted)

  for _, name in ipairs(sorted) do
    local pkg = packages[name]
    local status = installed[name] and green("[installed]") or dim("[available]")
    writeln(string.format("  %-20s %-8s %s  %s", name, pkg.version, status, dim(pkg.description)))
  end
  writeln("")
  writeln(dim(string.format("  %d packages total, %d installed", #sorted, (function()
    local c = 0; for _ in pairs(installed) do c = c + 1 end; return c
  end)())))
  return 0
end

local function cmd_search(query)
  if not query or query == "" then
    writeln(red("E:") .. " Specify a search term.")
    return 1
  end

  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end

  local installed = load_installed()
  local found = 0
  local sorted = {}
  for name in pairs(packages) do sorted[#sorted + 1] = name end
  table.sort(sorted)

  local q = query:lower()
  for _, name in ipairs(sorted) do
    local pkg = packages[name]
    if name:lower():find(q, 1, true) or pkg.description:lower():find(q, 1, true) then
      local status = installed[name] and green("[installed]") or ""
      writeln(string.format("  %-20s %-8s %s", name, pkg.version, status))
      writeln("    " .. dim(pkg.description))
      found = found + 1
    end
  end

  if found == 0 then
    writeln(yellow("No packages found matching '") .. query .. yellow("'."))
  else
    writeln(dim(string.format("\n  %d result(s)", found)))
  end
  return 0
end

local function cmd_info(name)
  if not name or name == "" then
    writeln(red("E:") .. " Specify a package name.")
    return 1
  end

  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end

  local pkg = packages[name]
  if not pkg then
    writeln(red("E:") .. " Package '" .. name .. "' not found.")
    return 1
  end

  local installed = load_installed()

  writeln(bold("Package: ") .. cyan(pkg.name))
  writeln(bold("Version: ") .. pkg.version)
  writeln(bold("Status:  ") .. (installed[name] and green("installed (" .. installed[name] .. ")") or dim("not installed")))
  writeln(bold("Description: ") .. pkg.description)

  if #pkg.depends > 0 then
    writeln(bold("Depends: ") .. table.concat(pkg.depends, ", "))
    local missing = {}
    for _, dep in ipairs(pkg.depends) do
      if not installed[dep] then missing[#missing + 1] = dep end
    end
    if #missing > 0 then
      writeln("  " .. yellow("Missing: ") .. table.concat(missing, ", "))
    end
  else
    writeln(bold("Depends: ") .. dim("(none)"))
  end

  if #pkg.files > 0 then
    writeln(bold("Files:"))
    for _, f in ipairs(pkg.files) do
      local exists = vfs.exists("/" .. f)
      writeln("  " .. (exists and green("✓") or red("✗")) .. "  /" .. f)
    end
  else
    writeln(bold("Files: ") .. dim("(meta-package)"))
  end

  -- Show who depends on this
  local rdeps = reverse_deps(packages, name)
  if #rdeps > 0 then
    writeln(bold("Required by: ") .. table.concat(rdeps, ", "))
  end

  return 0
end

local function cmd_autoremove()
  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end

  local installed = load_installed()
  local needed = {}

  -- Mark all explicitly installed packages and their dep chains as needed
  local function mark_needed(name)
    if needed[name] then return end
    needed[name] = true
    local pkg = packages[name]
    if pkg then
      for _, dep in ipairs(pkg.depends) do
        mark_needed(dep)
      end
    end
  end

  for name in pairs(installed) do
    mark_needed(name)
  end

  local orphans = {}
  for name in pairs(installed) do
    if not needed[name] then
      orphans[#orphans + 1] = name
    end
  end

  if #orphans == 0 then
    writeln(green("No orphaned packages to remove."))
    return 0
  end

  writeln(bold("The following packages are no longer needed:"))
  writeln("  " .. yellow(table.concat(orphans, " ")))
  return cmd_remove(orphans)
end

-- ── Usage ────────────────────────────────────────────────────────────────────

local function usage()
  writeln(bold("apt") .. " – UniOS package manager")
  writeln("")
  writeln("  " .. cyan("apt update") .. "              refresh package index from sources")
  writeln("  " .. cyan("apt install") .. " <pkg> ...   install packages (with dependencies)")
  writeln("  " .. cyan("apt remove") .. "  <pkg> ...   remove packages")
  writeln("  " .. cyan("apt upgrade") .. "             upgrade all installed packages")
  writeln("  " .. cyan("apt list") .. "                list all available packages")
  writeln("  " .. cyan("apt search") .. "  <query>     search packages by name/description")
  writeln("  " .. cyan("apt info") .. "    <pkg>       show package details")
  writeln("  " .. cyan("apt autoremove") .. "          remove orphaned dependencies")
  writeln("  " .. cyan("apt help") .. "                show this help")
  writeln("")
  writeln(dim("Sources: " .. SOURCES_FILE))
  writeln(dim("Index:   " .. INDEX_CACHE))
end

-- ── Main ─────────────────────────────────────────────────────────────────────

local argv = arg or {}

if #argv == 0 then
  usage()
  return 0
end

local cmd = argv[1]
local rest = {}
for i = 2, #argv do rest[#rest + 1] = argv[i] end

if cmd == "update" then
  return cmd_update()
elseif cmd == "install" then
  return cmd_install(rest)
elseif cmd == "remove" or cmd == "purge" then
  return cmd_remove(rest)
elseif cmd == "upgrade" or cmd == "dist-upgrade" or cmd == "full-upgrade" then
  return cmd_upgrade()
elseif cmd == "list" then
  return cmd_list()
elseif cmd == "search" then
  return cmd_search(rest[1])
elseif cmd == "info" or cmd == "show" then
  return cmd_info(rest[1])
elseif cmd == "autoremove" then
  return cmd_autoremove()
elseif cmd == "help" or cmd == "--help" or cmd == "-h" then
  usage()
  return 0
else
  writeln(red("E:") .. " Unknown command '" .. cmd .. "'")
  writeln("Run 'apt help' for usage.")
  return 1
end
