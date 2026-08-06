# Boot Chain

This document is the serial boot walkthrough for an installed Laputa Linux
system on real hardware. The kernel executes `/init`; `xinit` reads
`/etc/inittab`; `rc.boot` mounts the early runtime filesystems, starts device
and network setup, initializes time, swap, and hostname, and then the console
login runs.

## 1. Interactive rootfs preparation

The runtime root must contain `baselayout`, `xsh`, and `xinit`. The integration
builder installs those packages and makes `/init` point to `/usr/bin/xinit`:

```xsh
proc ensure_boot_runtime(root: Path, rootfs_dir: Path, _: Path) [fs, process, env, error] {
  let xsh = ensure_host_xsh(root)?

  run_pm(
    root,
    xsh,
    [
      "build-install",
      rootfs_dir.display(),
      fp"${root}/target/linux-vm/xsh-runtime-build-root".display(),
      fp"${root}/target/linux-vm/xsh-runtime-work".display(),
      fp"${root}/target/linux-vm/xsh-runtime-out".display(),
      fp"${packages_root(root)?}/repo/baselayout".display(),
      fp"${packages_root(root)?}/repo/xsh".display(),
      fp"${packages_root(root)?}/repo/xinit".display(),
    ],
  )?

  fs.remove(fp"${rootfs_dir}/init", missing_ok: true)?
  fs.symlink(p"usr/bin/xinit", fp"${rootfs_dir}/init")?
  ensure_linux_sh(rootfs_dir)?
}
```

The package version of `xinit` also installs both `/usr/bin/xinit` and `/init`:

```xsh
export proc build(dest: Path) [fs, error] {
  fs.install(p"xinit.xsh", fp"${dest}/usr/bin/xinit", 0o755, parents: true, overwrite: true)?
  fs.symlink(p"xinit", fp"${dest}/usr/bin/init")?
  fs.symlink(p"usr/bin/xinit", fp"${dest}/init")?
}
```

The kernel therefore executes:

```text
/init -> usr/bin/xinit
```

## 2. Package inputs

`baselayout` is an extract-install package. It copies its `files/rootfs` tree
into the rootfs:

```xsh
export let sources: List[Path] = [
  p"files/rootfs",
]

export let extract_install: Bool = true

export proc build(dest: Path) [fs, error] {
  let _ = fs.copy_tree(p".", dest, parents: true, overwrite: true)?

  for keep in fs.walk(dest) |> where .kind == "file" and .name == ".keep" {
    keep.path.remove()?
  }
}
```

The xsh package supplies the interpreter and the interactive shell symlink:

```xsh
fs.install(staged[0].path, fp"${dest}/bin/xsh", 0o755, parents: true, overwrite: true)?

for command_name in ["xshi", "xsht"] {
  let link = fp"${dest}/usr/local/bin/${command_name}"
  fs.remove(link, missing_ok: true)?
  fs.symlink(p"xsh", link)?
}
```

The package version of `xinit` installs `/usr/bin/xinit`, `/usr/bin/init`, and
`/init`:

```xsh
export proc build(dest: Path) [fs, error] {
  fs.install(p"xinit.xsh", fp"${dest}/usr/bin/xinit", 0o755, parents: true, overwrite: true)?
  fs.symlink(p"xinit", fp"${dest}/usr/bin/init")?
  fs.symlink(p"usr/bin/xinit", fp"${dest}/init")?
}
```

## 3. `xinit` starts as PID 1

`xinit` is an XSH script:

```xsh
#!/bin/xsh
```

With no arguments, it reads `XSH_INIT_INITTAB` or `/etc/inittab`:

```xsh
proc main(...argv: List[Str]) [fs, process, env, time, error, io] {
  if argv.len() == 0 {
    run_pid1(Path(env_value("XSH_INIT_INITTAB", "/etc/inittab"))?)?
    return
  }
}
```

`run_pid1` installs PID 1 signal/subreaper behavior, parses inittab, runs the
synchronous phases, spawns long-lived entries, and waits for child or lifecycle
events:

```xsh
proc run_pid1(inittab: Path) [fs, process, env, time, error] {
  let allow = env_enabled("XINIT_TEST_ALLOW_NON_PID1") or env_enabled("XSH_INIT_TEST_ALLOW_NON_PID1")
  unix.pid1_setup(["HUP", "TERM", "USR1", "USR2", "INT"], subreaper: true, allow_non_pid1: allow)?
  let entries = parse_inittab(inittab)?
  let launch_limit = env_int("XSH_INIT_TEST_MAX_RESPAWNS", 0)?
  let delay_ms = env_int("XSH_INIT_TEST_RESPAWN_DELAY_MS", 1000)?
  let exit_when_idle = env_enabled("XSH_INIT_TEST_EXIT_WHEN_IDLE")
  let fast = env_enabled("XSH_INIT_FAST_SHUTDOWN")
  var runtime: List[RuntimeEntry] = []
  var event = ""
  run_phase(entries, "sysinit")?
  run_phase(entries, "wait")?
  runtime = spawn_entries(entries, runtime, launch_limit, delay_ms)?
}
```

## 4. Kernel handoff

The kernel command line must name `/init` as PID 1. At the kernel/userspace
boundary the chain is:

```text
kernel
  -> /init
  -> /usr/bin/xinit
  -> /bin/xsh reads and executes /usr/bin/xinit
```

## 5. Network model

Networking is userspace-owned. The installed system uses `ifup` and
`/etc/network/interfaces`:

- `build-installer-image.xsh` installs `../xsh/core/ifup.xsh` as
  `/usr/bin/ifup`.
- `build-installer-image.xsh` installs `installer/laputa-network.boot` as
  `/usr/lib/init/rc.d/laputa-network.boot`.
- `setup-laputa.xsh` writes the installed target's
  `/etc/network/interfaces`.
- `laputa-network.boot` runs `ifup -a` when `/usr/bin/ifup` exists, otherwise it
  falls back to its own minimal static parser.

The network boot chain is:

```text
rc.boot
  -> mounts /proc, /sys, /run, /dev
  -> brings lo up
  -> runs generic boot hooks
/usr/lib/init/rc.d/laputa-network.boot
  -> /usr/bin/ifup -a
  -> /etc/network/interfaces
```

`/etc/network/interfaces` is not installed by `baselayout` and is not written
by `baselayout`. The installer writes it into the installed target. The
`baselayout` file set contains `/etc/fstab`, `/etc/hosts`, `/etc/inittab`,
`/etc/mdev.conf`, account files, init scripts, and hook directories, but no
interfaces file:

```text
../packages/repo/baselayout/files/rootfs/etc/fstab
../packages/repo/baselayout/files/rootfs/etc/hosts
../packages/repo/baselayout/files/rootfs/etc/inittab
../packages/repo/baselayout/files/rootfs/etc/mdev.conf
../packages/repo/baselayout/files/rootfs/etc/rc.d/.keep
```

The installer target is different. `setup-laputa.xsh` derives a static IPv4
configuration from the installer runtime's current interfaces and routes:

```xsh
proc installer_network_interfaces() [process, error] -> Result[Record] {
  let interfaces = linux.interfaces()?
  let routes = linux.routes()?
  var iface = ""
  var address = ""
  var netmask = "255.255.255.0"
  var gateway = "10.0.2.2"
```

It renders that as an ifupdown-style interfaces file:

```xsh
proc target_static_interfaces() [process, error] -> Result[Str] {
  let netcfg = installer_network_interfaces()?

  return f"""auto lo
iface lo inet loopback

auto ${netcfg.iface}
iface ${netcfg.iface} inet static
    address ${netcfg.address}
    netmask ${netcfg.netmask}
    gateway ${netcfg.gateway}
"""
}
```

And writes it into the installed target:

```xsh
write_file(fp"${root}/etc/network/interfaces", target_static_interfaces()?)?
```

`laputa-network.boot` is the boot hook that consumes that file:

```xsh
proc main() [fs, process, error] {
  if fs.exists(/usr/bin/ifup)? {
    run /usr/bin/ifup "-a" ?
    return
  }

  let path_value = /etc/network/interfaces

  if ! fs.exists(path_value)? {
    return
  }
```

`ifup` reads `/etc/network/interfaces` by default:

```xsh
proc default_interfaces_path() [env] -> Path {
  match env("XSH_IFUP_INTERFACES") {
    Ok(path_value) => Path(path_value)
    Err(_) => /etc/network/interfaces
  }
}
```

Today it can configure `loopback`, `manual`, and `static` stanzas. DHCP is
parsed as a method, but intentionally fails because the XSH DHCP client does not
exist yet:

```xsh
match stanza.method {
  "loopback" | "manual" => linux.link_up(physical)?
  "static" => configure_static(physical, stanza)?
  "dhcp" => return Err(IfupError.Config(f"${stanza.logical}: dhcp method is not implemented"))
  _ => return Err(IfupError.Config(f"${stanza.logical}: unsupported method ${stanza.method}"))
}
```

`xinit` does not currently support dependency-aware network hooks. It knows
inittab actions and service control commands, but no native lifecycle phase such
as `netlink-ready`, `network-online`, or `dhcp-bound`. The only hook mechanism
is the generic boot hook loop in `rc.boot`:

```xsh
for hook in g"/usr/lib/init/rc.d/*.boot" {
  if hook.metadata()?.kind == "file" {
    run $hook ?
  }
}

for hook in g"/etc/rc.d/*.boot" {
  if hook.metadata()?.kind == "file" {
    run $hook ?
  }
}
```

That means DHCP-dependent or route-dependent services should not be started
until `ifup` has configured the relevant interface. If userspace DHCP is added,
xinit needs either a dedicated network-ready hook contract or service
dependencies/readiness conditions. The current generic `*.boot` hooks are
ordered after `rc.boot`'s basic mounts and loopback setup, not after netlink
carrier, DHCP lease, DNS, or default route readiness.

## 6. `/etc/inittab`

The canonical `baselayout` inittab is:

```text
::sysinit:/usr/lib/init/rc.boot
::once:/usr/lib/init/mdev.supervise
::restart:/usr/bin/xinit /etc/inittab
::shutdown:/usr/lib/init/rc.shutdown
```

The installed system adds a console login entry, so the effective interactive
inittab is:

```text
::sysinit:/usr/lib/init/rc.boot
::once:/usr/lib/init/mdev.supervise
::restart:/usr/bin/xinit /etc/inittab
::shutdown:/usr/lib/init/rc.shutdown
ttyAMA0::poweroff:/usr/bin/login --force laputa
```

The fields are parsed as `id:runlevels:action:command`. `xinit` accepts these
actions:

```xsh
if ! (action == "sysinit" or action == "wait" or action == "once" or action == "restart" or action == "shutdown" or action == "respawn" or action == "poweroff") {
  return Err(XinitError.Failed("init-inittab", f"line ${index}: unsupported action '${action}'"))
}
```

Commands are split by XSH argv parsing, not by a shell:

```xsh
let argv = process.argv_words(command)?
```

## 7. `sysinit`: `/usr/lib/init/rc.boot`

The first executed inittab command is synchronous:

```text
::sysinit:/usr/lib/init/rc.boot
```

`xinit` runs every `sysinit` command before it starts any long-running entries:

```xsh
run_phase(entries, "sysinit")?
run_phase(entries, "wait")?
runtime = spawn_entries(entries, runtime, launch_limit, delay_ms)?
```

`rc.boot` creates and mounts the early runtime filesystems:

```xsh
#!/bin/xsh
for dir in [/proc, /sys, /run, /dev] {
  dir.mkdir()?
}

let mount_proc = linux.mount("proc", /proc, fstype: "proc", options: ["nosuid", "noexec", "nodev"])
let mount_sys = linux.mount("sys", /sys, fstype: "sysfs", options: ["nosuid", "noexec", "nodev"])
let mount_run = linux.mount("run", /run, fstype: "tmpfs", options: ["mode=0755", "nosuid", "nodev"])
let mount_dev = linux.mount("dev", /dev, fstype: "devtmpfs", options: ["mode=0755", "nosuid"])
```

It then creates terminal support and standard fd links:

```xsh
for dir in [/dev/pts, /dev/shm] {
  dir.mkdir()?
}

let proc_filesystems = fs.read_text(/proc/filesystems)?

if "devpts" in proc_filesystems {
  let mount_devpts = linux.mount(
    "devpts",
    /dev/pts,
    fstype: "devpts",
    options: ["mode=0620", "gid=5", "ptmxmode=0666", "nosuid", "noexec"],
  )

  if fs.exists(/dev/pts/ptmx)? and ! fs.exists(/dev/ptmx)? {
    match fs.symlink(p"pts/ptmx", /dev/ptmx) {
      Ok(_) => {}
      Err(_) => {}
    }
  }
}

if ! fs.exists(/dev/ptmx)? {
  let mknod_ptmx = linux.mknod(/dev/ptmx, "char", 5, 2)
}

let mount_shm = linux.mount("shm", /dev/shm, fstype: "tmpfs", options: ["mode=1777", "nosuid", "nodev"])

if ! fs.exists(/dev/fd)? {
  fs.symlink(/proc/self/fd, /dev/fd)?
}
```

Device population, fstab mounts, swap, loopback, clock, hostname, sysctl, and
boot hooks follow:

```xsh
if fs.exists(/usr/bin/mdev)? {
  run /usr/bin/mdev -s ?
}

let mount_all_result = linux.mount_all()
let swapon_all_result = linux.swapon_all()

if fs.exists(/proc/sys/net/ipv4/conf/lo)? {
  let link_up_result = linux.link_up("lo")
}
```

System time is set in `rc.boot` after the early mounts and loopback setup. If
`/etc/xsh-boot-epoch-ms` exists, `rc.boot` uses it:

```xsh
fs.write(
  fp"${rootfs_dir}/etc/xsh-boot-epoch-ms",
  f"""${time.now()}
""",
)?
```

If the file is absent, it falls back to the hardware clock:

```xsh
if fs.exists(/etc/xsh-boot-epoch-ms)? {
  match fs.read_text(/etc/xsh-boot-epoch-ms)?.trim().parse_int() {
    Ok(epoch_ms) => let set_system_clock_result = linux.set_system_clock(epoch_ms)
    Err(_) => {}
  }
} else {
  match linux.hwclock() {
    Ok(epoch_ms) => let set_system_clock_result = linux.set_system_clock(epoch_ms)
    Err(_) => {}
  }
}
```

```xsh
if fs.exists(/etc/hostname)? {
  let hostname = fs.read_text(/etc/hostname)?.trim()
  let set_hostname_result = unix.set_hostname(hostname)
}

let sysctl_result = linux.sysctl_load_dirs(
  [/run/sysctl.d, /etc/sysctl.d, /usr/lib/sysctl.d],
  fallback: /etc/sysctl.conf,
)

for hook in g"/usr/lib/init/rc.d/*.boot" {
  if hook.metadata()?.kind == "file" {
    run $hook ?
  }
}

for hook in g"/etc/rc.d/*.boot" {
  if hook.metadata()?.kind == "file" {
    run $hook ?
  }
}
```

The integration path writes `/etc/hostname`:

```xsh
fs.write(
  fp"${rootfs_dir}/etc/hostname",
  """laputa
""",
)?
```

It also writes `/etc/fstab`:

```xsh
fs.write(
  fp"${rootfs_dir}/etc/fstab",
  """# <file system> <dir> <type> <options> <dump> <pass>
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
""",
)?
```

## 8. `once`: `/usr/lib/init/mdev.supervise`

After `sysinit`, `xinit` spawns all entries whose action starts processes. That
set includes `once`, `respawn`, and `poweroff`:

```xsh
pure entry_spawns(entry: InittabEntry) -> Bool {
  return entry.action == "once" or entry.action == "respawn" or entry.action == "poweroff"
}
```

For entries with an `id`, `xinit` attaches the child to that tty. Entries with
an empty `id` start as a process group without a tty:

```xsh
let child = if entry.id == "" {
  unix.spawn_process_group(command)?
} else {
  unix.spawn_with_tty(command, tty: entry.id)?
}
```

The `mdev.supervise` inittab line has an empty id:

```text
::once:/usr/lib/init/mdev.supervise
```

The file only starts supervision if `/usr/bin/mdevd` exists:

```xsh
#!/bin/xsh
if fs.exists(/usr/bin/mdevd)? {
  run /usr/bin/xinit supervise mdevd ?
}
```

If `mdevd` is absent, this child exits. Because the action is `once`, it is not
restarted.

When `mdevd` is present, `xinit supervise mdevd` resolves the service path from
the command argument:

```xsh
proc service_path(target: Str) [env, error] -> Result[Path] {
  if "/" in target or target.ends_with(".xsh") {
    return Path(target)?
  }

  return fp"${service_dir()?.display()}/${target}.xsh"
}
```

With the default service directory, that means `mdevd` resolves to
`/usr/lib/xinit/services/mdevd.xsh`, which `baselayout` provides:

```xsh
export let service = {
  name: "mdevd",
  kind: "longrun",
  command: process.command_argv(
    /usr/bin/mdevd,
    ["mdevd", "-O", "4", "-f", "/etc/mdev.conf", "-C"],
    env: {PATH: "/bin:/usr/bin"},
  ),
  targets: ["boot"],
  restart: restart_policy(),
  logging: "append",
}
```

The module runs `mdevd` against `/etc/mdev.conf`.

## 9. `poweroff`: console login

The interactive login line is:

```text
ttyAMA0::poweroff:/usr/bin/login --force laputa
```

Because the id is `ttyAMA0`, `xinit` starts the command with that tty:

```xsh
let child = if entry.id == "" {
  unix.spawn_process_group(command)?
} else {
  unix.spawn_with_tty(command, tty: entry.id)?
}
```

The action is `poweroff`, so when the login process tree exits, `xinit` treats
that child exit as the system poweroff event:

```xsh
if current.pid == pid {
  out = runtime_set(
    out,
    {key: entry.key, pid: -1, launches: current.launches, next_ms: current.next_ms, action: entry.action},
  )

  if entry.action == "poweroff" {
    event = "poweroff"
  }
}
```

The `login` binary itself is not defined by `baselayout`; it must already be
present in the selected interactive rootfs package set. `baselayout` supplies
the user, group, shadow, shell, and profile files that `login` consumes.

## 10. User database and shell selection

`/etc/passwd` defines the `laputa` account and its login shell:

```text
root:x:0:0:root:/root:/bin/xshi
laputa:x:1000:1000:Laputa User:/home/laputa:/bin/xshi
nobody:x:99:99:Unprivileged User:/dev/null:/bin/false
```

`/etc/shadow` locks password authentication for these accounts:

```text
root:*:0:0:99999:7:::
laputa:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::
```

The inittab uses `login --force laputa`, so login is expected to skip password
authentication and start the account shell from `/etc/passwd`.

`/etc/group` makes `laputa` the primary user group and adds it to `wheel`:

```text
wheel:x:4:laputa
laputa:x:1000:
```

`/etc/shells` marks `/bin/xshi` as a valid login shell:

```text
# Pathnames of valid login shells.
# See shells(5) for details.

/bin/sh
/bin/xshi
```

`/etc/profile` sets the default login path:

```sh
export PATH=/bin:/usr/bin
```

The shell executable is installed by the `xsh` package as a symlink to the xsh
multicall binary:

```text
/bin/xshi -> xsh
```

At this point the serial boot chain has reached the login shell:

```text
kernel
  -> /init
  -> /usr/bin/xinit
  -> /etc/inittab
  -> /usr/lib/init/rc.boot
  -> /usr/lib/init/mdev.supervise
  -> /usr/bin/login --force laputa on ttyAMA0
  -> /bin/xshi
```

## 11. Runtime after login starts

Once the login shell is running, `xinit` stays in its PID 1 event loop:

```xsh
while event == "" {
  let pid_event = unix.wait_pid1_event()?

  if pid_event.kind == "signal" {
    if pid_event.signal == "HUP" {
      event = "restart"
    } else if pid_event.signal == "USR1" {
      event = "halt"
    } else if pid_event.signal == "USR2" or pid_event.signal == "INT" {
      event = "poweroff"
    } else if pid_event.signal == "TERM" {
      event = "reboot"
    }
  } else if pid_event.kind == "children" {
```

If the login shell exits, the `poweroff` inittab entry ends, so `xinit` stops
owned process groups, runs shutdown hooks, and powers off:

```xsh
shutdown_runtime(entries, runtime, fast)?

if event == "restart" {
  for entry in entries {
    if entry.action == "restart" {
      unix.exec(command_from_argv(entry.argv))?
    }
  }

  return
}

run_phase(entries, "shutdown")?
finalize(event)?
```

`/usr/lib/init/rc.shutdown` runs pre-shutdown hooks, unmounts filesystems,
remounts root read-only, syncs, and then runs post-shutdown hooks:

```xsh
#!/bin/xsh
for hook in g"/usr/lib/init/rc.d/*.pre.shutdown" {
  if hook.metadata()?.kind == "file" {
    run hook ?
  }
}

for hook in g"/etc/rc.d/*.pre.shutdown" {
  if hook.metadata()?.kind == "file" {
    run hook ?
  }
}

let swapoff_all_result = linux.swapoff_all()
let umount_all_result = linux.umount_all(types: ["nosysfs", "proc", "devtmpfs", "tmpfs"])
let remount_root_result = linux.mount("", /, fstype: "", options: ["remount", "ro"])
fs.sync()?
```

The final poweroff call is in `xinit.finalize`:

```xsh
if kind == "halt" {
  linux.halt()?
} else if kind == "poweroff" {
  linux.poweroff()?
} else if kind == "reboot" {
  linux.reboot()?
}
```

## 12. File read and execute order

The host-side package preparation chain is:

```text
main
  -> ensure_boot_runtime
    -> run_pm build-install baselayout xsh xinit
  -> install_rootfs_overlay
    -> ensure_baselayout
    -> canonical_inittab
```

For an installed system, the boot-time file order is:

```text
image/installer setup
  installs baselayout, xsh, xinit
  writes /init -> usr/bin/xinit
  writes /etc/inittab with the appended login line
  writes /etc/hostname
  writes /etc/fstab
  writes /etc/network/interfaces
  writes /etc/xsh-boot-epoch-ms
kernel
  executes /init
/init -> /usr/bin/xinit
  interpreter: /bin/xsh
  reads /etc/inittab
  executes /usr/lib/init/rc.boot
    reads /proc/filesystems
    may execute /usr/bin/mdev -s
    reads /etc/fstab through linux.mount_all()
    reads /etc/xsh-boot-epoch-ms or hardware clock
    reads /etc/hostname
    reads sysctl dirs and /etc/sysctl.conf fallback
    executes /usr/lib/init/rc.d/*.boot
      executes /usr/lib/init/rc.d/laputa-network.boot
        executes /usr/bin/ifup -a
        reads /etc/network/interfaces
        writes /run/network/ifstate
    executes /etc/rc.d/*.boot
  spawns /usr/lib/init/mdev.supervise once
    may execute /usr/bin/xinit supervise mdevd
      default service lookup reads /usr/lib/xinit/services/mdevd.xsh
      mdevd reads /etc/mdev.conf
  spawns /usr/bin/login --force laputa on ttyAMA0 as poweroff entry
/usr/bin/login
  reads /etc/passwd
  reads /etc/shadow
  reads /etc/group
  may read /etc/shells
  starts /bin/xshi for user laputa
/bin/xshi -> /bin/xsh
```

For the installer-built target, the additional networking write/read path is:

```text
build-installer-image.xsh
  installs installer/laputa-network.boot to /usr/lib/init/rc.d/laputa-network.boot
  installs ../xsh/core/ifup.xsh to /usr/bin/ifup
setup-laputa
  reads current installer interfaces with linux.interfaces()
  reads current installer routes with linux.routes()
  writes target /etc/network/interfaces as static IPv4 config
installed target boot
  executes /usr/lib/init/rc.boot
    executes /usr/lib/init/rc.d/laputa-network.boot
      executes /usr/bin/ifup -a
        reads /etc/network/interfaces
        writes /run/network/ifstate
        configures loopback/manual/static interfaces
        fails for iface METHOD dhcp until the XSH DHCP client exists
```
