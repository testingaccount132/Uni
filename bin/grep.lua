-- grep – search for patterns in files

local vfs = kernel.vfs
local lp  = kernel.require("lib.libpath")
local gpu = kernel.drivers.gpu
local cwd = sys("getcwd")

local ignore_case = false
local invert      = false
local line_nums   = false
local count_only  = false
local pattern     = nil
local files       = {}

local i = 2
while arg[i] do
  if arg[i] == "-i" then ignore_case = true
  elseif arg[i] == "-v" then invert = true
  elseif arg[i] == "-n" then line_nums = true
  elseif arg[i] == "-c" then count_only = true
  elseif arg[i] == "--help" then
    print("Usage: grep [-ivcn] pattern [file...]"); return 0
  elseif not pattern then
    pattern = arg[i]
  else
    files[#files+1] = arg[i]
  end
  i = i + 1
end

if not pattern then print("grep: missing pattern"); return 1 end

local function grep_file(path, label)
  local src, err
  if path == "-" then
    -- stdin
    src = kernel.drivers.keyboard.readline() or ""
  else
    local abs = lp.resolve(path, cwd)
    src, err = vfs.readfile(abs)
    if not src then print("grep: " .. path .. ": " .. tostring(err)); return 0, 1 end
  end

  local match_count = 0
  local lno = 0
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    lno = lno + 1
    local search_line = ignore_case and line:lower() or line
    local search_pat  = ignore_case and pattern:lower() or pattern
    local matched = search_line:find(search_pat) ~= nil
    if invert then matched = not matched end
    if matched then
      match_count = match_count + 1
      if not count_only then
        local prefix = ""
        if label then prefix = label .. ":" end
        if line_nums then prefix = prefix .. lno .. ":" end
        -- Highlight match
        local highlighted = line:gsub("(" .. pattern .. ")", "\27[1;31m%1\27[0m")
        gpu.write(prefix .. highlighted .. "\n")
      end
    end
  end

  if count_only then
    local prefix = label and (label .. ":") or ""
    print(prefix .. match_count)
  end

  return match_count, 0
end

local total = 0
local exit_code = 0

if #files == 0 then
  local c, ec = grep_file("-", nil)
  total = total + c; if ec ~= 0 then exit_code = ec end
else
  local show_label = #files > 1
  for _, f in ipairs(files) do
    local c, ec = grep_file(f, show_label and f or nil)
    total = total + c; if ec ~= 0 then exit_code = ec end
  end
end

return (total > 0 and exit_code == 0) and 0 or (exit_code ~= 0 and exit_code or 1)
