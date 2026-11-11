const GUEST_KERNEL_CANDIDATES = ["/boot/vmlinuz-stable", "/boot/vmlinuz-lts"]
const GUEST_QEMU_NAME = "qemu-system-x86_64"
const GUEST_MODULES = [
  "virtio_ring",
  "virtio",
  "virtio_pci_modern_dev",
  "virtio_pci_legacy_dev",
  "virtio_pci",
  "virtio_blk",
  "failover",
  "net_failover",
  "virtio_net",
  "crc16",
  "mbcache",
  "jbd2",
  "ext4",
]

proc guest_tool_or_skip(name: Str) [fs, process, error] -> Result[Path, Error] {
  match process.which(name) {
    Ok(found) => found,
    Err(_) => {
      test.skip(f"guest proof needs {name}")
      return p"/nonexistent"
    },
  }
}

proc guest_file_or_skip(path_value: Path, label: Str) [fs, error] {
  guard path_value.exists()? else {
    test.skip(f"guest proof needs {label} at {path_value.display()}")
    return
  }
}

proc guest_kernel() [fs, error] -> Result[Path, Error] {
  for candidate in GUEST_KERNEL_CANDIDATES {
    if fp"{candidate}".exists()? {
      return fp"{candidate}"
    }
  }

  test.skip("guest proof needs a host kernel at /boot/vmlinuz-stable or /boot/vmlinuz-lts")
  p"/nonexistent"
}

proc guest_modules_dir() [fs, error] -> Result[Path, Error] {
  var found = p"/nonexistent"
  for entry in fs.children(p"/lib/modules")? {
    if entry.kind == "dir" {
      found = entry.path
    }
  }

  guard found != p"/nonexistent" else {
    test.skip("guest proof needs host kernel modules under /lib/modules")
    return p"/nonexistent"
  }

  for name in GUEST_MODULES {
    guest_file_or_skip(fp"{found}/kernel/{guest_module_path(name)}.ko.gz", f"module {name}")?
  }

  found
}

pure guest_module_path(name: Str) -> Str {
  return "drivers/virtio/virtio" when name == "virtio"
  return "drivers/virtio/virtio_ring" when name == "virtio_ring"
  return "drivers/virtio/virtio_pci_modern_dev" when name == "virtio_pci_modern_dev"
  return "drivers/virtio/virtio_pci_legacy_dev" when name == "virtio_pci_legacy_dev"
  return "drivers/virtio/virtio_pci" when name == "virtio_pci"
  return "drivers/block/virtio_blk" when name == "virtio_blk"
  return "net/core/failover" when name == "failover"
  return "drivers/net/net_failover" when name == "net_failover"
  return "drivers/net/virtio_net" when name == "virtio_net"
  return "lib/crc/crc16" when name == "crc16"
  return "fs/mbcache" when name == "mbcache"
  return "fs/jbd2/jbd2" when name == "jbd2"
  "fs/ext4/ext4"
}

proc guest_xsh() [fs, process, env, error] -> Result[Path, Error] {
  let configured = (e"XSH_HOST" ?? "").trim()
  if configured != "" {
    return fp"{configured}"
  }

  match process.which("xsh") {
    Ok(found) => found,
    Err(_) => {
      test.skip("guest proof needs the host xsh binary")
      return p"/nonexistent"
    },
  }
}

proc build_initramfs(root: Path, output: Path) [fs, process, error] -> Result[Unit, Error] {
  var entries = ["."]
  for entry in fs.walk(root, hidden: true)? {
    let rel = entry.path.strip_prefix(root)?
    guard rel.display() != "" else {
      continue
    }

    entries += [f"./{rel.display()}"]
  }

  let list_file = fp"{root}.list"
  list_file.write(bytes.from_text(entries.join("\n") + "\n"))?
  let command = process.command_argv(
    "cpio",
    ["cpio", "--format=newc", "--owner=0:0", "-o"],
    root,
    {PATH: "/usr/bin:/bin"},
    stdin: list_file,
    stdout: output,
  )
  let status = process.run(command)?
  assert status.ok, "cpio could not pack the guest initramfs"
}

proc build_store_disk(path_value: Path, size_mb: Int) [fs, process, error] -> Result[Unit, Error] {
  let command = process.command_argv(
    "mke2fs",
    ["mke2fs", "-F", "-q", "-t", "ext4", "-L", "LAPUTA_TRUST_STORE", path_value.display(), f"{size_mb}M"],
    p"/",
    {PATH: "/usr/bin:/bin:/sbin"},
  )
  let status = process.run(command)?
  assert status.ok, "mke2fs could not format the guest store disk"
}

proc wait_for_marker(log: Path, marker: Str, attempts: Int) [fs, time, error] -> Result[Str, Error] {
  var tries = 0
  while tries < attempts {
    if log.exists()? {
      let text = log.read_text()?
      if marker in text {
        return text
      }

      if "LAPUTA_REPO_GUEST FAIL" in text or "LAPUTA_TRUST_GUEST FAIL" in text or "LAPUTA_REPO_ROTATE FAIL" in text {
        assert false, f"guest reported failure before {marker}: {text}"
      }
    }

    time.sleep(2s)?
    tries += 1
  }

  let tail = if log.exists()? { log.read_text()? } else { "<no serial log>" }
  assert false, f"guest never printed {marker}; serial tail: {tail}"
  
}

proc guest_alive(pid: Int) [process, error] -> Result[Bool, Error] {
  for entry in process.list()? |> where .pid == pid {
    return entry.status != "Z"
  }

  false
}

proc wait_for_exit(pid: Int, attempts: Int) [process, time, error] -> Result[Unit, Error] {
  var tries = 0
  while tries < attempts {
    guard guest_alive(pid)? else {
      return
    }

    time.sleep(2s)?
    tries += 1
  }

  assert false, "guest did not power off"
  return
}

proc stop_guest(pid: Int) [process, error] {
  match process.kill(pid, signal: "KILL") {
    Ok(_) => {},
    Err(_) => {},
  }
}

type GuestBoot = {pid: Int, log: Path}

proc launch_guest(
  ctx: TestContext,
  name: Str,
  kernel: Path,
  initramfs: Path,
  store: Path,
  url: Str,
) [fs, process, env, error] -> Result[GuestBoot, Error] {
  let qemu = guest_tool_or_skip(GUEST_QEMU_NAME)?
  let dir = test.temp_dir(ctx, name: name)?
  let log = fp"{dir}/serial.log"
  let argv = [
    qemu.display(),
    "-M", "q35,accel=kvm",
    "-cpu", "host",
    "-smp", "2",
    "-m", "1024M",
    "-kernel", kernel.display(),
    "-initrd", initramfs.display(),
    "-append", f"console=ttyS0 earlyprintk=serial devtmpfs.mount=1 init=/init XSH_LINUX_REAL=1 XSH_UNIX_REAL=1 repo_url={url}",
    "-drive", f"if=none,id=store,format=raw,file={store.display()}",
    "-device", "virtio-blk-pci,drive=store",
    "-netdev", "user,id=net0",
    "-device", "virtio-net-pci,netdev=net0",
    "-display", "none",
    "-serial", f"file:{log.display()}",
  ]
  let spawned = process.spawn(process.command_argv(qemu.display(), argv, dir))?
  {pid: spawned.pid, log}
}

proc stage_initramfs(
  ctx: TestContext,
  xsh: Path,
  modules_dir: Path,
  root_name: Str = "repo-guest-root",
  main_script: Str = "",
  provisioned_keys: List[Str] = [],
) [fs, process, env, error] -> Result[Path, Error] {
  let root = test.temp_dir(ctx, name: root_name)?
  for dir in ["bin", "guest", "lib/pm", "lib/modules", "etc/laputa", "store", "proc", "sys", "dev", "tmp"] {
    fp"{root}/{dir}".mkdir(parents: true)
  }
  xsh.copy(to: fp"{root}/bin/xsh", overwrite: true)?
  fp"{root}/bin/xsh".chmod(0o755)
  p"guest/trust-guest-init.xsh".copy(to: fp"{root}/init", overwrite: true)?
  fp"{root}/init".chmod(0o755)
  if main_script == "" {
    p"guest/repo-snapshot-guest.xsh".copy(to: fp"{root}/guest/main.xsh", overwrite: true)?
  } else {
    fp"{root}/guest/main.xsh".write(bytes.from_text(main_script))
  }
  fp"{root}/guest/main.xsh".chmod(0o755)
  let source = (e"LAPUTA_REPO_GUEST_MODULE_ROOT" ?? ".").trim()
  for entry in fs.children(fp"{source}/pm")? {
    if entry.name.ends_with(".xsh") {
      entry.path.copy(to: fp"{root}/lib/pm/{entry.name}", overwrite: true)?
    }
  }
  for name in ["signing-key", "next-key"] {
    let key = fp"tests/pm/fixtures/repo-snapshot/keys/{name}.public.base64".read_text()?.trim().base64_decode()?
    fp"{root}/guest/{name}".write(key)?
  }
  if ! provisioned_keys.is_empty() {
    var keys = bytes.from_text("")
    for name in provisioned_keys {
      keys = bytes.concat([keys, fp"tests/pm/fixtures/repo-snapshot/keys/{name}.public.base64".read_text()?.trim().base64_decode()?])
    }
    fp"{root}/etc/laputa/repo-snapshot-keys".write(keys, mode: 0o444)
  }
  for name in GUEST_MODULES {
    let command = process.command_argv("gzip", ["gzip", "-dc", fp"{modules_dir}/kernel/{guest_module_path(name)}.ko.gz".display()], root, {PATH: "/usr/bin:/bin"}, stdout: fp"{root}/lib/modules/{name}.ko")
    let status = process.run(command)?
    assert status.ok, f"cannot decompress module {name}"
  }
  root
}

proc wait_for_port(port_file: Path) [fs, time, error] -> Result[Int, Error] {
  var tries = 0
  while tries < 100 {
    if port_file.exists()? {
      return port_file.read_text()?.trim().parse_int_decimal()
    }
    time.sleep(100ms)?
    tries += 1
  }
  test.fail("HTTP fixture server did not publish its port")
  0
}

const REPO_ROTATION_GUEST = """
use pm.remote
use pm.repo_snapshot

error RotationGuestError = Failed(phase: Str, message: Str)

const GUEST_STORE_DEV = "/dev/vda"
const GUEST_STORE_MNT = "/store"
const GUEST_PHASE_FILE = "/store/rotation-phase"
const GUEST_STATE = "/store/rotation-state"
const GUEST_MARKER = "LAPUTA_REPO_ROTATE"
const GUEST_NOW = 1995000000

proc say(message: Str) [fs, error] {
  p"/dev/console".write(bytes.from_text(f"{GUEST_MARKER} {message}\\n"))?
}

proc fail_phase(phase: Str, message: Str) [fs, error] {
  say(f"FAIL {phase} {message}")?
  return Err(RotationGuestError.Failed(phase:, message:))
}

proc wait_for_dev_vda(phase: Str) [fs, time, error] {
  var elapsed = 0
  while ! p"/dev/vda".exists()? {
    guard elapsed < 30 else {
      return fail_phase(phase, "missing /dev/vda after 30s")
    }

    time.sleep(1s)?
    elapsed += 1
  }
}

proc insmod_one(name: Str, phase: Str) [fs, process, error] {
  match linux.insmod(fp"/lib/modules/{name}.ko") {
    Ok(_) => {},
    Err(problem) => return fail_phase(phase, f"insmod {name}: {problem.message}"),
  }
}

proc load_drivers(phase: Str) [fs, process, error] {
  for name in [
    "virtio_ring",
    "virtio",
    "virtio_pci_modern_dev",
    "virtio_pci_legacy_dev",
    "virtio_pci",
    "virtio_blk",
    "failover",
    "net_failover",
    "virtio_net",
    "crc16",
    "mbcache",
    "jbd2",
    "ext4",
  ] {
    insmod_one(name, phase)?
  }
}

proc mount_store(phase: Str) [fs, process, time, error] {
  wait_for_dev_vda(phase)?
  fp"{GUEST_STORE_MNT}".mkdir(parents: true)
  match linux.mount(bytes.from_text(GUEST_STORE_DEV), fp"{GUEST_STORE_MNT}", fstype: "ext4") {
    Ok(_) => {},
    Err(problem) => return fail_phase(phase, f"mount store: {problem.message}"),
  }
}

proc bring_up_net(phase: Str) [fs, process, net, error] {
  var iface = ""
  let names = [entry.name ?? "" for entry in linux.network_dump()?.links] |> sort
  for name in names {
    if name != "lo" and iface == "" {
      iface = name
    }
  }

  guard iface != "" else {
    return fail_phase(phase, "no non-loopback interface")
  }

  match linux.link_up(iface) {
    Ok(_) => {},
    Err(problem) => return fail_phase(phase, f"link up: {problem.message}"),
  }

  match linux.set_ipv4_address(iface, "10.0.2.15", "255.255.255.0") {
    Ok(_) => {},
    Err(problem) => return fail_phase(phase, f"set address: {problem.message}"),
  }

  match linux.add_default_ipv4_route("10.0.2.2", interface: iface) {
    Ok(_) => {},
    Err(problem) => return fail_phase(phase, f"add route: {problem.message}"),
  }
}

proc read_phase() [fs, error] -> Result[Str, Error] {
  guard fp"{GUEST_PHASE_FILE}".exists()? else {
    return "0"
  }

  fp"{GUEST_PHASE_FILE}".read_text()?.trim()
}

proc write_phase(value: Str) [fs, error] {
  fp"{GUEST_PHASE_FILE}".write(bytes.from_text(f"{value}\\n"))?
  fs.fsync(fp"{GUEST_PHASE_FILE}")?
  fs.fsync(fp"{GUEST_STORE_MNT}")?
}

proc cmdline_value(key: Str) [fs, error] -> Result[Str, Error] {
  for field in p"/proc/cmdline".read_text()?.split(" ") {
    guard field.starts_with(f"{key}=") else {
      continue
    }

    return field.byte_slice(key.byte_len() + 1, field.byte_len()).trim()
  }

  Err(RotationGuestError.Failed(phase: "cmdline", message: f"missing {key} on the kernel command line"))
}

proc accepted(url: Str) [fs, error] -> Result[repo_snapshot.SnapshotAccepted?, Error] {
  repo_snapshot.snapshot_read_accepted(repo_snapshot.snapshot_state_paths(fp"{GUEST_STATE}", f"{url}/repo"))?
}

proc accepted_generation(url: Str) [fs, error] -> Result[Str, Error] {
  let found = accepted(url)?
  if found == null {
    return "none"
  }

  found.generation
}

proc accepted_floor(url: Str) [fs, error] -> Result[Int, Error] {
  let found = accepted(url)?
  if found == null {
    return 0
  }

  found.time_floor
}

proc select_generation(url: Str, generation: Str, phase: Str) [fs, net, error] {
  let response = net.request({method: "GET", url: f"{url}/select/{generation}"})?
  guard response.status == 200 else {
    return fail_phase(phase, f"could not select {generation}")
  }
}

proc fetch(url: Str, out: Str, keys: List[Bytes], phase: Str) [fs, net, time, error] {
  let items = remote.load_verified_remote_index(f"{url}/repo", fp"{out}", keys, GUEST_NOW, GUEST_STATE)?
  guard items.len() == 1 and items[0].name == "fixture" else {
    return fail_phase(phase, "verified fetch returned unexpected contents")
  }
}

proc expect_rejected(url: Str, out: Str, keys: List[Bytes], fragment: Str, phase: Str) [fs, net, time, error] {
  match remote.load_verified_remote_index(f"{url}/repo", fp"{out}", keys, GUEST_NOW, GUEST_STATE) {
    Ok(_) => return fail_phase(phase, "a rejected snapshot was accepted"),
    Err(problem) => {
      guard fragment in problem.message else {
        return fail_phase(phase, f"a snapshot failed with {problem.message}")
      }
    },
  }
}

proc main() [fs, process, time, net, error, io] {
  p"/proc".mkdir(parents: true)
  p"/sys".mkdir(parents: true)
  linux.mount(bytes.from_text("devtmpfs"), p"/dev", fstype: "devtmpfs")?
  linux.mount(bytes.from_text("proc"), p"/proc", fstype: "proc")?
  linux.mount(bytes.from_text("sysfs"), p"/sys", fstype: "sysfs")?
  load_drivers("boot")?
  mount_store("boot")?
  bring_up_net("boot")?
  let url = cmdline_value("repo_url")?
  let keys = repo_snapshot.snapshot_load_keys(p"/etc/laputa/repo-snapshot-keys")?
  let phase = read_phase()?
  say(f"BOOT phase={phase} keys={keys.len()}")?

  if phase == "0" {
    select_generation(url, "gen1", "phase0")?
    fetch(url, "/store/out-gen1", keys, "phase0")?
    guard accepted_generation(url)? == "1" else {
      return fail_phase("phase0", "generation 1 was not accepted")
    }
    guard accepted_floor(url)? == 1994999000 else {
      return fail_phase("phase0", "generation 1 recorded the wrong time floor")
    }
    say("PHASE0_OK generation=1")?
    write_phase("1")?
    linux.poweroff()?
    return
  }

  if phase == "1" {
    select_generation(url, "gen1", "phase1")?
    fetch(url, "/store/out-gen1-window", keys, "phase1")?
    select_generation(url, "gen2", "phase1")?
    fetch(url, "/store/out-gen2-window", keys, "phase1")?
    guard accepted_generation(url)? == "2" else {
      return fail_phase("phase1", "generation 2 was not accepted during the rotation window")
    }
    guard accepted_floor(url)? == 1994999500 else {
      return fail_phase("phase1", "generation 2 recorded the wrong time floor")
    }
    say("PHASE1_OK generation=2")?
    write_phase("2")?
    linux.poweroff()?
    return
  }

  if phase == "2" {
    guard accepted_generation(url)? == "2" else {
      return fail_phase("phase2", "generation 2 did not survive reboot")
    }
    select_generation(url, "gen1", "phase2")?
    expect_rejected(url, "/store/out-gen1-revoked", keys, "signature is invalid", "phase2")?
    guard accepted_generation(url)? == "2" else {
      return fail_phase("phase2", "a revoked key changed the accepted generation")
    }
    select_generation(url, "gen3", "phase2")?
    fetch(url, "/store/out-gen3-recovery", keys, "phase2")?
    guard accepted_generation(url)? == "3" else {
      return fail_phase("phase2", "generation 3 did not recover delivery after rotation")
    }
    guard accepted_floor(url)? == 1994999500 else {
      return fail_phase("phase2", "the backdated recovery lowered the authenticated time floor")
    }
    say("PHASE2_OK generation=3 time_floor=1994999500")?
    write_phase("3")?
    linux.poweroff()?
    return
  }

  guard phase == "3" else {
    return fail_phase("boot", "unknown rotation phase")
  }

  guard accepted_generation(url)? == "3" else {
    return fail_phase("phase3", "generation 3 did not survive reboot")
  }
  guard accepted_floor(url)? == 1994999500 else {
    return fail_phase("phase3", "the authenticated time floor did not survive reboot")
  }
  select_generation(url, "gen2", "phase3")?
  expect_rejected(url, "/store/out-gen2-replay", keys, "accepted snapshot", "phase3")?
  guard accepted_generation(url)? == "3" else {
    return fail_phase("phase3", "a replayed generation changed the accepted floor")
  }
  select_generation(url, "gen3", "phase3")?
  fetch(url, "/store/out-gen3-replay", keys, "phase3")?
  guard accepted_generation(url)? == "3" else {
    return fail_phase("phase3", "the replayed generation did not remain accepted")
  }
  say("ROTATE_OK generation=3 time_floor=1994999500")?
  linux.poweroff()?
}

main()?
"""

proc rotation_boot(
  ctx: TestContext,
  name: Str,
  kernel: Path,
  xsh: Path,
  modules_dir: Path,
  script: Str,
  keys: List[Str],
  store: Path,
  url: Str,
  marker: Str,
) [fs, process, env, time, error] {
  let staging = stage_initramfs(ctx, xsh, modules_dir, root_name: f"{name}-root", main_script: script, provisioned_keys: keys)?
  let work = test.temp_dir(ctx, name: f"{name}-work")?
  let initramfs = fp"{work}/initramfs.cpio"
  build_initramfs(staging, initramfs)?
  let boot = launch_guest(ctx, name, kernel, initramfs, store, url)?
  defer stop_guest(boot.pid)
  let _ = wait_for_marker(boot.log, marker, 100)?
  wait_for_exit(boot.pid, 100)?
  let final = boot.log.read_text()?
  assert "LAPUTA_REPO_ROTATE FAIL" not in final
}

test signed_repo_key_rotation_and_recovery_survive_reboot [fs, process, env, time, error] { |ctx|
  guest_file_or_skip(p"/dev/kvm", "KVM")?
  let kernel = guest_kernel()?
  let modules_dir = guest_modules_dir()?
  let xsh = guest_xsh()?
  let _ = guest_tool_or_skip("cpio")?
  let _ = guest_tool_or_skip("mke2fs")?
  let _ = guest_tool_or_skip("gzip")?
  let python = guest_tool_or_skip("python3")?
  let work = test.temp_dir(ctx, name: "repo-rotate-work")?
  let port_file = fp"{work}/port"
  let fixture_root = path.absolute(p"tests/pm/fixtures/repo-snapshot")?
  let server_script = path.absolute(p"tests/pm/fixtures/repo-snapshot/rotation_server.py")?
  let server = spawn run $python $server_script $fixture_root $port_file ?
  defer server.cancel(signal: "TERM", kill_after: 5s)
  let url = f"http://10.0.2.2:{wait_for_port(port_file)?}"
  let store = fp"{work}/rotation-store.ext4"
  build_store_disk(store, 64)?
  let script = REPO_ROTATION_GUEST
  let phases = [
    {name: "repo-rotate-gen1", keys: ["signing-key"], marker: "PHASE0_OK generation=1"},
    {name: "repo-rotate-window", keys: ["signing-key", "next-key"], marker: "PHASE1_OK generation=2"},
    {name: "repo-rotate-recover", keys: ["next-key"], marker: "PHASE2_OK generation=3 time_floor=1994999500"},
    {name: "repo-rotate-replay", keys: ["next-key"], marker: "ROTATE_OK generation=3 time_floor=1994999500"},
  ]
  for phase in phases {
    rotation_boot(ctx, phase.name, kernel, xsh, modules_dir, script, phase.keys, store, url, phase.marker)?
  }
}

test signed_repo_fetch_survives_reboot_and_rejects_tamper_and_rollback [fs, process, env, time, error] { |ctx|
  guest_file_or_skip(p"/dev/kvm", "KVM")?
  let kernel = guest_kernel()?
  let modules_dir = guest_modules_dir()?
  let xsh = guest_xsh()?
  let _ = guest_tool_or_skip("cpio")?
  let _ = guest_tool_or_skip("mke2fs")?
  let _ = guest_tool_or_skip("gzip")?
  let python = guest_tool_or_skip("python3")?
  let work = test.temp_dir(ctx, name: "repo-guest-work")?
  let port_file = fp"{work}/port"
  let fixture_root = path.absolute(p"tests/pm/fixtures/repo-snapshot")?
  let server_script = path.absolute(p"guest/repo-snapshot-server.py")?
  let server = spawn run $python $server_script $fixture_root $port_file ?
  defer server.cancel(signal: "TERM", kill_after: 5s)
  let port = wait_for_port(port_file)?
  let staging = stage_initramfs(ctx, xsh, modules_dir)?
  let initramfs = fp"{work}/initramfs.cpio"
  build_initramfs(staging, initramfs)?
  let store = fp"{work}/store.ext4"
  build_store_disk(store, 64)?
  let boot = launch_guest(ctx, "repo-guest", kernel, initramfs, store, f"http://10.0.2.2:{port}")?
  defer stop_guest(boot.pid)?
  let text = wait_for_marker(boot.log, "ROLLBACK_REJECTED", 50)?
  assert "ACCEPT_AND_TAMPER_OK generation=2" in text
  assert "ROLLBACK_REJECTED generation=2" in text
  wait_for_exit(boot.pid, 50)?
  assert "LAPUTA_REPO_GUEST FAIL" not in boot.log.read_text()?
}
