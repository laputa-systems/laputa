import errno
import os
import pathlib
import shutil
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
xinit = root / "xinit/xinit.xsh"
sleep_bin = shutil.which("sleep") or "/bin/sleep"

SERVICE = """##! Log-pressure fixture service: idles while xinit owns its log.
## The service declaration.
export let service = {
  name: "sleeper",
  kind: "longrun",
  command: process.command_argv(SLEEP, ["sleep", "300"]),
  targets: [
    "boot",
  ],
  log: {mode: "append", max_size: 4096, keep: 2},
}
""".replace("SLEEP", f'"{sleep_bin}"')


def xinit_cmd(*args):
    return [str(binary), str(xinit), *args]


def run_xinit(args, control, timeout=15):
    result = subprocess.run(
        xinit_cmd(*args), env=dict(env, **control), cwd=root,
        capture_output=True, timeout=timeout,
    )
    return result


def wait_for(path, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for {path}")


def service_state(run_dir, name):
    import json

    status = run_dir / f"{name}.json"
    return json.loads(status.read_text())["state"]


def service_pid(run_dir, name):
    import json

    status = run_dir / f"{name}.json"
    return json.loads(status.read_text())["pid"]


def wait_respawned(run_dir, name, old_pid, timeout=30):
    import json

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            raw = json.loads((run_dir / f"{name}.json").read_text())
            if raw.get("state") == "running" and raw.get("pid") != old_pid:
                return
        except (FileNotFoundError, KeyError):
            pass
        time.sleep(0.2)
    raise RuntimeError(f"timed out waiting for {name} to respawn")


def log_pressure():
    with tempfile.TemporaryDirectory(prefix="log-pressure-", dir=scratch) as temporary:
        base = pathlib.Path(temporary)
        # Scanner status stays on writable scratch: production keeps /run
        # (tmpfs) apart from /var/log (state disk), so a full log volume
        # must not stop status writes or the supervisor itself.
        service_dir = base / "services"
        run_dir = base / "run"
        service_dir.mkdir()
        run_dir.mkdir()
        (service_dir / "sleeper.xsh").write_text(SERVICE)
        with tempfile.TemporaryDirectory(prefix="log-pressure-logs-", dir=scratch) as logs_tmp:
            log_dir = pathlib.Path(logs_tmp)
            subprocess.run(["mount", "-t", "tmpfs", "-o", "size=2m", "tmpfs", str(log_dir)], check=True)
            try:
                current = log_dir / "sleeper" / "current"
                current.parent.mkdir(parents=True)
                current.write_bytes(b"x" * 102400)
                filler = log_dir / "filler"
                with filler.open("wb", buffering=0) as output:
                    while True:
                        try:
                            output.write(bytes(65536))
                        except OSError as failure:
                            if failure.errno != errno.ENOSPC:
                                raise
                            break
                control = {
                    "XINIT_SERVICE_DIR": str(service_dir),
                    "XINIT_RUN_DIR": str(run_dir),
                    "XINIT_LOG_ROOT": str(log_dir),
                    "XINIT_TEST_ALLOW_NON_PID1": "1",
                }
                with subprocess.Popen(
                    xinit_cmd("scan", "boot"), env=dict(env, **control), cwd=root,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                ) as scanner:
                    try:
                        wait_for(run_dir / "scanner.json")
                        listed = run_xinit(["list"], control)
                        assert listed.returncode == 0, listed.stderr.decode(errors="replace")
                        assert "sleeper longrun" in listed.stdout.decode(errors="replace")
                        assert service_state(run_dir, "sleeper") == "running"
                        assert current.read_bytes() == b"x" * 102400
                        assert not (log_dir / "sleeper" / "current.1").exists()
                        print("PASS full disk: service starts degraded and the log stays put")
                        # A child exit is the scanner's real wakeup path: the
                        # next pass reconciles, re-enforces the cap, and
                        # respawns, all without touching the full volume.
                        let_old_pid = service_pid(run_dir, "sleeper")
                        os.kill(let_old_pid, signal.SIGTERM)
                        wait_respawned(run_dir, "sleeper", let_old_pid)
                        time.sleep(1)
                        assert scanner.poll() is None, "the supervisor died on a failed rotation"
                        assert service_state(run_dir, "sleeper") == "running"
                        assert current.read_bytes() == b"x" * 102400
                        assert not (log_dir / "sleeper" / "current.1").exists()
                        print("PASS full disk: the supervisor survives rotation pressure")
                        filler.unlink()
                        freed_pid = service_pid(run_dir, "sleeper")
                        os.kill(freed_pid, signal.SIGTERM)
                        wait_respawned(run_dir, "sleeper", freed_pid)
                        deadline = time.time() + 15
                        while not (log_dir / "sleeper" / "current.1").exists():
                            assert time.time() < deadline, "rotation did not resume after space was freed"
                            time.sleep(0.2)
                        print("PASS freed disk: rotation resumes and keeps the bound")
                    finally:
                        if scanner.poll() is None:
                            scanner.send_signal(signal.SIGTERM)
                            scanner.wait(timeout=15)
                        scanner.stdout.close()
                        scanner.stderr.close()
            finally:
                subprocess.run(["umount", str(log_dir)], check=True)


if "--log-pressure" in sys.argv:
    log_pressure()
    sys.exit(0)

subprocess.run(
    ["unshare", "-Urm", sys.executable, str(pathlib.Path(__file__).resolve()), "--log-pressure"],
    env=env, cwd=root, check=True, timeout=120,
)
print("PASS log pressure: copy-truncate degrades on a full disk and recovers")
