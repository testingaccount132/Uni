-- compositor – UniOS graphical desktop environment
-- Launches a desktop with taskbar, wallpaper, and app launcher.

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
  gpu.setForeground(theme.fg)
  gpu.fill(1, 1, W, H, " ")

  -- Subtle pattern
  gpu.setForeground(0x262640)
  for y = 2, H - 2, 2 do
    local pattern = ""
    for x = 1, W do
      pattern = pattern .. (((x + y) % 4 == 0) and "·" or " ")
    end
    gpu.set(1, y, pattern)
  end

  -- Center branding
  gpu.setForeground(0x45475A)
  local brand = "UniOS " .. (kernel.RELEASE or "1.0")
  gpu.set(math.floor((W - #brand) / 2) + 1, math.floor(H / 2), brand)
end

-- ── Taskbar ──────────────────────────────────────────────────────────────────

local TASKBAR_H = 1
local TASKBAR_Y = H

local taskbar_items = {
  { label = "[Apps]",     action = "launcher" },
  { label = "[Terminal]", action = "terminal" },
  { label = "[Files]",    action = "files" },
}

local function draw_taskbar()
  gpu.setBackground(0x11111B)
  gpu.setForeground(theme.fg)
  gpu.fill(1, TASKBAR_Y, W, TASKBAR_H, " ")

  local cx = 2
  for _, item in ipairs(taskbar_items) do
    gpu.setForeground(theme.accent)
    gpu.set(cx, TASKBAR_Y, item.label)
    item._x = cx
    item._w = #item.label
    cx = cx + #item.label + 2
  end

  -- Clock on the right
  gpu.setForeground(0x6C7086)
  local uptime = math.floor(computer.uptime())
  local hrs = math.floor(uptime / 3600)
  local mins = math.floor((uptime % 3600) / 60)
  local secs = uptime % 60
  local clock = string.format("%02d:%02d:%02d", hrs, mins, secs)
  gpu.set(W - #clock, TASKBAR_Y, clock)

  -- Window list in middle
  local wx = cx + 2
  for i, win in ipairs(comp._windows) do
    local is_active = (win == libgui._active_window)
    gpu.setForeground(is_active and theme.accent or 0x6C7086)
    local title = (win.title or "?"):sub(1, 12)
    if wx + #title + 2 < W - 10 then
      gpu.set(wx, TASKBAR_Y, title)
      wx = wx + #title + 2
    end
  end
end

-- ── App launcher ─────────────────────────────────────────────────────────────

local launcher_open = false
local launcher_items = {
  { name = "Terminal",     cmd = "gui-terminal" },
  { name = "File Browser", cmd = "gui-files"   },
  { name = "Text Editor",  cmd = "nano"        },
  { name = "System Info",  cmd = "gui-sysinfo" },
}

local function draw_launcher()
  if not launcher_open then return end
  local lw, lh = 24, #launcher_items + 2
  local lx, ly = 1, TASKBAR_Y - lh
  gpu.setBackground(0x1E1E2E)
  gpu.setForeground(theme.fg)
  gpu.fill(lx, ly, lw, lh, " ")
  gpu.setBackground(theme.titlebar)
  gpu.fill(lx, ly, lw, 1, " ")
  gpu.setForeground(theme.accent)
  gpu.set(lx + 1, ly, " Applications ")

  for i, item in ipairs(launcher_items) do
    gpu.setBackground(0x1E1E2E)
    gpu.setForeground(theme.fg)
    gpu.set(lx + 2, ly + i, item.name)
    item._y = ly + i
  end
end

-- ── Embedded GUI apps ────────────────────────────────────────────────────────

local function create_terminal_window()
  local win = libgui.create_window({
    x = 5, y = 3,
    w = math.min(60, W - 10),
    h = math.min(18, H - 6),
    title = "Terminal",
  })

  local output_lines = { "UniOS Terminal", "Type commands below.", "" }
  local input_buf = ""
  local scroll_offset = 0

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

  local orig_key = input_field.key
  input_field.key = function(ch, code)
    if ch == "\n" then
      local cmd = input_field.value or ""
      input_field.value = ""
      input_field.cursor = 1
      output_lines[#output_lines + 1] = "$ " .. cmd

      if cmd == "exit" or cmd == "close" then
        comp.remove_window(win)
        return
      end

      -- Simple command execution
      local ok, result = pcall(function()
        if cmd == "uname" or cmd == "uname -a" then
          return kernel.VERSION .. " " .. (kernel.RELEASE or "")
        elseif cmd == "whoami" then
          return "root"
        elseif cmd == "pwd" then
          return "/root"
        elseif cmd == "date" then
          return string.format("uptime: %.1fs", computer.uptime())
        elseif cmd == "clear" then
          for k in pairs(output_lines) do output_lines[k] = nil end
          output_lines[1] = ""
          return nil
        elseif cmd == "help" then
          return "Builtin: uname, whoami, pwd, date, clear, help, exit"
        else
          return "sh: " .. cmd .. ": use main terminal for full shell"
        end
      end)

      if result then
        output_lines[#output_lines + 1] = tostring(result)
      end
      output_lines[#output_lines + 1] = ""
      output_list.items = output_lines
      output_list.selected = #output_lines
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
  local win = libgui.create_window({
    x = 8, y = 4,
    w = math.min(50, W - 12),
    h = math.min(16, H - 6),
    title = "Files: /",
  })

  local cwd = "/"
  local items = {}

  local function refresh()
    items = {}
    if cwd ~= "/" then items[1] = ".." end
    local ls = vfs.list(cwd)
    if ls then
      for _, f in ipairs(ls) do
        items[#items + 1] = f
      end
      table.sort(items, function(a, b)
        if a == ".." then return true end
        if b == ".." then return false end
        local a_dir = vfs.isdir(cwd .. "/" .. a)
        local b_dir = vfs.isdir(cwd .. "/" .. b)
        if a_dir ~= b_dir then return a_dir end
        return a < b
      end)
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
        cwd = cwd:match("^(.+)/[^/]+$") or "/"
        refresh()
        file_list.items = items
        file_list.selected = 1
      elseif vfs.isdir(cwd .. "/" .. item) then
        cwd = (cwd == "/" and "/" or cwd .. "/") .. item
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
  local win = libgui.create_window({
    x = 12, y = 5,
    w = math.min(44, W - 14),
    h = 12,
    title = "System Info",
  })

  local info = {
    "System: " .. (kernel.VERSION or "UniOS"),
    "Release: " .. (kernel.RELEASE or "?"),
    "Codename: " .. (kernel.CODENAME or "?"),
    "",
    string.format("Uptime: %.1fs", computer.uptime()),
    string.format("Memory: %dKB / %dKB",
      math.floor((computer.totalMemory() - computer.freeMemory()) / 1024),
      math.floor(computer.totalMemory() / 1024)),
    string.format("Screen: %dx%d", W, H),
    "",
    "Packages: " .. (function()
      local data = vfs.readfile("/var/lib/apt/installed")
      if not data then return "?" end
      local c = 0
      for _ in data:gmatch("[^\n]+") do c = c + 1 end
      return tostring(c)
    end)(),
  }

  for i, line in ipairs(info) do
    libgui.add_widget(win, libgui.Label({
      x = 1, y = i,
      text = line,
      color = (i == 1 or i == 2 or i == 3) and theme.accent or theme.fg,
    }))
  end

  return win
end

-- ── Custom compositor loop ───────────────────────────────────────────────────

local function launch_app(name)
  if name == "terminal" or name == "gui-terminal" then
    local win = create_terminal_window()
    comp.add_window(win)
  elseif name == "files" or name == "gui-files" then
    local win = create_files_window()
    comp.add_window(win)
  elseif name == "gui-sysinfo" then
    local win = create_sysinfo_window()
    comp.add_window(win)
  elseif name == "nano" then
    comp.stop()
    gpu_drv.clear()
    return
  end
end

local function handle_taskbar_click(sx, sy)
  if sy ~= TASKBAR_Y then return false end
  for _, item in ipairs(taskbar_items) do
    if sx >= item._x and sx < item._x + item._w then
      if item.action == "launcher" then
        launcher_open = not launcher_open
      else
        launch_app(item.action)
      end
      return true
    end
  end
  return false
end

local function handle_launcher_click(sx, sy)
  if not launcher_open then return false end
  for _, item in ipairs(launcher_items) do
    if item._y and sy == item._y and sx >= 1 and sx <= 24 then
      launcher_open = false
      launch_app(item.cmd)
      return true
    end
  end
  launcher_open = false
  return false
end

local function main()
  kbd.set_raw(true)
  comp.init()

  local running = true
  local redraw_timer = 0

  while running do
    local ev = { computer.pullSignal(0.05) }

    if ev[1] then
      if ev[1] == "touch" then
        local sx, sy = ev[3], ev[4]

        if handle_taskbar_click(sx, sy) then
          -- handled
        elseif handle_launcher_click(sx, sy) then
          -- handled
        else
          launcher_open = false
          comp.handle_event(ev)
        end
      elseif ev[1] == "key_down" then
        local char = ev[3]
        -- Ctrl+Q exits compositor
        if char == 17 then
          running = false
        else
          comp.handle_event(ev)
        end
      else
        comp.handle_event(ev)
      end
    end

    -- Redraw periodically
    redraw_timer = redraw_timer + 1
    if redraw_timer >= 2 then
      redraw_timer = 0
      draw_desktop()
      comp.draw()
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
