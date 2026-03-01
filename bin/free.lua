-- free – display memory usage

local gpu = kernel.drivers.gpu
local lc  = kernel.require("lib.libc")

local total = computer.totalMemory()
local free_ = computer.freeMemory()
local used  = total - free_

gpu.write(string.format("\27[1m%15s %10s %10s %10s\27[0m\n", "", "total", "used", "free"))
gpu.write(string.format("%-15s %10s %10s %10s\n",
  "Mem:",
  lc.human_size(total),
  lc.human_size(used),
  lc.human_size(free_)
))
return 0
