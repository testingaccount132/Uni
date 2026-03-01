-- uname – print system information

local all = false
local flags = { s=false, n=false, r=false, v=false, m=false }

for i = 1, #arg do
  if arg[i] == "-a" then all = true
  elseif arg[i]:sub(1,1) == "-" then
    for c in arg[i]:sub(2):gmatch(".") do
      if flags[c] ~= nil then flags[c] = true end
    end
  end
end

if not all and not (flags.s or flags.n or flags.r or flags.v or flags.m) then
  flags.s = true
end

local hostname = kernel.vfs.readfile("/etc/hostname") or "uni"
hostname = hostname:gsub("%s+$", "")

local parts = {}
if all or flags.s then parts[#parts+1] = "UniOS" end
if all or flags.n then parts[#parts+1] = hostname end
if all or flags.r then parts[#parts+1] = "1.0.0" end
if all or flags.v then parts[#parts+1] = "#1 " .. kernel.VERSION end
if all or flags.m then parts[#parts+1] = "oc" end

print(table.concat(parts, " "))
return 0
