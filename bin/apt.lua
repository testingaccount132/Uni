-- apt – UniOS package and system manager
-- Handles both system updates (from GitHub) and package installs.
-- apt update     — fetch latest file manifest from GitHub (with SHA hashes)
-- apt upgrade    — download all changed/new system files
-- apt install    — install packages from the repo
-- apt remove     — remove packages
-- apt list       — list available packages
-- apt search     — search packages
-- apt info       — show package details

local gpu   = kernel.drivers.gpu
local vfs   = kernel.vfs
local lp    = kernel.require("lib.libpath")

local function write(s)   gpu.write(tostring(s))        end
local function writeln(s) gpu.write(tostring(s) .. "\n") end

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
local MANIFEST_DB   = "/var/lib/apt/manifest"

local REPO_RAW = "https://raw.githubusercontent.com/testingaccount132/Uni/main"
local REPO_API = "https://api.github.com/repos/testingaccount132/Uni/git/trees/main?recursive=1"

-- Files/dirs to skip during system upgrade
local SKIP_PATTERNS = {
  "^%.",              -- dotfiles (.gitignore, .github/, etc.)
  "^README",
  "^LICENSE",
  "^INSTALL",
  "%.md$",
  "%.js$",
  "%.json$",
  "%.yml$",
  "%.yaml$",
  "^repo/",           -- repo packages are installed via apt install
  "^scripts/",        -- build scripts (minify.js etc.)
  "^tools/minify",    -- minification tool, not needed at runtime
  "^eeprom/bios%.lua$",  -- skip full bios; .min.lua is what gets flashed
}

local function should_skip(path)
  for _, pat in ipairs(SKIP_PATTERNS) do
    if path:match(pat) then return true end
  end
  return false
end

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

  -- Wait for connection to establish
  while computer.uptime() < deadline do
    local ok, err = req.finishConnect()
    if ok then break end
    if ok == nil then req.close(); return nil, tostring(err or "connection failed") end
    os.sleep(0.05)
  end

  -- Read response
  local chunks = {}
  while computer.uptime() < deadline do
    local chunk, reason = req.read(65536)
    if chunk then
      chunks[#chunks + 1] = chunk
    elseif reason then
      req.close(); return nil, tostring(reason)
    else
      if #chunks > 0 then break end
      os.sleep(0.05)
    end
  end
  req.close()
  local data = table.concat(chunks)
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

local function read_file(path)
  return vfs.readfile(path)
end

-- ── Simple hash function (djb2) ──────────────────────────────────────────────
-- Used to detect local file changes without storing full content

local function djb2_hash(str)
  if not str then return "0" end
  local hash = 5381
  for i = 1, #str do
    hash = ((hash * 33) + str:byte(i)) % 0xFFFFFFFF
  end
  return string.format("%08x", hash)
end

-- ── GitHub API tree parser ───────────────────────────────────────────────────
-- Extracts file paths and their SHA hashes from the GitHub tree API response

local function parse_github_tree(json)
  local files = {}
  for obj in json:gmatch("{([^}]+)}") do
    local ftype = obj:match('"type"%s*:%s*"([^"]+)"')
    if ftype == "blob" then
      local path = obj:match('"path"%s*:%s*"([^"]+)"')
      local sha  = obj:match('"sha"%s*:%s*"([^"]+)"')
      local size = obj:match('"size"%s*:%s*(%d+)')
      if path and not should_skip(path) then
        files[#files + 1] = {
          path = path,
          sha  = sha or "",
          size = tonumber(size) or 0,
        }
      end
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  return files
end

-- ── Manifest (local cache of remote file hashes) ─────────────────────────────
-- Format: sha size path (one per line)

local function load_manifest()
  local raw = read_file(MANIFEST_DB)
  if not raw then return {} end
  local files = {}
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    local sha, size, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
    if sha and path then
      files[path] = { sha = sha, size = tonumber(size) or 0 }
    end
  end
  return files
end

local function save_manifest(tree)
  local lines = {}
  for _, f in ipairs(tree) do
    lines[#lines + 1] = f.sha .. " " .. f.size .. " " .. f.path
  end
  mkdirp("/var/lib/apt")
  write_file(MANIFEST_DB, table.concat(lines, "\n") .. "\n")
end

-- ── Package Index Parser (same format as before) ─────────────────────────────

local function parse_index(raw)
  local packages = {}
  local current = nil
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    line = line:match("^%s*(.-)%s*$")
    if line == "" or line:sub(1, 1) == "#" then
      if current then packages[current.name] = current; current = nil end
    elseif line:sub(1, 1) == "@" then
      if current then packages[current.name] = current end
      local name, ver, desc = line:match("^@(%S+)%s+(%S+)%s+(.*)$")
      if name then current = { name = name, version = ver, description = desc or "", depends = {}, files = {} } end
    elseif current and line:match("^depends:") then
      for dep in (line:match("^depends:%s*(.*)$") or ""):gmatch("%S+") do
        current.depends[#current.depends + 1] = dep
      end
    elseif current and line:match("^files:") then
      for f in (line:match("^files:%s*(.*)$") or ""):gmatch("%S+") do
        current.files[#current.files + 1] = f
      end
    end
  end
  if current then packages[current.name] = current end
  return packages
end

-- ── Installed DB ─────────────────────────────────────────────────────────────

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
  local ok, err = write_file(INSTALLED_DB, table.concat(lines, "\n") .. "\n")
  if not ok then writeln(red("E:") .. " Failed to save DB: " .. tostring(err)) end
end

-- ── Source URLs ──────────────────────────────────────────────────────────────

local function load_sources()
  local raw = read_file(SOURCES_FILE)
  if not raw then return {} end
  local sources = {}
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then sources[#sources + 1] = line end
  end
  return sources
end

local function load_index()
  local raw = read_file(INDEX_CACHE)
  if raw and #raw > 10 then return parse_index(raw) end
  return nil, "no index (run 'apt update' first)"
end

-- ── Dependency Resolution ────────────────────────────────────────────────────

local function resolve_deps(packages, names, installed)
  local order, visited, in_stack, errors = {}, {}, {}, {}
  local function visit(name)
    if visited[name] then return true end
    if in_stack[name] then errors[#errors+1] = "circular dependency: " .. name; return false end
    local pkg = packages[name]
    if not pkg then errors[#errors+1] = "package not found: " .. name; return false end
    in_stack[name] = true
    for _, dep in ipairs(pkg.depends) do
      if not installed[dep] then if not visit(dep) then in_stack[name] = nil; return false end end
    end
    in_stack[name] = nil; visited[name] = true; order[#order+1] = name; return true
  end
  for _, name in ipairs(names) do if not installed[name] then visit(name) end end
  return order, errors
end

local function reverse_deps(packages, pkg_name)
  local rdeps = {}
  for name, pkg in pairs(packages) do
    for _, dep in ipairs(pkg.depends) do
      if dep == pkg_name then rdeps[#rdeps+1] = name; break end
    end
  end
  return rdeps
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- COMMANDS
-- ═══════════════════════════════════════════════════════════════════════════════

local function cmd_update()
  if not internet then writeln(red("E:") .. " No internet card."); return 1 end

  -- 1. Fetch system file tree from GitHub API
  write(dim("Hit: ") .. "GitHub API tree ... ")
  local tree_json, tree_err = http_get(REPO_API, 20)
  if not tree_json then
    writeln(red("FAILED") .. " " .. tostring(tree_err))
    writeln(yellow("W:") .. " GitHub API may be rate-limited. Try again in a minute.")
    return 1
  end

  local tree = parse_github_tree(tree_json)
  writeln(green("OK") .. dim(" (" .. #tree .. " files)"))
  save_manifest(tree)

  -- 2. Fetch package index from sources
  local sources = load_sources()
  local all_raw = ""
  for _, src in ipairs(sources) do
    local url = src .. "/packages.idx"
    write(dim("Hit: ") .. url .. " ... ")
    local data, e = http_get(url, 20)
    if data then
      writeln(green("OK") .. dim(" (" .. #data .. "B)"))
      all_raw = all_raw .. "\n" .. data
    else
      writeln(red("FAILED") .. " " .. tostring(e))
    end
    coroutine.yield()
  end

  if #all_raw > 10 then
    mkdirp("/var/lib/apt")
    write_file(INDEX_CACHE, all_raw)
    local packages = parse_index(all_raw)
    local count = 0; for _ in pairs(packages) do count = count + 1 end
    writeln(green("Updated") .. " package index: " .. bold(tostring(count)) .. " packages.")
  end

  -- Summary
  local manifest = load_manifest()
  local local_changed = 0
  local local_missing = 0
  for path, info in pairs(manifest) do
    local local_data = read_file("/" .. path)
    if not local_data then
      local_missing = local_missing + 1
    else
      local local_hash = djb2_hash(local_data)
      if #local_data ~= info.size then
        local_changed = local_changed + 1
      end
    end
  end

  local total_files = 0; for _ in pairs(manifest) do total_files = total_files + 1 end
  writeln("")
  writeln(bold("System status:"))
  writeln("  " .. tostring(total_files) .. " files tracked")
  if local_changed > 0 then
    writeln("  " .. yellow(tostring(local_changed) .. " files differ from remote"))
  end
  if local_missing > 0 then
    writeln("  " .. cyan(tostring(local_missing) .. " new files available"))
  end
  if local_changed == 0 and local_missing == 0 then
    writeln("  " .. green("System is up to date."))
  else
    writeln("  Run " .. cyan("'apt upgrade'") .. " to update.")
  end

  return 0
end

local function cmd_upgrade()
  if not internet then writeln(red("E:") .. " No internet card."); return 1 end

  local manifest = load_manifest()
  if not next(manifest) then
    writeln(red("E:") .. " No manifest. Run 'apt update' first.")
    return 1
  end

  -- Compare local files with manifest
  local to_download = {}
  local up_to_date = 0

  for path, info in pairs(manifest) do
    local local_data = read_file("/" .. path)
    if not local_data then
      to_download[#to_download + 1] = { path = path, reason = "new", size = info.size }
    else
      if #local_data ~= info.size then
        to_download[#to_download + 1] = { path = path, reason = "changed", size = info.size }
      else
        up_to_date = up_to_date + 1
      end
    end
  end

  if #to_download == 0 then
    writeln(green("System is up to date.") .. dim(" (" .. up_to_date .. " files checked)"))
    return 0
  end

  -- Sort: changed first, then new
  table.sort(to_download, function(a, b)
    if a.reason ~= b.reason then return a.reason < b.reason end
    return a.path < b.path
  end)

  -- Show summary
  local changed_count = 0
  local new_count = 0
  for _, f in ipairs(to_download) do
    if f.reason == "changed" then changed_count = changed_count + 1
    else new_count = new_count + 1 end
  end

  writeln(bold("The following files will be updated:"))
  if changed_count > 0 then
    writeln("  " .. yellow("Modified: ") .. tostring(changed_count) .. " file(s)")
  end
  if new_count > 0 then
    writeln("  " .. cyan("New: ") .. tostring(new_count) .. " file(s)")
  end
  writeln(dim("  " .. tostring(up_to_date) .. " files already up to date."))
  writeln("")

  -- Download and update
  local done = 0
  local failed = 0
  local total_bytes = 0

  for i, f in ipairs(to_download) do
    local pct = math.floor(i / #to_download * 100)
    local tag = f.reason == "changed" and yellow("UPD") or cyan("NEW")
    write(string.format("[%3d%%] %s %s ... ", pct, tag, f.path))

    local url = REPO_RAW .. "/" .. f.path
    local data, dl_err = http_get(url, 30)
    if data then
      local dir = ("/" .. f.path):match("^(.+)/[^/]+$")
      if dir then mkdirp(dir) end
      local ok, w_err = write_file("/" .. f.path, data)
      if ok then
        writeln(green("OK") .. dim(" (" .. #data .. "B)"))
        done = done + 1
        total_bytes = total_bytes + #data
      else
        writeln(red("WRITE FAILED") .. " " .. tostring(w_err))
        failed = failed + 1
      end
    else
      writeln(red("FAILED") .. " " .. tostring(dl_err))
      failed = failed + 1
    end
    coroutine.yield()
  end

  writeln("")
  if failed == 0 then
    writeln(green("Done.") .. string.format(" %d file(s) updated, %s downloaded.",
      done, (total_bytes > 1024) and string.format("%.1fKB", total_bytes/1024) or (total_bytes .. "B")))
  else
    writeln(yellow("Warning:") .. string.format(" %d succeeded, %d failed.", done, failed))
  end
  return failed == 0 and 0 or 1
end

local function cmd_install(names)
  if #names == 0 then writeln(red("E:") .. " No package names specified."); writeln("Usage: apt install <pkg1> [pkg2] ..."); return 1 end

  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end
  local installed = load_installed()

  for _, name in ipairs(names) do
    if not packages[name] then
      writeln(red("E:") .. " Package '" .. name .. "' not found. Run 'apt update' to refresh.")
      return 1
    end
  end

  local order, errs = resolve_deps(packages, names, installed)
  if #errs > 0 then for _, msg in ipairs(errs) do writeln(red("E:") .. " " .. msg) end; return 1 end
  if #order == 0 then writeln(green("All requested packages are already installed.")); return 0 end

  local name_set = {}
  for _, n in ipairs(names) do name_set[n] = true end
  local new_pkgs, dep_pkgs = {}, {}
  for _, pkg_name in ipairs(order) do
    if name_set[pkg_name] then new_pkgs[#new_pkgs+1] = pkg_name else dep_pkgs[#dep_pkgs+1] = pkg_name end
  end

  writeln(bold("The following packages will be installed:"))
  if #dep_pkgs > 0 then writeln("  " .. dim("dependencies:") .. " " .. table.concat(dep_pkgs, " ")) end
  writeln("  " .. green(table.concat(new_pkgs, " ")))

  local total_files = 0
  for _, pkg_name in ipairs(order) do total_files = total_files + #packages[pkg_name].files end
  writeln(dim(string.format("  %d package(s), %d file(s)", #order, total_files)))
  writeln("")

  if not internet then writeln(red("E:") .. " No internet card."); return 1 end

  local sources = load_sources()
  local base_url = sources[1]
  if not base_url then writeln(red("E:") .. " No source URL."); return 1 end
  local file_base = base_url:gsub("/$", "")

  local done, failed = 0, 0

  for _, pkg_name in ipairs(order) do
    local pkg = packages[pkg_name]
    write(cyan("[" .. pkg_name .. "]") .. " " .. pkg.version)
    if #pkg.files == 0 then writeln("  " .. dim("(meta-package)")) else writeln("") end

    local pkg_failed = false
    for _, file_path in ipairs(pkg.files) do
      if file_path:find("..", 1, true) or file_path:sub(1,1) == "/" then
        writeln("  " .. red("REJECTED") .. " " .. file_path); failed = failed + 1; pkg_failed = true
      else
        local url = file_base .. "/" .. file_path
        write("  " .. dim("GET ") .. file_path .. " ... ")
        local data, dl_err = http_get(url, 30)
        if data then
          local dir = ("/" .. file_path):match("^(.+)/[^/]+$")
          if dir then mkdirp(dir) end
          local ok, w_err = write_file("/" .. file_path, data)
          if ok then writeln(green("OK") .. dim(" (" .. #data .. "B)")); done = done + 1
          else writeln(red("WRITE FAIL") .. " " .. tostring(w_err)); failed = failed + 1; pkg_failed = true end
        else writeln(red("FAILED") .. " " .. tostring(dl_err)); failed = failed + 1; pkg_failed = true end
      end
      coroutine.yield()
    end

    if not pkg_failed then installed[pkg_name] = pkg.version; save_installed(installed) end
  end

  writeln("")
  if failed == 0 then writeln(green("Done.") .. string.format(" %d package(s), %d file(s).", #order, done))
  else writeln(yellow("Warning:") .. string.format(" %d failed.", failed)) end
  return failed == 0 and 0 or 1
end

local function cmd_remove(names)
  if #names == 0 then writeln(red("E:") .. " No package names specified."); return 1 end
  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end
  local installed = load_installed()

  for _, name in ipairs(names) do
    if not installed[name] then writeln(yellow("W:") .. " '" .. name .. "' not installed."); return 1 end
  end

  for _, name in ipairs(names) do
    local rdeps = reverse_deps(packages, name)
    local blocking = {}
    for _, rd in ipairs(rdeps) do
      if installed[rd] then
        local removing = false
        for _, n in ipairs(names) do if n == rd then removing = true; break end end
        if not removing then blocking[#blocking+1] = rd end
      end
    end
    if #blocking > 0 then
      writeln(red("E:") .. " Cannot remove '" .. name .. "': required by " .. table.concat(blocking, ", "))
      return 1
    end
  end

  writeln(bold("Removing:") .. " " .. red(table.concat(names, " ")))
  local removed = 0
  for _, name in ipairs(names) do
    local pkg = packages[name]
    if pkg then
      for _, fp in ipairs(pkg.files) do
        local abs = "/" .. fp
        if vfs.exists(abs) then vfs.remove(abs); removed = removed + 1; writeln("  " .. dim("rm ") .. abs) end
      end
    end
    installed[name] = nil
  end
  save_installed(installed)
  writeln(green("Done.") .. " " .. removed .. " file(s) removed.")
  return 0
end

local function cmd_list()
  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end
  local installed = load_installed()
  local sorted = {}; for name in pairs(packages) do sorted[#sorted+1] = name end; table.sort(sorted)
  for _, name in ipairs(sorted) do
    local pkg = packages[name]
    local status = installed[name] and green("[installed]") or dim("[available]")
    writeln(string.format("  %-20s %-8s %s  %s", name, pkg.version, status, dim(pkg.description)))
  end
  local ic = 0; for _ in pairs(installed) do ic = ic + 1 end
  writeln(dim(string.format("\n  %d packages, %d installed", #sorted, ic)))
  return 0
end

local function cmd_search(query)
  if not query or query == "" then writeln(red("E:") .. " Specify a search term."); return 1 end
  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end
  local installed = load_installed()
  local q = query:lower()
  local found = 0
  local sorted = {}; for name in pairs(packages) do sorted[#sorted+1] = name end; table.sort(sorted)
  for _, name in ipairs(sorted) do
    local pkg = packages[name]
    if name:lower():find(q, 1, true) or pkg.description:lower():find(q, 1, true) then
      local status = installed[name] and green("[installed]") or ""
      writeln(string.format("  %-20s %-8s %s", name, pkg.version, status))
      writeln("    " .. dim(pkg.description))
      found = found + 1
    end
  end
  if found == 0 then writeln(yellow("No results for '") .. query .. yellow("'."))
  else writeln(dim(string.format("\n  %d result(s)", found))) end
  return 0
end

local function cmd_info(name)
  if not name then writeln(red("E:") .. " Specify a package name."); return 1 end
  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end
  local pkg = packages[name]
  if not pkg then writeln(red("E:") .. " Package '" .. name .. "' not found."); return 1 end
  local installed = load_installed()
  writeln(bold("Package: ") .. cyan(pkg.name))
  writeln(bold("Version: ") .. pkg.version)
  writeln(bold("Status:  ") .. (installed[name] and green("installed (" .. installed[name] .. ")") or dim("not installed")))
  writeln(bold("Description: ") .. pkg.description)
  if #pkg.depends > 0 then writeln(bold("Depends: ") .. table.concat(pkg.depends, ", "))
  else writeln(bold("Depends: ") .. dim("(none)")) end
  if #pkg.files > 0 then
    writeln(bold("Files:"))
    for _, f in ipairs(pkg.files) do
      writeln("  " .. (vfs.exists("/" .. f) and green("v") or red("x")) .. "  /" .. f)
    end
  end
  local rdeps = reverse_deps(packages, name)
  if #rdeps > 0 then writeln(bold("Required by: ") .. table.concat(rdeps, ", ")) end
  return 0
end

local function cmd_autoremove()
  local packages, e = load_index()
  if not packages then writeln(red("E:") .. " " .. tostring(e)); return 1 end
  local installed = load_installed()
  local needed = {}
  local function mark(name) if needed[name] then return end; needed[name] = true; local p = packages[name]; if p then for _, d in ipairs(p.depends) do mark(d) end end end
  for name in pairs(installed) do mark(name) end
  local orphans = {}
  for name in pairs(installed) do if not needed[name] then orphans[#orphans+1] = name end end
  if #orphans == 0 then writeln(green("No orphaned packages.")); return 0 end
  writeln(bold("Orphaned:") .. " " .. yellow(table.concat(orphans, " ")))
  return cmd_remove(orphans)
end

local function cmd_status()
  local manifest = load_manifest()
  local installed = load_installed()
  local packages = load_index()

  local total_sys = 0; for _ in pairs(manifest) do total_sys = total_sys + 1 end
  local total_pkg = 0; if packages then for _ in pairs(packages) do total_pkg = total_pkg + 1 end end
  local total_inst = 0; for _ in pairs(installed) do total_inst = total_inst + 1 end

  writeln(bold("UniOS System Status"))
  writeln("  System files:  " .. tostring(total_sys) .. " tracked")
  writeln("  Packages:      " .. tostring(total_pkg) .. " available, " .. tostring(total_inst) .. " installed")
  writeln("  Kernel:        " .. kernel.VERSION .. " " .. (kernel.RELEASE or ""))
  writeln("  Memory:        " .. string.format("%dKB / %dKB",
    math.floor((computer.totalMemory() - computer.freeMemory()) / 1024),
    math.floor(computer.totalMemory() / 1024)))
  return 0
end

-- ── Usage ────────────────────────────────────────────────────────────────────

local function usage()
  writeln(bold("apt") .. " – UniOS system & package manager")
  writeln("")
  writeln("  " .. cyan("apt update") .. "              fetch latest file manifest + package index")
  writeln("  " .. cyan("apt upgrade") .. "             update all changed system files")
  writeln("  " .. cyan("apt install") .. " <pkg> ...   install packages (with dependencies)")
  writeln("  " .. cyan("apt remove") .. "  <pkg> ...   remove packages")
  writeln("  " .. cyan("apt list") .. "                list available packages")
  writeln("  " .. cyan("apt search") .. "  <query>     search packages")
  writeln("  " .. cyan("apt info") .. "    <pkg>       show package details")
  writeln("  " .. cyan("apt status") .. "              show system status")
  writeln("  " .. cyan("apt autoremove") .. "          remove orphaned dependencies")
  writeln("")
  writeln(dim("'apt upgrade' compares file sizes with GitHub to find changes."))
  writeln(dim("Only modified or new files are downloaded."))
end

-- ── Main ─────────────────────────────────────────────────────────────────────

local argv = arg or {}
if #argv == 0 then usage(); return 0 end

local cmd = argv[1]
local rest = {}; for i = 2, #argv do rest[#rest+1] = argv[i] end

if     cmd == "update"     then return cmd_update()
elseif cmd == "upgrade" or cmd == "dist-upgrade" or cmd == "full-upgrade" then return cmd_upgrade()
elseif cmd == "install"    then return cmd_install(rest)
elseif cmd == "remove" or cmd == "purge" then return cmd_remove(rest)
elseif cmd == "list"       then return cmd_list()
elseif cmd == "search"     then return cmd_search(rest[1])
elseif cmd == "info" or cmd == "show" then return cmd_info(rest[1])
elseif cmd == "autoremove" then return cmd_autoremove()
elseif cmd == "status"     then return cmd_status()
elseif cmd == "help" or cmd == "--help" or cmd == "-h" then usage(); return 0
else writeln(red("E:") .. " Unknown command '" .. cmd .. "'"); writeln("Run 'apt help' for usage."); return 1
end
