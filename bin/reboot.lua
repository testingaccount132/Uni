-- reboot – restart the computer
local shutdown = arg[2] == "-h" or arg[2] == "--halt"
if shutdown then
  print("Halting system…")
  computer.shutdown(false)
else
  print("Rebooting…")
  computer.shutdown(true)
end
