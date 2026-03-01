-- touch – create or update file timestamps

local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local cwd = sys("getcwd")

local paths = {}
for i = 2, #arg do paths[#paths+1] = arg[i] end
if #paths == 0 then print("touch: missing operand"); return 1 end

local exit_code = 0
for _, p in ipairs(paths) do
  local abs = lp.resolve(p, cwd)
  if not vfs.exists(abs) then
    -- Create empty file
    local fd, err = vfs.open(abs, "w")
    if not fd then
      print("touch: cannot touch '" .. p .. "': " .. tostring(err))
      exit_code = 1
    else
      vfs.write(fd, "")
      vfs.close(fd)
    end
  end
  -- For OC there's no utime; touching just creates the file
end
return exit_code
