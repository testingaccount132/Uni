-- rm – remove files

local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local cwd = sys("getcwd")

local recursive = false
local force     = false
local paths = {}

for i = 1, #arg do
  if arg[i] == "-r" or arg[i] == "-R" then recursive = true
  elseif arg[i] == "-f" then force = true
  elseif arg[i] == "-rf" or arg[i] == "-fr" then recursive = true; force = true
  elseif arg[i] == "--help" then print("Usage: rm [-rf] file..."); return 0
  else paths[#paths+1] = arg[i] end
end

if #paths == 0 then print("rm: missing operand"); return 1 end

local function rm_recursive(abs)
  if vfs.isdir(abs) then
    local entries = vfs.list(abs) or {}
    for _, name in ipairs(entries) do
      rm_recursive(lp.join(abs, name))
    end
  end
  return vfs.remove(abs)
end

local exit_code = 0
for _, p in ipairs(paths) do
  local abs = lp.resolve(p, cwd)
  if not vfs.exists(abs) then
    if not force then print("rm: cannot remove '" .. p .. "': no such file"); exit_code = 1 end
  elseif vfs.isdir(abs) and not recursive then
    print("rm: cannot remove '" .. p .. "': is a directory"); exit_code = 1
  else
    local ok, err = rm_recursive(abs)
    if not ok and not force then
      print("rm: cannot remove '" .. p .. "': " .. tostring(err)); exit_code = 1
    end
  end
end
return exit_code
