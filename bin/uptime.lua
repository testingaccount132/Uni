-- uptime – show system uptime

local gpu  = kernel.drivers.gpu
local secs = math.floor(computer.uptime())
local h    = math.floor(secs / 3600)
local m    = math.floor((secs % 3600) / 60)
local s    = secs % 60
gpu.write(string.format("up %d:%02d:%02d  |  UniOS %s\n", h, m, s, kernel.VERSION))
return 0
