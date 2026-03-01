-- df – report filesystem disk space usage

local lc = kernel.require("lib.libc")

print(string.format("\27[1m%-20s %10s %10s %10s %6s %s\27[0m",
  "Filesystem", "Size", "Used", "Avail", "Use%", "Mounted on"))

for mp, fs in pairs(kernel.vfs.mounts()) do
  local raw = fs._raw
  local size_str, used_str, avail_str, pct = "?", "?", "?", "?"
  if raw and raw.spaceTotal then
    local total = raw.spaceTotal()
    local used  = raw.spaceUsed()
    local avail = total - used
    local p     = total > 0 and math.floor(used / total * 100) or 0
    size_str  = lc.human_size(total)
    used_str  = lc.human_size(used)
    avail_str = lc.human_size(avail)
    pct       = p .. "%"
  elseif fs._addr then
    size_str = "tmpfs"
    used_str = "-"
    avail_str = "-"
    pct = "-"
  end
  print(string.format("%-20s %10s %10s %10s %6s %s",
    (fs._addr and fs._addr:sub(1,8) or "virtual"), size_str, used_str, avail_str, pct, mp))
end
return 0
