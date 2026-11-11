##! Disposable Alpine x86_64 guests under QEMU/KVM, one VM each, with a real
##! OpenRC as PID 1. `up` writes an inventory and `down` stops exactly the VMs
##! and seed servers `up` started. The pinned base image is cached under the
##! fixture directory; each guest runs on a copy-on-write overlay and is reached
##! through a loopback host-forward. The no-cloud seed is served from the host
##! on loopback because QEMU's vvfat driver exposes only 8.3 names.

const base_version = "3.22.8"
const base_name = "alpine-3.22.8-x86_64-bios-cloudinit-r0.qcow2"
const base_url = "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/alpine-3.22.8-x86_64-bios-cloudinit-r0.qcow2"
const base_sha256 = "5c937ea2b0270239e536ea7594c8418789defe972ec3d54d3bfabf5625740379"

const disk_size = "4G"
const memory_mb = 1024
const cpus = 2
const boot_timeout_ms = 600000

type Vm = {name: Str, pid: Int, server_pid: Int, ssh_port: Int, http_port: Int, work: Str}

type State = {vms: List[Vm]}

type Capture = {code: Int, stdout: Str, stderr: Str}

proc ensure_base(cache: Path) [fs, net, process, error] -> Result[Path] {
  cache.mkdir(parents: true)
  let base = fp"{cache}/{base_name}"
  if ! base.exists()? {
    let downloaded = net.download({url: base_url, dest: base, overwrite: true})?
    guard downloaded.status == 200 else {
      fail f"download {base_url} returned HTTP {downloaded.status}"
    }
  }

  let digest = hash.sha256(base)?.hex()
  guard digest == base_sha256 else {
    fail f"{base} has sha256 {digest}, want {base_sha256} (remove the cache and retry)"
  }

  Ok(base)
}

proc free_port(start: Int) [process, error] -> Result[Int] {
  var port = start
  while port < 65000 {
    let listeners = process.port(port)? |> collect()
    if listeners.is_empty() {
      return Ok(port)
    }

    port += 1
  }

  fail "no free TCP port"
}

proc start_seed(seed: Path, port: Int, out: Path, err: Path) [fs, process, time, error] -> Result[Int] {
  let argv = ["python3", "-m", "http.server", "--bind", "127.0.0.1", "--directory", f"{seed}", f"{port}"]
  let command = process.command_argv("python3", argv, p".", {}, b"", out, err, detach: true, new_session: true, ignore_hup: true)
  let spawned = process.spawn(command)?
  for _ in range(20) {
    if ! fp"/proc/{spawned.pid}".exists()? {
      fail f"seed HTTP server on port {port} exited: {err.read_text()?.trim()}"
    }

    let listeners = process.port(port)? |> collect()
    if ! listeners.is_empty() {
      return Ok(spawned.pid)
    }

    time.sleep(100ms)
  }

  let _ = process.kill(spawned.pid, signal: "KILL")
  fail f"seed HTTP server on port {port} did not listen: {err.read_text()?.trim()}"
}

proc stop_process(pid: Int, grace_ms: Int) [fs, process, time, error] -> Result[Unit] {
  if pid <= 0 {
    return
  }

  let _ = process.kill(pid, signal: "TERM")
  let started = time.now()
  while time.now() - started < grace_ms {
    if ! fp"/proc/{pid}".exists()? {
      return
    }

    time.sleep(100ms)
  }

  let _ = process.kill(pid, signal: "KILL")
  time.sleep(200ms)
}

proc ssh_capture(client: Path, port: Int, account: Str, script: Str) [process, error] -> Result[Capture] {
  let out = run.capture --text timeout 30 ssh -i $client -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p $port f"{account}@127.0.0.1" $script
  Ok({code: out.status.exit_code() ?? -1, stdout: out.stdout, stderr: out.stderr})
}

proc wait_ready(client: Path, port: Int) [process, time, error] -> Result[Unit] {
  let started = time.now()
  var last = ""
  while time.now() - started < boot_timeout_ms {
    let probe = ssh_capture(client, port, "deploy", "cloud-init status 2>/dev/null")?
    last = f"exit {probe.code}: {probe.stdout.trim()} {probe.stderr.trim()}"
    if "status: done" in probe.stdout {
      return
    }

    time.sleep(2s)
  }

  fail f"guest on port {port} did not finish cloud-init ({last})"
}

proc verify_guest(client: Path, port: Int) [process, error] -> Result[Unit] {
  let comm = ssh_capture(client, port, "deploy", "cat /proc/1/comm")?
  guard comm.code == 0 and comm.stdout.trim() == "init" else {
    fail f"guest on port {port}: PID 1 is not init: exit {comm.code}: {comm.stdout.trim()} {comm.stderr.trim()}"
  }

  let runlevel = ssh_capture(client, port, "deploy", "rc-status default")?
  guard runlevel.code == 0 and "Runlevel: default" in runlevel.stdout and "sshd" in runlevel.stdout and "started" in runlevel.stdout else {
    fail f"guest on port {port}: default runlevel is not serving sshd: exit {runlevel.code}: {runlevel.stdout.trim()} {runlevel.stderr.trim()}"
  }

  let doas = ssh_capture(client, port, "deploy", "doas -n id -u")?
  guard doas.code == 0 and doas.stdout.trim() == "0" else {
    fail f"guest on port {port}: deploy cannot use doas: exit {doas.code}: {doas.stderr.trim()}"
  }

  let shadow = ssh_capture(client, port, "deploy", "doas -n test -x /usr/sbin/usermod")?
  guard shadow.code == 0 else {
    fail f"guest on port {port}: usermod is not installed"
  }
}

proc host_key_pin(port: Int, keyfile: Path) [fs, process, time, error] -> Result[Str] {
  let started = time.now()
  while time.now() - started < boot_timeout_ms {
    let out = run.capture --text ssh-keyscan -T 5 -t ed25519 -p $port 127.0.0.1
    if out.status.ok {
      for line in out.stdout.lines() {
        let fields = line.fields()
        if fields.len() >= 3 and fields[1] == "ssh-ed25519" {
          keyfile.write(f"{fields[1]} {fields[2]}\n")
          let fingerprint = run.text ssh-keygen -lf $keyfile
          return Ok(fingerprint.fields()[1])
        }
      }
    }

    time.sleep(1s)
  }

  fail f"no ed25519 host key from 127.0.0.1:{port}"
}

proc start_qemu(base: Path, vm: Vm) [fs, process, error] -> Result[Int] {
  let overlay = f"{vm.work}/disk.qcow2"
  let args = [
    "-name", vm.name,
    "-machine", "pc,accel=kvm",
    "-cpu", "host",
    "-smp", f"{cpus}",
    "-m", f"{memory_mb}",
    "-drive", f"file={overlay},if=ide,index=0,format=qcow2",
    "-boot", "order=c",
    "-smbios", f"type=1,serial=ds=nocloud-net;s=http://10.0.2.2:{vm.http_port}/",
    "-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{vm.ssh_port}-:22",
    "-device", "e1000,netdev=net0",
    "-display", "none",
    "-serial", f"file:{vm.work}/serial.log",
    "-monitor", "none",
    "-no-reboot",
    "-daemonize",
    "-pidfile", f"{vm.work}/qemu.pid",
  ]
  let created = run.status qemu-img create -f qcow2 -F qcow2 -b $base $overlay $disk_size
  guard created.ok else {
    fail f"qemu-img create failed for {vm.name}"
  }

  let out = run.capture --text qemu-system-x86_64 @args
  guard out.status.ok else {
    fail f"qemu for {vm.name} failed: {out.stderr.trim()}"
  }

  let pidfile = fp"{vm.work}/qemu.pid"
  guard pidfile.exists()? else {
    fail f"qemu for {vm.name} did not write {pidfile}"
  }

  Ok(pidfile.read_text()?.trim().parse_int()?)
}

proc seed_text(name: Str, run_id: Str, pubkey: Str) -> Str {
  let password = f"xinfra-{run_id}-{name}"
  f"""#cloud-config
hostname: {name}
preserve_hostname: false
ssh_pwauth: false
disable_root: false
users:
  - default
  - name: deploy
    shell: /bin/ash
    groups: [wheel]
    lock_passwd: true
    ssh_authorized_keys:
      - {pubkey}
  - name: plain
    shell: /bin/ash
    lock_passwd: true
    ssh_authorized_keys:
      - {pubkey}
write_files:
  - path: /etc/doas.d/xinfra.conf
    permissions: '0400'
    owner: root:root
    content: |
      permit nopass deploy
  - path: /root/.ssh/authorized_keys
    permissions: '0600'
    owner: root:root
    content: |
      {pubkey}
chpasswd:
  expire: false
  list: |
    root:{password}
    deploy:{password}
    plain:{password}
packages:
  - doas
  - shadow
runcmd:
  - rc-update add sshd default
  - rc-service sshd restart
"""
}

proc cleanup(vms: List[Vm]) [fs, process, time, error] {
  for vm in vms {
    let _ = stop_process(vm.pid, 2000)
    let _ = stop_process(vm.server_pid, 2000)
    let _ = run.status rm -rf -- $vm.work
  }
}

## Download the pinned base image and start COUNT VMs beginning at host number
## FIRST, writing DIR/inventory.toml.
cli main up(count: Int = 2, first: Int = 1, dir: Path = p".work/fixtures/vm") [fs, net, process, time, error] {
  guard count >= 1 and count <= 2 else {
    fail "count must be 1..2: at most two VMs run at once"
  }

  guard first >= 1 else {
    fail "first must be at least 1"
  }

  fp"{dir}".mkdir(parents: true)
  let root = fp"{dir}".resolve()?
  let cache = fp"{root}/cache"
  let base = ensure_base(cache)?
  let client = fp"{root}/client"
  if ! client.exists()? {
    run ssh-keygen -q -t ed25519 -N "" -f $client
  }

  let pubkey = fp"{client}.pub".read_text()?.trim()
  let record = fp"{root}/vms.json"
  guard ! record.exists()? else {
    fail f"{record} exists; run down first"
  }

  let run_id = f"{time.now()}"
  var lines = [
    "[defaults]",
    "user = \"deploy\"",
    "privilege = \"doas\"",
    "key = \"client\"",
    "timeout_ms = 60000",
    "transfer_timeout_ms = 600000",
    "",
  ]
  var vms: List[Vm] = []
  errdefer { cleanup(vms) }
  for index in range(1, count + 1) {
    let number = first + index - 1
    let name = f"fx-{number}"
    let work = f"{root}/vm-{run_id}-{name}"
    let seed = fp"{work}/seed"
    seed.mkdir(parents: true)
    fp"{seed}/meta-data".write(f"instance-id: iid-{run_id}-{name}\nlocal-hostname: {name}\n")
    fp"{seed}/user-data".write(seed_text(name, run_id, pubkey))
    fp"{seed}/vendor-data".write("")
    fp"{seed}/network-config".write("")

    let base_port = 20000 + time.now() % 20000
    let http_port = free_port(base_port)?
    let ssh_port = free_port(http_port + 1)?
    let vm = Vm(name:, pid: 0, server_pid: 0, ssh_port:, http_port:, work:)
    let server_pid = start_seed(seed, http_port, fp"{work}/http.log", fp"{work}/http.err")?
    vms += [{...vm, server_pid: server_pid}]
    let pid = start_qemu(base, {...vm, server_pid: server_pid})?
    vms[vms.len() - 1] = {...vm, pid: pid, server_pid: server_pid}
    wait_ready(client, ssh_port)?
    verify_guest(client, ssh_port)?
    let pin = host_key_pin(ssh_port, fp"{work}/host.pub")?
    stop_process(server_pid, 2000)?
    guard ! fp"/proc/{server_pid}".exists()? else {
      fail f"{name}: seed server pid {server_pid} is still running"
    }

    vms[vms.len() - 1] = {...vm, pid: pid, server_pid: 0}

    lines += [
      f"[hosts.{name}]",
      "address = \"127.0.0.1\"",
      f"port = {ssh_port}",
      f"host_key = \"{pin}\"",
      "",
      f"[hosts.{name}-root]",
      "address = \"127.0.0.1\"",
      f"port = {ssh_port}",
      "user = \"root\"",
      "privilege = \"root\"",
      f"host_key = \"{pin}\"",
      "",
      f"[hosts.{name}-plain]",
      "address = \"127.0.0.1\"",
      f"port = {ssh_port}",
      "user = \"plain\"",
      "privilege = \"doas\"",
      f"host_key = \"{pin}\"",
      "",
    ]
  }

  fp"{root}/inventory.toml".write(lines.join("\n") + "\n")
  json.write(record, {vms: vms})?
  print f"started {vms.len()} VM(s) on Alpine {base_version}; inventory at {root}/inventory.toml"
}

## Stop the VMs recorded in DIR/vms.json and remove their work directories.
cli main down(dir: Path = p".work/fixtures/vm") [fs, process, time, error] {
  let record = fp"{dir}/vms.json"
  if ! record.exists()? {
    return
  }

  let state = json.read(record)?.require(State)?
  for vm in state.vms {
    stop_process(vm.pid, 10000)?
    stop_process(vm.server_pid, 2000)?
    guard ! fp"/proc/{vm.pid}".exists()? else {
      fail f"{vm.name}: qemu pid {vm.pid} is still running"
    }

    guard ! fp"/proc/{vm.server_pid}".exists()? else {
      fail f"{vm.name}: seed server pid {vm.server_pid} is still running"
    }

    let _ = run.status rm -rf -- $vm.work
  }

  record.remove()
  print f"removed {state.vms.len()} VM(s)"
}
