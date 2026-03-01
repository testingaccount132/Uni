-- reboot – restart the computer
local shutdown = arg[1] == "-h" or arg[1] == "--halt"
if shutdown then
  print("Halting system…")
  computer.shutdown(false)
else
  print("Rebooting…")
  computer.shutdown(true)
end
