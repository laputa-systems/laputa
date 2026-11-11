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
MARKER_COUNT = "LAPUTA_BOOT_MARKER_COUNT"
RESTORE_VERIFY_MARKERS = (
    "RESTORE_CHECK_OK",
    "RESTORE_RESTIC_OK",
    "RESTORE_REBACKUP_OK",
    "RESTORE_KEYLOSS_OK",
    "RESTORE_SECOND_KEY_OK",
    "RESTORE_MASTERKEY_OK",
    VERIFY_OK,
)

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


def artifact_store():
    return pathlib.Path(os.environ.get("LAPUTA_ARTIFACT_STORE", root / ".out/artifacts/x86_64/v2/sha256"))


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


def stage_base(staging, drill_hook=True):
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
    if drill_hook:
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


def stage_backup_disk(tools_dir, image, pw1, pw2, size="512M", staging_dir=None, store=None):
    staging = pathlib.Path(staging_dir) if staging_dir is not None else drill / "backup-staging"
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    (staging / "tools").mkdir(parents=True)
    (staging / "tools/rustic").write_bytes((tools_dir / "rustic").read_bytes())
    (staging / "tools/rustic").chmod(0o755)
    (staging / "tools/restic").write_bytes((tools_dir / "restic").read_bytes())
    (staging / "tools/restic").chmod(0o755)
    lib = staging / "tools/lib"
    lib.mkdir(parents=True)
    store = pathlib.Path(store) if store is not None else artifact_store()
    gnu_stubs = next(
        (entry for entry in store.iterdir()
         if (entry / "artifact.json").exists()
         and json.loads((entry / "artifact.json").read_text()).get("package_name") == "gnu-stubs"),
        None,
    )
    if gnu_stubs is None:
        raise RuntimeError(f"no gnu-stubs artifact in {store}; the restore tools need its libgcc_s")
    with tarfile.open(str(gnu_stubs / "payload.tar.gz")) as archive:
        for member in ("usr/lib/libgcc_s.so", "usr/lib/libgcc_s.so.1"):
            reader = archive.extractfile(archive.getmember(member))
            assert reader is not None
            (lib / pathlib.Path(member).name).write_bytes(reader.read())
    keys = staging / "keys"
    keys.mkdir(parents=True, mode=0o700)
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


def provision_restic(cache_dir=None, search=None):
    cache = pathlib.Path(cache_dir) if cache_dir is not None else root / ".cache/restore-tools"
    if search is None:
        search = (root / ".work/tmp/restore-tools",)
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / f"restic_{RESTIC_VERSION}_linux_amd64"
    if target.exists():
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        if digest != RESTIC_BIN_SHA256:
            raise RuntimeError(f"cached restic has unexpected sha256 {digest}")
        return target
    for directory in search:
        candidate = pathlib.Path(directory) / f"restic_{RESTIC_VERSION}_linux_amd64"
        if candidate.exists():
            digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
            if digest != RESTIC_BIN_SHA256:
                raise RuntimeError(f"cached restic has unexpected sha256 {digest}")
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


def provision_rustic(tools_dir, quiet=False, store=None):
    store = pathlib.Path(store) if store is not None else artifact_store()
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
        raise RuntimeError(f"no rustic artifact in {store}; build it first")
    package_id = json.loads((store / key / "artifact.json").read_text())["package_id"]
    version = package_id.rsplit("-", 1)[0].rsplit("-", 1)[1]
    if version != "0.11.4":
        raise RuntimeError(f"unexpected rustic version: {package_id}")
    if not quiet:
        print(f"PASS tooling: packaged rustic {version}, artifact {key}")
    payload = store / key / "payload.tar.gz"
    with tarfile.open(str(payload)) as archive:
        member = archive.getmember("usr/bin/rustic")
        reader = archive.extractfile(member)
        assert reader is not None
        (tools_dir / "rustic").write_bytes(reader.read())
    (tools_dir / "rustic").chmod(0o755)


def launch(argv, console, errlog, extra_cmdline="", extra_drives=(),
           strip_proof_flag=False, cwd=None):
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
    console.unlink(missing_ok=True)
    err = open(errlog, "wb")
    child = subprocess.Popen(fixed, stdout=subprocess.DEVNULL, stderr=err, cwd=cwd or root)
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


def validate_verify_output(text, marker_count=2, require_proof=True):
    for marker in ("Kernel panic", "not syncing", FAILED, "RESTORE_FAILED"):
        assert marker not in text, f"guest proof failed with {marker}"
    required = list(RESTORE_VERIFY_MARKERS)
    if require_proof:
        required.append(PROOF_OK)
    if marker_count is not None:
        required.append(f"{MARKER_COUNT} {marker_count}")
    for marker in required:
        assert marker in text, f"missing {marker} after restore"


def boot_base_argv():
    return json.loads(drill_cmd("argv-plain"))["argv"]


def install_state(source, dest):
    if pathlib.Path(source).resolve() != pathlib.Path(dest).resolve():
        shutil.copy(str(source), str(dest))


def start_phase(argv, console, qemu_log, token, drives=(), extra="",
                strip_proof_flag=True, cwd=None):
    extra_cmdline = f" {extra.strip()} {token}" if extra.strip() else f" {token}"
    return launch(argv, console, qemu_log, extra_cmdline, drives,
                  strip_proof_flag=strip_proof_flag, cwd=cwd)


def run_phase(argv, console, qemu_log, token, drives=(), extra="",
              strip_proof_flag=True, timeout=420, expect=(), cwd=None):
    guest, err = start_phase(argv, console, qemu_log, token, drives, extra=extra,
                             strip_proof_flag=strip_proof_flag, cwd=cwd)
    try:
        for marker in expect:
            wait_for(console, marker, timeout)
        fail_if_bad(console)
        return console.read_text(errors="replace")
    finally:
        stop_guest(guest, err, console)


def backup_state(argv, state_source, state_dest, backup_image, console, qemu_log,
                 extra="", cwd=None, timeout=420):
    install_state(state_source, state_dest)
    return run_phase(argv, console, qemu_log, "LAPUTA_RESTORE_BACKUP=1",
                     [("backup", backup_image)], extra=extra, strip_proof_flag=True,
                     timeout=timeout, expect=(BACKUP_OK,), cwd=cwd)


def restore_state(argv, state_source, state_dest, backup_image, blank_image,
                  console, qemu_log, extra="", cwd=None, timeout=420):
    install_state(state_source, state_dest)
    return run_phase(argv, console, qemu_log, "LAPUTA_RESTORE_RESTORE=1",
                     [("backup", backup_image), ("blank", blank_image)], extra=extra,
                     strip_proof_flag=True, timeout=timeout, expect=(RESTORE_OK,), cwd=cwd)


def prepare_tools(tools_dir, cache_dir=None, quiet=False, store=None, search=None):
    tools_dir.mkdir(parents=True, exist_ok=True)
    provision_rustic(tools_dir, quiet=quiet, store=store)
    shutil.copy(str(provision_restic(cache_dir, search=search)), str(tools_dir / "restic"))


def build_restore_tools(drill_home, pw1, pw2, store=None, cache_dir=None, search=None):
    tools_dir = drill_home / "tools"
    prepare_tools(tools_dir, cache_dir=cache_dir, store=store, search=search)
    stage_backup_disk(tools_dir, drill_home / "backup.ext4", pw1, pw2,
                      staging_dir=drill_home / "backup-staging", store=store)
    staging = drill_home / "blank-staging"
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    staging.mkdir(parents=True)
    make_state_image(staging, drill_home / "blank.ext4")
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    return tools_dir


def build_skeleton_state(image, drill_home, drill_hook=True):
    staging = drill_home / "skeleton-staging"
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    stage_base(staging, drill_hook=drill_hook)
    if drill_hook:
        stage_drill_files(staging)
    make_state_image(staging, image)
    subprocess.run(["rm", "-rf", str(staging)], check=True)


def setup():
    for path in (state_image, drill):
        subprocess.run(["rm", "-rf", str(path)], check=True)
    drill.mkdir(parents=True)
    pw1 = ("test-only-restore1-" + secrets.token_hex(8) + "\n").encode()
    pw2 = ("test-only-restore2-" + secrets.token_hex(8) + "\n").encode()
    staging = drill / "boot1-staging"
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    stage_base(staging)
    run_xsh(str(apply_fixture), "--", str(staging))
    stage_drill_files(staging)
    make_state_image(staging, drill / "boot1-state.ext4")
    subprocess.run(["rm", "-rf", str(staging)], check=True)
    build_skeleton_state(drill / "skeleton-state.ext4", drill)
    build_restore_tools(drill, pw1, pw2)


def phase_backup():
    backup_state(boot_base_argv(), drill / "boot1-state.ext4", state_image,
                 drill / "backup.ext4", drill / "backup.log", drill / "backup.qemu.log",
                 extra="LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL=1")
    print("PASS backup: state dirs snapshotted with no generation in the set")


def phase_restore():
    restore_state(boot_base_argv(), drill / "skeleton-state.ext4", state_image,
                  drill / "backup.ext4", drill / "blank.ext4",
                  drill / "restore.log", drill / "restore.qemu.log",
                  extra="LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL=1")
    print("PASS restore: blank disk carries byte-identical identity files")


def phase_verify():
    install_state(drill / "blank.ext4", state_image)
    console = drill / "verify.log"
    guest, err = start_phase(boot_base_argv(), console, drill / "verify.qemu.log",
                             "LAPUTA_RESTORE_VERIFY=1", [("backup", drill / "backup.ext4")],
                             extra="LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL=1",
                             strip_proof_flag=False)
    try:
        wait_for(console, PROOF_OK, 420)
        wait_for(console, VERIFY_OK, 120)
        fail_if_bad(console)
        validate_verify_output(console.read_text(errors="replace"))
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
