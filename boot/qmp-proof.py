#!/usr/bin/env python3
import json
import socket
import sys
import time


EX_TEMPFAIL = 75


class QmpCommandRejected(Exception):
    def __init__(self, execute, detail):
        super().__init__(f"{execute}: {detail}")
        self.execute = execute


class QmpOutcomeIndeterminate(Exception):
    def __init__(self, execute):
        super().__init__(execute)
        self.execute = execute


def qmp_read(sock):
    line = b""
    while not line.endswith(b"\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise EOFError("QMP socket closed")
        line += chunk
    return json.loads(line.decode("utf-8"))


def qmp_request(execute, arguments=None):
    payload = {"execute": execute}
    if arguments is not None:
        payload["arguments"] = arguments

    return (json.dumps(payload) + "\n").encode("utf-8")


def qmp_result(sock, execute):
    while True:
        msg = qmp_read(sock)
        if "return" in msg:
            return msg["return"]
        if "error" in msg:
            raise QmpCommandRejected(execute, msg["error"])


def qmp_cmd(sock, execute, arguments=None):
    sock.sendall(qmp_request(execute, arguments))
    return qmp_result(sock, execute)


def qmp_input_event(sock, events):
    execute = "input-send-event"
    request = qmp_request(execute, {"events": events})
    try:
        sock.sendall(request)
    except OSError as error:
        raise QmpOutcomeIndeterminate(execute) from error

    try:
        return qmp_result(sock, execute)
    except QmpCommandRejected:
        raise
    except (EOFError, OSError, UnicodeError, json.JSONDecodeError) as error:
        raise QmpOutcomeIndeterminate(execute) from error


def send_qmp_key(sock, qcode):
    key = {"type": "qcode", "data": qcode}
    qmp_input_event(sock, [{"type": "key", "data": {"key": key, "down": True}}])
    time.sleep(0.04)
    qmp_input_event(sock, [{"type": "key", "data": {"key": key, "down": False}}])
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


def ready(sock_path):
    with_qmp(sock_path, lambda _sock: None)
    print("laputa-qemu-qmp-ready ok")


def control(sock_path, operation):
    with_qmp(sock_path, lambda sock: qmp_cmd(sock, operation))
    print(f"laputa-qemu-qmp-{operation} ok")


def input_proof(sock_path):
    def run(sock):
        for key in ["l", "a", "p", "u", "t", "a", "ret"]:
            send_qmp_key(sock, key)
        modifier = {"type": "qcode", "data": "ctrl"}
        key = {"type": "qcode", "data": "d"}
        qmp_input_event(sock, [{"type": "key", "data": {"key": modifier, "down": True}}])
        qmp_input_event(sock, [{"type": "key", "data": {"key": key, "down": True}}])
        qmp_input_event(sock, [{"type": "key", "data": {"key": key, "down": False}}])
        qmp_input_event(sock, [{"type": "key", "data": {"key": modifier, "down": False}}])

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

    if mode == "ready":
        if len(argv) != 3:
            raise SystemExit("usage: qmp-proof.py ready SOCKET")
        ready(sock_path)
        return

    if mode in ["stop", "cont"]:
        if len(argv) != 3:
            raise SystemExit(f"usage: qmp-proof.py {mode} SOCKET")
        control(sock_path, mode)
        return

    raise SystemExit(f"unknown qmp proof mode {mode}")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except QmpOutcomeIndeterminate as error:
        print(f"QMP outcome indeterminate after sending {error.execute}", file=sys.stderr)
        raise SystemExit(EX_TEMPFAIL)
    except QmpCommandRejected as error:
        print(f"QMP command rejected: {error}", file=sys.stderr)
        raise SystemExit(1)
