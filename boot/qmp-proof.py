#!/usr/bin/env python3
import json
import socket
import sys
import time


def qmp_read(sock):
    line = b""
    while not line.endswith(b"\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise EOFError("QMP socket closed")
        line += chunk
    return json.loads(line.decode("utf-8"))


def qmp_cmd(sock, execute, arguments=None):
    payload = {"execute": execute}
    if arguments is not None:
        payload["arguments"] = arguments
    sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
    while True:
        msg = qmp_read(sock)
        if "return" in msg:
            return msg["return"]
        if "error" in msg:
            raise RuntimeError(f"{execute}: {msg['error']}")


def send_qmp_key(sock, qcode):
    key = {"type": "qcode", "data": qcode}
    qmp_cmd(sock, "input-send-event", {"events": [{"type": "key", "data": {"key": key, "down": True}}]})
    time.sleep(0.04)
    qmp_cmd(sock, "input-send-event", {"events": [{"type": "key", "data": {"key": key, "down": False}}]})
    time.sleep(0.04)


def with_qmp(sock_path, callback):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(sock_path)
        qmp_read(sock)
        qmp_cmd(sock, "qmp_capabilities")
        callback(sock)


def screenshot(sock_path, shot):
    def run(sock):
        qmp_cmd(sock, "human-monitor-command", {"command-line": f"screendump {shot}"})

    with_qmp(sock_path, run)
    print("laputa-qemu-qmp-screenshot ok")


def input_proof(sock_path):
    def run(sock):
        for key in ["l", "a", "p", "u", "t", "a", "ret"]:
            send_qmp_key(sock, key)
        modifier = {"type": "qcode", "data": "ctrl"}
        key = {"type": "qcode", "data": "d"}
        qmp_cmd(sock, "input-send-event", {"events": [{"type": "key", "data": {"key": modifier, "down": True}}]})
        qmp_cmd(sock, "input-send-event", {"events": [{"type": "key", "data": {"key": key, "down": True}}]})
        qmp_cmd(sock, "input-send-event", {"events": [{"type": "key", "data": {"key": key, "down": False}}]})
        qmp_cmd(sock, "input-send-event", {"events": [{"type": "key", "data": {"key": modifier, "down": False}}]})

    with_qmp(sock_path, run)
    print("laputa-qemu-qmp-input ok")


def main(argv):
    if len(argv) < 3:
        raise SystemExit("usage: qmp-proof.py MODE SOCKET [OUT]")

    mode = argv[1]
    sock_path = argv[2]

    if mode == "screenshot":
        if len(argv) != 4:
            raise SystemExit("usage: qmp-proof.py screenshot SOCKET OUT")
        screenshot(sock_path, argv[3])
        return

    if mode == "input":
        input_proof(sock_path)
        return

    raise SystemExit(f"unknown qmp proof mode {mode}")


if __name__ == "__main__":
    main(sys.argv)
