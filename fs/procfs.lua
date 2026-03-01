-- UniOS procfs (/proc)
-- Virtual filesystem exposing process information, system stats, etc.

local procfs = {}

local _meta = {}

local function proc_status(pid)
  local proc = kernel.process.get(pid)
  if not proc then return nil end
  return string.format(
    "Name:\t%s\nPid:\t%d\nPPid:\t%d\nState:\t%s\nUid:\t%d\nGid:\t%d\n",
    proc.name, proc.pid, proc.ppid, proc.state, proc.uid, proc.gid
  )
end

local function proc_cmdline(pid)
  local proc = kernel.process.get(pid)
  if not proc then return nil end
  return proc.name
end

local function read_uptime()
  return string.format("%.2f\n", computer.uptime())
end

local function read_meminfo()
  local total = computer.totalMemory()
  local free  = computer.freeMemory()
  local used  = total - free
  return string.format(
    "MemTotal:\t%d kB\nMemFree:\t%d kB\nMemUsed:\t%d kB\n",
    math.floor(total / 1024), math.floor(free / 1024), math.floor(used / 1024)
  )
end

local function read_version()
  return (kernel.VERSION or "UniOS") .. " " .. (kernel.RELEASE or "0.0") .. "\n"
end

local function read_loadavg()
  local procs = kernel.process.list()
  local running = 0
  for _, p in ipairs(procs) do
    if p.state == "running" then running = running + 1 end
  end
  return string.format("0.00 0.00 0.00 %d/%d\n", running, #procs)
end

local function read_mounts()
  local lines = {}
  for mp, fs in pairs(kernel.vfs.mounts()) do
    local dev = "none"
    if fs._addr then dev = tostring(fs._addr):sub(1, 8) end
    lines[#lines + 1] = dev .. " " .. mp .. " auto rw 0 0"
  end
  table.sort(lines)
  return table.concat(lines, "\n") .. "\n"
end

local function make_fd(content)
  local pos = 1
  return {
    _data = content,
    read = function(self, n)
      if pos > #self._data then return nil end
      local chunk = self._data:sub(pos, pos + (n or 4096) - 1)
      pos = pos + #chunk
      return chunk
    end,
    write = function() return false end,
    close = function() end,
  }
end

function _meta.open(path, mode)
  local rel = path:gsub("^/+", "")

  -- /proc/uptime
  if rel == "uptime" then return make_fd(read_uptime()) end
  if rel == "meminfo" then return make_fd(read_meminfo()) end
  if rel == "version" then return make_fd(read_version()) end
  if rel == "loadavg" then return make_fd(read_loadavg()) end
  if rel == "mounts"  then return make_fd(read_mounts()) end

  -- /proc/self/status  (resolves to current pid)
  local self_file = rel:match("^self/(.+)$")
  if self_file then
    local cur_pid = kernel.scheduler.current_pid()
    if not cur_pid then return nil, "no current process" end
    rel = cur_pid .. "/" .. self_file
  end

  -- /proc/<pid>/status, /proc/<pid>/cmdline
  local pid_str, file = rel:match("^(%d+)/(.+)$")
  if pid_str then
    local pid = tonumber(pid_str)
    if file == "status" then
      local data = proc_status(pid)
      if not data then return nil, "no such process" end
      return make_fd(data)
    elseif file == "cmdline" then
      local data = proc_cmdline(pid)
      if not data then return nil, "no such process" end
      return make_fd(data)
    end
  end

  return nil, "no such file: /proc/" .. rel
end

function _meta.close(fd) fd:close() end
function _meta.read(fd, n) return fd:read(n) end
function _meta.write(fd, d) return false end

function _meta.list(path)
  local rel = (path or "/"):gsub("^/+", "")

  if rel == "" then
    local entries = { "uptime", "meminfo", "version", "loadavg", "mounts", "self/" }
    for _, p in ipairs(kernel.process.list()) do
      entries[#entries + 1] = tostring(p.pid) .. "/"
    end
    return entries
  end

  -- /proc/<pid>/
  local pid_str = rel:match("^(%d+)/?$")
  if pid_str then
    local pid = tonumber(pid_str)
    if kernel.process.get(pid) then
      return { "status", "cmdline" }
    end
  end

  if rel == "self" or rel == "self/" then
    return { "status", "cmdline" }
  end

  return {}
end

function _meta.stat(path)
  local rel = (path or "/"):gsub("^/+", "")
  if rel == "" then return { isdir = true, size = 0, readonly = true } end
  if rel == "self" or rel:match("^%d+$") then
    return { isdir = true, size = 0, readonly = true }
  end
  if rel == "uptime" or rel == "meminfo" or rel == "version" or
     rel == "loadavg" or rel == "mounts" then
    return { isdir = false, size = 0, readonly = true }
  end
  if rel:match("^%d+/") or rel:match("^self/") then
    return { isdir = false, size = 0, readonly = true }
  end
  return nil
end

function _meta.isdir(path)
  local rel = (path or "/"):gsub("^/+", "")
  return rel == "" or rel == "self" or rel:match("^%d+$") ~= nil
end

function _meta.exists(path)
  return _meta.stat(path) ~= nil
end

function _meta.mkdir()  return false, "procfs: read-only" end
function _meta.remove() return false, "procfs: read-only" end
function _meta.rename() return false, "procfs: read-only" end

function procfs.init()
  kernel.info("procfs: initialised")
end

return setmetatable(procfs, { __index = _meta })
