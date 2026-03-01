-- which – locate a command in PATH
local lp  = kernel.require("lib.libpath")
local env = sys("getenv")
local path_list = lp.split_path((env and env.PATH) or "/bin:/usr/bin")

local found = false
for i = 1, #arg do
  local p = lp.which(arg[i], path_list)
  if p then
    print(p); found = true
  else
    print("which: "..arg[i]..": not found")
  end
end
return found and 0 or 1
