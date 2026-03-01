-- ps – report running processes

local gpu = kernel.drivers.gpu

local procs = kernel.process.list()
local header = string.format("%-6s %-6s %-8s %-10s %s",
  "PID", "PPID", "STATE", "UID", "COMMAND")

print("\27[1m" .. header .. "\27[0m")
print(string.rep("─", 50))

for _, p in ipairs(procs) do
  local state = p.state or "?"
  local color = ""
  if state == "running"  then color = "\27[32m"
  elseif state == "sleeping" then color = "\27[33m"
  elseif state == "zombie"   then color = "\27[31m"
  elseif state == "stopped"  then color = "\27[35m"
  end
  print(string.format("%-6d %-6d %s%-8s\27[0m %-10d %s",
    p.pid, p.ppid or 0, color, state, p.uid or 0, p.name or "?"))
end

return 0
