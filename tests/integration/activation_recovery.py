import contextlib
import os
import pathlib
import signal
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
scratch = root / ".work/tmp"
scratch.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, XSH_MODULE_PATH=str(root), TMPDIR=str(scratch))
fixture = root / "tests/integration/fixtures/activation-recovery.xsh"
binary = root / ".out/host/x86_64/xsh"


def command(operation, state):
    return [str(binary), str(fixture), "--", operation, str(state)]


def run(operation, state, prefix=(), success=True):
    result = subprocess.run(
        [*prefix, *command(operation, state)], env=env, cwd=root,
        capture_output=True, timeout=15,
    )
    if success and result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return result


with tempfile.TemporaryDirectory(prefix="activation-recovery-", dir=scratch) as temporary:
    base = pathlib.Path(temporary)
    for operation in ("b", "select", "confirm"):
        for boundary in (1, 2):
            for fault in ("signal=SIGKILL", "error=ENOSPC"):
                state = base / f"{operation}-{boundary}-{fault}"
                run("prepare", state)
                if operation != "b":
                    run("b", state)
                if operation == "confirm":
                    run("select", state)
                before = (state / "activation.json").read_bytes()
                result = run(
                    operation, state,
                    ("strace", "-f", "-qq", "-e", "trace=fsync", "-e",
                     f"inject=fsync:{fault}:when={boundary}"), success=False,
                )
                assert result.returncode != 0, (operation, boundary, fault)
                if fault == "signal=SIGKILL":
                    assert result.returncode == -signal.SIGKILL, result.stderr
                run("status", state)
                after = (state / "activation.json").read_bytes()
                assert (after == before) == (boundary == 1)
                if boundary == 1:
                    run(operation, state)
                else:
                    assert run(operation, state, success=False).returncode != 0 or operation == "select"
                run("status", state)
                print(f"PASS {operation} fsync {boundary}: {fault}, record and writer recovered")

    for operations in (("b", "c"), ("b", "collect")):
        state = base / "-".join(operations)
        run("prepare", state)
        with contextlib.ExitStack() as stack:
            writers = [stack.enter_context(subprocess.Popen(
                command(candidate, state), env=env, cwd=root,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )) for candidate in operations]
            try:
                for writer in writers:
                    writer.communicate(timeout=15)
                successes = sum(writer.returncode == 0 for writer in writers)
                if operations == ("b", "c"):
                    assert successes == 1
                else:
                    assert successes >= 1
            finally:
                for writer in writers:
                    if writer.poll() is None:
                        writer.kill()
                    writer.wait()
        run("status", state)
        print(f"PASS concurrent {operations}: retained images satisfy the record")
