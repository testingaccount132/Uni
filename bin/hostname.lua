-- hostname – get or set the system hostname

if arg[2] then
  -- Set hostname
  local ok, err = kernel.vfs.writefile("/etc/hostname", arg[2] .. "\n")
  if not ok then print("hostname: "..tostring(err)); return 1 end
  -- Also update running environment
  sys("setenv", "HOSTNAME", arg[2])
  return 0
else
  local h = kernel.vfs.readfile("/etc/hostname") or "uni"
  print(h:match("^%s*(.-)%s*$"))
  return 0
end
