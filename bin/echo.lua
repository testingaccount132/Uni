-- echo – print arguments

local newline = true
local i = 2

if arg[2] == "-n" then newline = false; i = 3 end
if arg[2] == "-e" then i = 3 end  -- accept -e (escape sequences already handled by shell)

local parts = {}
while arg[i] do parts[#parts+1] = arg[i]; i = i + 1 end

kernel.drivers.gpu.write(table.concat(parts, " "))
if newline then kernel.drivers.gpu.write("\n") end
return 0
