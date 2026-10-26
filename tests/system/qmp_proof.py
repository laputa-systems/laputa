import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "boot" / "qmp-proof.py"
SCRATCH_ROOT = ROOT / ".work" / "tmp"


def temporary_directory():
    SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(dir=SCRATCH_ROOT)


class QmpProofTests(unittest.TestCase):
    def test_input_disconnect_after_send_is_indeterminate_without_replay(self):
        with temporary_directory() as temp_root:
            socket_path = Path(temp_root) / "qmp.sock"
            received = []
            peer_failures = []

            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(socket_path))
                server.listen(1)
                server.settimeout(5)

                def peer():
                    try:
                        connection, _ = server.accept()
                        with connection:
                            connection.settimeout(5)
                            stream = connection.makefile("rb")
                            connection.sendall(b'{"QMP":{}}\n')
                            capabilities = json.loads(stream.readline())
                            self.assertEqual(capabilities["execute"], "qmp_capabilities")
                            connection.sendall(b'{"return":{}}\n')
                            received.append(json.loads(stream.readline()))
                    except Exception as error:
                        peer_failures.append(error)

                peer_thread = threading.Thread(target=peer)
                peer_thread.start()
                result = subprocess.run(
                    [sys.executable, str(HELPER), "input", str(socket_path)],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env={**os.environ, "TMPDIR": temp_root},
                )
                peer_thread.join(timeout=5)

            self.assertFalse(peer_thread.is_alive())
            self.assertEqual(peer_failures, [])
            self.assertEqual(len(received), 1)
            self.assertEqual(received[0]["execute"], "input-send-event")
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertIn("indeterminate", result.stderr.lower())
            self.assertIn("input-send-event", result.stderr)

    def test_stop_and_cont_dispatch_once_and_skip_events(self):
        with temporary_directory() as temp_root:
            socket_path = Path(temp_root) / "qmp.sock"
            requests = []
            peer_failures = []

            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(socket_path))
                server.listen(2)
                server.settimeout(1)

                def peer():
                    try:
                        for command in ["stop", "cont"]:
                            connection, _ = server.accept()
                            with connection:
                                connection.settimeout(1)
                                with connection.makefile("rb") as stream:
                                    connection.sendall(b'{"QMP":{}}\n')
                                    capabilities = json.loads(stream.readline())
                                    requests.append(capabilities)
                                    connection.sendall(b'{"return":{}}\n')
                                    request = json.loads(stream.readline())
                                    requests.append(request)
                                    connection.sendall(
                                        json.dumps(
                                            {"event": command.upper()}, separators=(",", ":")
                                        ).encode()
                                        + b"\n"
                                        + b'{"return":{}}\n'
                                    )
                    except Exception as error:
                        peer_failures.append(error)

                peer_thread = threading.Thread(target=peer)
                peer_thread.start()
                results = [
                    subprocess.run(
                        [sys.executable, str(HELPER), command, str(socket_path)],
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=5,
                        env={**os.environ, "TMPDIR": temp_root},
                    )
                    for command in ["stop", "cont"]
                ]
                peer_thread.join(timeout=5)

            self.assertFalse(peer_thread.is_alive())
            self.assertEqual(peer_failures, [])
            self.assertEqual(
                [request["execute"] for request in requests],
                [
                    "qmp_capabilities",
                    "stop",
                    "qmp_capabilities",
                    "cont",
                ],
            )
            for result, command in zip(results, ["stop", "cont"]):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"qmp-{command} ok", result.stdout)

    def test_stop_reports_qmp_command_error_without_replay(self):
        with temporary_directory() as temp_root:
            socket_path = Path(temp_root) / "qmp.sock"
            requests = []
            peer_failures = []

            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(socket_path))
                server.listen(1)
                server.settimeout(1)

                def peer():
                    try:
                        connection, _ = server.accept()
                        with connection:
                            connection.settimeout(1)
                            with connection.makefile("rb") as stream:
                                connection.sendall(b'{"QMP":{}}\n')
                                requests.append(json.loads(stream.readline()))
                                connection.sendall(b'{"return":{}}\n')
                                requests.append(json.loads(stream.readline()))
                                connection.sendall(
                                    b'{"error":{"class":"GenericError","desc":"cannot stop"}}\n'
                                )
                    except Exception as error:
                        peer_failures.append(error)

                peer_thread = threading.Thread(target=peer)
                peer_thread.start()
                result = subprocess.run(
                    [sys.executable, str(HELPER), "stop", str(socket_path)],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env={**os.environ, "TMPDIR": temp_root},
                )
                peer_thread.join(timeout=5)

            self.assertFalse(peer_thread.is_alive())
            self.assertEqual(peer_failures, [])
            self.assertEqual(
                [request["execute"] for request in requests],
                ["qmp_capabilities", "stop"],
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot stop", result.stderr)


if __name__ == "__main__":
    unittest.main()
