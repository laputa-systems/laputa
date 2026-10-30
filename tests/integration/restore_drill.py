import hashlib
import json
import os
import pathlib
import secrets
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import urllib.request

root = pathlib.Path(__file__).resolve().parents[2]
scratch = root / ".work/tmp"
scratch.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, XSH_MODULE_PATH=str(root), TMPDIR=str(scratch))
binary = root / ".out/host/x86_64/xsh"
fixture = root / "tests/integration/fixtures/maintained-fallback.xsh"
apply_fixture = root / "tests/integration/fixtures/maintained-state-apply.xsh"
outputs = root / "target/laputa/qemu-maintained"
drill = outputs / "restore-drill"
state_image = outputs / "state.ext4"

BACKUP_OK = "RESTORE_BACKUP_OK"
RESTORE_OK = "RESTORE_RESTORE_OK"
VERIFY_OK = "RESTORE_VERIFY_OK"
PROOF_OK = "LAPUTA_MAINTAINED_PROOF_OK"
FAILED = "LAPUTA_MAINTAINED_PROOF_FAILED"
LOGGER_OK = "LAPUTA_MAINTAINED_LOGGER_OK"
DHCP_OK = "LAPUTA_MAINTAINED_DHCP_OK"
MARKER_COUNT = "LAPUTA_BOOT_MARKER_COUNT"

RESTIC_VERSION = "0.18.1"
RESTIC_URL = (
    "https://github.com/restic/restic/releases/download/v0.18.1/"
    "restic_0.18.1_linux_amd64.bz2"
)
RESTIC_BZ2_SHA256 = (
    "680838f19d67151adba227e1570cdd8af12c19cf1735783ed1ba928bc41f363d"
)
RESTIC_BIN_SHA256 = (
    "01143daba61a1dc8afb0cb3d03ba83e6b118f55b6b146b27473a09efc3df13d6"
)


def run_xsh(*args, timeout=60):
    result = subprocess.run(
        [str(binary), *args], env=env, cwd=root,
        capture_output=True, timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return result.stdout.decode()


def drill_cmd(op, *args):
    return run_xsh(str(fixture), "--", op, *[str(a) for a in args])


def stage_base(staging):
    for name in ("etc", "home", "var"):
        (staging / name).mkdir(parents=True)
    base_etc = root / "packages/baselayout/files/rootfs/etc"
    for entry in sorted(base_etc.iterdir()):
        if entry.name == "inittab":
            continue
        dest = staging / "etc" / entry.name
        if entry.is_symlink() or entry.is_file():
            subprocess.run(["cp", "-a", str(entry), str(dest)], check=True)
        elif entry.is_dir():
            subprocess.run(["cp", "-a", str(entry), str(staging / "etc")], check=True)
    subprocess.run(["cp", str(root / "profiles/qemu-maintained/etc/inittab"),
                    str(staging / "etc/inittab")], check=True)
    with open(staging / "etc/inittab", "a") as handle:
        handle.write("::once:/usr/bin/xsh /etc/laputa/drill/drill.xsh\n")
    subprocess.run(["cp", str(root / "packages/nftables/nftables.conf"),
                    str(staging / "etc/nftables.conf")], check=True)
    (staging / "etc/network").mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", str(root / "packages/laputa-net/interfaces"),
                    str(staging / "etc/network/interfaces")], check=True)
    (staging / "var/lib/dhcpc").mkdir(parents=True)
    (staging / "var/lib/dhcpc").chmod(0o700)
    (staging / "var/lib/laputa").mkdir(parents=True, exist_ok=True)
    (staging / "var/log").mkdir(parents=True, exist_ok=True)
    (staging / "format").write_text("laputa-maintained-state-1\n")


def stage_drill_files(staging):
    drill_dir = staging / "etc/laputa/drill"
    drill_dir.mkdir(parents=True, exist_ok=True)
    (drill_dir / ".no-backup").write_text("exclude drill scaffolding from the backup\n")


def make_state_image(staging, image, size="256M"):
    subprocess.run(
        ["/sbin/mkfs.ext4", "-q", "-F", "-d", str(staging), str(image), size],
        check=True,
    )
    image.chmod(0o600)


def stage_backup_disk(tools_dir, image, pw1, pw2, size="512M"):
    staging = drill / "backup-staging"
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    (staging / "tools").mkdir(parents=True)
    (staging / "tools/rustic").write_bytes((tools_dir / "rustic").read_bytes())
    (staging / "tools/rustic").chmod(0o755)
    (staging / "tools/restic").write_bytes((tools_dir / "restic").read_bytes())
    (staging / "tools/restic").chmod(0o755)
    lib = staging / "tools/lib"
    lib.mkdir(parents=True)
    store = root / ".out/artifacts/x86_64/v2/sha256"
    gnu_stubs = next(
        entry for entry in store.iterdir()
        if (entry / "artifact.json").exists()
        and json.loads((entry / "artifact.json").read_text()).get("package_name") == "gnu-stubs"
    )
    with tarfile.open(str(gnu_stubs / "payload.tar.gz")) as archive:
        for member in ("usr/lib/libgcc_s.so", "usr/lib/libgcc_s.so.1"):
            reader = archive.extractfile(archive.getmember(member))
            assert reader is not None
            (lib / pathlib.Path(member).name).write_bytes(reader.read())
    keys = staging / "keys"
    keys.mkdir(parents=True)
    (keys / "password1").write_bytes(pw1)
    (keys / "password1").chmod(0o600)
    (keys / "password2").write_bytes(pw2)
    (keys / "password2").chmod(0o600)
    subprocess.run(
        ["/sbin/mkfs.ext4", "-q", "-F", "-d", str(staging), str(image), size],
        check=True,
    )
    image.chmod(0o600)
    subprocess.run(["rm", "-rf", str(staging)], check=True)


def provision_restic():
    cache = root / ".cache/restore-tools"
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / f"restic_{RESTIC_VERSION}_linux_amd64"
    if target.exists():
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        if digest != RESTIC_BIN_SHA256:
            raise RuntimeError(f"cached restic has unexpected sha256 {digest}")
        return target
    for name in ("restic_0.18.1_linux_amd64", "restic_0.18.1_linux_amd64.bz2"):
        candidate = root / ".work/tmp/restore-tools" / name
        if candidate.exists() and name == "restic_0.18.1_linux_amd64":
            shutil.copy(str(candidate), str(target))
            return target
    archive = cache / "restic.bz2"
    urllib.request.urlretrieve(RESTIC_URL, str(archive))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != RESTIC_BZ2_SHA256:
        raise RuntimeError(f"downloaded restic has unexpected sha256 {digest}")
    subprocess.run(["bzip2", "-dk", str(archive)], check=True)
    candidate = cache / "restic"
    if not candidate.exists():
        raise RuntimeError("restic decompression produced no binary")
    candidate.rename(target)
    return target


def provision_rustic(tools_dir):
    store = root / ".out/artifacts/x86_64/v2/sha256"
    key = None
    for entry in store.iterdir():
        meta = entry / "artifact.json"
        if not meta.exists():
            continue
        record = json.loads(meta.read_text())
        if record.get("package_name") == "rustic":
            key = record["key"]
            break
    if key is None:
        raise RuntimeError("no rustic artifact in the store; build it first")
    package_id = json.loads((store / key / "artifact.json").read_text())["package_id"]
    version = package_id.rsplit("-", 1)[0].rsplit("-", 1)[1]
    if version != "0.11.4":
        raise RuntimeError(f"unexpected rustic version: {package_id}")
    print(f"PASS tooling: packaged rustic {version}, artifact {key}")
    payload = (root / ".out/artifacts/x86_64/v2/sha256" / key / "payload.tar.gz")
    with tarfile.open(str(payload)) as archive:
        member = archive.getmember("usr/bin/rustic")
        reader = archive.extractfile(member)
        assert reader is not None
        (tools_dir / "rustic").write_bytes(reader.read())
    (tools_dir / "rustic").chmod(0o755)


def launch(argv, console, errlog, extra_cmdline="", extra_drives=(),
           strip_proof_flag=False):
    fixed = list(argv)
    serial = fixed.index("-serial")
    fixed[serial + 1] = f"file:{console}"
    append = fixed.index("-append")
    if extra_cmdline:
        fixed[append + 1] += extra_cmdline
    if strip_proof_flag:
        fixed[append + 1] = " ".join(
            token for token in fixed[append + 1].split(" ")
            if token != "LAPUTA_MAINTAINED_PROOF_FLAG=1"
        )
    for drive_id, path in extra_drives:
        device = next(a for a in fixed if a.startswith("virtio") and "drive=" in a)
        kind = device.split(",")[0]
        fixed.extend(["-drive", f"if=none,id={drive_id},format=raw,file={path}",
                      "-device", f"{kind},drive={drive_id}"])
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


def stop_guest(child, err, console):
    err.close()
    if child.poll() is None:
        child.send_signal(signal.SIGKILL)
    try:
        child.wait(timeout=60)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
        raise RuntimeError("QEMU did not exit in time")


def fail_if_bad(console):
    text = console.read_text(errors="replace")
    for marker in ("Kernel panic", "not syncing", FAILED, "RESTORE_FAILED"):
        if marker in text:
            raise RuntimeError(f"guest proof failed with {marker}; inspect {console}")


def boot_base_argv():
    return json.loads(drill_cmd("argv-plain"))["argv"]


def setup():
    for path in (state_image, drill):
        subprocess.run(["rm", "-rf", str(path)], check=True)
    drill.mkdir(parents=True)
    tools_dir = drill / "tools"
    tools_dir.mkdir(parents=True)
    provision_rustic(tools_dir)
    shutil.copy(str(provision_restic()), str(tools_dir / "restic"))
    pw1 = ("test-only-restore1-" + secrets.token_hex(8) + "\n").encode()
    pw2 = ("test-only-restore2-" + secrets.token_hex(8) + "\n").encode()
    keys = drill / "keys"
    keys.mkdir()
    (keys / "password1").write_bytes(pw1)
    (keys / "password1").chmod(0o600)
    (keys / "password2").write_bytes(pw2)
    (keys / "password2").chmod(0o600)
    staging = drill / "boot1-staging"
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    stage_base(staging)
    run_xsh(str(apply_fixture), "--", str(staging))
    stage_drill_files(staging)
    make_state_image(staging, drill / "boot1-state.ext4")
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    staging = drill / "skeleton-staging"
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    stage_base(staging)
    stage_drill_files(staging)
    make_state_image(staging, drill / "skeleton-state.ext4")
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    stage_backup_disk(tools_dir, drill / "backup.ext4", pw1, pw2)
    staging = drill / "blank-staging"
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    staging.mkdir(parents=True)
    make_state_image(staging, drill / "blank.ext4")
    subprocess.run(["rm", "-rf", str(staging)], check=True)


def phase_backup():
    shutil.copy(str(drill / "boot1-state.ext4"), str(state_image))
    console = drill / "backup.log"
    guest, err = launch(
        boot_base_argv(), console, drill / "backup.qemu.log",
        " LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL=1 LAPUTA_RESTORE_BACKUP=1",
        [("backup", drill / "backup.ext4")],
        strip_proof_flag=True,
    )
    try:
        wait_for(console, BACKUP_OK, 420)
        fail_if_bad(console)
        print("PASS backup: state dirs snapshotted with no generation in the set")
    finally:
        stop_guest(guest, err, console)


def phase_restore():
    shutil.copy(str(drill / "skeleton-state.ext4"), str(state_image))
    console = drill / "restore.log"
    guest, err = launch(
        boot_base_argv(), console, drill / "restore.qemu.log",
        " LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL=1 LAPUTA_RESTORE_RESTORE=1",
        [("backup", drill / "backup.ext4"), ("blank", drill / "blank.ext4")],
        strip_proof_flag=True,
    )
    try:
        wait_for(console, RESTORE_OK, 420)
        fail_if_bad(console)
        print("PASS restore: blank disk carries byte-identical identity files")
    finally:
        stop_guest(guest, err, console)


def phase_verify():
    shutil.copy(str(drill / "blank.ext4"), str(state_image))
    console = drill / "verify.log"
    guest, err = launch(
        boot_base_argv(), console, drill / "verify.qemu.log",
        " LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL=1 LAPUTA_RESTORE_VERIFY=1",
        [("backup", drill / "backup.ext4")],
    )
    try:
        wait_for(console, PROOF_OK, 420)
        wait_for(console, VERIFY_OK, 120)
        fail_if_bad(console)
        text = console.read_text(errors="replace")
        assert LOGGER_OK in text, "supervised syslog did not report running"
        assert DHCP_OK in text, "supervised dhcpc did not report a bound lease"
        assert f"{MARKER_COUNT} 2" in text, "boot marker log did not count the restore boot"
        for marker in ("RESTORE_CHECK_OK", "RESTORE_RESTIC_OK",
                       "RESTORE_REBACKUP_OK", "RESTORE_KEYLOSS_OK",
                       "RESTORE_SECOND_KEY_OK"):
            assert marker in text, f"missing {marker} after restore"
        print("PASS verify: identity survived the restore with logger and dhcp supervised")
    finally:
        stop_guest(guest, err, console)


def main():
    raw = sys.argv[1:]
    reuse = "--reuse" in raw
    if "--help" in raw or "-h" in raw:
        print("usage: restore_drill.py [--reuse] [backup] [restore] [verify]")
        print("  default runs setup plus all three phases; --reuse skips setup")
        print("  and replays the named phases against the previous run's disks")
        return
    phases = [a for a in raw if not a.startswith("--")] or ["all"]
    if phases == ["all"]:
        phases = ["backup", "restore", "verify"]
    for phase in phases:
        if phase not in ("backup", "restore", "verify"):
            raise SystemExit(f"unknown drill phase {phase}")
    if not reuse:
        setup()
    else:
        for name in ("boot1-state.ext4", "skeleton-state.ext4",
                     "backup.ext4", "blank.ext4"):
            if not (drill / name).exists():
                raise SystemExit(f"--reuse needs a prior setup run; missing {name}")
    if "backup" in phases:
        phase_backup()
    if "restore" in phases:
        # The original VM is gone from here on; only the backup disk, the image
        # bundle, and fresh state images take part.
        phase_restore()
    if "verify" in phases:
        phase_verify()
    if phases == ["backup", "restore", "verify"]:
        print("PASS restore-drill: blank-disk restore boots with a clean re-backup")


if __name__ == "__main__":
    main()
