#!/usr/bin/env python3
import json
import os
import socket
import sys
from pathlib import Path

args = sys.argv
socket_path = args[args.index("-qmp") + 1].split(",", 1)[0][5:]
root = Path(args[args.index("-kernel") + 1]).parent.parent
if (root / "startup-exit").exists():
    print("qemu: device model missing", file=sys.stderr, flush=True)
    sys.exit(1)
trace = root / "native-events"
(root / "qemu-pid").write_text(str(os.getpid()))
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
    server.bind(socket_path)
    server.listen(8)
    print("LAPUTA_FIXTURE_PROOF_READY", flush=True)
    while True:
        conn, _ = server.accept()
        with conn, conn.makefile("rb") as stream:
            with (root / "connections").open("a") as out:
                out.write("connection\n")
            conn.sendall(b'{"QMP":{}}\n')
            first = json.loads(stream.readline())
            assert first["execute"] == "qmp_capabilities"
            reject_ready = root / "reject-ready"
            if reject_ready.exists():
                reject_ready.unlink()
                conn.sendall(json.dumps({"error": {"class": "GenericError", "desc": "retry ready"}, "id": first["id"]}).encode() + b"\n")
                continue
            conn.sendall(json.dumps({"return": {}, "id": first["id"]}).encode() + b"\n")
            previous_id = first["id"]
            received = []
            for line in stream:
                request = json.loads(line)
                assert request["id"] > previous_id
                previous_id = request["id"]
                if request["execute"] == "input-send-event":
                    events = request["arguments"]["events"]
                    with trace.open("a") as out:
                        out.write(json.dumps(events) + "\n")
                    received.append([(event["data"]["key"]["data"], event["data"]["down"]) for event in events])
                elif request["execute"] == "screendump":
                    filename = request["arguments"]["filename"]
                    with (root / "screenshot-requests").open("a") as out:
                        out.write(filename + "\n")
                    reject = root / "reject-screenshot"
                    if reject.exists():
                        reject.unlink()
                        conn.sendall(json.dumps({"error": {"class": "GenericError", "desc": "retry screenshot"}, "id": request["id"]}).encode() + b"\n")
                        continue
                    pixel = b"\x00\x00\x00" if (root / "reader-exits").exists() else b"\xff\x00\xff"
                    Path(filename).write_bytes(b"P6\n16 1\n255\n" + pixel * 16)
                    if (root / "final-failure").exists():
                        print("QEMU_FATAL after screenshot", file=sys.stderr, flush=True)
                else:
                    raise AssertionError(request)
                if (root / "disconnect-input").exists() and received and received[-1] == [("l", True)]:
                    break
                conn.sendall(json.dumps({"return": {}, "id": request["id"]}).encode() + b"\n")
            if len(received) == 18:
                expected = [[(key, down)] for key in ["l", "a", "p", "u", "t", "a", "ret"] for down in [True, False]]
                expected += [[("ctrl", True)], [("d", True)], [("d", False)], [("ctrl", False)]]
                assert received == expected
                print("LAPUTA_FIXTURE_PROOF_OK", flush=True)
