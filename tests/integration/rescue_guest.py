import hashlib
import json
import os
import pathlib
import shutil
import signal
import struct
import subprocess
import tarfile
import time

root = pathlib.Path(__file__).resolve().parents[2]
scratch = root / ".work/tmp"
scratch.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, XSH_MODULE_PATH=str(root), TMPDIR=str(scratch))
binary = root / ".out/host/x86_64/xsh"
fixture = root / "tests/integration/fixtures/rescue-drill.xsh"
store = pathlib.Path(os.environ.get("LAPUTA_ARTIFACT_STORE", root / ".out/artifacts/x86_64/v2/sha256"))
kernel = pathlib.Path(os.environ.get("LAPUTA_RESCUE_KERNEL", root / "target/laputa/qemu-maintained/current/vmlinuz"))
work = root / ".work/rescue-guest"

PAYLOAD = b"laputa rescue payload\n"
PAYLOAD_SHA256 = hashlib.sha256(PAYLOAD).hexdigest()
ROOT_PACKAGES = ["baselayout", "musl", "xsh", "xinit", "e2fsprogs"]
CASES = [("clean", 0), ("repaired", 1), ("unrecoverable", 8)]
CMDLINE = (
    "earlyprintk=serial console=ttyS0 ignore_loglevel devtmpfs.mount=1 "
    "root=/dev/vda rootfstype=ext4 ro rootwait rootdelay=2 init=/init loglevel=8 "
    "XSH_LINUX_REAL=1 XSH_UNIX_REAL=1 XINIT_LOG_ROOT=/run/log TMPDIR=/run"
)
INITTAB = "::sysinit:/usr/lib/init/rc.boot\n::once:/usr/bin/xsh /usr/lib/laputa/rescue-proof.xsh\n::restart:/usr/bin/xinit /etc/inittab\n"


def run_xsh(*args):
    result = subprocess.run([str(binary), *args], env=env, cwd=root, capture_output=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return result.stdout.decode()


def packaged_payload(name):
    candidates = []
    for entry in store.iterdir():
        meta = entry / "artifact.json"
        if not meta.exists():
            continue
        record = json.loads(meta.read_text())
        if record.get("package_name") == name:
            release = int(record["package_id"].rsplit("-", 1)[1])
            candidates.append((release, entry / "payload.tar.gz"))
    if not candidates:
        raise RuntimeError(f"no {name} artifact in {store}; build it with make build PKGS=e2fsprogs")
    return max(candidates)[1]


def compose_rescue_root(image):
    staging = work / "rescue-root"
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    for name in ROOT_PACKAGES:
        with tarfile.open(packaged_payload(name)) as archive:
            archive.extractall(staging, filter="tar")
    (staging / "etc/inittab").write_text(INITTAB)
    proof = staging / "usr/lib/laputa/rescue-proof.xsh"
    proof.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(root / "guest/rescue-proof.xsh", proof)
    proof.chmod(0o755)
    image.unlink(missing_ok=True)
    subprocess.run(["/sbin/mke2fs", "-q", "-F", "-t", "ext4", "-d", str(staging), str(image), "256M"], check=True)
    shutil.rmtree(staging)


def fixture_disk(path, kind):
    staging = work / "fixture-tree"
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    (staging / "payload").write_bytes(PAYLOAD)
    path.unlink(missing_ok=True)
    subprocess.run(["/sbin/mke2fs", "-q", "-F", "-t", "ext4", "-O", "^metadata_csum", "-d", str(staging), str(path), "32M"], check=True)
    shutil.rmtree(staging)
    with open(path, "r+b") as disk:
        free = superblock_free_blocks(disk)
        if kind == "repaired":
            disk.seek(1024 + 12)
            disk.write(struct.pack("<I", free + 7))
        elif kind == "unrecoverable":
            disk.seek(1024 + 56)
            disk.write(b"\x00\x00")
    return free


def superblock_free_blocks(disk):
    disk.seek(1024 + 12)
    return struct.unpack("<I", disk.read(4))[0]


def host_check(path):
    return subprocess.run(["/sbin/e2fsck", "-f", "-n", str(path)], capture_output=True).returncode


def host_preen_refusal(path):
    return subprocess.run(["/sbin/e2fsck", "-f", "-p", str(path)], capture_output=True).returncode


def boot(image, disk, console, expected):
    plan = json.loads(run_xsh(str(fixture), "--", "plan", str(image), str(disk)))["command"]
    argv = [
        "qemu-system-x86_64", "-M", "q35,accel=kvm", "-cpu", "host", "-smp", "1", "-m", "512M",
        "-kernel", str(kernel), "-append", f"{CMDLINE} LAPUTA_RESCUE_EXPECT={expected}", "-nic", "none", "-no-reboot",
        *plan,
    ]
    serial = argv.index("-serial")
    argv[serial + 1] = f"file:{console}"
    return argv


def wait_for(path, needles, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            text = path.read_text(errors="replace")
            for bad in ("Kernel panic", "LAPUTA_RESCUE_PROOF_FAILED"):
                if bad in text:
                    raise RuntimeError(f"rescue guest failed with {bad}; inspect {path}")
            if all(needle in text for needle in needles):
                return text
        time.sleep(1)
    raise RuntimeError(f"timed out waiting for {needles}; inspect {path}")


def rescue_case(image, name, expected):
    disk = work / f"detached-{name}.img"
    free = fixture_disk(disk, name)
    before = host_check(disk)
    console = work / f"rescue-{name}.log"
    console.unlink(missing_ok=True)
    argv = boot(image, disk, console, expected)
    with open(work / f"rescue-{name}.qemu.log", "wb") as err:
        child = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=err, cwd=root)
        try:
            text = wait_for(console, [f"LAPUTA_RESCUE_PROOF_OK status {expected}"], 240)
        finally:
            child.send_signal(signal.SIGKILL)
            child.wait(timeout=60)
    assert "LAPUTA_RESCUE_ISOLATED" in text
    classified = run_xsh(str(fixture), "--", "classify", str(expected)).strip()
    assert classified == name, (classified, name)
    after = host_check(disk)
    if name == "clean":
        assert before == 0 and after == 0, (before, after)
        assert f"LAPUTA_RESCUE_PAYLOAD {PAYLOAD_SHA256}" in text
    elif name == "repaired":
        assert after == 0, (before, after)
        with open(disk, "rb") as repaired:
            assert superblock_free_blocks(repaired) == free, "the superblock free-block count was not repaired"
        assert f"LAPUTA_RESCUE_PAYLOAD {PAYLOAD_SHA256}" in text
    else:
        assert host_preen_refusal(disk) == 8, "the damaged superblock changed"
        assert "LAPUTA_RESCUE_PAYLOAD" not in text
    print(f"PASS rescue: {name} (e2fsck {expected})")


def main():
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    image = work / "rescue-root.ext4"
    compose_rescue_root(image)
    for name, expected in CASES:
        rescue_case(image, name, expected)


if __name__ == "__main__":
    main()
