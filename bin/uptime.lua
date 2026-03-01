-- uptime – show system uptime

local secs = math.floor(computer.uptime())
local h    = math.floor(secs / 3600)
local m    = math.floor((secs % 3600) / 60)
local s    = secs % 60
print(string.format("up %d:%02d:%02d  |  UniOS %s", h, m, s, kernel.VERSION))
return 0
