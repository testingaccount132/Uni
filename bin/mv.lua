-- mv – move/rename files

local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local cwd = sys("getcwd")

local srcs = {}
for i = 1, #arg do srcs[#srcs+1] = arg[i] end

if #srcs < 2 then print("mv: missing operand"); return 1 end
local dst = table.remove(srcs)
local dst_abs = lp.resolve(dst, cwd)

local exit_code = 0
for _, src in ipairs(srcs) do
  local src_abs = lp.resolve(src, cwd)
  local final_dst = dst_abs
  if vfs.isdir(dst_abs) then
    final_dst = lp.join(dst_abs, lp.basename(src_abs))
  end
  local ok, err = vfs.rename(src_abs, final_dst)
  if not ok then
    print("mv: cannot move '" .. src .. "': " .. tostring(err))
    exit_code = 1
  end
end
return exit_code
