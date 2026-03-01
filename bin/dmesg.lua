-- dmesg – print kernel ring buffer log

local log = kernel.klog()
if not log or #log == 0 then
  print("(kernel log is empty)")
  return 0
end

local filter = arg[1]  -- optional level filter: INFO / WARN / ERR / PANIC

local colors = {
  INFO  = "\27[0m",
  WARN  = "\27[33m",
  ERR   = "\27[31m",
  PANIC = "\27[1;31m",
}

for _, entry in ipairs(log) do
  if not filter or entry.level == filter:upper() then
    local col = colors[entry.level] or "\27[0m"
    local ts  = string.format("[%8.3f]", entry.ts or 0)
    print(string.format("%s\27[36m%s\27[0m %s[%s]\27[0m %s",
      "", ts, col, entry.level, entry.msg))
  end
end
return 0
