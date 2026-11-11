import argparse
import gzip
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[2]
scratch_root = root / ".work/tmp"
fixtures = root / "xinit/tests/fixtures"
ready = "R1_PROOF_READY"
pre_shutdown = "R1_REBOOT_OWNED_STOPPED_BEFORE_FS_SHUTDOWN"
failure = "R1_FAIL"

scanner_entry = "::respawn:/usr/bin/xinit scan boot"


def require(condition, message, console=None):
    if condition:
        return
    detail = ""
    if console is not None and console.exists():
        lines = console.read_text(errors="replace").splitlines()
        detail = "\n" + "\n".join(lines[-40:])
    raise AssertionError(message + detail)


def copy(stage, source, destination, mode=0o644):
    target = stage / destination.lstrip("/")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    target.chmod(mode)


def stage_root(seed, stage):
    for directory in (
        "bin",
        "core",
        "dev",
        "etc/r1",
        "etc/rc.d",
        "proc",
        "run",
        "sys",
        "tmp",
        "usr/bin",
        "usr/lib/init",
        "usr/lib/xinit/services",
        "var/log",
    ):
        (stage / directory).mkdir(parents=True, exist_ok=True)

    shutil.copytree(seed / "core", stage / "core", symlinks=True, dirs_exist_ok=True)
    copy(stage, seed / "xsh", "/bin/xsh", 0o755)
    copy(stage, root / "xinit/xinit.xsh", "/usr/bin/xinit", 0o755)
    (stage / "init").symlink_to(pathlib.Path("usr/bin/xinit"))

    baselayout = root / "packages/baselayout/files/rootfs"
    copy(stage, baselayout / "usr/lib/init/rc.boot", "/usr/lib/init/rc.boot", 0o755)
    copy(stage, baselayout / "usr/lib/init/rc.shutdown", "/usr/lib/init/rc.shutdown", 0o755)

    shipped = [line.strip() for line in (baselayout / "etc/inittab").read_text().splitlines() if line.strip() == scanner_entry]
    require(len(shipped) == 1, "baselayout inittab must name exactly one boot scanner")

    for name in ("base", "app", "slow"):
        copy(stage, fixtures / f"lifecycle_{name}.xsh", f"/usr/lib/xinit/services/r1-{name}.xsh")
    copy(stage, fixtures / "lifecycle_broken.xsh", "/etc/r1/broken.xsh")
    copy(stage, fixtures / "lifecycle_worker.xsh", "/etc/r1/worker.xsh", 0o755)
    copy(stage, fixtures / "lifecycle_proof.xsh", "/etc/r1/proof.xsh", 0o755)
    copy(stage, fixtures / "lifecycle_pre_shutdown.xsh", "/etc/rc.d/50-r1.pre.shutdown", 0o755)

    (stage / "etc/inittab").write_text(
        "\n".join(
            [
                "::sysinit:/usr/lib/init/rc.boot",
                shipped[0],
                "::once:/etc/r1/proof.xsh",
                "::restart:/usr/bin/xinit /etc/inittab",
                "::shutdown:/usr/lib/init/rc.shutdown",
                "",
            ]
        )
    )
    (stage / "etc/fstab").write_text("")


def pack(stage, initrd):
    entries = ["."]
    for directory, directories, files in os.walk(stage):
        relative = os.path.relpath(directory, stage)
        directories.sort()
        files.sort()
        if relative != ".":
            entries.append(relative)
        for name in files:
            entries.append(name if relative == "." else os.path.join(relative, name))
    archiver = subprocess.run(
        ["cpio", "-o", "-H", "newc"],
        input=("\n".join(entries) + "\n").encode(),
        cwd=stage,
        capture_output=True,
    )
    if archiver.returncode:
        raise RuntimeError(archiver.stderr.decode(errors="replace"))
    with gzip.open(initrd, "wb", compresslevel=1) as output:
        output.write(archiver.stdout)


def launch(qemu, kernel, initrd, console, qemu_log):
    cmdline = "console=ttyS0 rdinit=/init panic=-1 loglevel=4 devtmpfs.mount=1"
    argv = [
        qemu,
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
        f"file:{console}",
        "-kernel",
        str(kernel),
        "-initrd",
        str(initrd),
        "-append",
        cmdline,
    ]
    errors = open(qemu_log, "wb")
    child = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=errors)
    return child, errors


def markers(console, prefix):
    found = []
    if not console.exists():
        return found
    for line in console.read_text(errors="replace").splitlines():
        if line.startswith(prefix + " "):
            found.append(json.loads(line[len(prefix) + 1:]))
    return found


def marker_line(console, prefix):
    if not console.exists():
        return None
    for number, line in enumerate(console.read_text(errors="replace").splitlines()):
        if line.startswith(prefix):
            return number
    return None


def run_guest(seed, kernel, qemu, timeout):
    work = scratch_root / f"xinit-lifecycle-{os.getpid()}-{int(time.time())}"
    work.mkdir(parents=True)
    stage = work / "root"
    stage.mkdir()
    initrd = work / "initrd.gz"
    console = work / "console.log"
    qemu_log = work / "qemu.log"
    stage_root(seed, stage)
    require((stage / "etc/inittab").read_text().count("xinit scan boot") == 1, "inittab must name exactly one boot scanner")
    pack(stage, initrd)

    child, errors = launch(qemu, kernel, initrd, console, qemu_log)
    succeeded = False
    try:
        deadline = time.time() + timeout
        while time.time() < deadline:
            text = console.read_text(errors="replace") if console.exists() else ""
            if "Kernel panic" in text or "not syncing" in text:
                raise AssertionError("guest kernel panicked\n" + text[-4000:])
            if failure in text:
                raise AssertionError("guest proof failed\n" + text[-4000:])
            if ready in text:
                break
            if child.poll() is not None:
                raise AssertionError("guest exited before its proof marker\n" + text[-4000:])
            time.sleep(0.25)
        else:
            raise AssertionError("guest did not reach its proof marker")

        try:
            status = child.wait(timeout=90)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            raise AssertionError("guest did not reboot within the shutdown budget")

        text = console.read_text(errors="replace")
        require(status == 0, f"QEMU exited with {status} after the guest reboot", console)
        require(failure not in text, "guest proof reported a failure", console)
        require("Kernel panic" not in text and "not syncing" not in text, "guest kernel panicked", console)

        graph = markers(console, "R1_GRAPH")
        require(len(graph) == 1, "missing or repeated graph marker", console)
        require(graph[0]["base"] == 1 and graph[0]["app"] == 1 and graph[0]["slow"] == 1, f"initial starts were not single: {graph[0]}", console)
        require(graph[0]["scanners"] == 1, f"scanner count was not one: {graph[0]}", console)

        backoff = markers(console, "R1_BACKOFF")
        require(len(backoff) == 1, "missing backoff marker", console)
        require(backoff[0]["observed_ms"] >= 400, f"respawn was not delayed: {backoff[0]}", console)
        require(backoff[0]["restarts"] >= 1, f"restart count did not advance: {backoff[0]}", console)
        require(backoff[0]["starts_base"] == 1 and backoff[0]["starts_app"] == 2 and backoff[0]["starts_slow"] == 1, f"crash cascaded to a dependent: {backoff[0]}", console)

        restart = markers(console, "R1_SCANNER_RESTART")
        require(len(restart) == 1, "missing scanner restart marker", console)
        require(restart[0]["old"] != restart[0]["new"], f"scanner pid did not change: {restart[0]}", console)
        require(restart[0]["duplicates"] == 0, f"duplicate instances appeared: {restart[0]}", console)
        require(restart[0]["workers_base"] == 1 and restart[0]["workers_app"] == 1 and restart[0]["workers_slow"] == 1, f"worker process count was not one per unit: {restart[0]}", console)
        require(restart[0]["scanners"] == 1, f"scanner process count was not one: {restart[0]}", console)
        require(restart[0]["starts_base"] == 2 and restart[0]["starts_app"] == 3 and restart[0]["starts_slow"] == 2, f"scanner restart duplicated starts: {restart[0]}", console)

        malformed = markers(console, "R1_MALFORMED")
        require(len(malformed) == 1 and malformed[0]["status"] != 0, "malformed configuration did not fail", console)
        require(malformed[0]["field"] == "typo" and malformed[0]["source"] == "/etc/r1/broken.xsh", f"malformed status was not explicit: {malformed}", console)

        readiness = markers(console, "R1_READINESS")
        require(len(readiness) == 1 and readiness[0]["ready"] is False and readiness[0]["state"] == "running", "readiness timeout was not explicit", console)

        require(pre_shutdown in text, "reboot did not report owned services stopped before filesystem shutdown", console)
        pre = markers(console, "R1_REBOOT_PRE")
        require(len(pre) == 1 and pre[0]["survivors"] == 0 and pre[0]["root_rw"] is True, f"shutdown hook saw a wrong state: {pre}", console)
        require(marker_line(console, "R1_PROOF_READY") < marker_line(console, pre_shutdown), "reboot began before the proof finished", console)
        succeeded = True
        print(f"PASS graph={graph[0]} backoff={backoff[0]} scanner={restart[0]} malformed={malformed[0]} readiness={readiness[0]} shutdown={pre[0]}")
    finally:
        errors.close()
        if child.poll() is None:
            child.kill()
            child.wait()
        if succeeded:
            shutil.rmtree(work)
        else:
            print(f"guest evidence kept at {work}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel", type=pathlib.Path, default=root / "target/laputa/qemu-maintained/current/vmlinuz")
    parser.add_argument("--xsh-root", type=pathlib.Path, default=root / ".out/seed/x86_64")
    parser.add_argument("--qemu", default="qemu-system-x86_64")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    require(args.kernel.exists(), f"kernel is missing at {args.kernel}; build qemu-maintained or pass --kernel")
    require((args.xsh_root / "xsh").exists() and (args.xsh_root / "core").is_dir(), f"xsh root at {args.xsh_root} needs xsh and core/")
    require(pathlib.Path("/dev/kvm").exists(), "KVM is required for the lifecycle guest")
    qemu = shutil.which(args.qemu)
    require(qemu is not None, f"{args.qemu} is not installed")
    require(shutil.which("cpio") is not None, "cpio is required to stage the initramfs")
    scratch_root.mkdir(parents=True, exist_ok=True)

    run_guest(args.xsh_root, args.kernel, qemu, args.timeout)


if __name__ == "__main__":
    main()
