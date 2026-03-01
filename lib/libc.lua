-- UniOS libc – Standard C-like utility library
-- Provides string utils, table utils, math helpers, error handling,
-- and the POSIX-flavoured C standard library subset.

local libc = {}

-- ── String utilities ──────────────────────────────────────────────────────────

function libc.split(str, sep, plain)
  sep = sep or "%s"
  local parts = {}
  local pattern = plain and sep or sep
  local i = 1
  while true do
    local s, e = str:find(plain and sep or pattern, i, plain)
    if not s then
      parts[#parts + 1] = str:sub(i)
      break
    end
    parts[#parts + 1] = str:sub(i, s - 1)
    i = e + 1
  end
  return parts
end

function libc.trim(s)
  return s:match("^%s*(.-)%s*$")
end

function libc.ltrim(s)
  return s:match("^%s*(.+)$") or ""
end

function libc.rtrim(s)
  return s:match("^(.-)[%s]+$") or s
end

function libc.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function libc.ends_with(s, suffix)
  return suffix == "" or s:sub(- #suffix) == suffix
end

function libc.pad_right(s, n, ch)
  ch = ch or " "
  s = tostring(s)
  while #s < n do s = s .. ch end
  return s
end

function libc.pad_left(s, n, ch)
  ch = ch or " "
  s = tostring(s)
  while #s < n do s = ch .. s end
  return s
end

function libc.repeat_str(s, n)
  return string.rep(s, n)
end

-- ── Table utilities ───────────────────────────────────────────────────────────

function libc.keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  return ks
end

function libc.values(t)
  local vs = {}
  for _, v in pairs(t) do vs[#vs + 1] = v end
  return vs
end

function libc.map(t, fn)
  local out = {}
  for i, v in ipairs(t) do out[i] = fn(v, i) end
  return out
end

function libc.filter(t, fn)
  local out = {}
  for _, v in ipairs(t) do if fn(v) then out[#out + 1] = v end end
  return out
end

function libc.reduce(t, fn, init)
  local acc = init
  for _, v in ipairs(t) do acc = fn(acc, v) end
  return acc
end

function libc.copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

function libc.deep_copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[libc.deep_copy(k)] = libc.deep_copy(v) end
  return setmetatable(out, getmetatable(t))
end

function libc.contains(t, val)
  for _, v in ipairs(t) do if v == val then return true end end
  return false
end

-- ── Math helpers ──────────────────────────────────────────────────────────────

function libc.clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

function libc.lerp(a, b, t)
  return a + (b - a) * t
end

function libc.round(n, places)
  places = places or 0
  local m = 10 ^ places
  return math.floor(n * m + 0.5) / m
end

function libc.human_size(bytes)
  local units = { "B", "KB", "MB", "GB", "TB" }
  local i = 1
  local v = bytes
  while v >= 1024 and i < #units do
    v = v / 1024; i = i + 1
  end
  return string.format("%.1f %s", v, units[i])
end

-- ── Error handling ────────────────────────────────────────────────────────────

function libc.try(fn, ...)
  local ok, err = pcall(fn, ...)
  return ok, err
end

function libc.assert(cond, msg, level)
  if not cond then
    error(msg or "assertion failed", (level or 1) + 1)
  end
  return cond
end

-- ── Time ──────────────────────────────────────────────────────────────────────

function libc.time()
  return computer.uptime()
end

function libc.sleep(sec)
  -- Cooperative sleep: yield to scheduler
  coroutine.yield({ "sleep", sec })
end

-- ── Environment ───────────────────────────────────────────────────────────────

function libc.getenv(key)
  return sys("getenv", key)
end

function libc.setenv(key, val)
  sys("setenv", key, val)
end

function libc.getcwd()
  return sys("getcwd")
end

function libc.chdir(path)
  return sys("chdir", path)
end

function libc.getpid()
  return sys("getpid")
end

function libc.getppid()
  return sys("getppid")
end

function libc.exit(code)
  sys("exit", code or 0)
end

-- ── Install globals ───────────────────────────────────────────────────────────

_G.libc = libc

-- POSIX-ish shortcuts
_G.getenv  = libc.getenv
_G.setenv  = libc.setenv
_G.getcwd  = libc.getcwd
_G.chdir   = libc.chdir
_G.getpid  = libc.getpid
_G.sleep   = libc.sleep
_G.exit    = libc.exit

return libc
