# UniOS — Installation Guide

> Every method of getting UniOS running, from the quickest one-liner to manual control.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Method A — One-Line Bootstrap (Easiest)](#2-method-a--one-line-bootstrap-easiest)
3. [Method B — EEPROM Recovery (No OS needed)](#3-method-b--eeprom-recovery-no-os-needed)
4. [Flashing the EEPROM](#4-flashing-the-eeprom)
5. [First Boot](#5-first-boot)
6. [Keeping UniOS Updated](#6-keeping-unios-updated)
7. [Tools Reference](#7-tools-reference)
8. [Post-Install Setup](#8-post-install-setup)
9. [Troubleshooting](#9-troubleshooting)
10. [Uninstalling](#10-uninstalling)

---

## 1. Prerequisites

### Mods
- **OpenComputers** (1.7.10 or 1.12.2)

### Computer specs

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| Computer Case | Tier 2 | Tier 3 |
| CPU | Tier 2 | Tier 3 |
| RAM | 2× Tier 2 (1.5 MB) | 2× Tier 3 (3 MB) |
| GPU + Screen | Tier 2 | Tier 3 |
| HDD | Tier 2 (1 MB) | Tier 3 (2 MB) |
| EEPROM | 1× | 1× |
| **Internet Card** | Required | — |

> **RAM note:** UniOS needs at least 1.5 MB total. Tier 1 sticks (256 KB each) are not enough.

---

## 2. Method A — One-Line Bootstrap (Easiest)

**Requirements:** OpenOS running, internet card installed.

This downloads every UniOS file, installs it to your chosen disk, and flashes the EEPROM — all automatically with a graphical progress UI.

### Step 1 — Run the bootstrap

Paste this into your OpenOS terminal:

```sh
wget -fq https://raw.githubusercontent.com/testingaccount132/Uni/main/tools/bootstrap.lua /tmp/bs.lua && lua /tmp/bs.lua
```

That's it. The bootstrap will:

1. Detect your internet card
2. Show a disk selection menu if you have multiple writable disks
3. Download all UniOS files from GitHub with a live progress bar
4. Write `/etc/hostname`, create `/root`, create standard dirs
5. Flash the EEPROM automatically (if one is present)

### Step 2 — Reboot

```sh
reboot
```

UniOS boots. Done.

---

## 3. Method B — EEPROM Recovery (No OS needed)

If your UniOS BIOS is already flashed but boot files are missing or corrupted, the BIOS has a built-in recovery mode.

When critical files (`/boot/init.lua`, `/kernel/kernel.lua`, `/bin/sh.lua`) are missing, the BIOS automatically enters **Recovery Mode** and offers:

```
RECOVERY MODE
Missing: /boot/init.lua
Internet found.
[1] Bootstrap installer
[2] Reboot
[3] Halt
```

Press `1` to automatically download and run the bootstrap installer from GitHub. This reinstalls all system files without needing OpenOS.

**Requirements:** Internet card installed, UniOS BIOS flashed on EEPROM.

---

## 4. Flashing the EEPROM

The EEPROM holds the BIOS. Without flashing it, OC boots the default Lua BIOS which doesn't know about UniOS.

### Graphical flasher (recommended)

```sh
lua /eeprom/flash.lua
```

Or point it at a specific BIOS file:

```sh
lua /eeprom/flash.lua /eeprom/bios.lua
```

**What the flasher does:**
1. Scans for EEPROM component
2. Finds the BIOS file on any disk
3. Checks Lua syntax before writing
4. Backs up the current EEPROM to `/eeprom.bak`
5. Writes the new BIOS
6. Verifies the write byte-by-byte
7. Sets the EEPROM label to `UniOS BIOS 1.1`

**Flags:**

| Flag | Effect |
|------|--------|
| *(none)* | Flash `/eeprom/bios.lua` |
| `/path/to/bios.lua` | Flash a specific file |
| `--verify` | Compare current EEPROM to file, don't write |
| `--dump` | Print current EEPROM source to stdout |

### Manual one-liner

```lua
-- From an OpenOS Lua prompt:
local e = component.proxy(component.list("eeprom")())
local f = io.open("/eeprom/bios.min.lua","rb")
e.set(f:read("*a")); f:close()
e.setLabel("UniOS BIOS 1.1")
print("Done.")
```

> **Note:** Use `bios.min.lua` (3.7 KB) for EEPROM flashing — it's pre-minified and always fits within the 4 KB limit. The full `bios.lua` (9.7 KB) is the readable source but too large for EEPROM.

---

## 5. First Boot

A successful boot looks like:

```
UniOS BIOS 1.1
Scanning for boot device…
Boot device: 3a4f9b2c…
Loaded /boot/init.lua (1842 bytes)
Booting UniOS 1.0…

[init] Stage-1 boot, UniOS 1.0
[INFO] UniOS 1.0 (Helix) starting
[INFO] Boot device: 3a4f9b2c
[INFO] Loading VFS…
[INFO] Loading GPU driver…
[INFO] Loading keyboard driver…
[INFO] Loading disk driver…   hda [3a4f9b2c] label='My Disk'
[INFO] Spawning PID 1…   /bin/sh.lua
[INFO] Kernel ready. Entering scheduler.

UniOS 1.0  |  type 'help' for builtins

root@uni:~#
```

You're in. Try `uname -a` or `ls /`.

---

## 6. Keeping UniOS Updated

UniOS includes `apt`, a package manager that tracks file changes via the GitHub API.

### Update the system

```sh
apt update         # fetch latest file manifest with hashes from GitHub
apt upgrade        # download only changed or new files
```

### Install optional packages

```sh
apt install gui    # graphical desktop environment
apt install bash   # advanced shell with functions and arrays
apt install nano   # text editor (included by default)
```

### Check system status

```sh
apt status         # show tracked files, installed packages, memory
apt list           # list all available packages
apt search gui     # search for packages
```

---

## 7. Tools Reference

### `tools/bootstrap.lua`
Full installer. Downloads everything from GitHub. Run from OpenOS.
```sh
lua /tmp/bs.lua   # after wget
```

### `bin/apt.lua`
Package manager and system updater. Available as `apt` from within UniOS.
```sh
apt update               # fetch file manifest from GitHub
apt upgrade              # update changed files
apt install <package>    # install a package
apt remove <package>     # remove a package
apt list                 # list available packages
apt status               # system overview
```

### `eeprom/flash.lua`
EEPROM flasher with TUI.
```sh
lua /eeprom/flash.lua [bios_path] [--verify|--dump]
```

### `tools/uninstall.lua`
Remove all UniOS system files.
```sh
lua /tools/uninstall.lua
```

---

## 8. Post-Install Setup

### Change hostname
```sh
hostname mycomputer          # via command
echo "mycomputer" > /etc/hostname   # direct
```
Takes effect on next boot.

### Personalise the shell
```sh
cat >> /root/.shrc << 'EOF'
alias ll='ls -la'
alias ..='cd ..'
export EDITOR=nano
EOF
```

### Add a command
```lua
-- /bin/hello.lua
local gpu = kernel.drivers.gpu
gpu.write("Hello, " .. (arg[1] or "world") .. "!\n")
return 0
```
```sh
hello UniOS
```

### Mount a second disk
In `/etc/rc`:
```lua
local addr = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
kernel.vfs.mount("/data", kernel.vfs._wrap_oc_fs(component.proxy(addr), addr))
```

### View kernel log
```sh
dmesg           # all log entries
dmesg WARN      # only warnings
dmesg ERR       # only errors
```

### Check memory
```sh
free
```

### Check disk space
```sh
df
```

---

## 9. Troubleshooting

### `No bootable filesystem found`
The BIOS can't find `/boot/init.lua` on any disk.
- Make sure the UniOS HDD is inserted in the computer case
- If BIOS is flashed, it will enter Recovery Mode automatically
- Run `apt upgrade` from another machine then move the disk

### Black screen after power on
The BIOS crashed before output appeared — usually a corrupted EEPROM.
- Put back the original OC EEPROM, boot OpenOS
- Re-run `lua /eeprom/flash.lua --verify` to check
- Re-flash with `lua /eeprom/flash.lua`

### Shell appears but keyboard does nothing
- Right-click the screen to grab focus
- Verify a keyboard component is in the computer
- Run `ps` — the `sh` process should show `running`

### `kernel.require: module not found`
Files are missing. Fix:
```sh
# From UniOS with internet:
apt update && apt upgrade
# From OpenOS: re-run the bootstrap
```

### Out of memory / crashes
Install more RAM (at least 2× Tier 2). Check usage with:
```sh
free
dmesg ERR
```

### Bootstrap says `no internet card`
Install an Internet Card (Tier 1 is sufficient) into a card slot on the computer case.

### `EEPROM flash failed`
- Make sure an EEPROM is physically installed
- Use `bios.min.lua` — it's pre-minified to fit the 4 KB EEPROM limit
- Try the manual flash one-liner from Section 4

---

## 10. Uninstalling

### Remove UniOS files
```sh
# From OpenOS on the target machine:
lua /tools/uninstall.lua
```
Prompts for confirmation, removes all system files, optionally restores `/eeprom.bak`.

### Restore original EEPROM manually
```sh
# From OpenOS:
local e = component.proxy(component.list("eeprom")())
local f = io.open("/eeprom.bak","rb")
e.set(f:read("*a")); f:close()
print("Restored.")
```

---

## Quick Reference

```
INSTALL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Easiest:   wget -fq …/tools/bootstrap.lua /tmp/bs.lua && lua /tmp/bs.lua
Recovery:  BIOS detects missing files → downloads bootstrap automatically
Update:    apt update && apt upgrade

KEY FILES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
eeprom/bios.min.lua       flash this to boot UniOS (minified, fits 4KB)
eeprom/bios.lua           readable BIOS source (too large for EEPROM)
eeprom/flash.lua          EEPROM flasher TUI
tools/bootstrap.lua       one-click internet installer
bin/apt.lua               package manager & system updater

SHELL SHORTCUTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
↑/↓     history    Tab      complete    Ctrl+C   SIGINT
Ctrl+D  logout     reboot   restart     dmesg    kernel log
```

---

<div align="center">Vibecoded with <a href="https://cursor.com">Cursor</a> AI</div>
