-- kill – send signal to process

local sig = "SIGTERM"
local pids = {}

for i = 2, #arg do
  if arg[i]:sub(1,1) == "-" then
    sig = arg[i]:sub(2):upper()
    if not sig:match("^SIG") then sig = "SIG" .. sig end
  else
    local pid = tonumber(arg[i])
    if pid then pids[#pids+1] = pid
    else print("kill: invalid pid: " .. arg[i]) end
  end
end

if #pids == 0 then print("Usage: kill [-SIGNAL] pid..."); return 1 end

local exit_code = 0
for _, pid in ipairs(pids) do
  local ok, err = kernel.process.kill(pid, sig)
  if not ok then
    print("kill: (" .. pid .. ") - " .. tostring(err))
    exit_code = 1
  end
end
return exit_code
