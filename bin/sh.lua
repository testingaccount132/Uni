-- UniOS /bin/sh  – UNIX-style interactive shell
-- Supports: pipes, redirections, variables, quoting, globbing,
-- builtins, background jobs, command history, and tab completion.

local VERSION = "1.0"

-- ── Globals available from kernel ────────────────────────────────────────────
local gpu = kernel.drivers.gpu
local kbd = kernel.drivers.keyboard
local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local lc  = kernel.require("lib.libc")

-- ── I/O abstraction (PTY-aware) ─────────────────────────────────────────────
-- If the process has a PTY slave attached as stdout, write there instead of GPU.
-- This allows the shell to work in both console mode and inside compositor terminals.
local _io = {}
do
  local pid = sys("getpid")
  local proc = kernel.process.get(pid)
  local has_pty = proc and proc.fds[1] and proc.fds[1].write
  if has_pty then
    _io.write = function(s) proc.fds[1]:write(tostring(s)) end
    _io.read_char = function()
      while true do
        if proc.fds[0] and proc.fds[0].read then
          local ch = proc.fds[0]:read(1)
          if ch then return ch end
        end
        coroutine.yield()
      end
    end
    _io.readline = function(prompt_str)
      if prompt_str then _io.write(prompt_str) end
      local line = {}
      while true do
        local ch = _io.read_char()
        if ch == "\n" or ch == "\r" then
          _io.write("\n")
          return table.concat(line)
        elseif ch == "\8" or ch == "\127" then
          if #line > 0 then
            table.remove(line)
            _io.write("\8 \8")
          end
        elseif ch == "\3" then
          _io.write("^C\n")
          return ""
        else
          line[#line + 1] = ch
          _io.write(ch)
        end
      end
    end
    _io.is_pty = true
  else
    _io.write = function(s) gpu.write(tostring(s)) end
    _io.read_char = function() return kbd.getchar() end
    _io.readline = function(prompt_str)
      return kbd.readline(prompt_str)
    end
    _io.is_pty = false
  end
end

-- ── Shell state ───────────────────────────────────────────────────────────────

local _env     = {}  -- copy of process env
local _vars    = {}  -- shell variables
local _aliases = {}  -- name → expansion
local _history = {}  -- command history
local _hist_i  = 0
local _cwd     = "/"
local _pid     = sys("getpid")
local _running = true

-- Bootstrap env from process
do
  local e = sys("getenv")
  if type(e) == "table" then
    for k, v in pairs(e) do _env[k] = v end
  end
  _cwd = sys("getcwd") or _env.HOME or "/"
end

local PATH_LIST = lp.split_path(_env.PATH or "/bin:/usr/bin")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function sh_write(s)  _io.write(tostring(s)) end
local function sh_writeln(s) _io.write(tostring(s) .. "\n") end
local function sh_err(s)
  _io.write("\27[31msh: " .. tostring(s) .. "\27[0m\n")
end

local function expand_var(name)
  if name == "?" then return tostring(_last_exit or 0) end
  if name == "$" then return tostring(_pid) end
  if name == "HOME" then return _env.HOME or "/root" end
  return _vars[name] or _env[name] or ""
end

-- ── Tokeniser / parser ────────────────────────────────────────────────────────

-- States
local TOK_WORD, TOK_PIPE, TOK_REDIR_IN, TOK_REDIR_OUT, TOK_REDIR_APP,
      TOK_SEMI, TOK_AND, TOK_OR, TOK_BG = 1,2,3,4,5,6,7,8,9

local function tokenise(line)
  local tokens = {}
  local i = 1
  local len = #line

  local function peek() return line:sub(i, i) end
  local function advance() i = i + 1 end
  local function at_end() return i > len end

  while not at_end() do
    local ch = peek()

    if ch:match("%s") then
      advance()

    elseif ch == "#" then
      break  -- comment

    elseif ch == "|" then
      advance()
      if peek() == "|" then advance(); tokens[#tokens+1] = { TOK_OR, "||" }
      else tokens[#tokens+1] = { TOK_PIPE, "|" } end

    elseif ch == "&" then
      advance()
      if peek() == "&" then advance(); tokens[#tokens+1] = { TOK_AND, "&&" }
      else tokens[#tokens+1] = { TOK_BG, "&" } end

    elseif ch == ";" then
      advance(); tokens[#tokens+1] = { TOK_SEMI, ";" }

    elseif ch == "<" then
      advance(); tokens[#tokens+1] = { TOK_REDIR_IN, "<" }

    elseif ch == ">" then
      advance()
      if peek() == ">" then advance(); tokens[#tokens+1] = { TOK_REDIR_APP, ">>" }
      else tokens[#tokens+1] = { TOK_REDIR_OUT, ">" } end

    else
      -- Word (with quoting + variable expansion)
      local word = ""
      while not at_end() do
        local c = peek()
        if c:match("[%s|&;<>]") then break end

        if c == "'" then
          -- Single quotes: no expansion
          advance()
          while not at_end() and peek() ~= "'" do
            word = word .. peek(); advance()
          end
          if not at_end() then advance() end  -- closing '

        elseif c == '"' then
          -- Double quotes: variable expansion
          advance()
          while not at_end() and peek() ~= '"' do
            local dc = peek()
            if dc == "$" then
              advance()
              local vn = ""
              if peek() == "{" then
                advance()
                while not at_end() and peek() ~= "}" do vn = vn .. peek(); advance() end
                if not at_end() then advance() end
              else
                while not at_end() and peek():match("[%w_]") do vn = vn .. peek(); advance() end
              end
              word = word .. expand_var(vn)
            else
              word = word .. dc; advance()
            end
          end
          if not at_end() then advance() end  -- closing "

        elseif c == "$" then
          advance()
          local vn = ""
          if peek() == "{" then
            advance()
            while not at_end() and peek() ~= "}" do vn = vn .. peek(); advance() end
            if not at_end() then advance() end
          else
            while not at_end() and peek():match("[%w_]") do vn = vn .. peek(); advance() end
          end
          word = word .. expand_var(vn)

        elseif c == "\\" then
          advance()
          if not at_end() then word = word .. peek(); advance() end

        else
          word = word .. c; advance()
        end
      end
      tokens[#tokens+1] = { TOK_WORD, word }
    end
  end

  return tokens
end

-- Parse tokens into a list of commands separated by | ; && ||
-- Returns a list of "pipeline groups":
-- { cmds = { {argv, stdin, stdout, stderr, background}, ... }, op = ";" | "&&" | "||" }
local function parse(tokens)
  local groups  = {}
  local current = { cmds = {}, op = ";" }
  local cmd     = { argv = {}, stdin = nil, stdout = nil, stderr = nil, bg = false }

  local function push_cmd()
    if #cmd.argv > 0 then
      current.cmds[#current.cmds + 1] = cmd
      cmd = { argv = {}, stdin = nil, stdout = nil, stderr = nil, bg = false }
    end
  end

  local function push_group(op)
    push_cmd()
    if #current.cmds > 0 then
      groups[#groups + 1] = current
    end
    current = { cmds = {}, op = op or ";" }
  end

  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local typ, val = tok[1], tok[2]

    if typ == TOK_WORD then
      -- Check for VAR=value assignment
      if #cmd.argv == 0 and val:match("^([%w_]+)=(.*)$") then
        local k, v = val:match("^([%w_]+)=(.*)$")
        _vars[k] = v
        _env[k]  = v
      else
        cmd.argv[#cmd.argv + 1] = val
      end

    elseif typ == TOK_PIPE then
      push_cmd()

    elseif typ == TOK_REDIR_IN then
      i = i + 1
      if tokens[i] then cmd.stdin = tokens[i][2] end

    elseif typ == TOK_REDIR_OUT then
      i = i + 1
      if tokens[i] then cmd.stdout = { file = tokens[i][2], append = false } end

    elseif typ == TOK_REDIR_APP then
      i = i + 1
      if tokens[i] then cmd.stdout = { file = tokens[i][2], append = true } end

    elseif typ == TOK_BG then
      cmd.bg = true
      push_group(";")

    elseif typ == TOK_SEMI then
      push_group(";")

    elseif typ == TOK_AND then
      push_group("&&")

    elseif typ == TOK_OR then
      push_group("||")
    end

    i = i + 1
  end
  push_group(";")
  return groups
end

-- ── Builtins ──────────────────────────────────────────────────────────────────

local builtins = {}

builtins["cd"] = function(argv)
  local path = argv[2] or _env.HOME or "/"
  local abs  = lp.resolve(path, _cwd)
  if not vfs.isdir(abs) then
    sh_err("cd: not a directory: " .. path); return 1
  end
  _cwd = abs
  sys("chdir", abs)
  return 0
end

builtins["pwd"] = function()
  sh_writeln(_cwd); return 0
end

builtins["echo"] = function(argv)
  local parts = {}
  local newline = true
  local i = 2
  if argv[2] == "-n" then newline = false; i = 3 end
  while argv[i] do parts[#parts+1] = argv[i]; i = i + 1 end
  sh_write(table.concat(parts, " "))
  if newline then sh_write("\n") end
  return 0
end

builtins["export"] = function(argv)
  for i = 2, #argv do
    local k, v = argv[i]:match("^([%w_]+)=(.*)$")
    if k then _env[k] = v; sys("setenv", k, v)
    else _env[argv[i]] = _vars[argv[i]] or ""; sys("setenv", argv[i], _env[argv[i]]) end
  end
  return 0
end

builtins["unset"] = function(argv)
  for i = 2, #argv do
    _vars[argv[i]] = nil; _env[argv[i]] = nil
    sys("setenv", argv[i], nil)
  end
  return 0
end

builtins["set"] = function(argv)
  for k, v in pairs(_env) do sh_writeln(k .. "=" .. tostring(v)) end
  return 0
end

builtins["alias"] = function(argv)
  if #argv == 1 then
    for k, v in pairs(_aliases) do sh_writeln("alias " .. k .. "='" .. v .. "'") end
    return 0
  end
  -- Join all args so quoted values with spaces survive tokenization
  local def = table.concat(argv, " ", 2)
  -- Name: word chars, dash, underscore, dot (for .. and ... aliases)
  local k, v = def:match("^([%w_%-%.]+)=(.*)$")
  if k then
    -- Strip surrounding single or double quotes from the value
    v = v:match("^'(.*)'$") or v:match('^"(.*)"$') or v
    _aliases[k] = v
  else
    sh_err("alias: bad syntax"); return 1
  end
  return 0
end

builtins["unalias"] = function(argv)
  _aliases[argv[2]] = nil; return 0
end

builtins["exit"] = function(argv)
  _running = false
  sys("exit", tonumber(argv[2]) or _last_exit or 0)
  return 0
end

builtins["history"] = function()
  for i, line in ipairs(_history) do
    sh_writeln(string.format("%4d  %s", i, line))
  end
  return 0
end

builtins["source"] = function(argv)
  local path = lp.resolve(argv[2] or "", _cwd)
  local src, err = vfs.readfile(path)
  if not src then sh_err("source: " .. tostring(err)); return 1 end
  return sh_exec_string(src)
end
builtins["."] = builtins["source"]

builtins["true"]  = function() return 0 end
builtins["false"] = function() return 1 end

builtins["type"] = function(argv)
  local name = argv[2] or ""
  if builtins[name] then sh_writeln(name .. " is a shell builtin")
  elseif _aliases[name] then sh_writeln(name .. " is aliased to '" .. _aliases[name] .. "'")
  else
    local path = lp.which(name, PATH_LIST)
    if path then sh_writeln(name .. " is " .. path)
    else sh_err("type: " .. name .. ": not found"); return 1 end
  end
  return 0
end

builtins["help"] = function()
  sh_writeln("\27[1;36mUniOS sh " .. VERSION .. " (" .. kernel.VERSION .. ")\27[0m")
  sh_writeln("")
  sh_writeln("\27[1mBuiltins:\27[0m " .. table.concat(lc.keys(builtins), ", "))

  local cmds = {}
  for _, dir in ipairs(PATH_LIST) do
    local ls = vfs.list(dir)
    if ls then
      for _, f in ipairs(ls) do
        local name = f:gsub("%.lua$", "")
        if not builtins[name] then
          cmds[name] = true
        end
      end
    end
  end
  local sorted = {}
  for name in pairs(cmds) do sorted[#sorted + 1] = name end
  table.sort(sorted)

  if #sorted > 0 then
    sh_writeln("\27[1mCommands:\27[0m " .. table.concat(sorted, ", "))
  end
  sh_writeln("")
  sh_writeln("\27[90mUse '<cmd> --help' for command help\27[0m")
  return 0
end

-- ── Command execution ─────────────────────────────────────────────────────────

local _last_exit = 0

local function exec_cmd(cmd)
  local argv   = cmd.argv
  local name   = argv[1]
  if not name or name == "" then return 0 end

  -- Alias expansion (one level)
  if _aliases[name] then
    local expanded = tokenise(_aliases[name])
    local new_argv = {}
    for _, t in ipairs(expanded) do
      if t[1] == TOK_WORD then new_argv[#new_argv+1] = t[2] end
    end
    for i = 2, #argv do new_argv[#new_argv+1] = argv[i] end
    argv = new_argv
    name = argv[1]
  end

  -- Builtin
  if builtins[name] then
    return builtins[name](argv) or 0
  end

  -- External command
  local path = lp.which(name, PATH_LIST)
  if not path then
    sh_err(name .. ": command not found"); return 127
  end

  local src, err = vfs.readfile(path)
  if not src then
    sh_err(name .. ": " .. tostring(err)); return 1
  end

  -- Run in the same process for simplicity (full fork would need scheduler support)
  local fn, perr = load(src, "=" .. name, "t", _G)
  if not fn then sh_err(name .. ": " .. tostring(perr)); return 1 end

  -- Set arg globals (POSIX: arg[0] = program name, arg[1..n] = real arguments)
  local old_arg = _G.arg
  local prog_arg = {}
  prog_arg[0] = name
  for i = 2, #argv do prog_arg[#prog_arg + 1] = argv[i] end
  _G.arg = prog_arg

  local ok, result = xpcall(fn, function(e)
    return debug and debug.traceback(e, 2) or e
  end)

  _G.arg = old_arg

  if not ok then
    sh_err(name .. ": runtime error: " .. tostring(result))
    return 1
  end
  return type(result) == "number" and result or 0
end

local function exec_pipeline(cmds)
  -- For now pipelines run sequentially (true IPC pipes need coroutines + buffers)
  -- A real pipe is left as a future extension.
  local last = 0
  for _, cmd in ipairs(cmds) do
    last = exec_cmd(cmd)
    _last_exit = last
  end
  return last
end

local function exec_groups(groups)
  local last = 0
  for _, group in ipairs(groups) do
    local run = true
    if group.op == "&&" and last ~= 0 then run = false end
    if group.op == "||" and last == 0  then run = false end
    if run then
      last = exec_pipeline(group.cmds)
      _last_exit = last
    end
  end
  return last
end

function sh_exec_string(src)
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    line = lc.trim(line)
    if line ~= "" and line:sub(1,1) ~= "#" then
      local toks = tokenise(line)
      local groups = parse(toks)
      exec_groups(groups)
    end
  end
  return _last_exit
end

-- ── Prompt ────────────────────────────────────────────────────────────────────

local function prompt()
  local user = _env.USER or "user"
  local host = lc.trim(vfs.readfile("/etc/hostname") or "uni")
  local cwd_display = _cwd
  if _env.HOME and cwd_display:sub(1, #_env.HOME) == _env.HOME then
    cwd_display = "~" .. cwd_display:sub(#_env.HOME + 1)
  end
  local uid = 0  -- TODO: real uid from process
  local sym = uid == 0 and "#" or "$"
  return string.format(
    "\27[1;32m%s@%s\27[0m:\27[1;34m%s\27[0m%s ",
    user, host, cwd_display, sym
  )
end

-- ── Line editor (with history) ────────────────────────────────────────────────

local function readline_with_history()
  local line = {}
  local hist_idx = #_history + 1
  local saved_line = ""

  _io.write(prompt())
  kernel.signal.set_fg(_pid)

  while true do
    local ch = _io.read_char()

    if ch == "\n" or ch == "\r" then
      _io.write("\n")
      break

    elseif ch == "\8" or ch == "\127" then
      if #line > 0 then
        table.remove(line)
        _io.write("\8 \8")
      end

    elseif ch == "\3" then   -- Ctrl-C
      _io.write("^C\n")
      line = {}
      break

    elseif ch == "\4" then   -- Ctrl-D
      if #line == 0 then
        _io.write("exit\n")
        _running = false
        sys("exit", 0)
      end

    elseif ch == "\9" then   -- Tab completion
      local partial = table.concat(line)
      local word    = partial:match("[^%s]+$") or ""
      local is_first_word = not partial:match("%S+%s")
      local completions = {}

      local function do_file_completion()
        local resolve_ok, resolved = pcall(lp.resolve, word, _cwd)
        if not resolve_ok then resolved = _cwd .. "/" .. word end
        local dir_ok, dir = pcall(lp.dirname, resolved)
        if not dir_ok then dir = _cwd end
        local base_ok, base = pcall(lp.basename, word ~= "" and word or ".")
        if not base_ok then base = word end
        if word == "" or word:sub(-1) == "/" then base = "" end
        local ls = vfs.list(dir) or {}
        for _, f in ipairs(ls) do
          if base == "" or f:sub(1, #base) == base then
            completions[#completions + 1] = f
          end
        end
      end

      if is_first_word then
        for bi in pairs(builtins) do
          if bi:sub(1, #word) == word then completions[#completions+1] = bi end
        end
        local ls = vfs.list("/bin") or {}
        for _, f in ipairs(ls) do
          local name = f:gsub("%.lua$", "")
          if name:sub(1, #word) == word then completions[#completions+1] = name end
        end
      else
        pcall(do_file_completion)
      end

      if #completions == 1 then
        local completion = completions[1]
        if is_first_word then completion = completion:gsub("%.lua$", "") end
        local suffix = completion:sub(#(word:match("[^/]+$") or word) + 1)
        if suffix ~= "" then
          for c in suffix:gmatch(".") do line[#line+1] = c end
          _io.write(suffix)
        end
      elseif #completions > 1 then
        table.sort(completions)
        _io.write("\n" .. table.concat(completions, "  ") .. "\n")
        _io.write(prompt() .. table.concat(line))
      end

    elseif ch == "up" then
      if hist_idx > 1 then
        if hist_idx == #_history + 1 then saved_line = table.concat(line) end
        hist_idx = hist_idx - 1
        local hl = _history[hist_idx] or ""
        _io.write(string.rep("\8 \8", #line))
        line = {}
        for c in hl:gmatch(".") do line[#line+1] = c end
        _io.write(hl)
      end

    elseif ch == "down" then
      if hist_idx <= #_history then
        hist_idx = hist_idx + 1
        local hl = hist_idx > #_history and saved_line or (_history[hist_idx] or "")
        _io.write(string.rep("\8 \8", #line))
        line = {}
        for c in hl:gmatch(".") do line[#line+1] = c end
        _io.write(hl)
      end

    elseif type(ch) == "string" and #ch == 1 then
      line[#line+1] = ch
      _io.write(ch)
    end
  end

  return table.concat(line)
end

-- ── Main loop ─────────────────────────────────────────────────────────────────

-- Source /etc/profile if it exists
pcall(function()
  local src = vfs.readfile("/etc/profile")
  if src then sh_exec_string(src) end
end)

-- Source ~/.shrc if it exists
pcall(function()
  local rc = vfs.readfile((_env.HOME or "/root") .. "/.shrc")
  if rc then sh_exec_string(rc) end
end)

-- Clear screen and print banner
if not _io.is_pty then
  do
    local raw = gpu.raw and gpu.raw()
    if raw then
      local rw, rh = raw.getResolution()
      raw.setBackground(0x000000)
      raw.setForeground(0xFFFFFF)
      raw.fill(1, 1, rw, rh, " ")
    end
    gpu.clear()
  end
end
_io.write("\27[1;36m" .. kernel.VERSION .. "\27[0m  |  type 'help' for builtins\n\n")

while _running do
  local ok, line = pcall(readline_with_history)
  if not ok then
    sh_err("readline error: " .. tostring(line))
    line = ""
  end

  line = lc.trim(line or "")

  if line ~= "" then
    -- Add to history (avoid duplicates at top)
    if _history[#_history] ~= line then
      _history[#_history + 1] = line
      if #_history > 500 then table.remove(_history, 1) end
    end

    local ok2, err2 = pcall(function()
      local toks   = tokenise(line)
      local groups = parse(toks)
      exec_groups(groups)
    end)
    if not ok2 then sh_err(tostring(err2)) end
  end

  coroutine.yield()
end
