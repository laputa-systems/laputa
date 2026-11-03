import argparse
import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[2]
scratch_root = root / ".work/tmp"
state_fixture = root / "tests/integration/fixtures/remote-admin-state.xsh"
state_image_builder = root / "system/maintained_state_image.xsh"
drill_fixture = root / "tests/integration/fixtures/remote-admin-drill.xsh"
OPERATOR = "admin"


def parse():
    parser = argparse.ArgumentParser(description="Administer one headless maintained VM over native SSH.")
    parser.add_argument("--xsh", required=True, help="an xsh with the native ssh module")
    parser.add_argument("--bundle", type=pathlib.Path, default=root / "target/laputa/qemu-maintained/current")
    parser.add_argument("--dropbearkey", required=True, help="the dropbearkey of the dropbear package")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--hold", type=int, default=0, help="seconds to keep the guest running before the drill")
    return parser.parse_args()


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, capture_output=True, text=True, **kwargs)


def provision(args, scratch):
    client_key = scratch / "client"
    run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "remote-admin", "-f", str(client_key)])
    staging = scratch / "state-staging"
    for name in ("etc", "home", "var"):
        (staging / name).mkdir(parents=True)
    base_etc = root / "packages/baselayout/files/rootfs/etc"
    for entry in sorted(base_etc.iterdir()):
        if entry.name == "inittab":
            continue
        subprocess.run(["cp", "-a", str(entry), str(staging / "etc" / entry.name)], check=True)
    shutil.copy(root / "profiles/qemu-maintained/etc/inittab", staging / "etc/inittab")
    shutil.copy(root / "packages/nftables/nftables.conf", staging / "etc/nftables.conf")
    (staging / "etc/network").mkdir(parents=True, exist_ok=True)
    shutil.copy(root / "packages/laputa-net/interfaces", staging / "etc/network/interfaces")
    (staging / "var/lib/dhcpc").mkdir(parents=True)
    (staging / "var/lib/dhcpc").chmod(0o700)
    (staging / "var/lib/laputa").mkdir(parents=True, exist_ok=True)
    (staging / "var/log").mkdir(parents=True, exist_ok=True)
    (staging / "format").write_text("laputa-maintained-state-1\n")

    host_key = staging / "etc/dropbear/dropbear_ed25519_host_key"
    host_key.parent.mkdir(parents=True)
    generated = run([args.dropbearkey, "-t", "ed25519", "-f", str(host_key)])
    fingerprint = next(line.split()[-1] for line in (generated.stdout + generated.stderr).splitlines() if line.startswith("Fingerprint:"))
    public = (client_key.with_suffix(".pub")).read_text().strip()
    env = dict(os.environ, XSH_MODULE_PATH=str(root), TMPDIR=str(scratch_root))
    run([args.xsh, str(state_fixture), "--", str(staging), OPERATOR, public], env=env, cwd=root)
    state_image = scratch / "state.ext4"
    run([
        args.xsh, str(state_image_builder), "--", str(staging), str(state_image), str(256 * 1024 * 1024),
        str(root / "packages/laputa-fs/files/mkfs.ext4.xsh"), args.xsh,
    ], env=env, cwd=root)
    shutil.rmtree(staging)
    return client_key, fingerprint, state_image


def boot(args, scratch, state_image, port):
    bundle = args.bundle
    console = scratch / "console.log"
    cmdline = (
        "earlyprintk=serial console=ttyS0 ignore_loglevel devtmpfs.mount=1 "
        "root=PARTUUID=33333333-3333-3333-3333-333333333333 rootfstype=ext4 rootwait rootdelay=2 rw "
        "init=/init loglevel=8 XSH_LINUX_REAL=1 XSH_UNIX_REAL=1 "
        "LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL=1"
    )
    argv = [
        "qemu-system-x86_64", "-M", "q35,accel=kvm", "-cpu", "host", "-smp", "2", "-m", "1536M",
        "-kernel", str(bundle / "vmlinuz"), "-append", cmdline,
        "-drive", f"if=none,id=root,format=raw,file={bundle / 'disk.img'},snapshot=on",
        "-device", "virtio-blk-pci,drive=root",
        "-drive", f"if=none,id=state,format=raw,file={state_image}",
        "-device", "virtio-blk-pci,drive=state",
        "-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22",
        "-device", "virtio-net-pci,netdev=net0",
        "-display", "none", "-serial", f"file:{console}", "-monitor", "none",
    ]
    log = open(scratch / "qemu.log", "wb")
    return subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=log), console


def wait_for_ssh(child, console, port, timeout=240):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if child.poll() is not None:
            raise RuntimeError(f"QEMU exited early; inspect {console}")
        if console.exists() and "Kernel panic" in console.read_text(errors="replace"):
            raise RuntimeError(f"guest panicked; inspect {console}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=2) as probe:
                probe.settimeout(2)
                if probe.recv(64).startswith(b"SSH-2.0-"):
                    return
        except OSError:
            pass
        time.sleep(1)
    raise RuntimeError(f"guest SSH did not come up; inspect {console}")


def main():
    args = parse()
    scratch_root.mkdir(parents=True, exist_ok=True)
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="remote-admin.", dir=scratch_root))
    child = None
    try:
        client_key, fingerprint, state_image = provision(args, scratch)
        port = free_port()
        child, console = boot(args, scratch, state_image, port)
        wait_for_ssh(child, console, port)
        if args.hold:
            print(f"HOLD port={port} key={client_key} fingerprint={fingerprint}", flush=True)
            time.sleep(args.hold)
        env = dict(os.environ, XSH_MODULE_PATH=str(root), TMPDIR=str(scratch_root))
        candidate = args.bundle / "vmlinuz"
        big = scratch / "large-candidate.bin"
        with open(big, "wb") as handle:
            handle.truncate(96 * 1024 * 1024)
        result = subprocess.run(
            [args.xsh, str(drill_fixture), "--", str(root), str(port), str(client_key), fingerprint, OPERATOR, str(candidate), str(big)],
            env=env, cwd=root, capture_output=True, text=True, timeout=600,
        )
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode:
            raise SystemExit(f"drill failed; guest console: {console}")
        print("PASS: administered one headless Laputa VM over the native SSH client")
    finally:
        if child is not None and child.poll() is None:
            child.send_signal(signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        if not args.keep:
            shutil.rmtree(scratch, ignore_errors=True)


main()
