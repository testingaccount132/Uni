-- env – display or modify the environment

if arg[2] == nil then
  local e = sys("getenv")
  if type(e) == "table" then
    local keys = {}
    for k in pairs(e) do keys[#keys+1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      print(k .. "=" .. tostring(e[k]))
    end
  end
  return 0
end

-- env VAR=val cmd [args...]  – run command with modified env
-- (simplified: just set vars, then exec)
local extra = {}
local cmd_start = nil
for i = 2, #arg do
  local k, v = arg[i]:match("^([%w_]+)=(.*)$")
  if k then
    extra[k] = v
  else
    cmd_start = i
    break
  end
end

if cmd_start then
  for k, v in pairs(extra) do sys("setenv", k, v) end
  -- exec the command
  local lp = kernel.require("lib.libpath")
  local env = sys("getenv")
  local path_list = lp.split_path((env and env.PATH) or "/bin:/usr/bin")
  local path = lp.which(arg[cmd_start], path_list)
  if not path then print("env: "..arg[cmd_start]..": not found"); return 127 end
  local src = kernel.vfs.readfile(path)
  if not src then print("env: cannot read "..path); return 1 end
  local fn = load(src, "="..arg[cmd_start], "t", _G)
  if not fn then return 1 end
  local old = arg
  arg = {}
  for i = cmd_start, #old do arg[#arg+1] = old[i] end
  local ok, rc = pcall(fn)
  arg = old
  return (ok and type(rc)=="number") and rc or (ok and 0 or 1)
end

return 0
