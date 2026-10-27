##! Guest proof: trust activation across reboot, replay, and power-cut.
##! Each test boots a real KVM guest from the host kernel with a staged
##! initramfs (static xsh, trust modules, seeds, fixture key, release B) and
##! a dedicated ext4 store disk. The host serves release C over fixture TLS
##! on 10.0.2.2; the guest reaches it through QEMU user-mode networking. The
##! serial console carries the verdict: every assertion below reads markers
##! the guest printed, including the exact bundle and policy digests the host
##! recomputes from fixtures. Missing KVM, kernel, modules, or image tools
##! skip the test instead of faking the proof.

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

proc fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/trust-update/{name}"
}

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

proc stage_initramfs(ctx: TestContext, name: Str, xsh: Path, modules_dir: Path) [fs, process, env, error] -> Result[Path, Error] {
  let root = test.temp_dir(ctx, name: name)?
  let key_bytes = fixture("keys/signing-key.public.base64").read_text()?.trim().base64_decode()?
  guard key_bytes.len() == 32 else {
    test.skip("guest proof needs the fixture verification key")
    return root
  }

  for dir in ["bin", "guest", "lib/trust", "lib/pm", "lib/modules", "etc/laputa", "etc/ssl/certs", "var/lib/laputa", "usr/share/laputa/trust/seed", "releases/release-b", "store", "proc", "sys", "dev", "tmp"] {
    fp"{root}/{dir}".mkdir(parents: true)
  }

  xsh.copy(to: fp"{root}/bin/xsh", overwrite: true)?
  fp"{root}/bin/xsh".chmod(0o755)
  p"guest/trust-guest-init.xsh".copy(to: fp"{root}/init", overwrite: true)?
  fp"{root}/init".chmod(0o755)
  p"guest/trust-guest.xsh".copy(to: fp"{root}/guest/main.xsh", overwrite: true)?
  fp"{root}/guest/main.xsh".chmod(0o755)
  for entry in fs.children(p"trust")? {
    if entry.name.ends_with(".xsh") {
      entry.path.copy(to: fp"{root}/lib/trust/{entry.name}", overwrite: true)?
    }
  }

  for entry in fs.children(p"pm")? {
    if entry.name.ends_with(".xsh") {
      entry.path.copy(to: fp"{root}/lib/pm/{entry.name}", overwrite: true)?
    }
  }

  fp"packages/ca-certificates/files/cacert.pem".copy(to: fp"{root}/usr/share/laputa/trust/seed/ca-certificates.crt", overwrite: true)?
  fp"packages/ca-certificates/files/trust-policy".copy(to: fp"{root}/usr/share/laputa/trust/seed/trust-policy", overwrite: true)?

  fp"{root}/etc/laputa/trust-update-key".write(key_bytes, mode: 0o444)
  fp"{root}/etc/ssl/certs/ca-certificates.crt".symlink(to: p"../../../var/lib/laputa/trust/active/ca-certificates.crt")
  fp"{root}/etc/laputa/trust-policy".symlink(to: p"../../var/lib/laputa/trust/active/trust-policy")
  fp"{root}/etc/ssl/cert.pem".symlink(to: p"certs/ca-certificates.crt")
  fp"{root}/var/lib/laputa/trust".symlink(to: p"/store/trust")
  for file in ["metadata", "metadata.sig", "ca-certificates.crt", "trust-policy"] {
    fp"{fixture("release-b")}/{file}".copy(to: fp"{root}/releases/release-b/{file}", overwrite: true)?
  }
  fp"{root}/releases/release-c".mkdir(parents: true)
  for file in ["metadata", "metadata.sig", "ca-certificates.crt", "trust-policy"] {
    fp"{fixture("release-c")}/{file}".copy(to: fp"{root}/releases/release-c/{file}", overwrite: true)?
  }

  for name in GUEST_MODULES {
    let command = process.command_argv(
      "gzip",
      ["gzip", "-dc", fp"{modules_dir}/kernel/{guest_module_path(name)}.ko.gz".display()],
      root,
      {PATH: "/usr/bin:/bin"},
      stdout: fp"{root}/lib/modules/{name}.ko",
    )
    let status = process.run(command)?
    guard status.ok else {
      test.skip(f"guest proof cannot decompress module {name}")
      return root
    }
  }

  root
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

      if "LAPUTA_TRUST_GUEST FAIL" in text {
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

type GuestTlsServer = {port: Int, pid: Int, handle: ProcessHandle}

proc wait_for_port(port_file: Path, attempts: Int) [fs, time, error] -> Result[Int, Error] {
  var tries = 0
  while tries < attempts {
    if port_file.exists()? {
      let text = port_file.read_text()?.trim()
      if text != "" {
        return text.parse_int_decimal()
      }
    }

    time.sleep(100ms)?
    tries += 1
  }

  test.skip("fixture TLS server did not publish its port")
  0
}

proc serve_release_c(
  ctx: TestContext,
  name: Str,
  drip: Str,
  delay_ms: Str,
) [fs, process, env, time, error] -> Result[GuestTlsServer, Error] {
  let dir = test.temp_dir(ctx, name: name)?
  let port_file = fp"{dir}/port"
  let port_text = port_file.display()
  let chain = fixture("tls/server-guest.crt").display()
  let key = fixture("tls/server-guest.key").display()
  let docroot = fixture("release-c").display()
  let script = fp"tests/pm/fixtures/trust-update/tls_server.py"
  let python = process.which("python3")?.display()
  if drip != "" {
    let child = spawn run $python $script $chain $key $port_text $docroot --drip $drip --delay-ms $delay_ms ?
    return {port: wait_for_port(port_file, 100)?, pid: child.pid, handle: child}
  }

  let child = spawn run $python $script $chain $key $port_text $docroot ?
  {port: wait_for_port(port_file, 100)?, pid: child.pid, handle: child}
}

proc stop_server(server: GuestTlsServer) [process, error] {
  match process.kill(server.pid, signal: "KILL") {
    Ok(_) => {},
    Err(_) => {},
  }

  match process.wait_any([server.handle]) {
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
  mode: Str,
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
    "-append", f"console=ttyS0 earlyprintk=serial devtmpfs.mount=1 init=/init XSH_LINUX_REAL=1 XSH_UNIX_REAL=1 trust_url={url} trust_mode={mode}",
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

type GuestDigests = {b_bundle: Str, b_policy: Str, c_bundle: Str, c_policy: Str}

proc expected_digests() [fs, error] -> Result[GuestDigests, Error] {
  {
    b_bundle: fixture("release-b/ca-certificates.crt").read_bytes()?.sha256().hex(),
    b_policy: fixture("release-b/trust-policy").read_bytes()?.sha256().hex(),
    c_bundle: fixture("release-c/ca-certificates.crt").read_bytes()?.sha256().hex(),
    c_policy: fixture("release-c/trust-policy").read_bytes()?.sha256().hex(),
  }
}

proc assert_clean_markers(text: Str, digests: GuestDigests, phase0: Bool) [error] {
  assert "LAPUTA_TRUST_GUEST FAIL" not in text
  if phase0 {
    assert f"PHASE0_OK generation=2 bundle={digests.b_bundle} policy={digests.b_policy}" in text
  }
}

test trust_guest_reboot_replays_clean_generation [fs, process, env, time, error] { |ctx|
  guest_file_or_skip(p"/dev/kvm", "KVM")?
  let kernel = guest_kernel()?
  let modules_dir = guest_modules_dir()?
  let xsh = guest_xsh()?
  let _ = guest_tool_or_skip("cpio")?
  let _ = guest_tool_or_skip("mke2fs")?
  let _ = guest_tool_or_skip("gzip")?
  let _ = guest_tool_or_skip("python3")?
  let digests = expected_digests()?
  let server = serve_release_c(ctx, "trust-guest-https", "", "")?
  defer stop_server(server)?

  let url = f"https://10.0.2.2:{server.port}/"
  let work = test.temp_dir(ctx, name: "trust-guest-replay-work")?
  let staging = stage_initramfs(ctx, "trust-guest-replay-root", xsh, modules_dir)?
  let initramfs = fp"{work}/initramfs.cpio"
  build_initramfs(staging, initramfs)?
  let store = fp"{work}/store.ext4"
  build_store_disk(store, 64)?

  let boot = launch_guest(ctx, "trust-guest-replay", kernel, initramfs, store, url, "replay")?
  defer stop_guest(boot.pid)?
  var text = wait_for_marker(boot.log, "PHASE0_OK", 50)?
  assert_clean_markers(text, digests, true)?
  text = wait_for_marker(boot.log, "BOOT phase=1", 50)?
  text = wait_for_marker(boot.log, "PHASE1_OK", 50)?
  assert f"PHASE1_OK generation=3 bundle={digests.c_bundle} policy={digests.c_policy}" in text
  text = wait_for_marker(boot.log, "BOOT phase=2", 50)?
  text = wait_for_marker(boot.log, "REPLAY_OK", 50)?
  assert f"REPLAY_OK generation=3 bundle={digests.c_bundle} policy={digests.c_policy}" in text
  wait_for_exit(boot.pid, 50)?
  let final = boot.log.read_text()?
  assert "LAPUTA_TRUST_GUEST FAIL" not in final
  assert "ENTRY phase=1 active=2 journal=false" in final
  assert "ENTRY phase=2 active=3 journal=false" in final
}

test trust_guest_power_cut_recovers_forward [fs, process, env, time, error] { |ctx|
  guest_file_or_skip(p"/dev/kvm", "KVM")?
  let kernel = guest_kernel()?
  let modules_dir = guest_modules_dir()?
  let xsh = guest_xsh()?
  let _ = guest_tool_or_skip("cpio")?
  let _ = guest_tool_or_skip("mke2fs")?
  let _ = guest_tool_or_skip("gzip")?
  let _ = guest_tool_or_skip("python3")?
  let digests = expected_digests()?
  let server = serve_release_c(ctx, "trust-guest-cut-https", "1024", "250")?
  defer stop_server(server)?

  let url = f"https://10.0.2.2:{server.port}/"
  let work = test.temp_dir(ctx, name: "trust-guest-cut-work")?
  let staging = stage_initramfs(ctx, "trust-guest-cut-root", xsh, modules_dir)?
  let initramfs = fp"{work}/initramfs.cpio"
  build_initramfs(staging, initramfs)?
  let store = fp"{work}/store.ext4"
  build_store_disk(store, 64)?

  let first = launch_guest(ctx, "trust-guest-cut-first", kernel, initramfs, store, url, "once")?
  var text = wait_for_marker(first.log, "PHASE0_OK", 50)?
  assert_clean_markers(text, digests, true)?
  text = wait_for_marker(first.log, "FETCH_START", 50)?
  time.sleep(2s)?
  stop_guest(first.pid)?
  wait_for_exit(first.pid, 30)?
  let cut = first.log.read_text()?
  assert "LAPUTA_TRUST_GUEST FAIL" not in cut
  assert "ENTRY phase=1 active=2 journal=false" in cut

  let second = launch_guest(ctx, "trust-guest-cut-second", kernel, initramfs, store, url, "once")?
  defer stop_guest(second.pid)?
  text = wait_for_marker(second.log, "PHASE1_OK", 50)?
  assert f"PHASE1_OK generation=3 bundle={digests.c_bundle} policy={digests.c_policy}" in text
  wait_for_exit(second.pid, 50)?
  let final = second.log.read_text()?
  assert "LAPUTA_TRUST_GUEST FAIL" not in final
  assert "ENTRY phase=1 active=2 journal=" in final or "ENTRY phase=1 active=3 journal=" in final, final

  assert "active=1" not in final
}

test trust_guest_rejects_stale_journal_without_mutation [fs, process, env, time, error] { |ctx|
  guest_file_or_skip(p"/dev/kvm", "KVM")?
  let kernel = guest_kernel()?
  let modules_dir = guest_modules_dir()?
  let xsh = guest_xsh()?
  let _ = guest_tool_or_skip("cpio")?
  let _ = guest_tool_or_skip("mke2fs")?
  let _ = guest_tool_or_skip("gzip")?
  let digests = expected_digests()?

  let work = test.temp_dir(ctx, name: "trust-guest-stale-work")?
  let staging = stage_initramfs(ctx, "trust-guest-stale-root", xsh, modules_dir)?
  let initramfs = fp"{work}/initramfs.cpio"
  build_initramfs(staging, initramfs)?
  let store = fp"{work}/store.ext4"
  build_store_disk(store, 64)?

  let boot = launch_guest(ctx, "trust-guest-stale", kernel, initramfs, store, "https://10.0.2.2:1/", "stale")?
  defer stop_guest(boot.pid)?
  var text = wait_for_marker(boot.log, "PHASE0_OK", 50)?
  assert_clean_markers(text, digests, true)?
  text = wait_for_marker(boot.log, "BOOT phase=1", 50)?
  text = wait_for_marker(boot.log, "STALE_OK", 50)?
  assert f"STALE_OK generation=2 bundle={digests.b_bundle} policy={digests.b_policy}" in text
  wait_for_exit(boot.pid, 50)?
  let final = boot.log.read_text()?
  assert "LAPUTA_TRUST_GUEST FAIL" not in final
  assert "ENTRY phase=1 active=2 journal=false" in final
}
