-- wc – word, line, character count

local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local cwd = sys("getcwd")

local count_l, count_w, count_c = false, false, false
local files = {}

for i = 1, #arg do
  if arg[i] == "-l" then count_l = true
  elseif arg[i] == "-w" then count_w = true
  elseif arg[i] == "-c" then count_c = true
  else files[#files+1] = arg[i] end
end

if not count_l and not count_w and not count_c then
  count_l = true; count_w = true; count_c = true
end

if #files == 0 then print("wc: no files"); return 1 end

local total_l, total_w, total_c = 0, 0, 0

for _, path in ipairs(files) do
  local abs = lp.resolve(path, cwd)
  local src, err = vfs.readfile(abs)
  if not src then print("wc: " .. path .. ": " .. tostring(err))
  else
    local l, w, c = 0, 0, #src
    for line in (src .. "\n"):gmatch("[^\n]*\n") do
      l = l + 1
      for _ in line:gmatch("%S+") do w = w + 1 end
    end
    total_l = total_l + l
    total_w = total_w + w
    total_c = total_c + c
    local parts = {}
    if count_l then parts[#parts+1] = string.format("%7d", l) end
    if count_w then parts[#parts+1] = string.format("%7d", w) end
    if count_c then parts[#parts+1] = string.format("%7d", c) end
    parts[#parts+1] = path
    print(table.concat(parts, " "))
  end
end

if #files > 1 then
  local parts = {}
  if count_l then parts[#parts+1] = string.format("%7d", total_l) end
  if count_w then parts[#parts+1] = string.format("%7d", total_w) end
  if count_c then parts[#parts+1] = string.format("%7d", total_c) end
  parts[#parts+1] = "total"
  print(table.concat(parts, " "))
end
return 0
