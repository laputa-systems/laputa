import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import time
import uuid


def await_state(scanner, root, predicate):
    deadline = time.monotonic() + 4
    last = None
    while time.monotonic() < deadline:
        assert scanner.poll() is None, f"scanner exited: {scanner.returncode}"
        try:
            last = json.loads((root / "run/app.json").read_text())
            if predicate(last):
                return last
        except FileNotFoundError:
            pass
        time.sleep(0.01)
    raise AssertionError(f"control request did not reconcile: {last}")


def guest():
    root = Path("/work/scenario")
    root.mkdir(mode=0o755)
    (root / "services").mkdir()
    (root / "services/app.xsh").write_text('''##! Steady service used to qualify control wakeups.

## The longrun service declaration.
export let service = {
  name: "app",
  command: process.command_argv("python3", ["python3", "-c", "import time; time.sleep(600)"]),
  logging: "off",
  restart: {mode: "never"},
  stop_timeout_ms: 100,
}
''')
    env = dict(os.environ, XSH_ROOT="/tools", XSH_MODULE_PATH="/laputa",
               XINIT_SERVICE_DIR=str(root / "services"), XINIT_RUN_DIR=str(root / "run"),
               XINIT_LOG_ROOT=str(root / "logs"), XSH_UNIX_DRY_RUN="1",
               XINIT_TEST_FAKE_PIDS="1", XINIT_TEST_MAX_EVENTS="0")
    command = ["/tools/xsh", "/scanner.xsh", "--"]

    def client(action, member):
        def credentials():
            os.setgroups([124] if member else [])
            os.setgid(1001)
            os.setuid(1001)
        result = subprocess.run(command + [action, "app"], env=env, text=True,
                                capture_output=True, timeout=4,
                                preexec_fn=credentials if member is not None else None)
        if member is False:
            assert result.returncode != 0, "nonmember queued a request"
        else:
            assert result.returncode == 0 and "queued" in result.stdout, result

    for generation in range(2):
        with (root / f"scanner-{generation}.log").open("w+") as output:
            scanner = subprocess.Popen(command + ["scan", "app"], env=env,
                                       stdout=output, stderr=subprocess.STDOUT)
            try:
                first = await_state(scanner, root, lambda state: state["state"] == "running"
                                    and state["pid"] > 0 and Path(f"/proc/{state['pid']}").exists())
                marker = json.loads((root / "run/scanner.json").read_text())
                assert marker["pid"] == scanner.pid and marker["start_time_ms"] > 0
                fifo = (root / "run/wake").stat()
                assert stat.S_ISFIFO(fifo.st_mode)
                assert fifo.st_uid == 0 and fifo.st_gid == 124 and fifo.st_mode & 0o777 == 0o660
                client("restart", False)
                for member in (None, True):
                    old_pid = first["pid"]
                    client("restart", member)
                    first = await_state(scanner, root, lambda state: state["state"] == "running"
                                        and state["pid"] > 0 and state["pid"] != old_pid)
                    assert not Path(f"/proc/{old_pid}").exists(), f"old service survived: {old_pid}"
                old_pid = first["pid"]
                scanner.send_signal(signal.SIGSTOP)
                deadline = time.monotonic() + 4
                while "\nState:\tT" not in Path(f"/proc/{scanner.pid}/status").read_text():
                    assert time.monotonic() < deadline, "scanner did not stop"
                    time.sleep(0.01)
                fd = os.open(root / "run/wake", os.O_RDWR | os.O_NONBLOCK | os.O_NOFOLLOW)
                try:
                    while True:
                        try:
                            os.write(fd, b"x" * 4096)
                        except BlockingIOError:
                            break
                    client("restart", True)
                finally:
                    os.close(fd)
                    scanner.send_signal(signal.SIGCONT)
                await_state(scanner, root, lambda state: state["state"] == "running"
                            and state["pid"] > 0 and state["pid"] != old_pid)
                client("stop", True)
                await_state(scanner, root, lambda state: state["state"] == "down")
                client("start", True)
                final = await_state(scanner, root, lambda state: state["state"] == "running")
                scanner.send_signal(signal.SIGTERM)
                assert scanner.wait(timeout=4) == 0
                assert not Path(f"/proc/{final['pid']}").exists(), "scanner retained its service"
                assert not (root / "run/wake").exists(), "scanner retained wake FIFO"
                output.seek(0)
                evidence = output.read()
                assert "uid=1001 verb=restart" in evidence, evidence
                print(f"PASS generation={generation} root+member restart, nonmember refusal, full wake channel, stop/start, TERM cleanup", flush=True)
            finally:
                if scanner.poll() is None:
                    scanner.send_signal(signal.SIGCONT)
                    scanner.terminate()
                    try:
                        scanner.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        scanner.kill()
                        scanner.wait(timeout=4)
                output.seek(0)
                print(output.read(), end="", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tools", type=Path)
    parser.add_argument("--scanner", type=Path)
    parser.add_argument("--guest", action="store_true")
    args = parser.parse_args()
    if args.guest:
        assert os.getuid() == 0 and Path("/work").is_dir()
        guest()
        return
    assert args.tools and (args.tools / "xsh").is_file() and (args.tools / "core").is_dir()
    repo = Path(__file__).resolve().parents[3]
    scanner = (args.scanner or repo / "xinit/xinit.xsh").resolve()
    scratch = repo / ".work/tmp" / ("control-wakeup-" + uuid.uuid4().hex[:10])
    scratch.mkdir(parents=True)
    (scratch / "passwd").write_text("root:x:0:0:root:/root:/bin/false\noperator:x:1001:1001:operator:/work:/bin/false\n")
    (scratch / "group").write_text("root:x:0:\noperator:x:1001:\nxinit-admin:x:124:operator\n")
    name = "xinit-control-" + uuid.uuid4().hex[:10]
    command = ["docker", "run", "--rm", "--name", name, "--network", "none", "--user", "0:0", "--group-add", "124",
               "--cap-drop", "ALL", "--cap-add", "CHOWN", "--cap-add", "SETUID", "--cap-add", "SETGID",
               "--read-only", "--pids-limit", "64", "--memory", "512m", "--cpus", "1",
               "--tmpfs", "/work:rw,mode=1777", "--env", "TMPDIR=/work", "--env", "PYTHONDONTWRITEBYTECODE=1",
               "--mount", f"type=bind,src={repo},dst=/laputa,readonly",
               "--mount", f"type=bind,src={scanner},dst=/scanner.xsh,readonly",
               "--mount", f"type=bind,src={args.tools.resolve()},dst=/tools,readonly",
               "--mount", f"type=bind,src={scratch / 'passwd'},dst=/etc/passwd,readonly",
               "--mount", f"type=bind,src={scratch / 'group'},dst=/etc/group,readonly",
               "--workdir", "/laputa", "--entrypoint", "python3", "xsh-test",
               "/laputa/xinit/tests/fixtures/control_wakeup.py", "--guest"]
    try:
        result = subprocess.run(command, timeout=90)
        assert result.returncode == 0, f"container exit {result.returncode}"
    finally:
        subprocess.run(["docker", "rm", "--force", name], capture_output=True, timeout=10)
        shutil.rmtree(scratch)


if __name__ == "__main__":
    main()
