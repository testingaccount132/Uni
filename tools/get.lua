-- UniOS get – fetch or update a single file (or all files) from GitHub
-- Works from within UniOS or OpenOS.
--
-- Usage:
--   get <file>              download one file from the repo
--   get --all               download/update every UniOS file
--   get --update            same as --all
--   get --check             show which files differ from latest GitHub version
--   get --list              list all files in the repo (from GitHub API)
--   get <url> -o <path>     download arbitrary URL to a local path

local REPO     = "https://raw.githubusercontent.com/testingaccount132/Uni/main"
local API_TREE = "https://api.github.com/repos/testingaccount132/Uni/git/trees/main?recursive=1"
local BRANCH   = "main"

-- Files/patterns to skip when doing --all / --update
local SKIP = {
  ["README.md"]  = true,
  ["LICENSE"]    = true,
  [".gitignore"] = true,
}
local function should_skip(path)
  return SKIP[path] or path:match("^%.") ~= nil
end

-- ── Tiny JSON field extractor ─────────────────────────────────────────────────
-- We only need "path" fields from the GitHub tree response.
-- Format: {"path":"some/file.lua","mode":"...","type":"blob",...}
-- We skip entries where "type" is "tree" (directories).

local function parse_tree(json)
  local files = {}
  -- Iterate over each {...} object in the tree array
  for obj in json:gmatch("{([^}]+)}") do
    local ftype = obj:match('"type"%s*:%s*"([^"]+)"')
    if ftype == "blob" then
      local path = obj:match('"path"%s*:%s*"([^"]+)"')
      if path and not should_skip(path) then
        files[#files+1] = path
      end
    end
  end
  table.sort(files)
  return files
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local gpu   = kernel and kernel.drivers and kernel.drivers.gpu
local vfs   = kernel and kernel.vfs
local write = gpu and function(s) gpu.write(s) end
              or function(s) io.write(s) end
local function writeln(s) write(tostring(s).."\n") end

local function ok(m)   writeln("\27[32m✓\27[0m  "..m) end
local function err(m)  writeln("\27[31m✗\27[0m  "..m) end
local function info(m) writeln("\27[36m·\27[0m  "..m) end
local function warn(m) writeln("\27[33m⚠\27[0m  "..m) end

-- Find internet component (works under both OpenOS and UniOS)
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

-- ── Dynamic file list from GitHub API ────────────────────────────────────────

--- Fetch the repository's full recursive file tree from the GitHub API.
--- Returns a list of relative file paths (blobs only, sorted).
--- Falls back to nil + error string on failure.
local function fetch_file_list()
  info("Fetching file list from GitHub API…")
  local json, e = http_get(API_TREE, 20)
  if not json then
    return nil, "GitHub API error: " .. tostring(e)
  end
  local files = parse_tree(json)
  if #files == 0 then
    return nil, "Received empty file list (API rate-limited?)"
  end
  return files
end

local function write_file(path, data)
  -- Try vfs first (UniOS), then raw fs (OpenOS)
  if vfs then
    local fd, e = vfs.open(path, "w")
    if not fd then return false, e end
    vfs.write(fd, data)
    vfs.close(fd)
    return true
  else
    -- OpenOS: ensure parent dir
    local dir = path:match("^(.+)/[^/]+$") or "/"
    if not fs.exists(dir) then fs.makeDirectory(dir) end
    local h = io.open(path, "wb")
    if not h then return false, "cannot open "..path end
    h:write(data); h:close()
    return true
  end
end

local function read_file(path)
  if vfs then
    return vfs.readfile(path)
  else
    local h = io.open(path, "rb")
    if not h then return nil end
    local d = h:read("*a"); h:close(); return d
  end
end

-- ── Commands ──────────────────────────────────────────────────────────────────

local function cmd_fetch(rel_path, dest)
  dest = dest or ("/" .. rel_path)
  local url = REPO .. "/" .. rel_path
  local data, e = http_get(url)
  if not data then err("Download failed: " .. tostring(e)); return false end
  local wrote, we = write_file(dest, data)
  if not wrote then err("Write failed: " .. tostring(we)); return false end
  ok(rel_path .. "  (" .. #data .. "B)")
  return true
end

local function cmd_all()
  if not internet then err("No internet card detected."); return 1 end
  local files, e = fetch_file_list()
  if not files then
    err(tostring(e))
    warn("Tip: check your internet card and try again.")
    return 1
  end
  writeln(string.format("\27[1mUpdating %d files from %s…\27[0m", #files, BRANCH))
  local failed = 0
  for i, f in ipairs(files) do
    write(string.format("\27[36m[%d/%d]\27[0m  ", i, #files))
    if not cmd_fetch(f) then failed = failed + 1 end
  end
  writeln("")
  if failed == 0 then
    ok("All " .. #files .. " files up to date.")
  else
    warn(failed .. " file(s) failed. Run 'get --update' again to retry.")
  end
  return failed == 0 and 0 or 1
end

local function cmd_check()
  if not internet then err("No internet card."); return 1 end
  local files, e = fetch_file_list()
  if not files then err(tostring(e)); return 1 end
  writeln(string.format("\27[1mComparing %d files with %s…\27[0m", #files, BRANCH))
  local outdated, missing = {}, {}
  for _, f in ipairs(files) do
    local local_data = read_file("/" .. f)
    if not local_data then
      missing[#missing+1] = f
      writeln(string.format("  \27[35m?\27[0m  %s  \27[35m(not installed)\27[0m", f))
    else
      local remote, re = http_get(REPO .. "/" .. f)
      if not remote then
        warn("Cannot fetch " .. f .. ": " .. tostring(re))
      elseif local_data ~= remote then
        outdated[#outdated+1] = f
        writeln(string.format("  \27[33m≠\27[0m  %s", f))
      else
        writeln(string.format("  \27[32m=\27[0m  %s", f))
      end
    end
  end
  writeln("")
  local total_diff = #outdated + #missing
  if total_diff == 0 then
    ok("Everything is up to date.")
  else
    if #missing  > 0 then warn(#missing  .. " file(s) not installed locally.") end
    if #outdated > 0 then warn(#outdated .. " file(s) differ from remote.") end
    warn("Run 'get --update' to sync.")
  end
  return total_diff == 0 and 0 or 1
end

local function cmd_list()
  if not internet then err("No internet card."); return 1 end
  local files, e = fetch_file_list()
  if not files then err(tostring(e)); return 1 end
  writeln(string.format("\27[1mUniOS repo (%s) — %d files:\27[0m", BRANCH, #files))
  -- Group by top-level directory
  local last_dir = nil
  for _, f in ipairs(files) do
    local dir = f:match("^([^/]+)/") or "."
    if dir ~= last_dir then
      writeln(string.format("\n  \27[36m%s/\27[0m", dir))
      last_dir = dir
    end
    writeln("    " .. f:match("[^/]+$"))
  end
  writeln("")
  return 0
end

local function cmd_arbitrary(url, dest)
  if not internet then err("No internet card."); return 1 end
  info("GET " .. url)
  local data, e = http_get(url)
  if not data then err("Failed: " .. tostring(e)); return 1 end
  local wrote, we = write_file(dest, data)
  if not wrote then err("Write: " .. tostring(we)); return 1 end
  ok("Saved to " .. dest .. "  (" .. #data .. "B)")
  return 0
end

local function usage()
  writeln("\27[1mget\27[0m – UniOS file fetcher  (repo: github.com/testingaccount132/Uni)")
  writeln("")
  writeln("  get <file>              fetch a repo file  (e.g. bin/ls.lua)")
  writeln("  get --update            download/update ALL repo files")
  writeln("  get --all               same as --update")
  writeln("  get --check             compare local files with latest on GitHub")
  writeln("  get --list              list every file in the repo")
  writeln("  get <url> -o <path>     download any URL to a local path")
  writeln("  get --help              show this message")
  writeln("")
  writeln("The file list is fetched dynamically from the GitHub API,")
  writeln("so 'get --update' always picks up newly added files automatically.")
  writeln("")
  writeln("Examples:")
  writeln("  get bin/ls.lua")
  writeln("  get --update")
  writeln("  get --check")
  writeln("  get https://example.com/mypkg.lua -o /bin/mypkg.lua")
end

-- ── Argument parsing ──────────────────────────────────────────────────────────

local argv = arg or {}
if argv[0] then table.remove(argv, 0) end   -- strip script name if present

if #argv == 0 or argv[1] == "--help" or argv[1] == "-h" then
  usage(); return 0
end

if argv[1] == "--all" or argv[1] == "--update" then
  return cmd_all()
end

if argv[1] == "--check" then
  return cmd_check()
end

if argv[1] == "--list" then
  return cmd_list()
end

-- Arbitrary URL?
if argv[1]:match("^https?://") then
  local dest = nil
  for i = 2, #argv do
    if argv[i] == "-o" then dest = argv[i+1]; break end
  end
  if not dest then err("Specify destination with -o <path>"); return 1 end
  return cmd_arbitrary(argv[1], dest)
end

-- Single repo file
local rel  = argv[1]:gsub("^/", "")
local dest = nil
for i = 2, #argv do
  if argv[i] == "-o" then dest = argv[i+1]; break end
end
return cmd_fetch(rel, dest) and 0 or 1
