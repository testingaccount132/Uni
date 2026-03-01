-- cp – copy files

local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local cwd = sys("getcwd")

local recursive = false
local srcs = {}
local dst

for i = 1, #arg do
  if arg[i] == "-r" or arg[i] == "-R" then recursive = true
  elseif arg[i] == "--help" then print("Usage: cp [-r] src... dst"); return 0
  else srcs[#srcs+1] = arg[i] end
end

if #srcs < 2 then print("cp: missing operand"); return 1 end
dst = table.remove(srcs)

local function copy_file(src_abs, dst_abs)
  local fdin, e1 = vfs.open(src_abs, "r")
  if not fdin then print("cp: " .. e1); return false end

  -- If dst is a directory, copy into it
  if vfs.isdir(dst_abs) then
    dst_abs = lp.join(dst_abs, lp.basename(src_abs))
  end

  local fdout, e2 = vfs.open(dst_abs, "w")
  if not fdout then vfs.close(fdin); print("cp: " .. e2); return false end

  while true do
    local chunk = vfs.read(fdin, 4096)
    if not chunk then break end
    vfs.write(fdout, chunk)
  end
  vfs.close(fdin)
  vfs.close(fdout)
  return true
end

local function copy_recursive(src_abs, dst_abs)
  if vfs.isdir(src_abs) then
    if not vfs.exists(dst_abs) then vfs.mkdir(dst_abs) end
    local entries = vfs.list(src_abs) or {}
    for _, name in ipairs(entries) do
      copy_recursive(lp.join(src_abs, name), lp.join(dst_abs, name))
    end
  else
    copy_file(src_abs, dst_abs)
  end
end

local dst_abs = lp.resolve(dst, cwd)
local exit_code = 0

for _, src in ipairs(srcs) do
  local src_abs = lp.resolve(src, cwd)
  if recursive then
    copy_recursive(src_abs, dst_abs)
  else
    if vfs.isdir(src_abs) then
      print("cp: -r not specified; omitting directory '" .. src .. "'")
      exit_code = 1
    else
      if not copy_file(src_abs, dst_abs) then exit_code = 1 end
    end
  end
end

return exit_code
