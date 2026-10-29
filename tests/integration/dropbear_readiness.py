import os
import pathlib
import socket
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
binary = pathlib.Path(sys.argv[1]).resolve()
scratch = root / ".work/tmp"
scratch.mkdir(parents=True, exist_ok=True)

for mode in ("positive", "conflict"):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        if mode == "conflict":
            listener.listen()
        else:
            listener.close()
        env = dict(
            os.environ,
            XSH_MODULE_PATH=str(root),
            TMPDIR=str(scratch),
            XSH_LINUX_REAL="1",
            XSH_UNIX_REAL="1",
            XINIT_DROPBEAR_BIND="127.0.0.1",
            XINIT_DROPBEAR_PORT=str(port),
            XINIT_DROPBEAR_EPHEMERAL="1",
        )
        result = subprocess.run(
            [
                str(root / ".out/host/x86_64/xsh"),
                str(root / "tests/integration/fixtures/dropbear-readiness.xsh"),
                "--",
                mode,
                str(binary),
            ],
            cwd=root,
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        print(result.stdout, end="")
        if result.returncode:
            raise RuntimeError(f"{mode}: {result.stderr}")
