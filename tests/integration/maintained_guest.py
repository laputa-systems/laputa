import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[2]
scratch = root / ".work/tmp"
scratch.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, XSH_MODULE_PATH=str(root), TMPDIR=str(scratch))
binary = root / ".out/host/x86_64/xsh"
fixture = root / "tests/integration/fixtures/maintained-fallback.xsh"
apply_fixture = root / "tests/integration/fixtures/maintained-state-apply.xsh"
outputs = root / "target/laputa/qemu-maintained"
state_image = outputs / "state.ext4"
generations = outputs / "generations"

READY = "LAPUTA_MAINTAINED_PROOF_READY"
OK = "LAPUTA_MAINTAINED_PROOF_OK"
FAILED = "LAPUTA_MAINTAINED_PROOF_FAILED"
LOGGER_OK = "LAPUTA_MAINTAINED_LOGGER_OK"
DHCP_OK = "LAPUTA_MAINTAINED_DHCP_OK"
HEALTH = "LAPUTA_ACTIVATION_HEALTH"
MARKER = "LAPUTA_BOOT_MARKER"
MARKER_COUNT = "LAPUTA_BOOT_MARKER_COUNT"
MARKER_KEYS = {"boot_serial", "failed_generation", "format", "generation_id", "profile", "root_digest", "services"}


def run_xsh(*args, timeout=60):
    result = subprocess.run(
        [str(binary), *args], env=env, cwd=root,
        capture_output=True, timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return result.stdout.decode()


def drill(op, *args):
    return run_xsh(str(fixture), "--", op, *[str(a) for a in args])


def ensure_state_image():
    if state_image.exists():
        return
    staging = outputs / "state-staging"
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    for name in ("etc", "home", "var"):
        (staging / name).mkdir(parents=True)
    # Initialize administered /etc from the image payloads before the
    # first-boot document is applied: baselayout's static files (the merge
    # base for the operator account), the maintained inittab the overlay
    # selects (PID 1 reads /etc/inittab from the state disk, not the
    # image), the packaged nftables ruleset the firewall oneshot loads,
    # and the loopback-only interfaces file. ca-certificates trust files
    # stay out: nothing in this drill reads them and the document carries
    # no trust key.
    base_etc = root / "packages/baselayout/files/rootfs/etc"
    for entry in sorted(base_etc.iterdir()):
        if entry.name == "inittab":
            continue
        dest = staging / "etc" / entry.name
        if entry.is_symlink() or entry.is_file():
            subprocess.run(["cp", "-a", str(entry), str(dest)], check=True)
        elif entry.is_dir():
            subprocess.run(["cp", "-a", str(entry), str(staging / "etc")], check=True)
    subprocess.run(["cp", str(root / "profiles/qemu-maintained/etc/inittab"), str(staging / "etc/inittab")], check=True)
    subprocess.run(["cp", str(root / "packages/nftables/nftables.conf"), str(staging / "etc/nftables.conf")], check=True)
    (staging / "etc/network").mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", str(root / "packages/laputa-net/interfaces"), str(staging / "etc/network/interfaces")], check=True)
    # Provisioning also creates the service-owned state subdirectories the
    # image never contains: dhcpc creates only its leaf directory with a
    # plain mkdir, so /var/lib must already exist, and the boot marker log
    # needs /var/log (the health reporter also creates it, belt and braces).
    (staging / "var/lib/dhcpc").mkdir(parents=True)
    (staging / "var/lib/dhcpc").chmod(0o700)
    (staging / "var/lib/laputa").mkdir(parents=True, exist_ok=True)
    (staging / "var/log").mkdir(parents=True, exist_ok=True)
    (staging / "format").write_text("laputa-maintained-state-1\n")
    run_xsh(str(apply_fixture), "--", str(staging))
    subprocess.run(
        ["/sbin/mkfs.ext4", "-q", "-F", "-d", str(staging), str(state_image), "256M"],
        check=True,
    )
    state_image.chmod(0o600)
    subprocess.run(["rm", "-rf", str(staging)], check=True)


def boot_argv(use_generations):
    if use_generations:
        return json.loads(drill("argv", generations))["argv"]
    return json.loads(drill("argv-plain"))["argv"]


def launch(argv, console, errlog, extra_cmdline=""):
    fixed = list(argv)
    serial = fixed.index("-serial")
    fixed[serial + 1] = f"file:{console}"
    append = fixed.index("-append")
    if extra_cmdline:
        fixed[append + 1] += extra_cmdline
    try:
        qmp = fixed.index("-qmp")
        socket = fixed[qmp + 1].split("unix:", 1)[1].split(",", 1)[0]
        pathlib.Path(socket).unlink(missing_ok=True)
    except (ValueError, IndexError):
        pass
    err = open(errlog, "wb")
    child = subprocess.Popen(fixed, stdout=subprocess.DEVNULL, stderr=err, cwd=root)
    return child, err


def wait_for(path, needle, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            text = path.read_text(errors="replace")
            if "Kernel panic" in text:
                raise RuntimeError(f"guest kernel panicked; inspect {path}")
            if needle in text:
                return
        time.sleep(2)
    raise RuntimeError(f"timed out waiting for {needle}; inspect {path}")


def wait_for_any(path, needles, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            text = path.read_text(errors="replace")
            if "Kernel panic" in text:
                raise RuntimeError(f"guest kernel panicked; inspect {path}")
            for needle in needles:
                if needle in text:
                    return needle
        time.sleep(2)
    raise RuntimeError(f"timed out waiting for {needles}; inspect {path}")


def wait_exit(child, timeout):
    try:
        child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
        raise RuntimeError("QEMU did not exit in time")


def fail_if_bad(console):
    text = console.read_text(errors="replace")
    for marker in ("Kernel panic", "not syncing", FAILED):
        if marker in text:
            raise RuntimeError(f"guest proof failed with {marker}; inspect {console}")


def validate_marker(console, generation, serial, failed):
    lines = [line for line in console.read_text(errors="replace").splitlines() if line.startswith(MARKER + " ")]
    assert lines, "guest console names no boot marker"
    marker = json.loads(lines[-1][len(MARKER) + 1:])
    assert set(marker) == MARKER_KEYS, marker.keys()
    assert marker["format"] == "laputa-boot-marker-1"
    assert marker["generation_id"] == generation, marker
    assert marker["boot_serial"] == serial, marker
    assert marker["failed_generation"] == failed, marker
    assert marker["root_digest"] and marker["profile"]
    assert isinstance(marker["services"], list) and marker["services"]
    for service in marker["services"]:
        assert set(service) == {"name", "state"} and service["name"] and service["state"]
    for secret in ("ssh-ed25519", "tskey", "password", "secret"):
        assert secret not in lines[-1]
    return marker


def proof_mode():
    for path in (state_image, outputs / "generations"):
        subprocess.run(["rm", "-rf", str(path)], check=True)
    ensure_state_image()
    console1 = outputs / "maintained-proof-1.log"
    argv = boot_argv(False)
    # No activation record exists in proof mode, so the harness supplies the
    # drill identity the health reporter waits for; the launcher owns these
    # flags on activation boots.
    guest, err = launch(argv, console1, outputs / "maintained-proof-1.qemu.log", " LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL=1")
    try:
        wait_for(console1, READY, 420)
        wait_exit(guest, 120)
    finally:
        err.close()
        if guest.poll() is None:
            guest.terminate()
            try:
                wait_exit(guest, 60)
            except RuntimeError:
                pass
    console2 = outputs / "maintained-proof-2.log"
    guest, err = launch(argv, console2, outputs / "maintained-proof-2.qemu.log", " LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL=1")
    try:
        wait_for(console2, OK, 420)
        fail_if_bad(console2)
        text = console2.read_text(errors="replace")
        assert LOGGER_OK in text, "supervised syslog did not report running"
        assert DHCP_OK in text, "supervised dhcpc did not report a bound lease"
        assert f"{MARKER_COUNT} 2" in text, "boot marker log did not accumulate across the reboot"
        validate_marker(console2, "current", 1, "")
        print("PASS proof: identity survived the reboot with logger and dhcp supervised")
    finally:
        err.close()
        if guest.poll() is None:
            guest.terminate()
            try:
                wait_exit(guest, 120)
            except RuntimeError:
                pass


def fallback_mode():
    for path in (state_image, generations):
        subprocess.run(["rm", "-rf", str(path)], check=True)
    ensure_state_image()
    generations.mkdir(parents=True)
    drill("setup", generations)
    for attempt in (1, 2):
        argv = json.loads(drill("argv", generations))["argv"]
        console = outputs / f"maintained-fallback-{attempt}.log"
        guest, err = launch(argv, console, outputs / f"maintained-fallback-{attempt}.qemu.log")
        try:
            # The first boot writes the identity baseline and asks for a
            # reboot; a boot that finds the baseline reports success and
            # stays up. Either way the attempt is already counted.
            wait_for_any(console, [READY, OK], 420)
            fail_if_bad(console)
        finally:
            err.close()
            if guest.poll() is None:
                guest.send_signal(signal.SIGKILL)
            try:
                wait_exit(guest, 60)
            except RuntimeError:
                pass
        print(f"PASS fallback: power cut during pending boot {attempt}")
    record = json.loads(drill("status", generations))
    assert record["pending"] is None and record["current"] == "a" and record["last"] == "fell-back", record
    argv = json.loads(drill("argv", generations))["argv"]
    console = outputs / "maintained-fallback-3.log"
    guest, err = launch(argv, console, outputs / "maintained-fallback-3.qemu.log")
    try:
        wait_for(console, OK, 420)
        fail_if_bad(console)
        text = console.read_text(errors="replace")
        assert HEALTH in text, "health report missing on the fallback boot"
        marker = validate_marker(console, "a", record["serial"], "b")
        assert {service["name"] for service in marker["services"]} >= {"logger", "dropbear", "dhcp-eth0"}
        assert f"{MARKER_COUNT} 3" in text, "boot marker log did not accumulate the failed boots"
        print(f"PASS fallback: logs name failed generation b with service history: {marker['services']}")
    finally:
        err.close()
        if guest.poll() is None:
            guest.terminate()
            try:
                wait_exit(guest, 120)
            except RuntimeError:
                pass
    final = json.loads(drill("status", generations))
    assert final["pending"] is None and final["current"] == "a", final
    print(f"PASS fallback: activation record rests on a with pending cleared: {final}")


if "--proof" in sys.argv:
    proof_mode()
elif "--fallback" in sys.argv:
    fallback_mode()
else:
    raise SystemExit("usage: maintained_guest.py --proof | --fallback")
