# UniOS

<div align="center">

```
  ██╗   ██╗███╗  ██╗██╗      ██████╗  ███████╗
  ██║   ██║████╗ ██║██║     ██╔═══██╗██╔════╝
  ██║   ██║██╔██╗██║██║     ██║   ██║╚══███╔╝
  ██║   ██║██║╚████║██║     ██║   ██║  ███╔╝
  ╚██████╔╝██║ ╚███║███████╗╚██████╔╝███████╗
   ╚═════╝ ╚═╝  ╚══╝╚══════╝ ╚═════╝ ╚══════╝
```

**A modular, UNIX-style operating system for [OpenComputers](https://www.curseforge.com/minecraft/mc-mods/opencomputers)**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenComputers](https://img.shields.io/badge/OpenComputers-1.7%2F1.12-orange.svg)](https://www.curseforge.com/minecraft/mc-mods/opencomputers)
[![Lua](https://img.shields.io/badge/Lua-5.3-blueviolet.svg)](https://www.lua.org/)
[![Version](https://img.shields.io/badge/version-1.0-green.svg)](https://github.com/testingaccount132/Uni/releases)

[**Installation Guide**](INSTALL.md) · [**Quick Start**](#quick-start) · [**Architecture**](#architecture) · [**Contributing**](#contributing)

</div>

---

## What is UniOS?

UniOS is a from-scratch operating system for the OpenComputers Minecraft mod, built with UNIX philosophy at its core — every component is small, focused, and replaceable.

It ships with:
- A **multi-stage bootloader** (EEPROM BIOS → Stage-1 init → Kernel)
- A **modular kernel** with a process manager, cooperative scheduler, signal system, and system call interface
- A **Virtual Filesystem** with mount table, devfs (`/dev`), and tmpfs (`/tmp`)
- **Hardware drivers** for GPU (with ANSI terminal emulation), keyboard, and disk
- A **full UNIX shell** with pipes, redirects, variables, history, tab-completion, and aliases
- **20+ standard utilities**: ls, cat, cp, mv, rm, mkdir, grep, ps, kill, df, free, uptime, uname, wc, head, tail, touch, clear...
- A **beautiful TUI installer** and **EEPROM flasher** with progress bars and live logs

---

## Quick Start

### Requirements

| Component | Minimum |
|-----------|---------|
| Computer Case | Tier 2 |
| CPU | Tier 2 |
| RAM | 2× Tier 2 (1.5 MB) |
| GPU + Screen | Tier 2 |
| HDD | Tier 2 |
| EEPROM | 1× |
| Internet Card | For bootstrap method |

### Install — one command

Paste this in OpenOS with an internet card:

```sh
wget -q https://raw.githubusercontent.com/testingaccount132/Uni/main/tools/bootstrap.lua /tmp/bs.lua && lua /tmp/bs.lua
```

The bootstrap downloads every file, installs it to your disk, flashes the EEPROM — then just `reboot`.

### Or use the offline TUI installer

Flash `installer/installer_eeprom.min.lua` (pre-minified, always fits) onto a blank EEPROM, put the UniOS disk + target disk in the computer, and power on. A 6-screen wizard handles everything.

### Keep UniOS updated

From within UniOS:

```sh
get --update       # pull latest from GitHub
get --check        # see what's changed
get bin/ls.lua     # update a single file
```

> **Full installation guide with all methods:** [INSTALL.md](INSTALL.md)

---

## Screenshots

```
UniOS BIOS 1.1                                                       BIOS boot
Scanning for boot device...
Boot device: 3a4f9b2c...
Loaded /boot/init.lua (1024 B)
Booting UniOS 1.1...

[ 0.02] INFO  UniOS 1.0 (Helix) starting
[ 0.02] INFO  Boot device: 3a4f9b2c...
[ 0.02] INFO  Free memory: 512K / 1024K
[ 0.03] INFO  Load VFS
[ 0.05] INFO  OK   VFS
[ 0.06] INFO  Load driver:gpu
[ 0.09] INFO  OK   driver:gpu
[ 0.10] INFO  Spawning PID 1
[ 0.12] INFO  Kernel ready in 0.12s. Entering scheduler.

UniOS 1.0  |  type 'help' for builtins

root@uni:~# ls -la /
drwxr-xr-x       0  bin
drwxr-xr-x       0  boot
drwxr-xr-x       0  drivers
drwxr-xr-x       0  eeprom
drwxr-xr-x       0  etc
drwxr-xr-x       0  fs
drwxr-xr-x       0  installer
drwxr-xr-x       0  kernel
drwxr-xr-x       0  lib
drwxr-xr-x       0  root
drwxr-xr-x       0  tmp

root@uni:~# uname -a
UniOS uni 1.0.0 #1 UniOS 1.0 oc

root@uni:~# ps
PID    PPID   STATE    UID        COMMAND
──────────────────────────────────────────────────
1      0      running  0          init
2      1      running  0          sh
```

---

## Architecture

```
  ┌─────────────────────────────────────────────────┐
  │              EEPROM BIOS  (bios.lua)             │
  │  Scans disks → finds /boot/init.lua → loads it  │
  └───────────────────┬─────────────────────────────┘
                      │
  ┌───────────────────▼─────────────────────────────┐
  │          Stage-1 Init  (boot/init.lua)           │
  │  Minimal require → mounts root → loads kernel   │
  └───────────────────┬─────────────────────────────┘
                      │
  ┌───────────────────▼─────────────────────────────┐
  │           Kernel  (kernel/kernel.lua)            │
  │                                                  │
  │  VFS ──── devfs (/dev)                          │
  │       └── tmpfs (/tmp)                          │
  │                                                  │
  │  Drivers: GPU · Keyboard · Disk                 │
  │                                                  │
  │  Process Manager ── Scheduler (round-robin)     │
  │  Signal System ──── Syscall Interface           │
  │                                                  │
  │  Libraries: libc · libio · libpath · libterm    │
  └───────────────────┬─────────────────────────────┘
                      │  runs /etc/rc, spawns PID 1
  ┌───────────────────▼─────────────────────────────┐
  │              Shell  (bin/sh.lua)   PID 1         │
  │  Builtins · External cmds · Pipes · Redirects   │
  └─────────────────────────────────────────────────┘
```

### Module Map

```
uni/
├── eeprom/
│   ├── bios.lua              ← Flash onto EEPROM to boot UniOS
│   └── flash.lua             ← Graphical EEPROM flasher tool
├── boot/
│   └── init.lua              ← Stage-1 bootloader
├── kernel/
│   ├── kernel.lua            ← Kernel entry & boot sequence
│   ├── process.lua           ← spawn / fork / exit / wait
│   ├── scheduler.lua         ← Cooperative round-robin scheduler
│   ├── signal.lua            ← UNIX signals + OC event dispatch
│   └── syscall.lua           ← System call table
├── fs/
│   ├── vfs.lua               ← Virtual filesystem + mount table
│   ├── devfs.lua             ← /dev filesystem
│   └── tmpfs.lua             ← In-memory /tmp filesystem
├── drivers/
│   ├── gpu.lua               ← ANSI terminal emulator
│   ├── keyboard.lua          ← Keyboard input + readline
│   └── disk.lua              ← Disk enumeration → /dev/hdX
├── lib/
│   ├── libc.lua              ← C-standard-like utility library
│   ├── libio.lua             ← I/O streams, installs `io`
│   ├── libpath.lua           ← Path utilities (resolve, which…)
│   ├── libterm.lua           ← ANSI colours, boxes, spinner
│   └── pkg.lua               ← Module loader, overrides `require`
├── bin/                      ← Standard utilities
│   ├── sh.lua                ← Interactive UNIX shell
│   ├── ls.lua  cat.lua  cp.lua  mv.lua  rm.lua  mkdir.lua
│   ├── grep  ps  kill  df  free  uptime  uname  wc
│   ├── head  tail  clear  reboot  dmesg  which  env
│   ├── hostname  ...
│   └── (drop any .lua file here to add a command)
├── etc/
│   ├── hostname              ← "uni"
│   ├── passwd                ← User database
│   ├── rc                    ← Boot script (Lua)
│   └── profile               ← Shell profile (sh syntax)
├── installer/
│   ├── install.lua           ← Full TUI installer wizard
│   └── installer_eeprom.lua  ← Bootable installer EEPROM BIOS
├── tools/
│   ├── bootstrap.lua         ← One-command internet installer (run from OpenOS)
│   ├── get.lua               ← Fetch/update files from GitHub (run from UniOS)
│   └── uninstall.lua         ← Remove UniOS files + restore EEPROM
├── INSTALL.md                ← Full installation guide
└── README.md
```

---

## Shell Features

| Feature | Example |
|---------|---------|
| Variables | `FOO=bar; echo $FOO` |
| Quoting | `echo "hello world"` · `echo 'no $expand'` |
| Pipes | `cat /etc/passwd \| grep root` |
| Redirection | `echo hi > /tmp/f` · `cat >> /tmp/f` |
| Background | `longprocess &` |
| Sequences | `cmd1; cmd2` |
| And/Or | `test && ok \|\| fail` |
| History | `↑` / `↓` keys |
| Tab complete | Commands + filenames |
| Aliases | `alias ll='ls -la'` |
| Env export | `export PATH=/bin:/usr/bin` |
| Source | `source /etc/profile` |

### Builtins

`cd`, `pwd`, `echo`, `export`, `unset`, `set`, `alias`, `unalias`, `source` (`.`), `exit`, `history`, `type`, `true`, `false`, `help`

---

## Extending UniOS

### Add a command

```lua
-- /bin/hello.lua
print("Hello, " .. (arg[2] or "world") .. "!")
return 0
```

```sh
hello UniOS
# → Hello, UniOS!
```

### Add a library

```lua
-- /lib/mylib.lua
local M = {}
function M.greet(name) return "Hi, " .. name end
return M
```

```lua
-- Anywhere in userland:
local mylib = require("lib.mylib")
print(mylib.greet("root"))
```

### Write a daemon

In `/etc/rc`:

```lua
local src = kernel.vfs.readfile("/usr/bin/mydaemon.lua")
if src then
  kernel.process.spawn(src, "mydaemon", { uid=0, cwd="/" })
end
```

### Mount a second filesystem

In `/etc/rc`:

```lua
local addr = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
local fs   = component.proxy(addr)
kernel.vfs.mount("/data", kernel.vfs._wrap_oc_fs(fs, addr))
```

---

## Signals

UniOS implements a POSIX-style signal system translated from OC keyboard events:

| Key | Signal | Default Action |
|-----|--------|----------------|
| Ctrl+C | SIGINT | Terminate foreground process |
| Ctrl+`\` | SIGQUIT | Terminate + core (terminate) |
| Ctrl+Z | SIGSTOP | Stop (pause) process |
| — | SIGTERM | Graceful terminate |
| — | SIGKILL | Force kill (uncatchable) |
| — | SIGCHLD | Child exited (ignore) |

Send signals manually:

```sh
kill -SIGTERM 3     # terminate PID 3
kill -SIGKILL 3     # force-kill PID 3
kill -SIGSTOP 3     # pause PID 3
```

---

## Contributing

Pull requests are welcome! Suggestions for new utilities, drivers, or shell features are especially appreciated.

### Guidelines

- Keep each file focused on one responsibility
- New userland tools go in `/bin/`, return an exit code
- New kernel modules register themselves with `kernel.*`
- New libraries go in `/lib/`, return a module table
- Follow the existing code style (no global pollution, use `kernel.require`)

### Areas to contribute

- [ ] `vi` / text editor
- [ ] `wget` (network / modem support)
- [ ] `tar` / `gz` archiver
- [ ] Pipe IPC (true kernel-buffered pipes between processes)
- [ ] `/proc` filesystem (like Linux `/proc`)
- [ ] Multi-user support (real uid/gid switching)
- [ ] Window manager / desktop for Tier 3 screens

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

<div align="center">

Made with ❤️ for the OpenComputers community

[⭐ Star this repo](https://github.com/testingaccount132/Uni) · [🐛 Report a bug](https://github.com/testingaccount132/Uni/issues) · [💡 Request a feature](https://github.com/testingaccount132/Uni/issues)

</div>
