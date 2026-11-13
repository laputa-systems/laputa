import os
import pathlib
import pwd
import socket
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
bin_dir = pathlib.Path(sys.argv[1]).resolve()
server = bin_dir / "oxish-server"
keygen = bin_dir / "oxish-keygen"
scratch = root / ".work/tmp"
scratch.mkdir(parents=True, exist_ok=True)
xsh = os.environ.get("XSH_HOST") or str(root / ".out/host/x86_64/xsh")
account = pwd.getpwuid(os.getuid()).pw_name

if os.getuid() == 0:
    raise SystemExit("oxish_readiness.py needs an unprivileged account: a root account is refused by login mode")

with tempfile.TemporaryDirectory(prefix="oxish-readiness.", dir=scratch) as work:
    work = pathlib.Path(work)
    host_key = work / "host_ed25519_key"
    client_key = work / "client"
    subprocess.run([str(keygen), "-f", str(host_key)], check=True, capture_output=True)
    subprocess.run([str(keygen), "-f", str(client_key)], check=True, capture_output=True)
    accounts = work / "accounts"
    accounts.write_text(f"{account} {(work / 'client.pub').read_text().strip()}\n")
    accounts.chmod(0o600)

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
                XINIT_OXISH_BIND="127.0.0.1",
                XINIT_OXISH_PORT=str(port),
                XINIT_OXISH_HOST_KEY=str(host_key),
                XINIT_OXISH_ACCOUNTS=str(accounts),
            )
            result = subprocess.run(
                [
                    xsh,
                    str(root / "tests/integration/fixtures/oxish-readiness.xsh"),
                    "--",
                    mode,
                    str(server),
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
