#!/usr/bin/env python3
"""Run the roadmap G2 steps 1-5 on one installed x86_64/KVM VM.

Step 1 provisions a fresh state disk, installs generation A from a built
bundle through the host activation record, and keeps the immutable image free
of operator keys.
Step 2 connects over XSH's verified native SSH client, inspects the running
generation, services, lease, resolver, clock service and redacted diagnostics,
then exercises a supervised logger restart, a DHCP daemon restart, and a
QMP link loss followed by reconnection.
Step 3 stages an operator-authorized generation B while A keeps running,
reconciles a lost reply and an SSH disconnect through the existing drills, and
records the pending operation.
Step 4 boots the admitted B twice into a kernel panic; the launcher then
selects the retained A after the bounded attempts and the state disk survives.
Step 5 stages a repaired C, verifies its running receipt and declared service
health over SSH, confirms it, and inspects the activation history across the
following reboot.

The test consumes a bundle produced by the existing builder; it does not
rebuild it. Staging digests pin bytes and are not an authenticity claim. The
PM generation_sha256 is the publisher identity the guest reports back.
"""

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import traceback

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRATCH_ROOT = ROOT / ".work/tmp"
DEFAULT_XSH = ROOT / ".out/seed/x86_64/xsh"
DEFAULT_BUNDLE = ROOT / "target/laputa/qemu-maintained/current"
DEFAULT_ARTIFACT_STORE = ROOT / ".out/artifacts/x86_64/v2/sha256"
CRITICAL_SERVICES = ["dhcp-eth0", "dropbear", "logger"]
OPERATOR = "probe"
ADMIN = "g2admin"
PROFILE = "qemu-maintained"

DEFAULT_XSH = pathlib.Path(os.environ.get("LAPUTA_XSH", DEFAULT_XSH))
DEFAULT_BUNDLE = pathlib.Path(os.environ.get("LAPUTA_QEMU_BUNDLE", DEFAULT_BUNDLE))
DEFAULT_ARTIFACT_STORE = pathlib.Path(os.environ.get("LAPUTA_ARTIFACT_STORE", DEFAULT_ARTIFACT_STORE))

HOST_DRIVER = r'''use system.activation
use system.build
use system.launcher
use system.qemu
use system.types
use profiles.qemu-maintained as maintained

proc receipt(id: Str, digest: Str) -> activation.GenerationReceipt {
  {id: id, kernel: "boot/vmlinuz", root_digest: digest}
}

proc summary(record: activation.ActivationRecord) -> Record {
  {
    current: record.current.id,
    fallback: record.fallback.id,
    pending: if record.pending == null { null } else { record.pending.id },
    attempts: record.boot_attempts,
    serial: record.boot_serial,
    max_attempts: record.max_boot_attempts,
    last: record.last_operation,
    policy_revision: record.admission_policy.revision,
    policy_ids: [image.generation.id for image in record.admission_policy.images],
  }
}

proc main(...argv: List[Str]) [fs, process, env, time, error] {
  let operation = argv[0]
  let state = Path(argv[1])
  if operation == "install" {
    state.mkdir()
    let digest = argv[2]
    let admitted = activation.activation_publish_image(state, receipt("a", digest), Path(argv[3]), Path(argv[4]), activation.ACTIVATION_STATE_FORMAT)?
    activation.activation_install(state, receipt("a", digest), {revision: 1, images: [admitted]})?
    print json.encode(summary(activation.activation_status(state)?))?
  } else if operation == "stage" {
    let id = argv[2]
    let digest = argv[3]
    let record = activation.activation_status(state)?
    let admitted = activation.activation_publish_image(state, receipt(id, digest), Path(argv[4]), Path(argv[5]), activation.ACTIVATION_STATE_FORMAT)?
    activation.activation_update_policy(state, {revision: record.admission_policy.revision + 1, images: record.admission_policy.images + [admitted]})?
    activation.activation_stage(state, receipt(id, digest))?
    print json.encode(summary(activation.activation_status(state)?))?
  } else if operation == "status" {
    print json.encode(summary(activation.activation_status(state)?))?
  } else if operation == "argv" {
    let outputs_root = Path(argv[2])
    let target = qemu.host_qemu_target()?
    let config = qemu.qemu_config(target)?
    let outputs = build.outputs(outputs_root)
    print json.encode({argv: qemu.boot_command_argv(config, maintained.profile, outputs, types.Test, state)?})?
  } else if operation == "confirm" {
    let report = json.read(Path(argv[2]))?.require(activation.GuestHealthReport)?
    var critical: List[Str] = []
    for name in argv[3].split(",") {
      if name != "" {
        critical += [name]
      }
    }
    activation.activation_confirm_guest_health(state, report, {profile: argv[4], critical_services: critical})?
    print json.encode(summary(activation.activation_status(state)?))?
  } else if operation == "verify" {
    let image = activation.activation_verify_image(state, receipt(argv[2], argv[3]))?
    print json.encode({id: image.id, kernel: image.kernel_file.display(), disk: image.disk_file.display()})?
  } else if operation == "restage" {
    activation.activation_stage(state, receipt(argv[2], argv[3]))?
    print json.encode(summary(activation.activation_status(state)?))?
  } else {
    fail "unknown host driver operation"
  }
}
main(@args)?
'''

PROVISION_DRIVER = r'''use system.first_boot

proc main(...argv: List[Str]) [fs, error] {
  let root = Path(argv[0])
  let operator = argv[1]
  let hostname = argv[2]
  let key = argv[3]
  let document = f"hostname {hostname}\noperator {operator}\nauthorized-key {key}\nnetwork dhcp\ntailscale no\nidentity restore\n"
  first_boot.apply(root, document)?
  print "applied"
}
main(@args)?
'''

REMOTE_DRIVER = r'''use system.remote

proc main(...argv: List[Str]) [fs, process, net, env, time, error, io] {
  let repo = Path(argv[0])
  let port = argv[1].parse_int()?
  let key = Path(argv[2])
  let host_key = argv[3]
  let account = argv[4]
  let operation = argv[5]
  let timeout_ms = argv[6].parse_int()?
  let program = remote.remote_program(repo)?
  let target: remote.RemoteTarget = {host: "127.0.0.1", port: port, user: account, key: key, host_key: host_key, timeout_ms: timeout_ms}
  if operation == "inspect" {
    with session = remote.remote_connect(target)? {
      print json.encode(remote.remote_inspect(session, program)?)?
    }
  } else if operation == "info" {
    with session = remote.remote_connect(target)? {
      print json.encode(ssh.info(session)?)?
    }
  } else if operation == "run" {
    let request = json.decode(argv[7])?.require(List[Str])?
    with session = remote.remote_connect(target)? {
      let result = remote.remote_run(session, program, request)?
      print json.encode({exit_code: result.exit_code, signaled: result.signaled, truncated: result.truncated, stdout: result.stdout.utf8() ?? "", stderr: result.stderr.utf8() ?? ""})?
    }
  } else if operation == "read" {
    let log_path = argv[7]
    with session = remote.remote_connect(target)? {
      let result = remote.remote_run(session, program, ["/usr/bin/cat", log_path])?
      print json.encode({exit_code: result.exit_code, stdout: result.stdout.utf8() ?? "", stderr: result.stderr.utf8() ?? ""})?
    }
  } else if operation == "stage" {
    let source = Path(argv[7])
    let name = argv[8]
    let digest = remote.remote_digest(source)?
    with session = remote.remote_connect(target)? {
      print json.encode(remote.remote_stage(session, program, source, name, digest)?)?
    }
  } else if operation == "diagnose" {
    with session = remote.remote_connect(target)? {
      print json.encode(remote.remote_diagnose(session, program)?)?
    }
  } else if operation == "wrong-key" {
    let wrong: remote.RemoteTarget = {...target, host_key: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
    match remote.remote_connect(wrong) {
      Ok(_) => fail "a wrong host key was accepted"
      Err(SshError.HostKeyMismatch {..}) => print "refused"
      Err(other) => fail "unexpected host key failure: " + other.message
    }
  } else {
    fail "unknown remote driver operation"
  }
}
main(@args)?
'''

POWEROFF = r'''#!/bin/xsh

proc main() [process, error] {
  process.kill(1, signal: "USR2")?
}
main()?
'''


def log(message):
    print(f"[g2] {message}", flush=True)


def fail(message):
    raise AssertionError(message)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def contains_bytes(path, needle):
    overlap = len(needle) - 1
    tail = b""
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            window = tail + chunk
            if needle in window:
                return True
            tail = window[-overlap:] if overlap else b""
    return False


def require_prerequisites(args, work):
    missing = []
    for label, path in (
        ("xsh", args.xsh),
        ("bundle", args.bundle),
        ("kernel", args.bundle / "vmlinuz"),
        ("disk", args.bundle / "disk.img"),
        ("generation", args.bundle / "generation.json"),
        ("state formatter", ROOT / "packages/laputa-fs/files/mkfs.ext4.xsh"),
        ("activation recovery", ROOT / "tests/integration/activation_recovery.py"),
        ("activation ssh", ROOT / "tests/integration/activation_ssh.py"),
        ("ssh-keygen", pathlib.Path(shutil.which("ssh-keygen") or "/nonexistent")),
        ("qemu-system-x86_64", pathlib.Path(shutil.which("qemu-system-x86_64") or "/nonexistent")),
        ("strace", pathlib.Path(shutil.which("strace") or "/nonexistent")),
        ("unshare", pathlib.Path(shutil.which("unshare") or "/nonexistent")),
        ("mount", pathlib.Path(shutil.which("mount") or "/nonexistent")),
        ("kvm", pathlib.Path("/dev/kvm")),
    ):
        if not path.exists():
            missing.append(f"{label}: {path}")
    if os.uname().machine != "x86_64":
        missing.append(f"host architecture {os.uname().machine} is not x86_64")
    if not args.dropbearkey.exists():
        missing.append(f"dropbearkey: {args.dropbearkey} (pass --dropbearkey or set LAPUTA_ARTIFACT_STORE)")
    if missing:
        print("SKIP: missing prerequisites:\n  " + "\n  ".join(missing), file=sys.stderr)
        sys.exit(77)


def run(argv, env, timeout=120, check=True):
    result = subprocess.run(argv, env=env, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(str(item) for item in argv)}\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return result


def xsh_env(work):
    return dict(os.environ, XSH_MODULE_PATH=str(ROOT), LC_ALL="C", TMPDIR=str(work / "tmp"))


def run_xsh(args, work, *argv, timeout=120, check=True):
    return run([str(args.xsh), *[str(item) for item in argv]], xsh_env(work), timeout=timeout, check=check)


def last_json(text):
    lines = [line for line in text.strip().splitlines() if line.strip()]
    if not lines:
        raise RuntimeError("expected a JSON line, got no output")
    return json.loads(lines[-1])


def host(args, work, operation, *extra, timeout=120, check=True):
    result = run_xsh(args, work, work / "host-driver.xsh", "--", operation, *[str(item) for item in extra], timeout=timeout, check=check)
    return last_json(result.stdout) if check else result


def remote(args, work, port, key, pin, operation, *extra, user=OPERATOR, timeout=30, check=True):
    result = run_xsh(
        args, work, work / "remote-driver.xsh", "--",
        str(ROOT), str(port), str(key), pin, user, operation, str(timeout * 1000),
        *[str(item) for item in extra], timeout=timeout + 30, check=check,
    )
    return last_json(result.stdout) if check else result


def wait_until(predicate, timeout, interval=0.5, message="condition"):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
        except Exception as failure:
            last = failure
            time.sleep(interval)
            continue
        if value:
            return value
        time.sleep(interval)
    raise RuntimeError(f"timed out waiting for {message}: {last}")


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def find_dropbearkey(args, work):
    if args.dropbearkey.exists():
        return args.dropbearkey
    store = args.artifact_store
    if store.exists():
        for entry in sorted(store.iterdir()):
            metadata = entry / "artifact.json"
            payload = entry / "payload.tar.gz"
            if not metadata.exists() or not payload.exists():
                continue
            record = json.loads(metadata.read_text())
            if record.get("package_name") != "dropbear":
                continue
            tools = work / "tools"
            tools.mkdir(parents=True, exist_ok=True)
            with tarfile.open(payload) as archive:
                archive.extract("usr/bin/dropbearkey", path=tools, filter="tar")
            binary = tools / "usr/bin/dropbearkey"
            binary.chmod(0o755)
            return binary
    return args.dropbearkey


def seed_trust_store(staging):
    files = ROOT / "packages/ca-certificates/files"
    generation = staging / "var/lib/laputa/trust/generations/1"
    generation.mkdir(parents=True)
    shutil.copy(files / "cacert.pem", generation / "ca-certificates.crt")
    shutil.copy(files / "trust-policy", generation / "trust-policy")
    (generation / "owner").write_text("package-seed\n")
    (staging / "var/lib/laputa/trust/accepted").write_text("1\n")
    (staging / "var/lib/laputa/trust/active").symlink_to("generations/1")
    (staging / "etc/laputa").mkdir(parents=True, exist_ok=True)
    (staging / "etc/laputa/trust-policy").symlink_to("../../var/lib/laputa/trust/active/trust-policy")
    (staging / "etc/ssl/certs").mkdir(parents=True, exist_ok=True)
    (staging / "etc/ssl/cert.pem").symlink_to("certs/ca-certificates.crt")
    (staging / "etc/ssl/certs/ca-certificates.crt").symlink_to("../../../var/lib/laputa/trust/active/ca-certificates.crt")


def install_strace_tools(staging):
    tools = staging / f"home/{OPERATOR}/g2-tools"
    tools.mkdir(parents=True)
    items = [
        "/usr/bin/strace",
        "/usr/lib/libdw.so.1",
        "/usr/lib/libelf.so.1",
        "/usr/lib/libz.so.1",
        "/usr/lib/libfts.so.0",
        "/usr/lib/libzstd.so.1",
        "/usr/lib/liblzma.so.5",
        "/usr/lib/libbz2.so.1",
    ]
    for item in items:
        shutil.copy(item, tools / pathlib.Path(item).name)
    tools.chmod(0o755)


def rescue_packages(artifact_store):
    wanted = {"baselayout", "musl", "xsh", "xinit", "e2fsprogs"}
    found = set()
    if not artifact_store.exists():
        return found
    for entry in artifact_store.iterdir():
        metadata = entry / "artifact.json"
        if metadata.exists():
            found.add(json.loads(metadata.read_text()).get("package_name", ""))
    return wanted & found


def install_admin(staging, public):
    passwd = staging / "etc/passwd"
    passwd.write_text(passwd.read_text().rstrip("\n") + f"\n{ADMIN}:x:0:0:G2 Administrator:/home/{ADMIN}:/usr/bin/xsh-login\n")
    shadow = staging / "etc/shadow"
    shadow.write_text(shadow.read_text().rstrip("\n") + f"\n{ADMIN}:*:0:0:99999:7:::\n")
    home = staging / f"home/{ADMIN}"
    ssh_dir = home / ".ssh"
    ssh_dir.mkdir(parents=True)
    home.chmod(0o755)
    ssh_dir.chmod(0o700)
    authorized = ssh_dir / "authorized_keys"
    authorized.write_text(public + "\n")
    authorized.chmod(0o600)


def provision(args, work):
    client_key = work / "client"
    run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "g2-lifecycle", "-f", str(client_key)], xsh_env(work), timeout=30)
    admin_key = work / "admin"
    run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "g2-admin", "-f", str(admin_key)], xsh_env(work), timeout=30)
    staging = work / "state-staging"
    for name in ("etc", "home", "var"):
        (staging / name).mkdir(parents=True)
    base_etc = ROOT / "packages/baselayout/files/rootfs/etc"
    for entry in sorted(base_etc.iterdir()):
        if entry.name == "inittab":
            continue
        subprocess.run(["cp", "-a", str(entry), str(staging / "etc" / entry.name)], check=True)
    shutil.copy(ROOT / "profiles/qemu-maintained/etc/inittab", staging / "etc/inittab")
    shutil.copy(ROOT / "packages/nftables/nftables.conf", staging / "etc/nftables.conf")
    (staging / "etc/network").mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "packages/laputa-net/interfaces", staging / "etc/network/interfaces")
    for directory, mode in (("var/lib/dhcpc", 0o700), ("var/lib/laputa", 0o755), ("var/lib/ntpd-rs", 0o755), ("var/log", 0o755)):
        path = staging / directory
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(mode)
    (staging / "format").write_text("laputa-maintained-state-1\n")
    seed_trust_store(staging)

    host_key = staging / "etc/dropbear/dropbear_ed25519_host_key"
    host_key.parent.mkdir(parents=True)
    generated = run([str(args.dropbearkey), "-t", "ed25519", "-f", str(host_key)], xsh_env(work), timeout=60)
    assert host_key.stat().st_mode & 0o077 == 0, "the host key is not private"
    fingerprint = next(line.split()[-1] for line in (generated.stdout + generated.stderr).splitlines() if line.startswith("Fingerprint:"))
    public = client_key.with_suffix(".pub").read_text().strip()
    admin_public = admin_key.with_suffix(".pub").read_text().strip()

    hostname = f"laputa-g2-{os.urandom(3).hex()}"
    run_xsh(args, work, work / "provision.xsh", "--", staging, OPERATOR, hostname, public, timeout=60)

    install_strace_tools(staging)
    install_admin(staging, admin_public)

    shadow = (staging / "etc/shadow").read_text().splitlines()
    operator_shadow = [line for line in shadow if line.startswith(f"{OPERATOR}:")]
    assert len(operator_shadow) == 1 and operator_shadow[0].split(":")[1] == "*", "operator password is not locked"
    passwd = (staging / "etc/passwd").read_text().splitlines()
    operator_passwd = [line for line in passwd if line.startswith(f"{OPERATOR}:")]
    assert len(operator_passwd) == 1, "operator account is not unique"
    assert operator_passwd[0].split(":")[5] == f"/home/{OPERATOR}", "operator home differs"
    authorized = staging / f"home/{OPERATOR}/.ssh/authorized_keys"
    assert authorized.read_text().strip().endswith(public.split()[-1]) or public in authorized.read_text(), "authorized key differs"

    state_image = work / "outputs/state.ext4"
    state_image.parent.mkdir(parents=True, exist_ok=True)
    run_xsh(
        args, work, ROOT / "system/maintained_state_image.xsh", "--",
        staging, state_image, 256 * 1024 * 1024,
        ROOT / "packages/laputa-fs/files/mkfs.ext4.xsh", args.xsh,
        timeout=300,
    )
    assert state_image.stat().st_mode & 0o077 == 0, "state image is not private"
    shutil.rmtree(staging)

    bundle = args.bundle
    for label, material in (("operator", public.split()[1]), ("administrator", admin_public.split()[1])):
        if contains_bytes(bundle / "disk.img", material.encode()):
            fail(f"the immutable generation disk contains the {label} public key")
    for label, path in (("operator", client_key), ("administrator", admin_key)):
        body = "".join(line for line in path.read_text().splitlines() if not line.startswith("-----"))
        if contains_bytes(bundle / "disk.img", body[80:144].encode()):
            fail(f"the immutable generation disk contains the {label} private key")
    return client_key, admin_key, fingerprint, state_image, hostname


def patch_argv(raw, port, console, qmp, work):
    argv = list(raw)
    for index in range(len(argv) - 1):
        if argv[index] == "-netdev" and argv[index + 1].startswith("user,id=net0"):
            argv[index + 1] = f"user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22"
        elif argv[index] == "-device" and argv[index + 1] == "virtio-net-pci,netdev=net0":
            argv[index + 1] = "virtio-net-pci,netdev=net0,id=nic0"
        elif argv[index] == "-serial" and argv[index + 1] == "stdio":
            argv[index + 1] = f"file:{console}"
        elif argv[index] == "-qmp":
            argv[index + 1] = f"unix:{qmp},server,nowait"
        elif argv[index] == "-append":
            tokens = [token for token in argv[index + 1].split(" ") if token != "LAPUTA_MAINTAINED_PROOF_FLAG=1"]
            tokens.append("LAPUTA_ACTIVATION_SSH_FIXTURE=1")
            argv[index + 1] = " ".join(tokens)
    console.unlink(missing_ok=True)
    qmp.unlink(missing_ok=True)
    return argv


def launch(argv, console, qemu_log):
    log_file = open(qemu_log, "wb")
    child = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=log_file, cwd=ROOT)
    return child, log_file


def stop(child, log_file=None):
    if child.poll() is None:
        child.send_signal(signal.SIGKILL)
    child.wait(timeout=60)
    if log_file is not None:
        log_file.close()


def console_text(console):
    return console.read_text(errors="replace") if console.exists() else ""


def wait_ssh(child, console, port, timeout=240):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError(f"QEMU exited before SSH; inspect {console}")
        text = console_text(console)
        if "Kernel panic" in text or "not syncing" in text:
            raise RuntimeError(f"guest panicked before SSH; inspect {console}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=2) as probe:
                probe.settimeout(2)
                if probe.recv(64).startswith(b"SSH-2.0-"):
                    return
        except OSError:
            pass
        time.sleep(1)
    raise RuntimeError(f"guest SSH did not come up; inspect {console}")


def wait_health(args, work, port, key, pin, timeout=180):
    return wait_until(
        lambda: (lambda value: value["health"] if value.get("health") else None)(remote(args, work, port, key, pin, "inspect", timeout=10)),
        timeout, 2, "guest health",
    )


def wait_boot_failure(child, console, timeout=180):
    deadline = time.monotonic() + timeout
    observed = None
    while time.monotonic() < deadline:
        text = console_text(console)
        if "Kernel panic" in text or "not syncing" in text:
            return text
        if "Waiting for root device" in text:
            observed = text
            break
        if child.poll() is not None:
            return text
        time.sleep(1)
    if observed is None:
        raise RuntimeError(f"generation B stayed silent; inspect {console}")
    time.sleep(5)
    return console_text(console)


def qmp(socket_path, execute, arguments):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.connect(str(socket_path))
        stream = sock.makefile("rwb")

        def read():
            while True:
                line = stream.readline()
                if not line:
                    raise RuntimeError("QMP closed")
                message = json.loads(line)
                if "event" not in message:
                    return message

        read()
        stream.write(b'{"execute":"qmp_capabilities","id":1}\n')
        stream.flush()
        read()
        stream.write((json.dumps({"execute": execute, "arguments": arguments, "id": 2}) + "\n").encode())
        stream.flush()
        reply = read()
        if "error" in reply:
            raise RuntimeError(f"QMP {execute}: {reply['error']}")


def service_state(args, work, port, key, pin, name):
    result = remote(args, work, port, key, pin, "read", f"/run/xinit/{name}.json")
    if result["exit_code"] != 0:
        return None
    return json.loads(result["stdout"])


def service_after_restart(args, work, port, key, pin, name, previous_pid, timeout=45):
    def ready():
        status = service_state(args, work, port, key, pin, name)
        if status is None:
            return None
        if status.get("state") == "running" and status.get("pid", 0) > 0 and status["pid"] != previous_pid:
            return status
        return None

    return wait_until(ready, timeout, 0.5, f"{name} restarted with a new pid")


def lease_status(args, work, port, key, pin):
    result = remote(args, work, port, key, pin, "read", "/run/dhcpc/eth0.status")
    assert result["exit_code"] == 0, result
    return json.loads(result["stdout"])


def boot_markers(args, work, port, key, pin):
    diagnosis = remote(args, work, port, key, pin, "diagnose")
    log = next(item for item in diagnosis["logs"] if item["path"] == "/var/log/boot-markers.log")
    assert log["readable"], "boot marker log is not readable over SSH"
    return [json.loads(line) for line in log["lines"] if line.strip()]


def poweroff_guest(args, work, port, admin_key, pin, child, log_file, label):
    script = work / f"poweroff-{label}.xsh"
    script.write_text(POWEROFF)
    staged = remote(args, work, port, admin_key, pin, "stage", script, f"g2-poweroff-{label}", user=ADMIN)
    assert staged["outcome"] in ("staged", "present"), staged
    result = remote(args, work, port, admin_key, pin, "run", json.dumps(["/usr/bin/xsh", staged["path"]]), user=ADMIN)
    assert result["exit_code"] == 0, result
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline and child.poll() is None:
        time.sleep(0.5)
    if child.poll() is None:
        stop(child, log_file)
        fail(f"guest {label} did not power off through PID 1")
    assert child.returncode == 0, f"guest {label} poweroff exit {child.returncode}"
    log(f"poweroff {label}: clean QEMU exit 0")


def step_remote(args, work, port, key, admin_key, pin, hostname, digest):
    log("step 2: verified SSH inspection and lifecycle exercise")
    info = remote(args, work, port, key, pin, "info")
    assert info["host_key"] == pin, info
    wrong = remote(args, work, port, key, pin, "wrong-key", check=False)
    assert wrong.returncode != 0 or "refused" in wrong.stdout, (wrong.returncode, wrong.stdout, wrong.stderr)
    wrong_text = (wrong.stdout + wrong.stderr)
    assert "wrong host key" in wrong_text or "refused" in wrong_text, wrong_text

    inspection = remote(args, work, port, key, pin, "inspect")
    assert inspection["hostname"] == hostname, inspection["hostname"]
    assert inspection["generation"]["profile"] == PROFILE
    assert inspection["generation"]["generation_sha256"] == digest
    assert inspection["health"]["generation_id"] == "a"
    assert inspection["health"]["boot_serial"] == 0
    assert inspection["health"]["root_digest"] == digest
    services = {item["name"]: item["state"] for item in inspection["services"]}
    for name in CRITICAL_SERVICES:
        assert services.get(name) == "running", (name, services)

    lease = lease_status(args, work, port, key, pin)
    assert lease["state"] == "bound", lease
    assert lease["address"] == "10.0.2.15" and lease["prefix"] == 24, lease
    assert lease["server"] == "10.0.2.2" and lease["resolver"] == "published", lease
    assert lease["renew_at"] > 0 and lease["rebind_at"] > lease["renew_at"] and lease["expire_at"] > lease["rebind_at"], lease
    resolv = remote(args, work, port, key, pin, "read", "/etc/resolv.conf")
    assert resolv["exit_code"] == 0 and "# Managed by dhcpc" in resolv["stdout"], resolv
    assert "nameserver 10.0.2.3" in resolv["stdout"], resolv

    clock = service_state(args, work, port, key, pin, "ntpd-rs")
    assert clock is not None, "the maintained profile installs ntpd-rs"
    log(f"clock status: ntpd-rs state={clock['state']} ready={clock['ready']} restarts={clock['restarts']}")

    diagnosis = remote(args, work, port, key, pin, "diagnose")
    marker_log = next(item for item in diagnosis["logs"] if item["path"] == "/var/log/boot-markers.log")
    assert marker_log["readable"], marker_log
    assert marker_log["lines"], "boot marker log is empty"
    assert not any("PRIVATE KEY" in line for line in marker_log["lines"])
    for item in diagnosis["logs"]:
        if not item["readable"]:
            assert item["lines"] == [], item
    log("redacted diagnostics: " + ", ".join(f"{item['path']}={item['readable']}" for item in diagnosis["logs"]))

    logger = service_state(args, work, port, key, pin, "logger")
    assert logger["state"] == "running" and logger["ready"], logger
    restarted = remote(args, work, port, admin_key, pin, "run", json.dumps(["/usr/bin/xinit", "restart", "logger"]), user=ADMIN)
    assert restarted["exit_code"] == 0, restarted
    logger = service_after_restart(args, work, port, key, pin, "logger", logger["pid"])
    assert logger["ready"], logger
    log(f"supervised restart: logger pid={logger['pid']} restarts={logger['restarts']}")

    dhcp = service_state(args, work, port, key, pin, "dhcp-eth0")
    restarted = remote(args, work, port, admin_key, pin, "run", json.dumps(["/usr/bin/xinit", "restart", "dhcp-eth0"]), user=ADMIN)
    assert restarted["exit_code"] == 0, restarted
    dhcp = service_after_restart(args, work, port, key, pin, "dhcp-eth0", dhcp["pid"])
    wait_until(lambda: lease_status(args, work, port, key, pin)["state"] == "bound", 60, 0.5, "lease after dhcp restart")
    after_restart = lease_status(args, work, port, key, pin)
    assert after_restart["address"] == "10.0.2.15"
    assert after_restart["wall_ms"] > lease["wall_ms"]
    log(f"supervised restart: dhcp-eth0 pid={dhcp['pid']} lease={after_restart['state']} {after_restart['address']}")

    qmp(work / "outputs/qmp.sock", "set_link", {"name": "nic0", "up": False})
    down = remote(args, work, port, key, pin, "inspect", timeout=5, check=False)
    assert down.returncode != 0, "inspection succeeded while the guest link was down"
    banner = b""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=3) as probe:
            probe.settimeout(5)
            try:
                banner = probe.recv(64)
            except OSError:
                banner = b""
    except OSError:
        banner = b""
    assert not banner, f"SSH banner appeared while the link was down: {banner!r}"
    qmp(work / "outputs/qmp.sock", "set_link", {"name": "nic0", "up": True})
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            inspection = remote(args, work, port, key, pin, "inspect", timeout=10)
            break
        except RuntimeError:
            time.sleep(2)
    else:
        fail("SSH did not recover after the link returned")
    assert inspection["generation"]["generation_sha256"] == digest
    recovered = lease_status(args, work, port, key, pin)
    assert recovered["state"] == "bound" and recovered["address"] == "10.0.2.15", recovered
    assert recovered["trouble"] == "none", recovered
    changed = [key for key in recovered["counters"] if recovered["counters"][key] != after_restart["counters"].get(key)]
    assert changed, (after_restart["counters"], recovered["counters"])
    log(f"temporary link loss: SSH dropped, reconnected, lease {recovered['state']} with counters changed {changed}")


def scenario(args, work):
    client_key, admin_key, fingerprint, state_image, hostname = provision(args, work)
    log(f"step 1: provisioned {OPERATOR} with locked password and host key {fingerprint}")

    generation = json.loads((args.bundle / "generation.json").read_text())
    assert generation["format"] == "laputa-generation-1", generation
    assert generation["profile"] == PROFILE and generation["target"] == "x86_64-linux-musl", generation
    digest = generation["generation_sha256"]
    assert len(digest) == 64, digest
    log(f"generation identity: {digest} kernel_sha256={sha256_file(args.bundle / 'vmlinuz')[:16]}... disk_sha256={sha256_file(args.bundle / 'disk.img')[:16]}...")

    outputs = work / "outputs"
    outputs.mkdir(parents=True, exist_ok=True)
    (outputs / "current").symlink_to(args.bundle.resolve())
    state_dir = outputs / "generations"
    installed = host(args, work, "install", state_dir, digest, args.bundle / "vmlinuz", args.bundle / "disk.img", timeout=600)
    assert installed["current"] == "a" and installed["pending"] is None and installed["policy_revision"] == 1, installed
    log(f"step 1: installed generation a with fallback a and policy revision 1")

    available = rescue_packages(args.artifact_store)
    if available == {"baselayout", "musl", "xsh", "xinit", "e2fsprogs"}:
        launcher = ROOT / ".out/host/x86_64/xsh"
        launcher.parent.mkdir(parents=True, exist_ok=True)
        if not launcher.exists():
            launcher.symlink_to(args.xsh.resolve())
        rescue = subprocess.run(
            [sys.executable, str(ROOT / "tests/integration/rescue_guest.py")],
            env=dict(xsh_env(work), LAPUTA_ARTIFACT_STORE=str(args.artifact_store), LAPUTA_RESCUE_KERNEL=str(args.bundle / "vmlinuz")),
            cwd=ROOT, capture_output=True, text=True, timeout=900,
        )
        print(rescue.stdout, end="")
        if rescue.returncode != 0:
            raise RuntimeError(f"rescue_guest.py failed\n{rescue.stdout}\n{rescue.stderr}")
        log("step 1: the independent rescue root booted clean, repaired, and unrecoverable disks")
    else:
        print(f"UNVERIFIED independent rescue (artifact store lacks {sorted({'baselayout', 'musl', 'xsh', 'xinit', 'e2fsprogs'} - available)})")

    launched = []
    console_a = work / "console-a.log"
    raw = host(args, work, "argv", state_dir, outputs)["argv"]
    assert "LAPUTA_GENERATION_ID=a" in " ".join(raw) and "LAPUTA_BOOT_SERIAL=0" in " ".join(raw), raw
    port = free_port()
    child, log_file = launch(patch_argv(raw, port, console_a, outputs / "qmp.sock", work), console_a, work / "qemu-a.log")
    launched.append((child, log_file))
    try:
        wait_ssh(child, console_a, port)
        health = wait_health(args, work, port, client_key, fingerprint)
        assert health["generation_id"] == "a" and health["boot_serial"] == 0 and health["root_digest"] == digest, health
        log("step 1: generation a boots with a matching running receipt and health report")

        sentinel = f"g2-{os.urandom(8).hex()}\n"
        sentinel_source = work / "sentinel"
        sentinel_source.write_text(sentinel)
        staged = remote(args, work, port, client_key, fingerprint, "stage", sentinel_source, "g2-sentinel")
        assert staged["outcome"] == "staged" and staged["sha256"] == hashlib.sha256(sentinel.encode()).hexdigest(), staged
        copied = remote(args, work, port, client_key, fingerprint, "run", json.dumps(["/usr/bin/cp", staged["path"], "/home/probe/g2-state-sentinel"]))
        assert copied["exit_code"] == 0, copied
        log("step 2: a verified staged file is placed in persistent home state")

        step_remote(args, work, port, client_key, admin_key, fingerprint, hostname, digest)

        recovery = subprocess.run(
            [sys.executable, str(ROOT / "tests/integration/activation_recovery.py")],
            env=dict(xsh_env(work), LAPUTA_XSH=str(args.xsh)), cwd=ROOT, capture_output=True, text=True, timeout=600,
        )
        print(recovery.stdout, end="")
        if recovery.returncode != 0:
            raise RuntimeError(f"activation_recovery.py failed\n{recovery.stdout}\n{recovery.stderr}")
        log("step 3: the existing host recovery drill passed (fsync death, ENOSPC, concurrency, lost replies)")

        remote(args, work, port, client_key, fingerprint, "run", json.dumps(["/usr/bin/mkdir", "-p", "/home/probe/ssh-proof"]))
        remote(args, work, port, client_key, fingerprint, "run", json.dumps(["/usr/bin/rm", "-f", "/home/probe/ssh-proof/tools"]))
        linked = remote(args, work, port, client_key, fingerprint, "run", json.dumps(["/usr/bin/ln", "-s", "/home/probe/g2-tools", "/home/probe/ssh-proof/tools"]))
        assert linked["exit_code"] == 0, linked
        ssh_drill = subprocess.run(
            [sys.executable, str(ROOT / "tests/integration/activation_ssh.py"), str(args.xsh), str(port), str(client_key), fingerprint],
            env=xsh_env(work), cwd=ROOT, capture_output=True, text=True, timeout=600,
        )
        print(ssh_drill.stdout, end="")
        if ssh_drill.returncode != 0:
            raise RuntimeError(f"activation_ssh.py failed\n{ssh_drill.stdout}\n{ssh_drill.stderr}")
        log("step 3: the existing SSH disconnect drill passed against the same guest")

        broken = work / "b-disk.img"
        with open(broken, "wb") as zero:
            zero.truncate(32 * 1024 * 1024)
        staged_b = host(args, work, "stage", state_dir, "b", digest, args.bundle / "vmlinuz", broken, timeout=600)
        assert staged_b["pending"] == "b" and staged_b["current"] == "a" and staged_b["fallback"] == "a", staged_b
        assert staged_b["policy_revision"] == 2 and staged_b["policy_ids"] == ["a", "b"], staged_b
        verify_b = host(args, work, "verify", state_dir, "b", digest)
        assert sha256_file(verify_b["kernel"]) == sha256_file(args.bundle / "vmlinuz")
        assert sha256_file(verify_b["disk"]) == sha256_file(broken)
        duplicate = host(args, work, "restage", state_dir, "b", digest, check=False)
        assert duplicate.returncode != 0 and "already pending" in duplicate.stderr, duplicate.stderr
        assert host(args, work, "status", state_dir) == staged_b, "a refused replay changed the record"
        inspection = remote(args, work, port, client_key, fingerprint, "inspect")
        assert inspection["generation"]["generation_sha256"] == digest
        log("step 3: generation b is operator-authorized, byte-pinned, staged, and pending; A still serves")
        poweroff_guest(args, work, port, admin_key, fingerprint, child, log_file, "a-to-b")
        status = host(args, work, "status", state_dir)
        assert status["pending"] == "b" and status["current"] == "a" and status["attempts"] == 0, status

        raw = host(args, work, "argv", state_dir, outputs)["argv"]
        assert "LAPUTA_GENERATION_ID=b LAPUTA_BOOT_SERIAL=1" in " ".join(raw), raw
        console_b1 = work / "console-b1.log"
        attempt_port = free_port()
        child, log_file = launch(patch_argv(raw, attempt_port, console_b1, outputs / "qmp.sock", work), console_b1, work / "qemu-b1.log")
        launched.append((child, log_file))
        text = wait_boot_failure(child, console_b1)
        assert any(marker in text for marker in ("Kernel panic", "not syncing", "Waiting for root device")), text[-2000:]
        stop(child)
        log("step 4: admitted generation b never reached userspace on its first boot attempt")

        status = host(args, work, "status", state_dir)
        assert status["pending"] == "b" and status["attempts"] == 1 and status["last"] == "pending-boot", status

        raw = host(args, work, "argv", state_dir, outputs)["argv"]
        assert "LAPUTA_GENERATION_ID=b LAPUTA_BOOT_SERIAL=2" in " ".join(raw), raw
        console_b2 = work / "console-b2.log"
        attempt_port = free_port()
        child, log_file = launch(patch_argv(raw, attempt_port, console_b2, outputs / "qmp.sock", work), console_b2, work / "qemu-b2.log")
        launched.append((child, log_file))
        text = wait_boot_failure(child, console_b2)
        assert any(marker in text for marker in ("Kernel panic", "not syncing", "Waiting for root device")), text[-2000:]
        stop(child)
        status = host(args, work, "status", state_dir)
        assert status["pending"] == "b" and status["attempts"] == 2, status
        log("step 4: the second startup failure exhausted the bound; the pending generation stays recorded")

        raw = host(args, work, "argv", state_dir, outputs)["argv"]
        command_line = " ".join(raw)
        assert "LAPUTA_GENERATION_ID=a" in command_line and "LAPUTA_FAILED_GENERATION=b" in command_line, command_line
        console_fallback = work / "console-fallback.log"
        port = free_port()
        child, log_file = launch(patch_argv(raw, port, console_fallback, outputs / "qmp.sock", work), console_fallback, work / "qemu-fallback.log")
        launched.append((child, log_file))
        wait_ssh(child, console_fallback, port)
        health = wait_health(args, work, port, client_key, fingerprint)
        assert health["generation_id"] == "a" and health["boot_serial"] == 2, health
        status = host(args, work, "status", state_dir)
        assert status["current"] == "a" and status["pending"] is None and status["attempts"] == 2 and status["last"] == "fell-back", status
        info = remote(args, work, port, client_key, fingerprint, "info")
        assert info["host_key"] == fingerprint, info
        sentinel_now = remote(args, work, port, client_key, fingerprint, "read", "/home/probe/g2-state-sentinel")
        assert sentinel_now["stdout"] == sentinel, sentinel_now
        markers = boot_markers(args, work, port, client_key, fingerprint)
        assert [(item["generation_id"], item["boot_serial"], item["failed_generation"]) for item in markers] == [("a", 0, ""), ("a", 2, "b")], markers
        log("step 4: the launcher selected retained a, identity and mutable state survived, and history names failed b")

        staged_c = host(args, work, "stage", state_dir, "c", digest, args.bundle / "vmlinuz", args.bundle / "disk.img", timeout=600)
        assert staged_c["pending"] == "c" and staged_c["current"] == "a" and staged_c["fallback"] == "a", staged_c
        assert staged_c["policy_revision"] == 3 and staged_c["policy_ids"] == ["a", "b", "c"], staged_c
        log("step 5: repaired generation c is staged with a retained fallback and no commit")
        poweroff_guest(args, work, port, admin_key, fingerprint, child, log_file, "a-to-c")

        raw = host(args, work, "argv", state_dir, outputs)["argv"]
        assert "LAPUTA_GENERATION_ID=c LAPUTA_BOOT_SERIAL=3" in " ".join(raw), raw
        console_c = work / "console-c.log"
        port = free_port()
        child, log_file = launch(patch_argv(raw, port, console_c, outputs / "qmp.sock", work), console_c, work / "qemu-c.log")
        launched.append((child, log_file))
        wait_ssh(child, console_c, port)
        health = wait_health(args, work, port, client_key, fingerprint)
        assert health["generation_id"] == "c" and health["boot_serial"] == 3 and health["root_digest"] == digest, health
        inspection = remote(args, work, port, client_key, fingerprint, "inspect")
        assert inspection["generation"]["generation_sha256"] == digest
        assert inspection["generation"]["profile"] == PROFILE
        live = {item["name"]: item["state"] for item in inspection["services"]}
        for name in CRITICAL_SERVICES:
            assert live.get(name) == "running", (name, live)
        status = host(args, work, "status", state_dir)
        assert status["pending"] == "c" and status["last"] == "pending-boot" and status["current"] == "a", status
        log("step 5: c reports its running receipt and live critical services before any commit")

        health_path = work / "health-c.json"
        health_path.write_text(json.dumps(health) + "\n")
        confirmed = host(args, work, "confirm", state_dir, health_path, ",".join(CRITICAL_SERVICES), PROFILE)
        assert confirmed["current"] == "c" and confirmed["fallback"] == "a" and confirmed["pending"] is None, confirmed
        assert confirmed["last"] == "confirmed" and confirmed["policy_revision"] == 3, confirmed
        markers = boot_markers(args, work, port, client_key, fingerprint)
        assert [(item["generation_id"], item["boot_serial"], item["failed_generation"]) for item in markers] == [("a", 0, ""), ("a", 2, "b"), ("c", 3, "")], markers
        log("step 5: health-confirmed c committed with a retained, still-admitted a")
        poweroff_guest(args, work, port, admin_key, fingerprint, child, log_file, "c-reboot")

        raw = host(args, work, "argv", state_dir, outputs)["argv"]
        assert "LAPUTA_GENERATION_ID=c LAPUTA_BOOT_SERIAL=3" in " ".join(raw), raw
        console_c2 = work / "console-c2.log"
        port = free_port()
        child, log_file = launch(patch_argv(raw, port, console_c2, outputs / "qmp.sock", work), console_c2, work / "qemu-c2.log")
        launched.append((child, log_file))
        wait_ssh(child, console_c2, port)
        wait_health(args, work, port, client_key, fingerprint)
        status = host(args, work, "status", state_dir)
        assert status["current"] == "c" and status["fallback"] == "a" and status["pending"] is None and status["last"] == "confirmed", status
        markers = boot_markers(args, work, port, client_key, fingerprint)
        assert [(item["generation_id"], item["boot_serial"], item["failed_generation"]) for item in markers] == [("a", 0, ""), ("a", 2, "b"), ("c", 3, ""), ("c", 3, "")], markers
        sentinel_now = remote(args, work, port, client_key, fingerprint, "read", "/home/probe/g2-state-sentinel")
        assert sentinel_now["stdout"] == sentinel, sentinel_now
        info = remote(args, work, port, client_key, fingerprint, "info")
        assert info["host_key"] == fingerprint, info
        log("step 5: c rebooted as current with the same identity and state; failure/activation history persisted")
    finally:
        for child, log_file in launched:
            if child.poll() is None:
                stop(child, log_file)
            else:
                if log_file is not None:
                    log_file.close()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if all(child.poll() is not None for child, _ in launched):
                break
            time.sleep(0.5)
        assert all(child.poll() is not None for child, _ in launched), "a QEMU child was left running"

    print("UNVERIFIED natural T1/T2 lease renewal (the run exercises persisted-lease reacquisition, a supervised restart, and rebind after link loss)")
    print("UNVERIFIED physical power loss or host filesystem reordering (process death and ENOSPC only)")
    print("UNVERIFIED aarch64 guest, Asterinas/Firecracker backend, and macOS administration client")
    print("UNVERIFIED non-root operator privilege delegation (the test provisioned a key-only UID 0 administrator because /run/xinit is root-owned)")
    print("UNVERIFIED G2 step 6 blank-disk restore (R7 tests/integration/restore_drill.py was not run)")
    print("UNVERIFIED signed release authenticity (generation_sha256 is PM publisher identity; byte pins are operator authorization)")
    print("UNVERIFIED rebuild by this test (the prebuilt --bundle was consumed)")
    print("PASS: G2 steps 1-5 on one installed x86_64/KVM VM")


def parse_args():
    parser = argparse.ArgumentParser(description="Run the roadmap G2 integrated lifecycle scenario.")
    parser.add_argument("--xsh", type=pathlib.Path, default=DEFAULT_XSH)
    parser.add_argument("--bundle", type=pathlib.Path, default=DEFAULT_BUNDLE)
    parser.add_argument("--dropbearkey", type=pathlib.Path, default=pathlib.Path(""))
    parser.add_argument("--artifact-store", type=pathlib.Path, default=DEFAULT_ARTIFACT_STORE)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    if args.dropbearkey == pathlib.Path(""):
        args.dropbearkey = pathlib.Path("/nonexistent")
    return args


def main():
    args = parse_args()
    SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix="g2-lifecycle.", dir=SCRATCH_ROOT))
    (work / "tmp").mkdir()
    try:
        args.dropbearkey = find_dropbearkey(args, work)
        require_prerequisites(args, work)
        (work / "host-driver.xsh").write_text(HOST_DRIVER)
        (work / "provision.xsh").write_text(PROVISION_DRIVER)
        (work / "remote-driver.xsh").write_text(REMOTE_DRIVER)
        scenario(args, work)
        if args.keep:
            log(f"artifacts kept at {work}")
    finally:
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)
