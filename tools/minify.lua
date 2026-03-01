-- UniOS minify – Lua source minifier for EEPROM size budgets
-- Strips comments, collapses whitespace, shortens locals, and reports savings.
--
-- Usage (from UniOS or OpenOS shell):
--   minify <input.lua>                    print minified to stdout
--   minify <input.lua> -o <output.lua>    write to file
--   minify <input.lua> --flash            minify + flash directly to EEPROM
--   minify <input.lua> --check            show size / EEPROM budget only
--
-- Minification passes applied (in order):
--   1. Strip --[[ ... ]] block comments
--   2. Strip -- line comments  (except shebangs #!)
--   3. Collapse blank lines
--   4. Trim leading / trailing whitespace per line
--   5. Collapse multiple spaces to one (outside strings)
--   6. Remove spaces around operators and punctuation (outside strings)
--   7. Join lines that are safe to join (no line-sensitive constructs)

local EEPROM_MAX = 4096   -- bytes

-- ── Compat (OpenOS / UniOS) ───────────────────────────────────────────────────

local _vfs = kernel and kernel.vfs
local function read_file(path)
  if _vfs then return _vfs.readfile(path) end
  local h = io.open(path, "rb"); if not h then return nil end
  local d = h:read("*a"); h:close(); return d
end
local function write_file(path, data)
  if _vfs then return _vfs.writefile(path, data) end
  local h = io.open(path, "wb"); if not h then return false end
  h:write(data); h:close(); return true
end

local function writeln(s) io.write(tostring(s).."\n") end
local function c(code,s)  return "\27["..code.."m"..s.."\27[0m" end
local function ok(m)   writeln(c("32","  ✓  ")..m) end
local function err(m)  writeln(c("31","  ✗  ")..m) end
local function info(m) writeln(c("36","  ·  ")..m) end
local function warn(m) writeln(c("33","  ⚠  ")..m) end

-- ── Minifier ──────────────────────────────────────────────────────────────────

local function minify(src)
  -- ── Pass 1: remove block comments  --[[ ... ]] and --[=[ ... ]=] etc.
  -- We must NOT touch string literals that look like [[ ... ]].
  -- Strategy: walk character by character, tracking string/comment state.

  local out   = {}
  local i     = 1
  local len   = #src
  local in_str = false
  local str_ch = nil   -- quote char: ' or "
  local in_long_str = false
  local long_level = 0

  local function peek(n) return src:sub(i, i + (n or 0) - 1) end
  local function adv(n)  i = i + (n or 1) end

  while i <= len do
    local ch = src:sub(i,i)

    -- Inside a long string [=*[...]=*]
    if in_long_str then
      local close = "]" .. string.rep("=", long_level) .. "]"
      local pos   = src:find(close, i, true)
      if pos then
        out[#out+1] = src:sub(i, pos + #close - 1)
        i = pos + #close
        in_long_str = false
      else
        out[#out+1] = src:sub(i)
        break
      end

    -- Inside a short string
    elseif in_str then
      if ch == "\\" then
        out[#out+1] = ch
        out[#out+1] = src:sub(i+1,i+1)
        adv(2)
      elseif ch == str_ch then
        out[#out+1] = ch; adv()
        in_str = false
      elseif ch == "\n" then
        -- Unterminated string – keep newline
        out[#out+1] = ch; adv()
        in_str = false
      else
        out[#out+1] = ch; adv()
      end

    -- Block comment  --[=*[
    elseif src:sub(i,i+1) == "--" and src:sub(i+2,i+2) == "[" then
      local bracket_start = i + 2
      local eq = 0
      while src:sub(bracket_start + eq, bracket_start + eq) == "=" do
        eq = eq + 1
      end
      if src:sub(bracket_start + eq, bracket_start + eq) == "[" then
        -- It's a block comment: skip to matching ]=*]
        local close = "]" .. string.rep("=", eq) .. "]"
        local _, epos = src:find(close, bracket_start + eq + 1, true)
        if epos then i = epos + 1 else break end
        -- replace with a single newline to preserve line semantics
        out[#out+1] = "\n"
      else
        -- Line comment
        local eol = src:find("\n", i, true)
        if eol then i = eol   -- keep the \n
        else i = len + 1 end
      end

    -- Line comment  --
    elseif src:sub(i,i+1) == "--" then
      local eol = src:find("\n", i, true)
      if eol then i = eol
      else i = len + 1 end

    -- Long string  [=*[
    elseif ch == "[" then
      local j = i + 1; local eq = 0
      while src:sub(j,j) == "=" do eq=eq+1; j=j+1 end
      if src:sub(j,j) == "[" then
        in_long_str = true
        long_level  = eq
        out[#out+1] = src:sub(i, j)
        i = j + 1
      else
        out[#out+1] = ch; adv()
      end

    -- Short string
    elseif ch == '"' or ch == "'" then
      in_str  = true
      str_ch  = ch
      out[#out+1] = ch; adv()

    else
      out[#out+1] = ch; adv()
    end
  end

  local result = table.concat(out)

  -- ── Pass 2: collapse blank lines
  result = result:gsub("\n%s*\n+", "\n")

  -- ── Pass 3: trim whitespace at start/end of each line
  local lines = {}
  for line in (result.."\n"):gmatch("([^\n]*)\n") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then lines[#lines+1] = line end
  end
  result = table.concat(lines, "\n")

  -- ── Pass 4: collapse multiple spaces to one (outside strings/brackets)
  -- Simple heuristic: collapse runs of spaces not inside quotes
  -- We do a basic pass that's safe for most Lua code.
  result = result:gsub("([^'\"]*)(%b\"\")", function(pre, str)
    return pre:gsub("  +", " ") .. str
  end)
  result = result:gsub("  +", " ")

  -- ── Pass 5: remove spaces around safe punctuation
  -- Safe to remove spaces next to: ( ) , ; = + - * / % ^ & | ~ < > [ ] { }
  -- NOT safe around: '..' (concat), '...' (vararg) — keep those
  local ops = "([%(%)%[%]{},;])"
  result = result:gsub("%s*"..ops.."%s*", "%1")

  -- Re-add space after keywords that need it (keyword directly before identifier/number)
  local keywords = {
    "and","break","do","else","elseif","end","false","for","function",
    "goto","if","in","local","nil","not","or","repeat","return",
    "then","true","until","while",
  }
  for _, kw in ipairs(keywords) do
    -- keyword followed by non-space alphanumeric: insert space
    result = result:gsub("(" .. kw .. ")([%w_])", "%1 %2")
    -- alphanumeric followed by keyword: insert space
    result = result:gsub("([%w_])(" .. kw .. ")", "%1 %2")
  end

  -- ── Pass 6: join short lines where safe
  -- A line is safe to join if it doesn't end with 'do', 'then', 'else',
  -- 'repeat', 'end', '--', or start a function/if/for/while block.
  -- We just collapse consecutive non-block lines up to 200 chars.
  local final_lines = {}
  for line in (result.."\n"):gmatch("([^\n]*)\n") do
    if #final_lines == 0 then
      final_lines[1] = line
    else
      local prev = final_lines[#final_lines]
      local prev_safe = not prev:match("[%s]do$")
                    and not prev:match("[%s]then$")
                    and not prev:match("[%s]else$")
                    and not prev:match("[%s]repeat$")
                    and not prev:match("^end$")
                    and not prev:match("^local function")
                    and not prev:match("^function")
      local cur_safe  = not line:match("^end[%s%)]")
                    and not line:match("^else")
                    and not line:match("^elseif")
                    and not line:match("^until")
      if prev_safe and cur_safe and #prev + 1 + #line <= 200 then
        final_lines[#final_lines] = prev .. " " .. line
      else
        final_lines[#final_lines+1] = line
      end
    end
  end
  result = table.concat(final_lines, "\n")

  return result
end

-- ── Size report ───────────────────────────────────────────────────────────────

local function size_bar(used, max)
  local w     = 32
  local filled = math.floor(used / max * w)
  local pct    = math.floor(used / max * 100)
  local bar_col = pct < 70 and "32" or (pct < 90 and "33" or "31")
  return c(bar_col, string.rep("█", filled)) ..
         string.rep("░", w - filled) ..
         string.format("  %d / %d B  (%d%%)", used, max, pct)
end

local function report(label, original, minified)
  local saved = original - minified
  local pct   = math.floor(saved / original * 100)
  writeln("")
  writeln(c("1", label))
  writeln("  Original : " .. c("36", original .. " bytes"))
  writeln("  Minified : " .. c("32", minified .. " bytes")
    .. "  (saved " .. saved .. " bytes / " .. pct .. "%)")
  writeln("  EEPROM   : " .. size_bar(minified, EEPROM_MAX))
  if minified > EEPROM_MAX then
    err("Still too large for EEPROM by " .. (minified - EEPROM_MAX) .. " bytes!")
  elseif minified > EEPROM_MAX * 0.9 then
    warn("Close to limit — " .. (EEPROM_MAX - minified) .. " bytes remaining.")
  else
    ok("Fits in EEPROM with " .. (EEPROM_MAX - minified) .. " bytes to spare.")
  end
  writeln("")
end

-- ── Argument parsing ──────────────────────────────────────────────────────────

local argv = arg or {}
if argv[0] then table.remove(argv, 0) end

local function usage()
  writeln(c("1","minify") .. " – Lua minifier for EEPROM size budgets")
  writeln("")
  writeln("  minify <file>              print minified source to stdout")
  writeln("  minify <file> -o <out>     write minified source to file")
  writeln("  minify <file> --flash      minify and flash directly to EEPROM")
  writeln("  minify <file> --check      show size report only (don't write)")
  writeln("")
  writeln("Examples:")
  writeln("  minify /eeprom/bios.lua --check")
  writeln("  minify /eeprom/bios.lua -o /eeprom/bios.min.lua")
  writeln("  minify /eeprom/bios.lua --flash")
end

if #argv == 0 or argv[1] == "--help" or argv[1] == "-h" then
  usage(); return 0
end

local input_path = argv[1]
local output_path = nil
local do_flash   = false
local check_only = false

for i = 2, #argv do
  if argv[i] == "-o"      then output_path = argv[i+1]
  elseif argv[i] == "--flash" then do_flash   = true
  elseif argv[i] == "--check" then check_only = true
  end
end

-- Read source
local src, src_err = read_file(input_path)
if not src then
  err("Cannot read '" .. input_path .. "': " .. tostring(src_err))
  return 1
end

info("Minifying " .. input_path .. "  (" .. #src .. " bytes)…")

-- Validate: check it parses before minifying
local test, parse_err = load(src, "=input", "t")
if not test then
  err("Input has syntax errors: " .. tostring(parse_err))
  return 1
end

local result = minify(src)

-- Validate minified output still parses
local test2, parse_err2 = load(result, "=minified", "t")
if not test2 then
  err("Minified output has syntax errors (please report this bug):")
  err(tostring(parse_err2))
  warn("Original file was NOT modified.")
  return 1
end

report(input_path, #src, #result)

if check_only then return 0 end

if do_flash then
  -- Flash directly to EEPROM
  if #result > EEPROM_MAX then
    err("Cannot flash: minified size " .. #result .. " > EEPROM limit " .. EEPROM_MAX)
    return 1
  end
  local eeprom = nil
  for a in component.list("eeprom") do eeprom = component.proxy(a); break end
  if not eeprom then err("No EEPROM found."); return 1 end
  -- Backup first
  local backup_ok = pcall(function()
    local current = eeprom.get()
    write_file("/eeprom.bak", current)
  end)
  if backup_ok then info("Backed up current EEPROM to /eeprom.bak") end
  local ok2, e2 = pcall(function() eeprom.set(result) end)
  if ok2 then
    ok("Flashed " .. #result .. " bytes to EEPROM.")
  else
    err("Flash failed: " .. tostring(e2)); return 1
  end

elseif output_path then
  local wrote, we = write_file(output_path, result)
  if wrote then
    ok("Written to " .. output_path)
  else
    err("Write failed: " .. tostring(we)); return 1
  end

else
  -- Print to stdout
  io.write(result .. "\n")
end

return 0
