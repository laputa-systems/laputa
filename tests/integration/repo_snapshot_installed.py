import base64
import hashlib
import json
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import maintained_guest as guest

root = guest.root
outputs = guest.outputs
work = root / ".work/repo-snapshot-installed"
mirror_binary = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / "mirror/target/debug/laputa-mirror"
publish_fixture = root / "tests/integration/fixtures/repo-snapshot-publish.xsh"
OK = "LAPUTA_REPO_INSTALLED_OK"
FAILED = "LAPUTA_REPO_INSTALLED_FAILED"
LIFETIME = 30 * 24 * 3600


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def http(method, url, data=None):
    argv = ["curl", "-sS", "--fail", "-X", method, url]
    if data is not None:
        argv += ["--data-binary", f"@{data}"]
    return subprocess.run(argv, check=True, capture_output=True).stdout


def index_rows(version):
    zeros = "0" * 64
    ones = "1" * 64
    return json.dumps([{
        "arch": "x86_64", "name": "zlib", "ver": version, "rel": "1", "deps": [],
        "mkdeps_host": [], "mkdeps_target": [], "sha256": zeros, "size": 7,
        "tarball": "packages/x86_64/zlib/zlib-%s-1-0123456789ab.tar.gz" % version,
        "metadata": "metadata/x86_64/zlib/zlib-%s-1-0123456789ab-fedcba987654.json" % version,
        "metadata_sha256": ones, "source_sha256": "", "metapackage": False,
        "artifact_key": "0123456789abcdef" * 4, "proof_key": "fedcba9876543210" * 4,
        "proof": "proofs/x86_64/zlib/zlib-%s-1-0123456789ab-fedcba987654.json" % version,
        "proof_receipt_sha256": ones,
    }])


class Repository:
    def __init__(self):
        self.data = work / "mirror-data"
        self.data.mkdir(parents=True)
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.key = work / "signing.private"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(self.key)], check=True, capture_output=True)
        der = subprocess.run(["openssl", "pkey", "-in", str(self.key), "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
        self.public = der[-32:]
        self.key_file = work / "repo-snapshot-keys"
        self.key_file.write_bytes(self.public)
        self.process = subprocess.Popen(
            [str(mirror_binary), "--local", str(self.data), "--listen", f"127.0.0.1:{self.port}"],
            stdout=subprocess.DEVNULL, stderr=open(work / "mirror.log", "wb"),
        )
        for _ in range(50):
            try:
                http("GET", f"{self.url}/health")
                break
            except subprocess.CalledProcessError:
                time.sleep(0.2)
        else:
            raise RuntimeError("mirror did not start")

    def stop(self):
        self.process.send_signal(signal.SIGTERM)
        self.process.wait(timeout=30)

    def put_index(self, version):
        body = work / f"index-{version}.json"
        body.write_text(index_rows(version))
        http("PUT", f"{self.url}/index.json", body)
        served = http("GET", f"{self.url}/index.json")
        return hashlib.sha256(served).hexdigest()

    def snapshot_dir(self, generation, digest):
        directory = work / f"snapshot-{generation}"
        directory.mkdir(parents=True, exist_ok=True)
        now = int(time.time())
        text = (f"laputa-repo-snapshot-v2\ngeneration {generation}\nissued-at {now - 600}\n"
                f"expires-at {now - 600 + LIFETIME}\nindex-sha256 {digest}\n")
        (directory / "snapshot.json").write_text(text)
        subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(self.key), "-rawin",
                        "-in", str(directory / "snapshot.json"), "-out", str(directory / "snapshot.sig")],
                       check=True, capture_output=True)
        return directory

    def publish(self, generation, digest):
        directory = self.snapshot_dir(generation, digest)
        guest.run_xsh(str(publish_fixture), "--", self.url, str(directory), str(self.key_file), str(work / "publish-work"))
        return directory


def boot(repository, expect, serial):
    argv = guest.boot_argv(False)
    argv[argv.index("-append") + 1] = " ".join(
        token for token in argv[argv.index("-append") + 1].split(" ") if token != "LAPUTA_MAINTAINED_PROOF_FLAG=1")
    qemu_port_url = f"http://10.0.2.2:{repository.port}"
    extra = (f" LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL={serial} XSH_MODULE_PATH=/usr/lib/pm"
             f" LAPUTA_REPO_DRILL={expect} LAPUTA_REPO_URL={qemu_port_url}")
    console = outputs / f"repo-installed-{serial}.log"
    child, err = guest.launch(argv, console, outputs / f"repo-installed-{serial}.qemu.log", extra)
    try:
        deadline = time.time() + 300
        while time.time() < deadline:
            text = console.read_text(errors="replace") if console.exists() else ""
            if FAILED in text:
                raise RuntimeError(f"installed fetch failed: {text[text.index(FAILED):][:300]}")
            if f"{OK} {expect}" in text:
                break
            if "Kernel panic" in text:
                raise RuntimeError(f"guest kernel panicked; inspect {console}")
            time.sleep(1)
        else:
            raise RuntimeError(f"timed out waiting for {expect}; inspect {console}")
        guest.wait_exit(child, 60)
    finally:
        err.close()
        if child.poll() is None:
            child.send_signal(signal.SIGKILL)
            child.wait(timeout=60)
    print(f"PASS installed guest: {expect}")


def main():
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    repository = Repository()
    try:
        digest_one = repository.put_index("1")
        gen1 = repository.publish(1, digest_one)
        key_b64 = base64.b64encode(repository.public).decode()
        shutil.rmtree(guest.state_image, ignore_errors=True)
        guest.state_image.unlink(missing_ok=True)
        guest.ensure_state_image(apply_args=(key_b64,))
        boot(repository, "accept-1", 1)
        digest_two = repository.put_index("2")
        boot(repository, "accept-1", 2)
        repository.publish(2, digest_two)
        boot(repository, "accept-2", 3)
        signed_index = repository.data / "indexes" / f"{digest_two}.json"
        original = signed_index.read_bytes()
        signed_index.write_bytes(original.replace(b'"size": 7', b'"size": 8'))
        boot(repository, "reject-tamper", 4)
        signed_index.write_bytes(original)
        shutil.copy(gen1 / "snapshot.json", repository.data / "snapshot.json")
        shutil.copy(gen1 / "snapshot.sig", repository.data / "snapshot.sig")
        boot(repository, "reject-rollback", 5)
    finally:
        repository.stop()


if __name__ == "__main__":
    main()
