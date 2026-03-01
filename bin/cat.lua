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
    print("Usage: cat [-n] [file...]"); return 0
  else
    paths[#paths+1] = arg[i]
  end
end

-- If no files, read stdin
if #paths == 0 then
  local kbd = kernel.drivers.keyboard
  while true do
    local line = kbd.readline()
    if not line then break end
    gpu.write(line .. "\n")
  end
  return 0
end

local line_no = 1
for _, p in ipairs(paths) do
  local abs = lp.resolve(p, cwd)
  local fd, err = vfs.open(abs, "r")
  if not fd then
    print("cat: " .. p .. ": " .. tostring(err))
  else
    while true do
      local chunk = vfs.read(fd, 512)
      if not chunk then break end
      if show_lines then
        -- Number each line
        for line in (chunk):gmatch("[^\n]*\n?") do
          if line ~= "" then
            if line:sub(-1) == "\n" then
              gpu.write(string.format("%6d\t%s", line_no, line))
              line_no = line_no + 1
            else
              gpu.write(line)
            end
          end
        end
      else
        gpu.write(chunk)
      end
    end
    vfs.close(fd)
  end
end
return 0
