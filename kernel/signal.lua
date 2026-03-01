-- UniOS Signal subsystem
-- Translates OpenComputers hardware events into UNIX-like signals
-- and delivers them to the correct process.

local signal = {}

-- Signal names and their default dispositions
signal.DEFAULT = {
  SIGHUP   = "terminate",
  SIGINT   = "terminate",
  SIGQUIT  = "terminate",
  SIGKILL  = "terminate",  -- uncatchable
  SIGTERM  = "terminate",
  SIGCHLD  = "ignore",
  SIGSTOP  = "stop",
  SIGCONT  = "continue",
  SIGUSR1  = "ignore",
  SIGUSR2  = "ignore",
  SIGALRM  = "terminate",
  SIGPIPE  = "terminate",
}

-- Foreground process group (pid that receives keyboard signals)
local _fg_pid = nil

function signal.init()
  _fg_pid = nil
  kernel.info("signal: ready")
end

--- Set the foreground PID (receives SIGINT, SIGQUIT from keyboard).
function signal.set_fg(pid)
  _fg_pid = pid
end

function signal.fg()
  return _fg_pid
end

--- Send signal `name` to process `pid`.
function signal.send(pid, name)
  local proc = kernel.process.get(pid)
  if not proc then return false end
  proc.signals[#proc.signals + 1] = name
  -- Wake sleeping process so it can handle the signal promptly
  if proc.state == "sleeping" then
    proc.state = "running"
    proc._sleep_until = nil
  end
  return true
end

--- Broadcast a signal to all processes in a group.
function signal.broadcast(name, exclude_pid)
  for _, proc in ipairs(kernel.process.list()) do
    if proc.pid ~= (exclude_pid or -1) then
      signal.send(proc.pid, name)
    end
  end
end

--- Dispatch an OpenComputers hardware event into signals.
function signal.dispatch(ev)
  if not ev or not ev[1] then return end
  local etype = ev[1]

  if etype == "key_down" then
    local char  = ev[3]
    local code  = ev[4]
    -- Ctrl+C → SIGINT
    if char == 3 then
      if _fg_pid then signal.send(_fg_pid, "SIGINT") end
    -- Ctrl+\ → SIGQUIT
    elseif char == 28 then
      if _fg_pid then signal.send(_fg_pid, "SIGQUIT") end
    -- Ctrl+Z → SIGSTOP (not standard in OC but included for completeness)
    elseif char == 26 then
      if _fg_pid then signal.send(_fg_pid, "SIGSTOP") end
    else
      -- Route raw key events to the keyboard driver
      if kernel.drivers and kernel.drivers.keyboard then
        kernel.drivers.keyboard.push(ev)
      end
    end

  elseif etype == "component_added" or etype == "component_removed" then
    -- Hardware hotplug – handled by drivers
    if kernel.drivers then
      for _, drv in pairs(kernel.drivers) do
        if drv.hotplug then drv.hotplug(ev) end
      end
    end

  elseif etype == "modem_message" then
    -- Network events (future)
  end
end

return signal
