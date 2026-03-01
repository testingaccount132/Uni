-- tail – output last lines of files

local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local cwd = sys("getcwd")

local n_lines = 10
local files   = {}
local i = 2

while arg[i] do
  if arg[i] == "-n" then
    i = i + 1; n_lines = tonumber(arg[i]) or 10
  elseif arg[i]:match("^%-(%d+)$") then
    n_lines = tonumber(arg[i]:sub(2))
  else
    files[#files+1] = arg[i]
  end
  i = i + 1
end

if #files == 0 then print("tail: no files specified"); return 1 end

for _, path in ipairs(files) do
  local abs = lp.resolve(path, cwd)
  local src, err = vfs.readfile(abs)
  if not src then print("tail: " .. path .. ": " .. tostring(err))
  else
    if #files > 1 then print("==> " .. path .. " <==") end
    local lines = {}
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines+1] = line
    end
    local start = math.max(1, #lines - n_lines + 1)
    for idx = start, #lines do
      print(lines[idx])
    end
  end
end
return 0
