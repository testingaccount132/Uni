-- cat – concatenate and print files

local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local gpu = kernel.drivers.gpu
local cwd = sys("getcwd")

local show_lines = false
local paths = {}

for i = 1, #arg do
  if arg[i] == "-n" then show_lines = true
  elseif arg[i] == "--help" then
    gpu.write("Usage: cat [-n] [file...]\n"); return 0
  else
    paths[#paths+1] = arg[i]
  end
end

if #paths == 0 then
  local kbd = kernel.drivers.keyboard
  while true do
    local line = kbd.readline()
    if not line or line == "" then break end
    gpu.write(line .. "\n")
    coroutine.yield()
  end
  return 0
end

local line_no = 1
for _, p in ipairs(paths) do
  local abs = lp.resolve(p, cwd)
  local fd, err = vfs.open(abs, "r")
  if not fd then
    gpu.write("cat: " .. p .. ": " .. tostring(err) .. "\n")
  else
    local data = ""
    while true do
      local chunk = vfs.read(fd, math.huge)
      if not chunk then break end
      data = data .. chunk
    end
    vfs.close(fd)

    if show_lines then
      for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        gpu.write(string.format("%6d\t%s\n", line_no, line))
        line_no = line_no + 1
      end
    else
      gpu.write(data)
      if #data > 0 and data:sub(-1) ~= "\n" then gpu.write("\n") end
    end
  end
end
return 0
