#!/usr/bin/env python3
import json
import socket
import sys
from pathlib import Path

args = sys.argv
socket_path = args[args.index("-qmp") + 1].split(",", 1)[0][5:]
root = Path(args[args.index("-kernel") + 1]).parent.parent
trace = root / "native-events"
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
    server.bind(socket_path)
    server.listen(8)
    print("LAPUTA_VT_SWITCH_AWAY\nLAPUTA_VT_SWITCH_BACK\nLAPUTA_DWL_FOOT_PROOF_READY", flush=True)
    vt_number = 2
    while True:
        conn, _ = server.accept()
        with conn, conn.makefile("rb") as stream:
            conn.sendall(b'{"QMP":{}}\n')
            first = json.loads(stream.readline())
            assert first["execute"] == "qmp_capabilities"
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
                elif request["execute"] == "human-monitor-command":
                    command = request["arguments"]["command-line"]
                    assert command.startswith("screendump ")
                    Path(command[11:]).write_bytes(b"P6\n16 1\n255\n" + b"\xff\x00\xff" * 16)
                else:
                    raise AssertionError(request)
                if (root / "disconnect-input").exists() and received and received[-1] == [("l", True)]:
                    break
                conn.sendall(json.dumps({"return": {}, "id": request["id"]}).encode() + b"\n")
            if len(received) == 2:
                assert received == [
                    [("ctrl", True), ("alt", True), (f"f{vt_number}", True)],
                    [(f"f{vt_number}", False), ("alt", False), ("ctrl", False)],
                ]
                vt_number -= 1
            if len(received) == 18:
                expected = [[(key, down)] for key in ["l", "a", "p", "u", "t", "a", "ret"] for down in [True, False]]
                expected += [[("ctrl", True)], [("d", True)], [("d", False)], [("ctrl", False)]]
                assert received == expected
                print("LAPUTA_DWL_FOOT_PROOF_OK", flush=True)
