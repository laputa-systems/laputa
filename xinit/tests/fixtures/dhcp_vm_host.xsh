#!/bin/xsh --
##! Host side of the DHCP virtual machine qualification. It stages an initramfs
##! holding a frozen xsh and its `core/` tree, boots it in QEMU with a kernel
##! the caller supplies, follows the serial console for `VMMARK` lines and
##! drives the machine over QMP: `stop` and `cont` for a pause of a chosen
##! length and `set_link` for a carrier flap. The guest re-enumerates its own
##! virtio-net device, because the supplied kernel has no PCI hotplug driver for
##! `device_del` to reach. Every number printed is a measurement, not a pass condition.
##!
##! Run from the Laputa checkout root:
##!   dhcp_vm_host.xsh XSH_ROOT KERNEL SCRATCH SCENARIO [SECONDS [QEMU_ARGUMENT...]]
##! `XSH_ROOT` holds a static `bin/xsh` and the matching `core/`; `SCENARIO` is
##! `pause` (SECONDS long), `wall` or `nic`. Output is one `HOSTRESULT` JSON line.

const QMP_TIMEOUT_MS = 10000

type Qmp = {fd: Int}

proc clock_ms() -> Result[Int] {
  time.monotonic()? / 1000000
}

proc stage(xsh_root: Path, scratch: Path) -> Result[Path] {
  let root = fp"{scratch}/root"
  for directory in ["bin", "guest", "proc", "sys", "dev", "run", "tmp", "etc"] {
    fp"{root}/{directory}".mkdir(parents: true)?
  }
  let fixtures = fp"{fs.cwd()?}/xinit/tests/fixtures"
  for guest in fs.children(fixtures)? {
    if guest.name.starts_with("dhcp_") and guest.name.ends_with("_guest.xsh") {
      let _ = fs.copy_file(guest.path, fp"{root}/guest/{guest.name}")?
    }
  }
  let _ = fs.copy_file(fp"{fixtures}/dhcp_boot_guest.xsh", fp"{root}/init")?
  fp"{root}/init".chmod(0o755)?
  let _ = fs.copy_file(fp"{xsh_root}/bin/xsh", fp"{root}/bin/xsh")?
  fp"{root}/bin/xsh".chmod(0o755)?
  let _ = fs.copy_tree(fp"{xsh_root}/core", fp"{root}/core")?
  let packed = process.run(process.command_argv("/bin/sh", ["sh", "-c", "find . | cpio -o -H newc 2>/dev/null | gzip -1 > ../initrd.gz"], root, timeout: 120s))?
  assert packed.ok, "the initramfs could not be packed"
  fp"{scratch}/initrd.gz"
}

proc qmp_read_line(fd: Int) -> Result[Str] {
  var line = b""
  let deadline = clock_ms()? + QMP_TIMEOUT_MS
  while clock_ms()? < deadline {
    if unix.poll_fd(fd, ["readable"], 100)? == ["readable"] {
      let chunk = unix.read_fd(fd, 1)?
      assert ! chunk.is_empty(), "QMP closed the connection"
      if chunk.byte_at(0) == 10 {
        return line.utf8()?
      }
      line = bytes.concat([line, chunk])
    }
  }
  Err(error.failure("QMP did not answer"))
}

proc qmp_command(qmp: Qmp, text: Str) -> Result[Str] {
  let _ = unix.write_fd(qmp.fd, bytes.from_text(text + "\n"))?
  while true {
    let line = qmp_read_line(qmp.fd)?
    if "\"return\"" in line or "\"error\"" in line {
      assert "\"error\"" not in line, f"QMP rejected {text}: {line}"
      return line
    }
  }
  Err(error.failure("unreachable"))
}

proc qmp_open(socket_path: Path) -> Result[Qmp] {
  let c = linux.net_constants()
  var tries = 0
  while tries < 100 {
    if socket_path.exists()? {
      let fd = linux.socket(c.AF_UNIX, c.SOCK_STREAM)?
      match linux.connect(fd, {family: "unix", address: socket_path.display()}) {
        Ok(_) => {
          let qmp = Qmp(fd:)
          let greeting = qmp_read_line(fd)?
          assert "QMP" in greeting, greeting
          let _ = qmp_command(qmp, "{\"execute\":\"qmp_capabilities\"}")?
          return qmp
        }
        Err(_) => unix.close_fd(fd)?
      }
    }
    time.sleep(50ms)
    tries += 1
  }
  Err(error.failure("the QMP socket never appeared"))
}

proc console_text(log: Path) -> Result[Str] {
  if log.exists()? { log.read_text()? } else { "" }
}

proc wait_for_text(log: Path, needle: Str, timeout_ms: Int) -> Result[Str] {
  let deadline = clock_ms()? + timeout_ms
  while clock_ms()? < deadline {
    let text = console_text(log)?
    if needle in text {
      return text
    }
    assert "Kernel panic" not in text, "the guest kernel panicked"
    time.sleep(20ms)
  }
  Err(error.failure(f"timed out waiting for {needle} in the guest console"))
}

proc occurrences(text: Str, needle: Str) -> Int {
  var found = 0
  for line in text.lines() {
    if line.trim() == needle {
      found += 1
    }
  }
  found
}

proc wait_for_count(log: Path, needle: Str, count: Int, timeout_ms: Int) -> Result[Int] {
  let deadline = clock_ms()? + timeout_ms
  while clock_ms()? < deadline {
    let text = console_text(log)?
    assert "Kernel panic" not in text, "the guest kernel panicked"
    if occurrences(text, needle) >= count {
      return clock_ms()?
    }
    time.sleep(10ms)
  }
  Err(error.failure(f"timed out waiting for {count} of {needle} in the guest console"))
}

proc line_with(text: Str, prefix: Str) -> Str {
  for line in text.lines() {
    if line.starts_with(prefix) {
      return line.byte_slice(prefix.byte_len()).trim()
    }
  }
  ""
}

proc qemu_argv(kernel: Path, initrd: Path, scratch: Path, scenario: Str, with_nic: Bool, extra: List[Str]) -> List[Str] {
  let guest = if scenario == "nic" { "network" } else { "clock" }
  let base = [
    "qemu-system-x86_64",
    "-enable-kvm",
    "-cpu",
    "host",
    "-m",
    "512",
    "-smp",
    "2",
    "-display",
    "none",
    "-monitor",
    "none",
    "-no-reboot",
    "-serial",
    f"file:{scratch}/console.log",
    "-qmp",
    f"unix:{scratch}/qmp.sock,server=on,wait=off",
    "-kernel",
    kernel.display(),
    "-initrd",
    initrd.display(),
    "-append",
    f"console=ttyS0 rdinit=/init panic=-1 loglevel=3 dhcpvm={guest} dhcpmode={scenario}",
  ]
  let devices = if with_nic { ["-netdev", "user,id=n0", "-device", "virtio-net-pci,id=nic0,netdev=n0,mac=02:00:00:00:00:01"] } else { [] }
  base.extend(devices).extend(extra)
}

proc run_pause(qmp: Qmp, console: Path, seconds: Int) -> Result[Str] {
  let _ = wait_for_text(console, "VMMARK sampling", 120000)?
  time.sleep(10s)
  let stopped = clock_ms()?
  let _ = qmp_command(qmp, "{\"execute\":\"stop\"}")?
  time.sleep(seconds * 1s)
  let _ = qmp_command(qmp, "{\"execute\":\"cont\"}")?
  let resumed = clock_ms()?
  f"{resumed - stopped}"
}

type Action = {what: Str, host_ms: Int}

proc run_nic(qmp: Qmp, console: Path) -> Result[List[Action]] {
  var actions: List[Action] = []
  let _ = wait_for_count(console, "VMMARK state bound", 1, 120000)?
  time.sleep(2s)
  let down = clock_ms()?
  let _ = qmp_command(qmp, "{\"execute\":\"set_link\",\"arguments\":{\"name\":\"nic0\",\"up\":false}}")?
  actions += [Action(what: "set_link_down", host_ms: down)]
  let lost = wait_for_count(console, "VMMARK state no_link", 1, 30000)?
  actions += [Action(what: "client_reports_no_link", host_ms: lost)]
  time.sleep(3s)
  let up = clock_ms()?
  let _ = qmp_command(qmp, "{\"execute\":\"set_link\",\"arguments\":{\"name\":\"nic0\",\"up\":true}}")?
  actions += [Action(what: "set_link_up", host_ms: up)]
  let again = wait_for_count(console, "VMMARK state bound", 2, 60000)?
  actions += [Action(what: "client_bound_after_flap", host_ms: again)]
  actions
}

proc main(...argv: List[Str]) {
  assert argv.len() >= 4, "usage: dhcp_vm_host.xsh XSH_ROOT KERNEL SCRATCH SCENARIO [SECONDS]"
  let xsh_root = fp"{argv[0]}"
  let kernel = fp"{argv[1]}"
  let scratch = fp"{argv[2]}"
  let scenario = argv[3]
  let seconds = if argv.len() > 4 { argv[4] as Int } else { 0 }
  let extra = if argv.len() > 5 { argv[5..] } else { [] }
  assert scenario in ["pause", "wall", "nic"], "scenario is pause, wall or nic"
  scratch.mkdir(parents: true)?
  let initrd = stage(xsh_root, scratch)?
  let console = fp"{scratch}/console.log"
  let child = spawn process.command_argv("qemu-system-x86_64", qemu_argv(kernel, initrd, scratch, scenario, scenario == "nic", extra), scratch, stdout: fp"{scratch}/qemu.out", stderr: fp"{scratch}/qemu.err")?
  defer child.cancel(signal: "TERM", kill_after: 5s)
  let qmp = qmp_open(fp"{scratch}/qmp.sock")?
  var held_ms = ""
  if scenario == "pause" {
    held_ms = run_pause(qmp, console, seconds)?
  }
  var actions: List[Action] = []
  if scenario == "nic" {
    actions = run_nic(qmp, console)?
  }
  let text = wait_for_text(console, "VMEXIT", 600000)?
  let guest = json.decode(line_with(text, "VMRESULT "))?
  let report = json.encode({scenario: scenario, requested_pause_seconds: seconds, host_stop_to_cont_ms: held_ms, extra_qemu_arguments: extra, host_actions: actions, guest: guest})?
  print f"HOSTRESULT {report}"
}

main(@args)?
