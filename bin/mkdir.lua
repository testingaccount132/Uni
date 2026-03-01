-- mkdir – make directories

local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local cwd = sys("getcwd")

local parents = false
local paths = {}

for i = 2, #arg do
  if arg[i] == "-p" then parents = true
  else paths[#paths+1] = arg[i] end
end

if #paths == 0 then print("mkdir: missing operand"); return 1 end

local function mkdir_p(abs)
  if vfs.exists(abs) then return true end
  local parent = lp.dirname(abs)
  if not vfs.exists(parent) then
    local ok, err = mkdir_p(parent)
    if not ok then return false, err end
  end
  return vfs.mkdir(abs)
end

local exit_code = 0
for _, p in ipairs(paths) do
  local abs = lp.resolve(p, cwd)
  local ok, err
  if parents then
    ok, err = mkdir_p(abs)
  else
    ok, err = vfs.mkdir(abs)
  end
  if not ok then
    print("mkdir: cannot create directory '" .. p .. "': " .. tostring(err))
    exit_code = 1
  end
end
return exit_code
