-- echo – print arguments

local newline = true
local i = 1

if arg[1] == "-n" then newline = false; i = 2 end
if arg[1] == "-e" then i = 2 end  -- accept -e (escape sequences already handled by shell)

local parts = {}
while arg[i] do parts[#parts+1] = arg[i]; i = i + 1 end

kernel.drivers.gpu.write(table.concat(parts, " "))
if newline then kernel.drivers.gpu.write("\n") end
return 0
