import json
import os
import signal
import socket
import subprocess
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[2]
XSH = os.environ["XSH"]


class QmpClientTests(unittest.TestCase):
    def exchange(self, peer, kind="readonly"):
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with TemporaryDirectory(dir=scratch) as directory:
            path = Path(directory) / "q"
            failures = []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                server.listen(1)
                server.settimeout(3)
                def serve():
                    try:
                        conn, _ = server.accept()
                        with conn, conn.makefile("rb") as stream:
                            conn.settimeout(3)
                            peer(conn, stream)
                    except Exception as error:
                        failures.append(error)
                thread = threading.Thread(target=serve)
                self.client = subprocess.Popen(
                    [XSH, str(ROOT / "tests/system/fixtures/qmp-client.xsh"), str(path), kind],
                    env={**os.environ, "XSH_MODULE_PATH": str(ROOT), "XSH_LINUX_REAL": "1", "XSH_UNIX_REAL": "1"},
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )
                thread.start()
                try:
                    stdout, stderr = self.client.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    self.client.kill()
                    self.client.communicate()
                    raise
                result = subprocess.CompletedProcess(self.client.args, self.client.returncode, stdout, stderr)
                thread.join(4)
            self.assertFalse(thread.is_alive())
            self.assertEqual(failures, [])
            return result

    def negotiate(self, conn, stream):
        conn.sendall(b'{"QM')
        conn.sendall(b'P":{}}\r\n')
        capability = json.loads(stream.readline())
        self.assertEqual(capability["execute"], "qmp_capabilities")
        conn.sendall(json.dumps({"return": {}, "id": capability["id"]}).encode() + b'\n')
        request = json.loads(stream.readline())
        self.assertEqual(request["execute"], "query-status")
        self.assertNotEqual(request["id"], capability["id"])
        return request

    def test_fragmented_greeting_and_coalesced_event_and_response(self):
        def peer(conn, stream):
            request = self.negotiate(conn, stream)
            conn.sendall(b'{"event":"STOP"}\r\n' + json.dumps({"return": {}, "id": request["id"]}).encode() + b'\r\n')
        result = self.exchange(peer)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ok", result.stdout)

    def test_buffered_event_flood_cannot_outlive_session_deadline(self):
        def peer(conn, stream):
            request = self.negotiate(conn, stream)
            threading.Event().wait(0.02)
            os.kill(self.client.pid, signal.SIGSTOP)
            try:
                conn.sendall(b'{"event":"X"}\n' * 100 + json.dumps({"return": {}, "id": request["id"]}).encode() + b'\n')
                threading.Event().wait(0.25)
            finally:
                os.kill(self.client.pid, signal.SIGCONT)
        result = self.exchange(peer, "flood")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deadline expired", result.stderr)

    def test_multiple_commands_share_connection_and_use_unique_ids(self):
        def peer(conn, stream):
            first = self.negotiate(conn, stream)
            conn.sendall(json.dumps({"return": {}, "id": first["id"]}).encode() + b'\n')
            second = json.loads(stream.readline())
            self.assertEqual(second["execute"], "query-name")
            self.assertNotEqual(second["id"], first["id"])
            conn.sendall(json.dumps({"return": {}, "id": second["id"]}).encode() + b'\n')
        result = self.exchange(peer, "multi")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejected_command_is_not_indeterminate(self):
        def peer(conn, stream):
            request = self.negotiate(conn, stream)
            conn.sendall(json.dumps({"error": {"class": "GenericError", "desc": "no"}, "id": request["id"]}).encode() + b'\n')
        result = self.exchange(peer, "mutation")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Rejected", result.stderr)
        self.assertNotIn("Indeterminate", result.stderr)

    def test_lost_mutation_reply_is_indeterminate(self):
        def peer(conn, stream):
            self.negotiate(conn, stream)
        result = self.exchange(peer, "mutation")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Indeterminate", result.stderr)

    def test_disconnect_at_mutation_send_is_indeterminate(self):
        def peer(conn, stream):
            conn.sendall(b'{"QMP":{}}\n')
            capability = json.loads(stream.readline())
            conn.sendall(json.dumps({"return": {}, "id": capability["id"]}).encode() + b'\n')
            conn.shutdown(socket.SHUT_RDWR)
        result = self.exchange(peer, "mutation")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Indeterminate", result.stderr)

    def test_wrong_response_id_is_rejected(self):
        def peer(conn, stream):
            request = self.negotiate(conn, stream)
            conn.sendall(json.dumps({"return": {}, "id": request["id"] + 1}).encode() + b'\n')
        result = self.exchange(peer)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected QMP response id", result.stderr)

    def test_frame_limit_is_enforced(self):
        def peer(conn, stream):
            try:
                conn.sendall(b"x" * (1048576 + 4096))
            except BrokenPipeError:
                pass
        result = self.exchange(peer)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("frame exceeds", result.stderr)

    def test_silent_peer_times_out_and_connection_closes(self):
        def peer(conn, stream):
            self.assertEqual(stream.read(1), b"")
        result = self.exchange(peer)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out", result.stderr)

    def test_partial_greeting_eof_fails(self):
        def peer(conn, stream):
            conn.sendall(b'{"QMP":')
        result = self.exchange(peer)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("QMP socket", result.stderr)

    def test_invalid_greeting_fails_before_request(self):
        def peer(conn, stream):
            conn.sendall(b'{"other":{}}\n')
            self.assertEqual(stream.readline(), b"")
        result = self.exchange(peer)
        self.assertNotEqual(result.returncode, 0)

    def test_eof_before_greeting_fails(self):
        result = self.exchange(lambda conn, stream: None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("QMP socket", result.stderr)


if __name__ == "__main__":
    unittest.main()
