import os
import pathlib
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[2]
if len(sys.argv) != 5:
    raise SystemExit("usage: activation_ssh.py XSH PORT KEY PIN")
xsh, port, key, pin = sys.argv[1:]
client = root / "tests/integration/fixtures/activation-ssh-client.xsh"
env = dict(os.environ, XSH_MODULE_PATH=str(root), TMPDIR=str(root / ".work/tmp"))
base = [xsh, str(client), "--", port, key, pin]


def call(operation, source=None):
    args = [*base, operation]
    if source is not None:
        args.append(str(root / source))
    result = subprocess.run(args, cwd=root, env=env, capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError(f"{operation}: {result.stderr}")
    return result.stdout.strip()


def wait_for(operation, expected, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if call(operation) == expected:
            return
        time.sleep(0.2)
    raise RuntimeError(f"timed out waiting for {operation}")


assert call("probe") == "ssh-stdin"
call("setup")
assert call("home-write") == "home-ok"
for operation, source in (
    ("activation", "system/activation.xsh"),
    ("launcher", "system/launcher.xsh"),
    ("fixture", "tests/integration/fixtures/activation-ssh-guest.xsh"),
):
    call(operation, source)
assert call("prepare") == "acknowledged"
stage = subprocess.Popen([*base, "stage"], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    wait_for("poll", "true", 60)
    if stage.poll() is not None:
        raise RuntimeError("stage returned before the reply was dropped")
    stage.kill()
    output, error = stage.communicate(timeout=10)
    if output:
        raise RuntimeError(f"stage replied before disconnect: {output}")
    assert call("inspect") == "acknowledged"
    call("release")
    wait_for("reaped", "true", 30)
    print("PASS: stage committed before SSH reply loss; reconnect verified state and selected the candidate")
finally:
    try:
        call("release")
    except (RuntimeError, subprocess.SubprocessError):
        pass
    if stage.poll() is None:
        stage.kill()
        stage.communicate(timeout=10)
