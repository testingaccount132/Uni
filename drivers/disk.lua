-- UniOS Disk Driver
-- Scans all filesystem components and registers them as block devices
-- under /dev/hdX.  The VFS mounts them separately.

local disk = {}

local _disks = {}  -- addr → { proxy, label, dev_name }

function disk.init()
  local idx = 0
  for addr, _ in component.list("filesystem") do
    local fs    = component.proxy(addr)
    local label = fs.getLabel and fs.getLabel() or ("disk" .. idx)
    local dname = "hd" .. string.char(97 + idx)  -- hda, hdb, …

    _disks[addr] = { proxy = fs, label = label, name = dname, addr = addr }

    -- Register in devfs
    kernel.devfs.register(dname, {
      read  = function() return nil end,  -- block devices aren't read raw
      write = function() return false end,
      _fs   = fs,
      _label = label,
    })

    kernel.info("disk: " .. dname .. " [" .. addr:sub(1,8) .. "] label='" .. label .. "'")
    idx = idx + 1
  end
end

--- Return the OC filesystem proxy for a device name (e.g. "hda").
function disk.get_by_name(name)
  for _, d in pairs(_disks) do
    if d.name == name then return d.proxy, d end
  end
  return nil
end

--- Return the OC filesystem proxy for an address prefix.
function disk.get_by_addr(prefix)
  for addr, d in pairs(_disks) do
    if addr:sub(1, #prefix) == prefix then return d.proxy, d end
  end
  return nil
end

--- List all detected disks.
function disk.list()
  local out = {}
  for _, d in pairs(_disks) do out[#out + 1] = d end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function disk.hotplug(ev)
  if ev[1] == "component_added" and ev[3] == "filesystem" then
    -- Re-scan
    disk.init()
  end
end

return disk
