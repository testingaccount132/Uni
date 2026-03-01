-- UniOS Scheduler
-- Cooperative round-robin scheduler backed by coroutines.
-- Each process gets a timeslice; it yields via coroutine.yield()
-- or implicitly when waiting for I/O.

local scheduler = {}

local _running = false
local _current_pid = nil

function scheduler.init()
  _running = false
  kernel.info("scheduler: round-robin ready")
end

--- Return the PID of the currently executing process.
function scheduler.current_pid()
  return _current_pid
end

--- Main scheduler loop – called once by the kernel after init.
function scheduler.run()
  _running = true
  kernel.info("scheduler: entering main loop")

  local proc_mod = kernel.process

  while _running do
    -- Tick sleeping processes
    proc_mod.tick()

    local procs = proc_mod.list()
    local any_runnable = false

    for _, proc in ipairs(procs) do
      if proc.state == "running" then
        any_runnable = true
        _current_pid = proc.pid

        -- Deliver pending signals first
        if #proc.signals > 0 then
          local sig = table.remove(proc.signals, 1)
          scheduler._deliver_signal(proc, sig)
        end

        -- Resume the coroutine
        local ok, val = coroutine.resume(proc.thread)

        if not ok then
          -- Coroutine errored
          kernel.warn("scheduler: pid=" .. proc.pid .. " error: " .. tostring(val))
          proc_mod.exit(proc.pid, 1)
        elseif coroutine.status(proc.thread) == "dead" then
          -- Normal exit
          proc_mod.exit(proc.pid, 0)
        end
        -- If val is a sleep request: { "sleep", seconds }
        if type(val) == "table" and val[1] == "sleep" then
          proc_mod.sleep(proc.pid, val[2] or 0)
        end

        _current_pid = nil
      end
    end

    -- If nothing is runnable, wait for an event to avoid busy-loop
    if not any_runnable then
      local ev = { computer.pullSignal(0.05) }
      kernel.signal.dispatch(ev)
    else
      -- Yield back to OC event loop briefly
      local ev = { computer.pullSignal(0) }
      if ev[1] then kernel.signal.dispatch(ev) end
    end
  end

  kernel.info("scheduler: loop exited")
end

function scheduler.stop()
  _running = false
end

-- Internal: deliver a kernel signal to a process.
function scheduler._deliver_signal(proc, sig)
  if sig == "SIGKILL" then
    kernel.process.exit(proc.pid, 137)
  elseif sig == "SIGTERM" then
    -- Give process a chance to handle it via its signal table
    if proc.signal_handlers and proc.signal_handlers["SIGTERM"] then
      pcall(proc.signal_handlers["SIGTERM"])
    else
      kernel.process.exit(proc.pid, 143)
    end
  elseif sig == "SIGSTOP" then
    proc.state = "stopped"
  elseif sig == "SIGCONT" then
    if proc.state == "stopped" then proc.state = "running" end
  end
  -- SIGCHLD and others: just wake the process
  if proc.state == "sleeping" then proc.state = "running" end
end

return scheduler
