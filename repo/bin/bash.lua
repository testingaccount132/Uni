-- bash – advanced UniOS shell
-- Enhanced shell with arrays, functions, arithmetic, here-strings,
-- and other bash-like features on top of the base sh.

local VERSION = "1.0"

local gpu = kernel.drivers.gpu
local kbd = kernel.drivers.keyboard
local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local lc  = kernel.require("lib.libc")

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
          _io.write("\n"); return table.concat(line)
        elseif ch == "\8" or ch == "\127" then
          if #line > 0 then table.remove(line); _io.write("\8 \8") end
        elseif ch == "\3" then _io.write("^C\n"); return ""
        else line[#line + 1] = ch; _io.write(ch) end
      end
    end
    _io.is_pty = true
  else
    _io.write = function(s) gpu.write(tostring(s)) end
    _io.read_char = function() return kbd.getchar() end
    _io.readline = function(prompt_str) return kbd.readline(prompt_str) end
    _io.is_pty = false
  end
end

local _env     = {}
local _vars    = {}
local _aliases = {}
local _history = {}
local _funcs   = {}  -- user-defined functions
local _arrays  = {}  -- bash-style arrays
local _cwd     = "/"
local _pid     = sys("getpid")
local _running = true
local _last_exit = 0

do
  local e = sys("getenv")
  if type(e) == "table" then for k, v in pairs(e) do _env[k] = v end end
  _cwd = sys("getcwd") or _env.HOME or "/"
end

local PATH_LIST = lp.split_path(_env.PATH or "/bin:/usr/bin")

local function sh_write(s)   _io.write(tostring(s)) end
local function sh_writeln(s) _io.write(tostring(s) .. "\n") end
local function sh_err(s) _io.write("\27[31mbash: " .. tostring(s) .. "\27[0m\n") end

local function expand_var(name)
  if name == "?" then return tostring(_last_exit or 0) end
  if name == "$" then return tostring(_pid) end
  if name == "#" then return tostring(_G.arg and #_G.arg or 0) end
  if name == "RANDOM" then return tostring(math.random(0, 32767)) end
  if name == "SECONDS" then return tostring(math.floor(computer.uptime())) end
  if name == "BASH_VERSION" then return VERSION end
  return _vars[name] or _env[name] or ""
end

-- Arithmetic evaluation (simple integer math)
local function arith_eval(expr)
  expr = expr:gsub("%$([%w_]+)", function(v) return expand_var(v) end)
  expr = expr:gsub("[^%d%+%-%*/%%%(%)%s]", "")
  local fn = load("return " .. expr)
  if fn then
    local ok, val = pcall(fn)
    if ok and type(val) == "number" then return math.floor(val) end
  end
  return 0
end

-- Tokenizer (same as sh but with bash extensions)
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
    if ch:match("%s") then advance()
    elseif ch == "#" then break
    elseif ch == "|" then advance(); if peek() == "|" then advance(); tokens[#tokens+1]={TOK_OR,"||"} else tokens[#tokens+1]={TOK_PIPE,"|"} end
    elseif ch == "&" then advance(); if peek() == "&" then advance(); tokens[#tokens+1]={TOK_AND,"&&"} else tokens[#tokens+1]={TOK_BG,"&"} end
    elseif ch == ";" then advance(); tokens[#tokens+1]={TOK_SEMI,";"}
    elseif ch == "<" then advance(); tokens[#tokens+1]={TOK_REDIR_IN,"<"}
    elseif ch == ">" then advance(); if peek() == ">" then advance(); tokens[#tokens+1]={TOK_REDIR_APP,">>"} else tokens[#tokens+1]={TOK_REDIR_OUT,">"} end
    else
      local word = ""
      while not at_end() do
        local c = peek()
        if c:match("[%s|&;<>]") then break end
        if c == "'" then
          advance()
          while not at_end() and peek() ~= "'" do word = word .. peek(); advance() end
          if not at_end() then advance() end
        elseif c == '"' then
          advance()
          while not at_end() and peek() ~= '"' do
            local dc = peek()
            if dc == "$" then
              advance()
              if peek() == "(" and line:sub(i+1, i+1) == "(" then
                advance(); advance()
                local expr = ""
                while not at_end() and not (peek() == ")" and line:sub(i+1, i+1) == ")") do
                  expr = expr .. peek(); advance()
                end
                if not at_end() then advance(); advance() end
                word = word .. tostring(arith_eval(expr))
              elseif peek() == "{" then
                advance()
                local vn = ""
                while not at_end() and peek() ~= "}" do vn = vn .. peek(); advance() end
                if not at_end() then advance() end
                word = word .. expand_var(vn)
              else
                local vn = ""
                while not at_end() and peek():match("[%w_]") do vn = vn .. peek(); advance() end
                word = word .. expand_var(vn)
              end
            else word = word .. dc; advance() end
          end
          if not at_end() then advance() end
        elseif c == "$" then
          advance()
          if peek() == "(" and line:sub(i+1, i+1) == "(" then
            advance(); advance()
            local expr = ""
            while not at_end() and not (peek() == ")" and line:sub(i+1, i+1) == ")") do
              expr = expr .. peek(); advance()
            end
            if not at_end() then advance(); advance() end
            word = word .. tostring(arith_eval(expr))
          elseif peek() == "{" then
            advance()
            local vn = ""
            while not at_end() and peek() ~= "}" do vn = vn .. peek(); advance() end
            if not at_end() then advance() end
            word = word .. expand_var(vn)
          else
            local vn = ""
            while not at_end() and peek():match("[%w_?$#]") do vn = vn .. peek(); advance() end
            word = word .. expand_var(vn)
          end
        elseif c == "\\" then advance(); if not at_end() then word = word .. peek(); advance() end
        else word = word .. c; advance() end
      end
      tokens[#tokens+1] = {TOK_WORD, word}
    end
  end
  return tokens
end

local function parse(tokens)
  local groups = {}
  local current = { cmds = {}, op = ";" }
  local cmd = { argv = {}, stdin = nil, stdout = nil, stderr = nil, bg = false }
  local function push_cmd()
    if #cmd.argv > 0 then current.cmds[#current.cmds+1] = cmd; cmd = { argv={}, stdin=nil, stdout=nil, stderr=nil, bg=false } end
  end
  local function push_group(op)
    push_cmd()
    if #current.cmds > 0 then groups[#groups+1] = current end
    current = { cmds = {}, op = op or ";" }
  end
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local typ, val = tok[1], tok[2]
    if typ == TOK_WORD then
      if #cmd.argv == 0 and val:match("^([%w_]+)=(.*)$") then
        local k, v = val:match("^([%w_]+)=(.*)$")
        _vars[k] = v; _env[k] = v
      else cmd.argv[#cmd.argv+1] = val end
    elseif typ == TOK_PIPE then push_cmd()
    elseif typ == TOK_REDIR_IN then i = i+1; if tokens[i] then cmd.stdin = tokens[i][2] end
    elseif typ == TOK_REDIR_OUT then i = i+1; if tokens[i] then cmd.stdout = { file = tokens[i][2], append = false } end
    elseif typ == TOK_REDIR_APP then i = i+1; if tokens[i] then cmd.stdout = { file = tokens[i][2], append = true } end
    elseif typ == TOK_BG then cmd.bg = true; push_group(";")
    elseif typ == TOK_SEMI then push_group(";")
    elseif typ == TOK_AND then push_group("&&")
    elseif typ == TOK_OR then push_group("||")
    end
    i = i + 1
  end
  push_group(";")
  return groups
end

-- Builtins
local builtins = {}

builtins["cd"] = function(argv)
  local path = argv[2] or _env.HOME or "/"
  if path == "-" then path = _env.OLDPWD or _cwd end
  local abs = lp.resolve(path, _cwd)
  if not vfs.isdir(abs) then sh_err("cd: not a directory: " .. path); return 1 end
  _env.OLDPWD = _cwd
  _cwd = abs; sys("chdir", abs); return 0
end
builtins["pwd"] = function() sh_writeln(_cwd); return 0 end
builtins["echo"] = function(argv)
  local parts = {}; local newline = true; local i = 2
  if argv[2] == "-n" then newline = false; i = 3 end
  if argv[2] == "-e" then i = 3 end
  while argv[i] do parts[#parts+1] = argv[i]; i = i + 1 end
  local out = table.concat(parts, " ")
  if argv[2] == "-e" then
    out = out:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\\\", "\\")
  end
  sh_write(out); if newline then sh_write("\n") end; return 0
end
builtins["export"] = function(argv)
  for i = 2, #argv do
    local k, v = argv[i]:match("^([%w_]+)=(.*)$")
    if k then _env[k] = v; sys("setenv", k, v)
    else _env[argv[i]] = _vars[argv[i]] or ""; sys("setenv", argv[i], _env[argv[i]]) end
  end; return 0
end
builtins["unset"] = function(argv)
  for i = 2, #argv do _vars[argv[i]] = nil; _env[argv[i]] = nil; sys("setenv", argv[i], nil) end; return 0
end
builtins["set"] = function(argv)
  for k, v in pairs(_env) do sh_writeln(k .. "=" .. tostring(v)) end; return 0
end
builtins["alias"] = function(argv)
  if #argv == 1 then for k, v in pairs(_aliases) do sh_writeln("alias "..k.."='"..v.."'") end; return 0 end
  local def = table.concat(argv, " ", 2)
  local k, v = def:match("^([%w_%-%%.]+)=(.*)$")
  if k then v = v:match("^'(.*)'$") or v:match('^"(.*)"$') or v; _aliases[k] = v
  else sh_err("alias: bad syntax"); return 1 end; return 0
end
builtins["unalias"] = function(argv) _aliases[argv[2]] = nil; return 0 end
builtins["exit"] = function(argv) _running = false; sys("exit", tonumber(argv[2]) or 0); return 0 end
builtins["history"] = function()
  for i, line in ipairs(_history) do sh_writeln(string.format("%4d  %s", i, line)) end; return 0
end
builtins["source"] = function(argv)
  local path = lp.resolve(argv[2] or "", _cwd)
  local src = vfs.readfile(path)
  if not src then sh_err("source: " .. tostring(path) .. ": not found"); return 1 end
  return sh_exec_string(src)
end
builtins["."] = builtins["source"]
builtins["true"]  = function() return 0 end
builtins["false"] = function() return 1 end
builtins["type"] = function(argv)
  local name = argv[2] or ""
  if _funcs[name] then sh_writeln(name .. " is a function")
  elseif builtins[name] then sh_writeln(name .. " is a shell builtin")
  elseif _aliases[name] then sh_writeln(name .. " is aliased to '" .. _aliases[name] .. "'")
  else
    local path = lp.which(name, PATH_LIST)
    if path then sh_writeln(name .. " is " .. path) else sh_err("type: " .. name .. ": not found"); return 1 end
  end; return 0
end
builtins["declare"] = function(argv)
  if argv[2] == "-a" and argv[3] then
    _arrays[argv[3]] = {}
  elseif argv[2] then
    local k, v = argv[2]:match("^([%w_]+)=(.*)$")
    if k then _vars[k] = v end
  end; return 0
end
builtins["let"] = function(argv)
  for i = 2, #argv do
    local expr = argv[i]
    local var, rhs = expr:match("^([%w_]+)=(.+)$")
    if var and rhs then _vars[var] = tostring(arith_eval(rhs)) end
  end; return 0
end
builtins["test"] = function(argv)
  if #argv < 2 then return 1 end
  local op = argv[2]
  if op == "-f" then return vfs.exists(lp.resolve(argv[3] or "", _cwd)) and 0 or 1
  elseif op == "-d" then return vfs.isdir(lp.resolve(argv[3] or "", _cwd)) and 0 or 1
  elseif op == "-z" then return (argv[3] == nil or argv[3] == "") and 0 or 1
  elseif op == "-n" then return (argv[3] and argv[3] ~= "") and 0 or 1
  elseif argv[3] == "=" or argv[3] == "==" then return (argv[2] == argv[4]) and 0 or 1
  elseif argv[3] == "!=" then return (argv[2] ~= argv[4]) and 0 or 1
  elseif argv[3] == "-eq" then return (tonumber(argv[2]) == tonumber(argv[4])) and 0 or 1
  elseif argv[3] == "-ne" then return (tonumber(argv[2]) ~= tonumber(argv[4])) and 0 or 1
  elseif argv[3] == "-lt" then return ((tonumber(argv[2]) or 0) < (tonumber(argv[4]) or 0)) and 0 or 1
  elseif argv[3] == "-gt" then return ((tonumber(argv[2]) or 0) > (tonumber(argv[4]) or 0)) and 0 or 1
  end
  return (argv[2] and argv[2] ~= "") and 0 or 1
end
builtins["["] = builtins["test"]
builtins["read"] = function(argv)
  local var = argv[2] or "REPLY"
  local line = _io.readline("")
  _vars[var] = line or ""; return 0
end
builtins["help"] = function()
  sh_writeln("\27[1;36mUniOS bash " .. VERSION .. " (" .. kernel.VERSION .. ")\27[0m")
  sh_writeln("")
  sh_writeln("\27[1mBuiltins:\27[0m " .. table.concat(lc.keys(builtins), ", "))
  sh_writeln("\27[1mFeatures:\27[0m pipes, redirects, $((arith)), functions, arrays, test/[")
  sh_writeln("")
  sh_writeln("\27[90mUse '<cmd> --help' for command help\27[0m")
  return 0
end

-- Command execution
local function exec_cmd(cmd, pipe_input)
  local argv = cmd.argv
  local name = argv[1]
  if not name or name == "" then return 0, "" end

  if _aliases[name] then
    local expanded = tokenise(_aliases[name])
    local new_argv = {}
    for _, t in ipairs(expanded) do if t[1] == TOK_WORD then new_argv[#new_argv+1] = t[2] end end
    for i = 2, #argv do new_argv[#new_argv+1] = argv[i] end
    argv = new_argv; name = argv[1]
  end

  -- User-defined function
  if _funcs[name] then
    local old_args = _G.arg
    _G.arg = { [0] = name }
    for i = 2, #argv do _G.arg[#_G.arg + 1] = argv[i] end
    local ok, result = pcall(function() return sh_exec_string(_funcs[name]) end)
    _G.arg = old_args
    return (ok and type(result) == "number") and result or (ok and 0 or 1), ""
  end

  local out_buf = {}
  local old_write = _io.write
  local redir_out_file = cmd.stdout and cmd.stdout.file
  local redir_out_append = cmd.stdout and cmd.stdout.append

  local function capture_write(s) out_buf[#out_buf + 1] = tostring(s) end

  local need_capture = cmd._pipe_out or redir_out_file
  if need_capture then _io.write = capture_write end

  local old_readline, old_read_char = _io.readline, _io.read_char
  if pipe_input and #pipe_input > 0 then
    local pi_pos = 1
    _io.read_char = function()
      if pi_pos > #pipe_input then return "\4" end
      local ch = pipe_input:sub(pi_pos, pi_pos); pi_pos = pi_pos + 1; return ch
    end
    _io.readline = function()
      local nl = pipe_input:find("\n", pi_pos, true)
      if not nl then
        if pi_pos > #pipe_input then return nil end
        local rest = pipe_input:sub(pi_pos); pi_pos = #pipe_input + 1; return rest
      end
      local line = pipe_input:sub(pi_pos, nl - 1); pi_pos = nl + 1; return line
    end
  end

  local code = 0
  if builtins[name] then
    code = builtins[name](argv) or 0
  else
    local path = lp.which(name, PATH_LIST)
    if not path then _io.write = old_write; _io.readline = old_readline; _io.read_char = old_read_char; sh_err(name .. ": command not found"); return 127, "" end
    local src = vfs.readfile(path)
    if not src then _io.write = old_write; _io.readline = old_readline; _io.read_char = old_read_char; sh_err(name .. ": read error"); return 1, "" end
    local fn, perr = load(src, "=" .. name, "t", _G)
    if not fn then _io.write = old_write; _io.readline = old_readline; _io.read_char = old_read_char; sh_err(name .. ": " .. tostring(perr)); return 1, "" end
    local old_arg = _G.arg
    local prog_arg = { [0] = name }
    for i = 2, #argv do prog_arg[#prog_arg + 1] = argv[i] end
    _G.arg = prog_arg
    local ok, result = xpcall(fn, function(e) return debug and debug.traceback(e, 2) or e end)
    _G.arg = old_arg
    if not ok then
      if need_capture then _io.write = old_write end
      sh_err(name .. ": " .. tostring(result))
      if need_capture then _io.write = capture_write end
      code = 1
    else code = type(result) == "number" and result or 0 end
  end

  _io.readline = old_readline; _io.read_char = old_read_char

  local output = ""
  if need_capture then
    _io.write = old_write
    output = table.concat(out_buf)
    if redir_out_file then
      local abs = lp.resolve(redir_out_file, _cwd)
      if abs ~= "/dev/null" then vfs.writefile(abs, output, redir_out_append) end
    end
  end
  return code, output
end

local function exec_pipeline(cmds)
  if #cmds == 1 then local c, _ = exec_cmd(cmds[1]); _last_exit = c; return c end
  local pipe_data = nil
  local last = 0
  for i, cmd in ipairs(cmds) do
    if i < #cmds then cmd._pipe_out = true end
    local code, output = exec_cmd(cmd, pipe_data)
    pipe_data = output; last = code; _last_exit = last
  end
  return last
end

local function exec_groups(groups)
  local last = 0
  for _, group in ipairs(groups) do
    local run = true
    if group.op == "&&" and last ~= 0 then run = false end
    if group.op == "||" and last == 0  then run = false end
    if run then last = exec_pipeline(group.cmds); _last_exit = last end
  end
  return last
end

function sh_exec_string(src)
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    line = lc.trim(line)
    if line ~= "" and line:sub(1,1) ~= "#" then
      -- Function definition: name() { ... }
      local fname = line:match("^([%w_]+)%s*%(%)%s*{%s*(.*)%s*}%s*$")
      if fname then
        local body = line:match("^[%w_]+%s*%(%)%s*{%s*(.*)%s*}%s*$")
        _funcs[fname] = body or ""
      else
        local toks = tokenise(line)
        local groups = parse(toks)
        exec_groups(groups)
      end
    end
  end
  return _last_exit
end

-- Prompt
local function prompt()
  local user = _env.USER or "user"
  local host = lc.trim(vfs.readfile("/etc/hostname") or "uni")
  local cwd_display = _cwd
  if _env.HOME and cwd_display:sub(1, #_env.HOME) == _env.HOME then
    cwd_display = "~" .. cwd_display:sub(#_env.HOME + 1)
  end
  local sym = (_env.USER == "root") and "#" or "$"
  return string.format("\27[1;32m%s@%s\27[0m:\27[1;34m%s\27[0m%s ", user, host, cwd_display, sym)
end

-- Line editor
local function readline_with_history()
  local line = {}
  local hist_idx = #_history + 1

  _io.write(prompt())
  kernel.signal.set_fg(_pid)

  while true do
    local ch = _io.read_char()
    if ch == "\n" or ch == "\r" then _io.write("\n"); break
    elseif ch == "\8" or ch == "\127" then
      if #line > 0 then table.remove(line); _io.write("\8 \8") end
    elseif ch == "\3" then _io.write("^C\n"); line = {}; break
    elseif ch == "\4" then
      if #line == 0 then _io.write("exit\n"); _running = false; sys("exit", 0) end
    elseif ch == "up" then
      if hist_idx > 1 then
        hist_idx = hist_idx - 1
        _io.write(string.rep("\8 \8", #line))
        line = {}; for c in (_history[hist_idx] or ""):gmatch(".") do line[#line+1] = c end
        _io.write(_history[hist_idx] or "")
      end
    elseif ch == "down" then
      if hist_idx <= #_history then
        hist_idx = hist_idx + 1
        _io.write(string.rep("\8 \8", #line))
        local hl = hist_idx > #_history and "" or (_history[hist_idx] or "")
        line = {}; for c in hl:gmatch(".") do line[#line+1] = c end
        _io.write(hl)
      end
    elseif ch == "\9" then
      local partial = table.concat(line)
      local word = partial:match("[^%s]+$") or ""
      local completions = {}
      local is_first = not partial:match("%S+%s")
      if is_first then
        for bi in pairs(builtins) do
          if bi:sub(1, #word) == word then completions[#completions+1] = bi end
        end
        for _, f in ipairs(vfs.list("/bin") or {}) do
          local n = f:gsub("%.lua$", "")
          if n:sub(1, #word) == word then completions[#completions+1] = n end
        end
      else
        pcall(function()
          local resolved = lp.resolve(word, _cwd)
          local dir = lp.dirname(resolved)
          local base = (word == "" or word:sub(-1) == "/") and "" or lp.basename(word)
          for _, f in ipairs(vfs.list(dir) or {}) do
            if base == "" or f:sub(1, #base) == base then completions[#completions+1] = f end
          end
        end)
      end
      if #completions == 1 then
        local suffix = completions[1]:sub(#(word:match("[^/]+$") or word) + 1)
        if suffix ~= "" then for c in suffix:gmatch(".") do line[#line+1] = c end; _io.write(suffix) end
      elseif #completions > 1 then
        table.sort(completions)
        _io.write("\n" .. table.concat(completions, "  ") .. "\n" .. prompt() .. table.concat(line))
      end
    elseif type(ch) == "string" and #ch == 1 then line[#line+1] = ch; _io.write(ch)
    end
  end
  return table.concat(line)
end

-- Source profiles
pcall(function() local src = vfs.readfile("/etc/profile"); if src then sh_exec_string(src) end end)
pcall(function() local rc = vfs.readfile((_env.HOME or "/root") .. "/.bashrc"); if rc then sh_exec_string(rc) end end)

if not _io.is_pty then
  do
    local raw = gpu.raw and gpu.raw()
    if raw then local rw, rh = raw.getResolution(); raw.setBackground(0); raw.setForeground(0xFFFFFF); raw.fill(1,1,rw,rh," ") end
    gpu.clear()
  end
end
_io.write("\27[1;36m" .. kernel.VERSION .. "\27[0m bash " .. VERSION .. "  |  type 'help'\n\n")

while _running do
  local ok, line = pcall(readline_with_history)
  if not ok then sh_err("readline: " .. tostring(line)); line = "" end
  line = lc.trim(line or "")
  if line ~= "" then
    if _history[#_history] ~= line then
      _history[#_history + 1] = line
      if #_history > 1000 then table.remove(_history, 1) end
    end
    pcall(function()
      local toks = tokenise(line)
      local groups = parse(toks)
      exec_groups(groups)
    end)
  end
  coroutine.yield()
end
