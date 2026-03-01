-- UniOS libgui – GUI widget toolkit for OpenComputers
-- Runs in Lua 5.3 with kernel, kernel.drivers.gpu, kernel.drivers.keyboard, computer.pullSignal.
-- All coordinates are 1-based. Drawing uses raw GPU proxy directly.

local libgui = {}

-- ── Color theme (Catppuccin Mocha dark) ────────────────────────────────────────

libgui.theme = {
  bg               = 0x1E1E2E,  -- dark background
  fg               = 0xCDD6F4,  -- text
  accent           = 0x89B4FA,  -- blue accent
  surface          = 0x313244,  -- widget surfaces
  overlay          = 0x45475A,  -- overlays, borders
  red              = 0xF38BA8,
  green            = 0xA6E3A1,
  yellow           = 0xF9E2AF,
  titlebar         = 0x181825,  -- window titlebar
  titlebar_active  = 0x89B4FA,  -- active window
  close_btn        = 0xF38BA8,  -- close button
}

local theme = libgui.theme

-- ── Helper: point in rect (1-based inclusive) ──────────────────────────────────

local function in_rect(px, py, rx, ry, rw, rh)
  return px >= rx and px < rx + rw and py >= ry and py < ry + rh
end

-- ── Widget: Button ────────────────────────────────────────────────────────────

function libgui.Button(opts)
  local o = opts or {}
  local w = {
    x = o.x or 1, y = o.y or 1, w = o.w or 10, h = o.h or 1,
    label = o.label or "Button",
    on_click = o.on_click,
  }
  function w.draw(gpu, baseX, baseY)
    local x, y = baseX + w.x, baseY + w.y
    gpu.setBackground(theme.surface)
    gpu.setForeground(theme.fg)
    gpu.fill(x, y, w.w, w.h, " ")
    local txt = w.label:sub(1, w.w)
    gpu.set(x + math.max(0, math.floor((w.w - #txt) / 2)), y, txt)
  end
  function w.click(lx, ly, button)
    if w.on_click then w.on_click(button) end
  end
  return w
end

-- ── Widget: Label ─────────────────────────────────────────────────────────────

function libgui.Label(opts)
  local o = opts or {}
  local w = {
    x = o.x or 1, y = o.y or 1, text = o.text or "", color = o.color or theme.fg,
  }
  function w.draw(gpu, baseX, baseY)
    gpu.setForeground(w.color)
    gpu.setBackground(theme.surface)
    gpu.set(baseX + w.x, baseY + w.y, w.text)
  end
  return w
end

-- ── Widget: TextInput ────────────────────────────────────────────────────────

function libgui.TextInput(opts)
  local o = opts or {}
  local w = {
    x = o.x or 1, y = o.y or 1, w = o.w or 20,
    placeholder = o.placeholder or "",
    value = o.value or "",
    cursor = 0, focused = false,
  }
  function w.draw(gpu, baseX, baseY)
    local x, y = baseX + w.x, baseY + w.y
    gpu.setBackground(theme.surface)
    gpu.setForeground(theme.fg)
    gpu.fill(x, y, w.w, 1, " ")
    local disp = w.value
    if disp == "" then
      gpu.setForeground(theme.overlay)
      disp = w.placeholder
    end
    gpu.set(x, y, disp:sub(1, w.w))
    if w.focused and w.cursor >= 0 and w.cursor <= #w.value then
      gpu.setForeground(theme.accent)
      local cp = math.min(w.cursor + 1, w.w)
      gpu.set(x + cp - 1, y, "|")
    end
  end
  function w.click(lx, ly, button)
    w.focused = true
    w.cursor = math.min(math.max(0, lx - w.x), #w.value)
  end
  function w.key(char, code)
    if not w.focused then return end
    if char == "\8" or char == "\127" then
      if w.cursor > 0 then
        w.value = w.value:sub(1, w.cursor - 1) .. w.value:sub(w.cursor + 1)
        w.cursor = w.cursor - 1
      end
    elseif char == "\n" or char == "\r" then
      w.focused = false
    elseif char and #char == 1 and char:byte() >= 32 then
      w.value = w.value:sub(1, w.cursor) .. char .. w.value:sub(w.cursor + 1)
      w.cursor = w.cursor + 1
    end
  end
  function w.focus() w.focused = true end
  function w.blur() w.focused = false end
  return w
end

-- ── Widget: Panel ─────────────────────────────────────────────────────────────

function libgui.Panel(opts)
  local o = opts or {}
  local w = {
    x = o.x or 1, y = o.y or 1, w = o.w or 10, h = o.h or 5,
    color = o.color or theme.surface,
  }
  function w.draw(gpu, baseX, baseY)
    gpu.setBackground(w.color)
    gpu.fill(baseX + w.x, baseY + w.y, w.w, w.h, " ")
  end
  return w
end

-- ── Widget: List ─────────────────────────────────────────────────────────────

function libgui.List(opts)
  local o = opts or {}
  local w = {
    x = o.x or 1, y = o.y or 1, w = o.w or 20, h = o.h or 10,
    items = o.items or {},
    selected = o.selected or 0,
    scroll = 0,
    on_select = o.on_select,
  }
  function w.draw(gpu, baseX, baseY)
    local x, y = baseX + w.x, baseY + w.y
    for i = 1, w.h do
      local idx = w.scroll + i
      local bg = theme.surface
      local fg = theme.fg
      if idx <= #w.items and idx == w.selected then
        bg = theme.accent
        fg = theme.bg
      end
      gpu.setBackground(bg)
      gpu.setForeground(fg)
      gpu.fill(x, y + i - 1, w.w, 1, " ")
      if idx <= #w.items then
        local item = tostring(w.items[idx]):sub(1, w.w)
        gpu.set(x, y + i - 1, item)
      end
    end
  end
  function w.click(lx, ly, button)
    local row = ly - w.y + 1
    local idx = w.scroll + row
    if idx >= 1 and idx <= #w.items then
      w.selected = idx
      if w.on_select then w.on_select(idx, w.items[idx]) end
    end
  end
  function w.key(char, code)
    if char == "up" or code == 200 then
      w.selected = math.max(1, w.selected - 1)
      if w.selected <= w.scroll then w.scroll = math.max(0, w.scroll - 1) end
    elseif char == "down" or code == 208 then
      w.selected = math.min(#w.items, w.selected + 1)
      if w.selected > w.scroll + w.h then w.scroll = w.scroll + 1 end
    end
    if w.on_select and w.selected > 0 then w.on_select(w.selected, w.items[w.selected]) end
  end
  return w
end

-- ── Window ───────────────────────────────────────────────────────────────────

local TITLEBAR_H = 1
local BORDER = 1

local function create_window(opts)
  local o = opts or {}
  local win = {
    x = o.x or 5, y = o.y or 5, w = o.w or 40, h = o.h or 20,
    title = o.title or "Window",
    widgets = {},
  }
  win.content_x = win.x + BORDER
  win.content_y = win.y + TITLEBAR_H + BORDER
  win.content_w = math.max(0, win.w - BORDER * 2)
  win.content_h = math.max(0, win.h - TITLEBAR_H - BORDER * 2)
  win.dragging = false
  win.drag_ox, win.drag_oy = 0, 0
  win.focused_widget = nil

  function win.add_widget(widget)
    win.widgets[#win.widgets + 1] = widget
  end

  function win.draw(gpu)
    local t = win == libgui._active_window and theme.titlebar_active or theme.titlebar
    -- Title bar
    gpu.setBackground(t)
    gpu.setForeground(theme.fg)
    gpu.fill(win.x, win.y, win.w, TITLEBAR_H, " ")
    local title = win.title:sub(1, win.w - 4)
    gpu.set(win.x + 1, win.y, title)
    -- Close button (rightmost cell)
    gpu.setBackground(theme.close_btn)
    gpu.setForeground(theme.bg)
    gpu.set(win.x + win.w - 1, win.y, "X")
    -- Content area background
    gpu.setBackground(theme.surface)
    gpu.fill(win.content_x, win.content_y, win.content_w, win.content_h, " ")
    -- Border (simplified: just fill edges)
    gpu.setBackground(theme.overlay)
    gpu.fill(win.x, win.y + TITLEBAR_H, win.w, 1, " ")
    -- Widgets
    for _, wd in ipairs(win.widgets) do
      if wd.draw then wd.draw(gpu, win.content_x, win.content_y) end
    end
  end

  function win.hit_titlebar(sx, sy)
    return sx >= win.x and sx < win.x + win.w and sy >= win.y and sy < win.y + TITLEBAR_H
  end

  function win.hit_close(sx, sy)
    return sx == win.x + win.w - 1 and sy == win.y
  end

  function win.screen_to_content(sx, sy)
    return sx - win.content_x, sy - win.content_y
  end

  function win.find_widget_at(lx, ly)
    for i = #win.widgets, 1, -1 do
      local w = win.widgets[i]
      local wx, wy = w.x or 0, w.y or 0
      local ww, wh = w.w or 1, w.h or 1
      if in_rect(lx, ly, wx, wy, ww, wh) then return w end
    end
    return nil
  end

  return win
end

-- ── Compositor ───────────────────────────────────────────────────────────────

local compositor = {
  _windows = {},
  _running = false,
  _screen_w = 80,
  _screen_h = 25,
}

function compositor.init()
  local gpu_proxy = kernel.drivers.gpu and kernel.drivers.gpu.raw()
  if not gpu_proxy then return end
  compositor._screen_w, compositor._screen_h = kernel.drivers.gpu.size()
end

function compositor.add_window(win)
  compositor._windows[#compositor._windows + 1] = win
  libgui._active_window = win
end

function compositor.remove_window(win)
  if win._on_close then pcall(win._on_close) end
  for i, w in ipairs(compositor._windows) do
    if w == win then
      table.remove(compositor._windows, i)
      if libgui._active_window == win then
        libgui._active_window = compositor._windows[#compositor._windows] or nil
      end
      break
    end
  end
end

function compositor.bring_to_front(win)
  for i, w in ipairs(compositor._windows) do
    if w == win then
      table.remove(compositor._windows, i)
      compositor._windows[#compositor._windows + 1] = win
      libgui._active_window = win
      return
    end
  end
end

function compositor.draw()
  local gpu = kernel.drivers.gpu and kernel.drivers.gpu.raw()
  if not gpu then return end
  local sw, sh = kernel.drivers.gpu.size()
  gpu.setBackground(theme.bg)
  gpu.setForeground(theme.fg)
  gpu.fill(1, 1, sw, sh, " ")
  for _, win in ipairs(compositor._windows) do
    win.draw(gpu)
  end
end

function compositor.handle_event(ev)
  local name = ev[1]
  if name == "touch" then
    local _, sx, sy, button = ev[2], ev[3], ev[4], ev[5]
    -- Find topmost window containing (sx, sy)
    local hit_win = nil
    for i = #compositor._windows, 1, -1 do
      local win = compositor._windows[i]
      if sx >= win.x and sx < win.x + win.w and sy >= win.y and sy < win.y + win.h then
        hit_win = win
        compositor.bring_to_front(win)
        break
      end
    end
    if hit_win then
      if hit_win.hit_close(sx, sy) then
        compositor.remove_window(hit_win)
        return
      end
      if hit_win.hit_titlebar(sx, sy) then
        hit_win.dragging = true
        hit_win.drag_ox = sx - hit_win.x
        hit_win.drag_oy = sy - hit_win.y
        return
      end
      local lx, ly = hit_win.screen_to_content(sx, sy)
      local wd = hit_win.find_widget_at(lx, ly)
      if hit_win.focused_widget and hit_win.focused_widget ~= wd then
        if hit_win.focused_widget.blur then hit_win.focused_widget.blur() end
      end
      hit_win.focused_widget = wd
      if wd then
        if wd.focus then wd.focus() end
        if wd.click then wd.click(lx - (wd.x or 0), ly - (wd.y or 0), button) end
      end
    end
  elseif name == "drag" then
    local _, sx, sy = ev[2], ev[3], ev[4]
    for _, win in ipairs(compositor._windows) do
      if win.dragging then
        win.x = math.max(1, sx - win.drag_ox)
        win.y = math.max(1, sy - win.drag_oy)
        win.content_x = win.x + BORDER
        win.content_y = win.y + TITLEBAR_H + BORDER
        break
      end
    end
  elseif name == "drop" then
    for _, win in ipairs(compositor._windows) do
      win.dragging = false
    end
  elseif name == "key_down" then
    local _, char, code = ev[2], ev[3], ev[4]
    local chr
    if type(char) == "number" and char > 0 and char < 256 then
      chr = string.char(char)
    elseif code == 200 then chr = "up"
    elseif code == 208 then chr = "down"
    elseif code == 203 then chr = "left"
    elseif code == 205 then chr = "right"
    elseif code == 211 then chr = "delete"
    elseif code == 199 then chr = "home"
    elseif code == 207 then chr = "end"
    elseif code == 28 then chr = "\n"
    elseif code == 14 then chr = "\8"
    elseif code == 15 then chr = "\t"
    else chr = nil
    end
    if libgui._active_window then
      local wd = libgui._active_window.focused_widget
      if wd and wd.key then
        wd.key(chr, code)
      end
    end
  end
end

function compositor.run()
  compositor.init()
  compositor._running = true
  while compositor._running do
    local ev = { computer.pullSignal(0.05) }
    if ev[1] then
      compositor.handle_event(ev)
    end
    compositor.draw()
    coroutine.yield()
  end
end

function compositor.stop()
  compositor._running = false
end

-- ── Public API ────────────────────────────────────────────────────────────────

libgui.create_window = function(opts)
  return create_window(opts)
end

libgui.add_widget = function(window, widget)
  window.add_widget(widget)
end

libgui.compositor = compositor

return libgui
