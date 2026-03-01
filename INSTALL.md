# UniOS — Installation Guide

> Every method of getting UniOS running, from the quickest one-liner to full manual control.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Method A — One-Line Bootstrap (Easiest)](#2-method-a--one-line-bootstrap-easiest)
3. [Method B — Installer Disk + TUI Wizard](#3-method-b--installer-disk--tui-wizard)
4. [Method C — From another UniOS (get --update)](#4-method-c--from-another-unios-get---update)
5. [Flashing the EEPROM](#5-flashing-the-eeprom)
6. [First Boot](#6-first-boot)
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
| **Internet Card** | Required for Methods A & C | — |

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
3. Download all 50 UniOS files from GitHub with a live progress bar
4. Write `/etc/hostname`, create `/root`, create standard dirs
5. Flash the EEPROM automatically (if one is present)

```
╔════════════════════════════════════════════════════════════════════╗
║            UniOS Bootstrap Installer                               ║
║            github.com/testingaccount132/Uni                        ║
╠════════════════════════════════════════════════════════════════════╣
║  ·  Internet card ready                                            ║
║  ✓  Target: My Disk (3a4f9b2c…)                                    ║
║  ·  Downloading 50 files from GitHub…                              ║
║  ✓  bios.lua (2847B)                                               ║
║  ✓  init.lua (1842B)                                               ║
║  ✓  kernel.lua (4201B)                                             ║
║      …                                                             ║
║  ✓  EEPROM flashed! (2847 bytes)                                   ║
║  ✓  Installation complete!  Reboot to start UniOS.                 ║
╠═══════════════════ ▕████████████████████▏ Done!  100% ════════════╣
╚════════════════════════════════════════════════════════════════════╝
```

### Step 2 — Reboot

```sh
reboot
```

UniOS boots. Done.

---

## 3. Method B — Installer Disk + TUI Wizard

Use this if you don't have an internet card, or if you're setting up multiple machines from one disk.

### Step 1 — Prepare the installer disk

Copy the full UniOS repository onto any OC floppy or HDD.

**From a PC:**
```bash
git clone https://github.com/testingaccount132/Uni.git
# Copy the Uni/ folder contents to an OC filesystem via mod support
```

**From an OpenOS machine with internet:**
```sh
wget -fq https://raw.githubusercontent.com/testingaccount132/Uni/main/tools/bootstrap.lua /tmp/bs.lua
lua /tmp/bs.lua
# This installs to the current machine; that disk becomes your installer
```

### Step 2 — Flash the Installer EEPROM

You need a dedicated "installer EEPROM" to make the disk bootable.

From any OC terminal:
```sh
# Copy installer_eeprom.lua to the EEPROM
lua /eeprom/flash.lua /installer/installer_eeprom.lua
```

Label it so you remember:
```sh
# OpenOS:
component.proxy(component.list("eeprom")()).setLabel("UniOS Installer")
```

### Step 3 — Assemble the installer computer

- Computer Case + CPU + RAM + GPU + Screen
- **Installer EEPROM** (from Step 2)
- **Installer disk** in a drive
- **Target HDD** (empty or to-be-overwritten) in another slot

### Step 4 — Power on and follow the wizard

The installer EEPROM launches the TUI automatically:

```
  ◉─────●─────○─────○─────○─────○
  Welcome  Disk  Options  Confirm  Install  Done
```

**Welcome** → Press `Enter`

**Disk selection** → Use `↑`/`↓` to pick your target HDD, `Enter` to confirm

**Options:**

| Setting | Key | Default |
|---------|-----|---------|
| Hostname | Type + `Enter` | `uni` |
| Flash EEPROM | `←`/`→` | Yes |
| Create /root | `←`/`→` | Yes |
| Wipe disk first | `←`/`→` | No |

**Confirm** → Press `Enter` to install, `Esc` to go back

**Progress** → Watch the live log and progress bar

**Done** → Press `Enter` to reboot automatically

### Step 5 — Swap and reboot

Remove the installer disk. The target HDD now has UniOS. Reboot.

---

## 4. Method C — From another UniOS (`get --update`)

If UniOS is already running and you want to update or clone to another disk:

### Update the current installation

```sh
get --update
```

This downloads every file from GitHub and overwrites your local copy. Safe to run at any time.

```
[1/50]  ✓  bios.lua (2847B)
[2/50]  ✓  init.lua (1842B)
...
✓  All 50 files updated.
```

### Check what has changed

```sh
get --check
```

```
  =  bin/ls.lua
  ≠  bin/grep.lua          ← this one differs from GitHub
  =  kernel/kernel.lua
...
2 file(s) differ. Run 'get --update' to sync.
```

### Download a single file

```sh
get bin/ls.lua                    # fetch from repo to /bin/ls.lua
get bin/ls.lua -o /tmp/ls_new.lua # fetch to a specific path
```

### Install to a second disk

```sh
# Mount the second disk, then clone
get --update   # updates current root
# Or use the TUI installer from within UniOS:
lua /installer/install.lua
```

---

## 5. Flashing the EEPROM

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
7. Sets the EEPROM label to `UniOS BIOS 1.0`

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
local f = io.open("/eeprom/bios.lua","rb")
e.set(f:read("*a")); f:close()
e.setLabel("UniOS BIOS 1.0")
print("Done.")
```

---

## 6. First Boot

A successful boot looks like:

```
UniOS BIOS 1.0
Scanning for boot device…
Boot device: 3a4f9b2c…
Loaded /boot/init.lua (1842 bytes)
Booting UniOS 1.0…

[init] Stage-1 boot, UniOS 1.0
[INFO] UniOS 1.0 (Helix) starting
[INFO] Boot device: 3a4f9b2c
[INFO] Loading VFS…
[INFO] Loading devfs…
[INFO] Loading tmpfs…
[INFO] Loading GPU driver…
[INFO] Loading keyboard driver…
[INFO] Loading disk driver…   hda [3a4f9b2c] label='My Disk'
[INFO] Loading process manager…
[INFO] Loading scheduler…
[INFO] Loading signal system…
[INFO] Loading syscall table…  24 syscalls registered
[INFO] Loading standard libraries…
[INFO] Running /etc/rc…
[INFO] rc: done
[INFO] Spawning PID 1…   /bin/sh.lua
[INFO] Kernel ready. Entering scheduler.

UniOS 1.0  |  type 'help' for builtins

root@uni:~#
```

You're in. Try `uname -a` or `ls /`.

---

## 7. Tools Reference

### `tools/bootstrap.lua`
Full installer. Downloads everything from GitHub. Run from OpenOS.
```sh
lua /tmp/bs.lua   # after wget
```

### `tools/get.lua`
File fetcher and updater. Available as `get` from within UniOS.
```sh
get --update              # update all files
get --check               # see what's outdated
get bin/ls.lua            # fetch one file
get https://… -o /path    # download any URL
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

### `installer/install.lua`
Full TUI installer wizard. Can be run from within UniOS or from the installer EEPROM.
```sh
lua /installer/install.lua
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
export EDITOR=vi
EOF
```

### Add a command
```lua
-- /bin/hello.lua
print("Hello, " .. (arg[2] or "world") .. "!")
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
- Run `get --update` from another machine then move the disk

### Black screen after power on
The BIOS crashed before output appeared — usually a corrupted EEPROM.
- Put back the original OC EEPROM, boot OpenOS
- Re-run `lua /eeprom/flash.lua --verify` to check
- Re-flash

### Shell appears but keyboard does nothing
- Right-click the screen to grab focus
- Verify a keyboard component is in the computer
- Run `ps` — the `sh` process should show `running`

### `kernel.require: module not found`
Files are missing. Fix:
```sh
# From OpenOS with internet:
get --update
# From another machine: copy missing files
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
- Check the bios.lua is under 4096 bytes: `wc -c /eeprom/bios.lua`
- Try the manual flash one-liner from Section 5

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
Offline:   Installer disk + installer_eeprom → TUI wizard
Update:    get --update
Check:     get --check

KEY FILES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
eeprom/bios.lua           flash this to boot UniOS
eeprom/flash.lua          EEPROM flasher TUI
tools/bootstrap.lua       one-click internet installer
tools/get.lua             fetch/update individual files
installer/install.lua     full TUI installer wizard

SHELL SHORTCUTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
↑/↓     history    Tab      complete    Ctrl+C   SIGINT
Ctrl+D  logout     reboot   restart     dmesg    kernel log
```
