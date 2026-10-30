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

      if "LAPUTA_REPO_GUEST FAIL" in text or "LAPUTA_TRUST_GUEST FAIL" in text {
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

proc stage_initramfs(ctx: TestContext, xsh: Path, modules_dir: Path) [fs, process, env, error] -> Result[Path, Error] {
  let root = test.temp_dir(ctx, name: "repo-guest-root")?
  for dir in ["bin", "guest", "lib/pm", "lib/modules", "store", "proc", "sys", "dev", "tmp"] {
    fp"{root}/{dir}".mkdir(parents: true)
  }
  xsh.copy(to: fp"{root}/bin/xsh", overwrite: true)?
  fp"{root}/bin/xsh".chmod(0o755)
  p"guest/trust-guest-init.xsh".copy(to: fp"{root}/init", overwrite: true)?
  fp"{root}/init".chmod(0o755)
  p"guest/repo-snapshot-guest.xsh".copy(to: fp"{root}/guest/main.xsh", overwrite: true)?
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
