-- compositor – UniOS graphical desktop environment
-- Launch with: compositor
-- Exit with: Ctrl+Q

local gpu_drv = kernel.drivers.gpu
local gpu     = gpu_drv and gpu_drv.raw()
local kbd     = kernel.drivers.keyboard
local vfs     = kernel.vfs
local libgui  = kernel.require("lib.libgui")

if not gpu then
  if gpu_drv then gpu_drv.write("compositor: no GPU available\n") end
  return 1
end

local theme = libgui.theme
local comp  = libgui.compositor
local W, H  = gpu_drv.size()

-- ── Desktop background ───────────────────────────────────────────────────────

local function draw_desktop()
  gpu.setBackground(theme.bg)
  gpu.fill(1, 1, W, H - 1, " ")

  -- Gradient-like top accent line
  gpu.setBackground(0x181825)
  gpu.fill(1, 1, W, 1, " ")
  gpu.setForeground(theme.accent)
  gpu.set(2, 1, " UniOS Desktop")
  gpu.setForeground(0x585B70)
  local mem_pct = math.floor((1 - computer.freeMemory() / computer.totalMemory()) * 100)
  local top_info = string.format("mem %d%%  ", mem_pct)
  gpu.set(W - #top_info, 1, top_info)

  -- Center logo
  local cx = math.floor(W / 2)
  local cy = math.floor(H / 2) - 2

  gpu.setForeground(0x313244)
  local logo = {
    "  _   _       _ ___  ___  ",
    " | | | |_ __ (_)/ _ \\/ __| ",
    " | |_| | '_ \\| | (_) \\__ \\ ",
    "  \\___/|_| |_|_|\\___/|___/ ",
  }
  for i, line in ipairs(logo) do
    local lx = cx - math.floor(#line / 2)
    gpu.set(math.max(1, lx), cy + i - 1, line)
  end

  gpu.setForeground(0x45475A)
  local ver = kernel.VERSION .. " " .. (kernel.CODENAME or "")
  gpu.set(cx - math.floor(#ver / 2), cy + #logo, ver)

  -- Hint at bottom
  gpu.setForeground(0x313244)
  local hint = "Ctrl+Q exit  |  Click taskbar to open apps"
  gpu.set(cx - math.floor(#hint / 2), H - 2, hint)
end

-- ── Taskbar ──────────────────────────────────────────────────────────────────

local TASKBAR_Y = H

local taskbar_items = {
  { label = " Apps ", action = "launcher", icon = ">" },
  { label = " Term ", action = "terminal" },
  { label = " Files ", action = "files" },
  { label = " Info ", action = "gui-sysinfo" },
}

local function draw_taskbar()
  gpu.setBackground(0x11111B)
  gpu.setForeground(theme.fg)
  gpu.fill(1, TASKBAR_Y, W, 1, " ")

  -- Separator line above taskbar
  gpu.setBackground(0x181825)
  gpu.setForeground(0x313244)

  local cx = 1
  for _, item in ipairs(taskbar_items) do
    gpu.setBackground(0x181825)
    gpu.setForeground(theme.accent)
    gpu.set(cx, TASKBAR_Y, item.label)
    item._x = cx
    item._w = #item.label
    cx = cx + #item.label + 1
  end

  -- Window buttons in the middle
  gpu.setBackground(0x11111B)
  local wx = cx + 1
  for _, win in ipairs(comp._windows) do
    local is_active = (win == libgui._active_window)
    if is_active then
      gpu.setBackground(0x313244)
      gpu.setForeground(theme.accent)
    else
      gpu.setBackground(0x11111B)
      gpu.setForeground(0x585B70)
    end
    local title = " " .. (win.title or "?"):sub(1, 10) .. " "
    if wx + #title < W - 12 then
      gpu.set(wx, TASKBAR_Y, title)
      win._taskbar_x = wx
      win._taskbar_w = #title
      wx = wx + #title + 1
    end
  end

  -- Clock on the right
  gpu.setBackground(0x11111B)
  gpu.setForeground(0x6C7086)
  local uptime = math.floor(computer.uptime())
  local hrs = math.floor(uptime / 3600)
  local mins = math.floor((uptime % 3600) / 60)
  local secs = uptime % 60
  local clock = string.format(" %02d:%02d:%02d ", hrs, mins, secs)
  gpu.set(W - #clock + 1, TASKBAR_Y, clock)
end

-- ── App launcher ─────────────────────────────────────────────────────────────

local launcher_open = false
local launcher_items = {
  { name = " Terminal      ", cmd = "terminal",    icon = ">" },
  { name = " File Browser  ", cmd = "files",       icon = "#" },
  { name = " System Info   ", cmd = "gui-sysinfo", icon = "i" },
}

local function draw_launcher()
  if not launcher_open then return end
  local lw = 20
  local lh = #launcher_items + 2
  local lx, ly = 1, TASKBAR_Y - lh

  -- Shadow
  gpu.setBackground(0x0A0A14)
  gpu.fill(lx + 1, ly + 1, lw, lh, " ")

  -- Panel
  gpu.setBackground(0x1E1E2E)
  gpu.setForeground(theme.fg)
  gpu.fill(lx, ly, lw, lh, " ")

  -- Header
  gpu.setBackground(theme.accent)
  gpu.setForeground(0x1E1E2E)
  gpu.fill(lx, ly, lw, 1, " ")
  gpu.set(lx + 1, ly, " Applications")

  -- Items
  for i, item in ipairs(launcher_items) do
    gpu.setBackground(0x1E1E2E)
    gpu.setForeground(theme.fg)
    gpu.set(lx + 1, ly + i, item.name)
    item._y = ly + i
  end
end

-- ── Embedded GUI apps ────────────────────────────────────────────────────────

local win_counter = 0

local function next_pos()
  win_counter = win_counter + 1
  local ox = ((win_counter - 1) % 5) * 3 + 4
  local oy = ((win_counter - 1) % 4) * 2 + 3
  return ox, oy
end

local function create_terminal_window()
  local px, py = next_pos()
  local tw = math.min(62, W - 8)
  local th = math.min(18, H - 7)
  local win = libgui.create_window({ x = px, y = py, w = tw, h = th, title = "Terminal" })

  -- Create PTY pair and spawn shell
  local master, slave
  local shell_pid = nil
  pcall(function()
    master, slave = sys("pty_create")
    if master and slave then
      -- Build a stdin/stdout fd wrapper for the shell process
      local stdin_fd = {
        _dev = slave,
        read  = function(self, n) return slave.read(n) end,
        write = function(self, d) return slave.write(d) end,
        close = function(self) end,
      }
      local stdout_fd = {
        _dev = slave,
        read  = function(self, n) return slave.read(n) end,
        write = function(self, d) return slave.write(d) end,
        close = function(self) end,
      }
      shell_pid = sys("spawn", "/bin/sh.lua", "sh", {
        cwd = "/root",
        env = {
          PATH = "/bin:/sbin:/usr/bin:/tools",
          HOME = "/root",
          SHELL = "/bin/sh",
          TERM = "uni-pty",
          USER = "root",
        },
        stdin = stdin_fd,
        stdout = stdout_fd,
        stderr = stdout_fd,
      })
    end
  end)

  local output_lines = {}
  local output_buf = ""

  if not master then
    output_lines[1] = "PTY not available. Using simple terminal."
    output_lines[2] = "Commands: help, uname, whoami, pwd, date, mem, ls, cat, cd, clear, exit"
    output_lines[3] = ""
  end

  local output_list = libgui.List({
    x = 1, y = 1,
    w = win.content_w - 2,
    h = win.content_h - 2,
    items = output_lines,
  })

  local input_field = libgui.TextInput({
    x = 1, y = win.content_h - 1,
    w = win.content_w - 2,
    placeholder = "$ ",
  })

  -- Poll PTY master for output and display it
  win._poll = function()
    if not master then return end
    local data = master.read(4096)
    if data then
      output_buf = output_buf .. data
      -- Split into lines
      while true do
        local nl = output_buf:find("\n")
        if not nl then break end
        local line = output_buf:sub(1, nl - 1)
        output_buf = output_buf:sub(nl + 1)
        -- Strip ANSI escapes for display
        local clean = line:gsub("\27%[[%d;]*%a", "")
        output_lines[#output_lines + 1] = clean
      end
      output_list.items = output_lines
      output_list.selected = #output_lines
    end
  end

  -- Cleanup on window close
  win._on_close = function()
    if shell_pid then
      pcall(function() sys("kill", shell_pid, "SIGTERM") end)
    end
    if master then
      pcall(function() master.close() end)
    end
  end

  local term_cwd = "/root"

  local orig_key = input_field.key
  input_field.key = function(ch, code)
    if ch == "\n" then
      local cmd_str = input_field.value or ""
      input_field.value = ""
      input_field.cursor = 1

      if master then
        -- Send to PTY
        master.write(cmd_str .. "\n")
      else
        -- Fallback simple terminal
        output_lines[#output_lines + 1] = "$ " .. cmd_str

        if cmd_str == "" then
          output_lines[#output_lines + 1] = ""
        elseif cmd_str == "exit" or cmd_str == "close" then
          comp.remove_window(win)
          return
        else
          local parts = {}
          for w in cmd_str:gmatch("%S+") do parts[#parts + 1] = w end
          local cmd = parts[1]

          local result = nil
          if cmd == "uname" then
            result = kernel.VERSION .. " " .. (kernel.RELEASE or "")
          elseif cmd == "whoami" then
            result = "root"
          elseif cmd == "pwd" then
            result = term_cwd
          elseif cmd == "date" then
            result = string.format("uptime: %.1fs", computer.uptime())
          elseif cmd == "mem" or cmd == "free" then
            local total = computer.totalMemory()
            local free = computer.freeMemory()
            result = string.format("Total: %dKB  Used: %dKB  Free: %dKB",
              math.floor(total / 1024), math.floor((total - free) / 1024), math.floor(free / 1024))
          elseif cmd == "ls" then
            local dir = parts[2] or term_cwd
            if dir:sub(1, 1) ~= "/" then dir = term_cwd .. "/" .. dir end
            local ls = vfs.list(dir)
            if ls then
              local entries = {}
              for _, f in ipairs(ls) do
                entries[#entries + 1] = vfs.isdir(dir .. "/" .. f) and (f .. "/") or f
              end
              table.sort(entries)
              result = table.concat(entries, "  ")
            else
              result = "ls: cannot access '" .. dir .. "'"
            end
          elseif cmd == "cat" then
            if not parts[2] then result = "cat: missing file" else
              local file = parts[2]
              if file:sub(1, 1) ~= "/" then file = term_cwd .. "/" .. file end
              local data = vfs.readfile(file)
              result = data or ("cat: " .. file .. ": no such file")
            end
          elseif cmd == "cd" then
            local dir = parts[2] or "/root"
            if dir:sub(1, 1) ~= "/" then dir = term_cwd .. "/" .. dir end
            if vfs.isdir(dir) then term_cwd = dir else result = "cd: not a directory" end
          elseif cmd == "clear" then
            for k in pairs(output_lines) do output_lines[k] = nil end
            output_lines[1] = ""
          elseif cmd == "help" then
            result = "help uname whoami pwd date mem ls cat cd clear exit"
          else
            result = cmd .. ": command not found"
          end

          if result then output_lines[#output_lines + 1] = tostring(result) end
          output_lines[#output_lines + 1] = ""
        end

        output_list.items = output_lines
        output_list.selected = #output_lines
      end
    else
      if orig_key then orig_key(ch, code) end
    end
  end

  libgui.add_widget(win, output_list)
  libgui.add_widget(win, input_field)
  win.focused_widget = input_field
  return win
end

local function create_files_window()
  local px, py = next_pos()
  local fw = math.min(52, W - 10)
  local fh = math.min(18, H - 7)
  local win = libgui.create_window({ x = px, y = py, w = fw, h = fh, title = "Files: /" })

  local cwd = "/"
  local items = {}

  local function refresh()
    items = {}
    if cwd ~= "/" then items[1] = ".." end
    local ls = vfs.list(cwd)
    if ls then
      local dirs, files = {}, {}
      for _, f in ipairs(ls) do
        local path = (cwd == "/" and "/" or cwd .. "/") .. f
        if vfs.isdir(path) then
          dirs[#dirs + 1] = f .. "/"
        else
          files[#files + 1] = f
        end
      end
      table.sort(dirs)
      table.sort(files)
      for _, d in ipairs(dirs) do items[#items + 1] = d end
      for _, f in ipairs(files) do items[#items + 1] = f end
    end
    win.title = "Files: " .. cwd
  end

  refresh()

  local file_list = libgui.List({
    x = 1, y = 1,
    w = win.content_w - 2,
    h = win.content_h - 1,
    items = items,
    on_select = function(idx, item)
      if not item then return end
      if item == ".." then
        cwd = cwd:match("^(.+)/[^/]+/?$") or "/"
        refresh()
        file_list.items = items
        file_list.selected = 1
      elseif item:sub(-1) == "/" then
        local name = item:sub(1, -2)
        cwd = (cwd == "/" and "/" or cwd .. "/") .. name
        refresh()
        file_list.items = items
        file_list.selected = 1
      end
    end,
  })

  libgui.add_widget(win, file_list)
  win.focused_widget = file_list
  return win
end

local function create_sysinfo_window()
  local px, py = next_pos()
  local sw = math.min(46, W - 12)
  local win = libgui.create_window({ x = px, y = py, w = sw, h = 14, title = "System Info" })

  local total_mem = computer.totalMemory()
  local free_mem = computer.freeMemory()
  local used_mem = total_mem - free_mem
  local pkg_count = "?"
  pcall(function()
    local data = vfs.readfile("/var/lib/apt/installed")
    if data then
      local c = 0
      for _ in data:gmatch("[^\n]+") do c = c + 1 end
      pkg_count = tostring(c)
    end
  end)

  local info = {
    { text = "UniOS " .. (kernel.RELEASE or "1.0") .. " '" .. (kernel.CODENAME or "") .. "'", color = theme.accent },
    { text = "" },
    { text = string.format("Uptime:     %.1fs", computer.uptime()) },
    { text = string.format("Memory:     %dKB / %dKB (%d%%)",
        math.floor(used_mem / 1024), math.floor(total_mem / 1024),
        math.floor(used_mem / total_mem * 100)) },
    { text = string.format("Screen:     %dx%d", W, H) },
    { text = string.format("Packages:   %s installed", pkg_count) },
    { text = "" },
    { text = "GPU: " .. (gpu.getResolution and string.format("%dx%d", gpu.getResolution()) or "?") },
    { text = "" },
    { text = "github.com/testingaccount132/Uni", color = 0x585B70 },
  }

  for i, item in ipairs(info) do
    libgui.add_widget(win, libgui.Label({
      x = 2, y = i,
      text = item.text,
      color = item.color or theme.fg,
    }))
  end

  return win
end

-- ── App launching ────────────────────────────────────────────────────────────

local function launch_app(name)
  if name == "terminal" then
    comp.add_window(create_terminal_window())
  elseif name == "files" then
    comp.add_window(create_files_window())
  elseif name == "gui-sysinfo" then
    comp.add_window(create_sysinfo_window())
  end
end

local function handle_taskbar_click(sx, sy)
  if sy ~= TASKBAR_Y then return false end

  -- Check taskbar buttons
  for _, item in ipairs(taskbar_items) do
    if item._x and sx >= item._x and sx < item._x + item._w then
      if item.action == "launcher" then
        launcher_open = not launcher_open
      else
        launcher_open = false
        launch_app(item.action)
      end
      return true
    end
  end

  -- Check window buttons on taskbar
  for _, win in ipairs(comp._windows) do
    if win._taskbar_x and sx >= win._taskbar_x and sx < win._taskbar_x + (win._taskbar_w or 0) then
      comp.bring_to_front(win)
      return true
    end
  end

  return false
end

local function handle_launcher_click(sx, sy)
  if not launcher_open then return false end
  for _, item in ipairs(launcher_items) do
    if item._y and sy == item._y and sx >= 1 and sx <= 20 then
      launcher_open = false
      launch_app(item.cmd)
      return true
    end
  end
  launcher_open = false
  return false
end

-- ── Main loop ────────────────────────────────────────────────────────────────

local function main()
  kbd.set_raw(true)
  comp.init()

  local running = true
  local frame = 0

  while running do
    local ev = { computer.pullSignal(0.05) }

    if ev[1] then
      if ev[1] == "touch" then
        local sx, sy = ev[3], ev[4]
        if not handle_taskbar_click(sx, sy) then
          if not handle_launcher_click(sx, sy) then
            launcher_open = false
            comp.handle_event(ev)
          end
        end
      elseif ev[1] == "key_down" then
        local char = ev[3]
        if char == 17 then
          running = false
        else
          comp.handle_event(ev)
        end
      else
        comp.handle_event(ev)
      end
    end

    -- Poll PTY output from terminal windows
    for _, win in ipairs(comp._windows) do
      if win._poll then
        pcall(win._poll)
      end
    end

    frame = frame + 1
    if frame >= 2 then
      frame = 0
      draw_desktop()
      for _, win in ipairs(comp._windows) do
        win.draw(gpu)
      end
      draw_taskbar()
      draw_launcher()
    end

    coroutine.yield()
  end

  kbd.set_raw(false)
  gpu_drv.clear()
  return 0
end

local ok, err = pcall(main)
kbd.set_raw(false)
pcall(function() gpu_drv.clear() end)
if not ok then
  pcall(function() gpu_drv.write("compositor: " .. tostring(err) .. "\n") end)
  return 1
end
return 0
