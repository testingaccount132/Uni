-- ls – list directory contents

local function usage()
  print("Usage: ls [-la] [path...]")
  os.exit(1)
end

local vfs  = kernel.vfs
local lp   = kernel.require("lib.libpath")
local lt   = kernel.require("lib.libterm")
local gpu  = kernel.drivers.gpu

local cwd  = sys("getcwd")

-- Parse flags
local long = false
local all  = false
local paths = {}

for i = 1, #arg do
  local a = arg[i]
  if a:sub(1,1) == "-" then
    for c in a:sub(2):gmatch(".") do
      if c == "l" then long = true
      elseif c == "a" then all = true
      else print("ls: unknown flag -" .. c); return 1 end
    end
  else
    paths[#paths+1] = a
  end
end

if #paths == 0 then paths = { cwd } end

local function classify(path)
  local st = vfs.stat(path)
  if not st then return "?" end
  if st.isdir then return "d" else return "-" end
end

local function color_name(name, path)
  local st = vfs.stat(path)
  if not st then return name end
  if st.isdir then
    return "\27[1;34m" .. name .. "\27[0m"
  elseif name:match("%.lua$") or name:match("%.sh$") then
    return "\27[1;32m" .. name .. "\27[0m"
  end
  return name
end

local function ls_dir(dir)
  dir = lp.resolve(dir, cwd)
  local entries = vfs.list(dir)
  if not entries then
    print("ls: cannot access '" .. dir .. "': no such file or directory")
    return 1
  end
  table.sort(entries)

  if not all then
    local filtered = {}
    for _, e in ipairs(entries) do
      if e:sub(1,1) ~= "." then filtered[#filtered+1] = e end
    end
    entries = filtered
  end

  if long then
    -- Header
    print("total " .. #entries)
    for _, name in ipairs(entries) do
      local full = lp.join(dir, name)
      local st   = vfs.stat(full) or {}
      local kind = st.isdir and "d" or "-"
      local size = st.size or 0
      print(string.format("%s%s %8d  %s",
        kind, "rwxr-xr-x",   -- permissions (simplified)
        size,
        color_name(name, full)
      ))
    end
  else
    -- Columnar output
    local w, _ = kernel.drivers.gpu.size()
    w = w or 80
    local max_len = 1
    for _, e in ipairs(entries) do max_len = math.max(max_len, #e) end
    local col_w  = max_len + 2
    local cols   = math.max(1, math.floor(w / col_w))
    local col    = 0
    for _, name in ipairs(entries) do
      local full = lp.join(dir, name)
      local colored = color_name(name, full)
      local pad = col_w - #name
      gpu.write(colored .. string.rep(" ", pad))
      col = col + 1
      if col >= cols then
        gpu.write("\n"); col = 0
      end
    end
    if col > 0 then gpu.write("\n") end
  end
  return 0
end

local exit_code = 0
for _, p in ipairs(paths) do
  if #paths > 1 then print(p .. ":") end
  local rc = ls_dir(p)
  if rc ~= 0 then exit_code = rc end
end
return exit_code
