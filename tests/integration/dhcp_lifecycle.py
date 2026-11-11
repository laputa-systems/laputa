#!/usr/bin/env python3
"""Drive the maintained qemu-maintained guest through the IPv4 DHCP lifecycle.

The test owns one unprivileged user+network namespace, one tap, a scripted
DHCPv4/DNS server, and a virtio-serial control agent running as root in the
guest. It never uses the network under test for control, so lease expiry and
link loss cannot remove the test channel.

The guest agent is installed only on the disposable state disk. The profile and
the immutable generation image are unchanged.
"""

import argparse
import fcntl
import json
import os
import pathlib
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRATCH_ROOT = ROOT / ".work/tmp"
AGENT_FIXTURE = ROOT / "tests/integration/fixtures/dhcp_lifecycle_agent.xsh"
APPLY_FIXTURE = ROOT / "tests/integration/fixtures/maintained-state-apply.xsh"
DEFAULT_XSH = ROOT / ".out/seed/x86_64/xsh"
DEFAULT_CORE = ROOT / ".out/seed/x86_64/core"
DEFAULT_BUNDLE = ROOT / "target/laputa/qemu-maintained/current"

ETH = "eth0"
GUEST_MAC = "02:00:00:00:00:01"
TAP = "ltap0"
SERVER_IP = "192.0.2.1"
DNS_B_IP = "192.0.2.2"
LEASE_A = "192.0.2.100"
LEASE_B = "192.0.2.101"
DNS_NAME = "dhcp-test.laputa"
DNS_A_ANSWER = "192.0.2.71"
DNS_B_ANSWER = "192.0.2.72"
ROUTE_OLD = ("203.0.113.0", 24)
ROUTE_NEW = ("203.0.114.0", 24)
ROUTE_B = ("203.0.115.0", 24)

TUNSETIFF = 0x400454CA
IFF_TAP = 0x0002
IFF_NO_PI = 0x1000
SIOCGIFFLAGS = 0x8913
SIOCSIFFLAGS = 0x8914
SO_BINDTODEVICE = 25
IP_PKTINFO = getattr(socket, "IP_PKTINFO", 8)
BROADCAST_DESTINATIONS = ("255.255.255.255", "192.0.2.255", "0.0.0.0")


def is_broadcast_destination(destination):
    return destination in BROADCAST_DESTINATIONS

DHCPDISCOVER = 1
DHCPOFFER = 2
DHCPREQUEST = 3
DHCPNAK = 6

CMDLINE = (
    "earlyprintk=serial console=ttyS0 ignore_loglevel devtmpfs.mount=1 "
    "root=PARTUUID=33333333-3333-3333-3333-333333333333 rootfstype=ext4 rootwait rootdelay=2 rw "
    "init=/init loglevel=8 XSH_LINUX_REAL=1 XSH_UNIX_REAL=1 "
    "LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL=1"
)


def log(message):
    print(f"[dhcp-lifecycle] {message}", flush=True)


def fail(message):
    raise AssertionError(message)


def require_prerequisites(args):
    missing = []
    for name, path in (
        ("xsh", args.xsh),
        ("core", args.core),
        ("bundle", args.bundle),
        ("kernel", args.bundle / "vmlinuz"),
        ("disk", args.bundle / "disk.img"),
        ("agent fixture", AGENT_FIXTURE),
        ("apply fixture", APPLY_FIXTURE),
        ("mkfs.ext4", pathlib.Path("/sbin/mkfs.ext4")),
        ("qemu-system-x86_64", pathlib.Path(shutil.which("qemu-system-x86_64") or "/nonexistent")),
        ("kvm", pathlib.Path("/dev/kvm")),
    ):
        if not path.exists():
            missing.append(f"{name}: {path}")
    if pathlib.Path(sys.executable) and os.uname().machine != "x86_64":
        missing.append(f"host architecture {os.uname().machine} is not x86_64")
    if missing:
        print("SKIP: missing prerequisites:\n  " + "\n  ".join(missing), file=sys.stderr)
        sys.exit(77)


def reexec_in_user_net_namespace():
    if os.environ.get("LAPUTA_DHCP_LIFECYCLE_NETNS") == "1":
        return
    unshare = shutil.which("unshare")
    if unshare is None:
        print("SKIP: unshare is required to own the tap without host privileges", file=sys.stderr)
        sys.exit(77)
    os.environ["LAPUTA_DHCP_LIFECYCLE_NETNS"] = "1"
    os.execv(unshare, [unshare, "-Urn", sys.executable, str(pathlib.Path(__file__).resolve()), *sys.argv[1:]])


def ifreq(name):
    return struct.pack("16s", name.encode()).ljust(40, b"\x00")


def set_link_up(name):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        buf = bytearray(ifreq(name))
        flags = struct.unpack("H", fcntl.ioctl(sock, SIOCGIFFLAGS, bytes(buf))[16:18])[0]
        buf[16:18] = struct.pack("H", flags | 0x1 | 0x40)
        fcntl.ioctl(sock, SIOCSIFFLAGS, bytes(buf))
    finally:
        sock.close()


def xsh_env(core):
    return dict(os.environ, XSH_MODULE_PATH=f"{ROOT}:{core}", LC_ALL="C", TMPDIR=str(SCRATCH_ROOT / "tmp"))


def run_xsh(args, *argv, timeout=120):
    result = subprocess.run(
        [str(args.xsh), *[str(item) for item in argv]],
        env=xsh_env(args.core), cwd=ROOT, capture_output=True, timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace") or result.stdout.decode(errors="replace"))
    return result.stdout.decode()


def create_tap(args, name, address, secondary=None):
    fd = os.open("/dev/net/tun", os.O_RDWR)
    fcntl.ioctl(fd, TUNSETIFF, struct.pack("16sH22s", name.encode(), IFF_TAP | IFF_NO_PI, b""))
    ip_tool = args.ip_tool
    run_xsh(args, ip_tool, "addr", "add", f"{address}/24", "dev", name)
    if secondary is not None:
        run_xsh(args, ip_tool, "addr", "add", f"{secondary}/24", "dev", name)
    set_link_up(name)
    return fd


class DhcpServer(threading.Thread):
    def __init__(self, name, server_ip, guest_mac):
        super().__init__(daemon=True)
        self.server_ip = server_ip
        self.guest_mac = bytes(int(part, 16) for part in guest_mac.split(":"))
        self.log = []
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.responder = None
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, name.encode() + b"\x00")
        self.sock.setsockopt(socket.IPPROTO_IP, IP_PKTINFO, 1)
        self.sock.bind(("0.0.0.0", 67))
        self.sock.settimeout(0.25)

    def record(self, message):
        with self.lock:
            self.log.append(message)

    def entries(self):
        with self.lock:
            return list(self.log)

    def run(self):
        while not self.stop.is_set():
            try:
                data, ancillary, _, source = self.sock.recvmsg(4096, socket.CMSG_SPACE(12))
            except socket.timeout:
                continue
            except OSError:
                break
            message = parse_dhcp(data)
            if message is None or message["chaddr"][:6] != self.guest_mac:
                continue
            message["at"] = time.monotonic()
            message["source"] = source
            message["destination"] = packet_destination(ancillary)
            self.record(message)
            responder = self.responder
            reply = responder(message) if responder else None
            if reply is not None:
                self.send(reply, message)
                message["reply"] = reply["type_name"]

    def send(self, reply, request):
        packet = build_dhcp(reply, request, self.server_ip)
        if reply["type"] == DHCPNAK:
            target = ("255.255.255.255", 68)
        elif is_broadcast_destination(request.get("destination", "")) or request["flags"] & 0x8000 or request["ciaddr"] == "0.0.0.0":
            target = ("255.255.255.255", 68)
        else:
            target = (request["ciaddr"], 68)
        try:
            self.sock.sendto(packet, target)
        except OSError as problem:
            self.record({"kind": "send-error", "at": time.monotonic(), "error": str(problem)})

    def close(self):
        self.stop.set()
        self.sock.close()
        self.join(timeout=5)


class DnsServer(threading.Thread):
    def __init__(self, name, address, answer):
        super().__init__(daemon=True)
        self.answer = answer
        self.queries = []
        self.stop = threading.Event()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, name.encode() + b"\x00")
        self.sock.bind((address, 53))
        self.sock.settimeout(0.25)

    def run(self):
        while not self.stop.is_set():
            try:
                data, source = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                break
            reply = dns_answer(data, self.answer)
            if reply is not None:
                self.queries.append((time.monotonic(), source, self.answer))
                self.sock.sendto(reply, source)

    def close(self):
        self.stop.set()
        self.sock.close()
        self.join(timeout=5)


class Qmp:
    def __init__(self, path, timeout=10):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        deadline = time.monotonic() + timeout
        while True:
            try:
                self.sock.connect(str(path))
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)
        self.file = self.sock.makefile("rwb")
        self.file.readline()
        self.execute("qmp_capabilities")

    def execute(self, name, arguments=None):
        request = {"execute": name}
        if arguments is not None:
            request["arguments"] = arguments
        self.file.write((json.dumps(request) + "\n").encode())
        self.file.flush()
        while True:
            line = self.file.readline()
            if not line:
                raise RuntimeError(f"QMP closed while waiting for {name}")
            reply = json.loads(line)
            if "return" in reply or "error" in reply:
                if "error" in reply:
                    raise RuntimeError(f"QMP rejected {name}: {reply['error']}")
                return reply["return"]

    def close(self):
        try:
            self.file.close()
            self.sock.close()
        except OSError:
            pass


class Agent:
    def __init__(self, path, timeout=60):
        self.lock = threading.Lock()
        self.timeout = timeout
        self.sock = self.connect(path)

    def connect(self, path):
        deadline = time.monotonic() + 240
        while True:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            try:
                sock.connect(str(path))
                self.file = sock.makefile("rwb")
                return sock
            except OSError:
                sock.close()
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"guest control agent did not appear at {path}")
                time.sleep(0.2)

    def request(self, op, **fields):
        payload = dict({"op": op}, **fields)
        with self.lock:
            self.file.write((json.dumps(payload) + "\n").encode())
            self.file.flush()
            line = self.file.readline()
            if not line:
                raise RuntimeError(f"guest control agent closed during {op}")
            reply = json.loads(line)
            if not reply.get("ok"):
                raise RuntimeError(f"guest control agent failed {op}: {reply.get('error')}")
            return reply.get("result", reply.get("observation"))

    def observation(self):
        return self.request("status")

    def ping(self):
        return self.request("ping")

    def close(self):
        try:
            self.file.close()
            self.sock.close()
        except OSError:
            pass


def packet_destination(ancillary):
    for level, kind, payload in ancillary:
        if level == socket.IPPROTO_IP and kind == IP_PKTINFO and len(payload) >= 12:
            return socket.inet_ntoa(payload[8:12])
    return ""


def parse_options(data):
    options = {}
    index = 0
    while index < len(data):
        kind = data[index]
        index += 1
        if kind == 0:
            continue
        if kind == 255:
            break
        if index >= len(data):
            break
        length = data[index]
        index += 1
        options[kind] = data[index:index + length]
        index += length
    return options


def parse_dhcp(data):
    if len(data) < 240 or data[236:240] != b"\x63\x82\x53\x63":
        return None
    op, htype, hlen, hops, xid, secs, flags = struct.unpack("!BBBBIHH", data[:12])
    ciaddr = socket.inet_ntoa(data[12:16])
    yiaddr = socket.inet_ntoa(data[16:20])
    siaddr = socket.inet_ntoa(data[20:24])
    giaddr = socket.inet_ntoa(data[24:28])
    chaddr = data[28:44]
    options = parse_options(data[240:])
    kind = options.get(53, b"\x00")[0]
    requested = socket.inet_ntoa(options[50]) if 50 in options and len(options[50]) == 4 else None
    server = socket.inet_ntoa(options[54]) if 54 in options and len(options[54]) == 4 else None
    return {
        "kind": kind,
        "type_name": {1: "discover", 3: "request", 4: "decline", 7: "release", 8: "inform"}.get(kind, str(kind)),
        "xid": xid,
        "flags": flags,
        "ciaddr": ciaddr,
        "yiaddr": yiaddr,
        "siaddr": siaddr,
        "giaddr": giaddr,
        "chaddr": chaddr,
        "requested_ip": requested,
        "server_id": server,
        "broadcast": bool(flags & 0x8000),
    }


def option(kind, payload):
    if len(payload) > 255:
        raise ValueError("DHCP option too long")
    return bytes([kind, len(payload)]) + payload


def encode_classless(routes):
    payload = b""
    for destination, prefix, gateway in routes:
        payload += bytes([prefix])
        count = (prefix + 7) // 8
        payload += socket.inet_aton(destination)[:count]
        payload += socket.inet_aton(gateway)
    return payload


def build_dhcp(reply, request, server_ip):
    header = struct.pack(
        "!BBBBIHH4s4s4s4s16s", 2, 1, 6, 0, request["xid"], 0, request["flags"],
        socket.inet_aton("0.0.0.0"),
        socket.inet_aton(reply.get("address", "0.0.0.0")),
        socket.inet_aton(server_ip), socket.inet_aton("0.0.0.0"), request["chaddr"],
    )
    options = option(53, bytes([reply["type"]])) + option(54, socket.inet_aton(server_ip))
    if reply["type"] != DHCPNAK:
        options += option(51, struct.pack("!I", reply["lease"]))
        options += option(58, struct.pack("!I", reply["t1"]))
        options += option(59, struct.pack("!I", reply["t2"]))
        options += option(1, socket.inet_aton("255.255.255.0"))
        options += option(28, socket.inet_aton("192.0.2.255"))
        if reply.get("dns"):
            options += option(6, b"".join(socket.inet_aton(item) for item in reply["dns"]))
        if reply.get("routes"):
            options += option(121, encode_classless(reply["routes"]))
    options += b"\xff"
    return header + b"\x00" * 192 + b"\x63\x82\x53\x63" + options


def config(lease, t1, t2, dns, route):
    return {
        "lease": lease, "t1": t1, "t2": t2, "dns": [dns],
        "routes": [("0.0.0.0", 0, SERVER_IP), (route[0], route[1], SERVER_IP)],
    }


CFG_A = config(20, 6, 15, SERVER_IP, ROUTE_OLD)
CFG_A2 = config(20, 6, 15, DNS_B_IP, ROUTE_NEW)
CFG_B = config(10, 4, 8, DNS_B_IP, ROUTE_B)
CFG_LONG = config(60, 20, 50, SERVER_IP, ROUTE_B)


class World:
    def __init__(self, server, dns_a, dns_b):
        self.lock = threading.Lock()
        self.mode = "initial"
        self.hold_until = 0.0
        self.server = server
        self.dns_a = dns_a
        self.dns_b = dns_b
        server.responder = self.respond

    def set_mode(self, mode):
        with self.lock:
            self.mode = mode
            self.hold_until = 0.0
        log(f"server mode {mode}")

    def reply(self, kind, address, cfg):
        if kind == DHCPDISCOVER:
            return dict({"type": DHCPOFFER, "type_name": "offer", "address": address}, **cfg)
        return dict({"type": 5, "type_name": "ack", "address": address}, **cfg)

    def respond(self, message):
        with self.lock:
            mode = self.mode
            kind = message["kind"]
            bound = kind == DHCPREQUEST and message["requested_ip"] is None and message["ciaddr"] != "0.0.0.0"
            renew = bound and not is_broadcast_destination(message.get("destination", ""))
            rebind = bound and is_broadcast_destination(message.get("destination", ""))
            selected = kind == DHCPREQUEST and message["requested_ip"] is not None

            if mode == "initial":
                return self.reply(kind, LEASE_A, CFG_A) if kind in (DHCPDISCOVER, DHCPREQUEST) else None
            if mode == "renew_change":
                if kind == DHCPDISCOVER:
                    return self.reply(kind, LEASE_A, CFG_A2)
                if kind == DHCPREQUEST:
                    self.mode = "steady2"
                    return self.reply(kind, LEASE_A, CFG_A2)
                return None
            if mode == "silent_renew":
                if kind == DHCPREQUEST and renew:
                    return None
                if kind == DHCPREQUEST:
                    self.mode = "steady2"
                    return self.reply(kind, LEASE_A, CFG_A2)
                if kind == DHCPDISCOVER:
                    return self.reply(kind, LEASE_A, CFG_A2)
                return None
            if mode == "steady2":
                if kind in (DHCPDISCOVER, DHCPREQUEST):
                    return self.reply(kind, LEASE_A, CFG_A2)
                return None
            if mode == "nak_renew":
                if kind == DHCPREQUEST:
                    self.mode = "nak_hold"
                    self.hold_until = time.monotonic() + 5.0
                    return {"type": DHCPNAK, "type_name": "nak"}
                return None
            if mode == "nak_hold":
                if kind == DHCPDISCOVER:
                    if time.monotonic() < self.hold_until:
                        return None
                    self.mode = "selecting_b"
                    return self.reply(kind, LEASE_B, CFG_B)
                if kind == DHCPREQUEST and message["requested_ip"] == LEASE_B:
                    self.mode = "steady_b"
                    return self.reply(kind, LEASE_B, CFG_B)
                return None
            if mode == "selecting_b":
                if kind == DHCPREQUEST and message["requested_ip"] == LEASE_B:
                    self.mode = "steady_b"
                    return self.reply(kind, LEASE_B, CFG_B)
                if kind == DHCPDISCOVER:
                    return self.reply(kind, LEASE_B, CFG_B)
                return None
            if mode == "steady_b":
                if kind in (DHCPDISCOVER, DHCPREQUEST):
                    return self.reply(kind, LEASE_B, CFG_B)
                return None
            if mode == "expire":
                return None
            if mode == "normal_long":
                if kind in (DHCPDISCOVER, DHCPREQUEST):
                    self.mode = "steady_long"
                    return self.reply(kind, LEASE_B, CFG_LONG)
                return None
            if mode == "steady_long":
                if kind in (DHCPDISCOVER, DHCPREQUEST):
                    return self.reply(kind, LEASE_B, CFG_LONG)
                return None
            return None


def dns_answer(data, answer):
    if len(data) < 12:
        return None
    ident = data[:2]
    flags = b"\x81\x80"
    question = data[12:]
    question_end = question.find(b"\x00")
    if question_end < 0 or len(question) < question_end + 5:
        return None
    qtype = struct.unpack("!H", question[question_end + 1:question_end + 3])[0]
    query = question[:question_end + 5]
    if qtype != 1:
        answer_body = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 0, 0)
        return ident + flags + b"\x00\x01\x00\x01\x00\x00\x00\x00" + query + answer_body
    body = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 0, 4) + socket.inet_aton(answer)
    return ident + flags + b"\x00\x01\x00\x01\x00\x00\x00\x00" + query + body


def install_agent(staging):
    target = staging / "etc/laputa/dhcp-lifecycle-agent.xsh"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(AGENT_FIXTURE, target)
    target.chmod(0o755)
    hooks = staging / "etc/network/if-up.d"
    hooks.mkdir(parents=True, exist_ok=True)
    hook = hooks / "10-dhcp-lifecycle-agent"
    hook.write_text(
        "#!/usr/bin/xsh\n"
        "let _ = unix.spawn_process_group(process.command_argv(p\"/usr/bin/xsh\", [\"/usr/bin/xsh\", \"/etc/laputa/dhcp-lifecycle-agent.xsh\"]))?\n"
    )
    hook.chmod(0o755)


def provision_state(args, scratch, name):
    staging = scratch / f"{name}-staging"
    state = scratch / f"{name}.ext4"
    shutil.rmtree(staging, ignore_errors=True)
    for directory in ("etc", "home", "var"):
        (staging / directory).mkdir(parents=True)
    base_etc = ROOT / "packages/baselayout/files/rootfs/etc"
    for entry in sorted(base_etc.iterdir()):
        if entry.name == "inittab":
            continue
        if entry.is_dir():
            shutil.copytree(entry, staging / "etc" / entry.name, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy(entry, staging / "etc" / entry.name, follow_symlinks=False)
    shutil.copy(ROOT / "profiles/qemu-maintained/etc/inittab", staging / "etc/inittab")
    shutil.copy(ROOT / "packages/nftables/nftables.conf", staging / "etc/nftables.conf")
    (staging / "etc/network").mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "packages/laputa-net/interfaces", staging / "etc/network/interfaces")
    (staging / "var/lib/dhcpc").mkdir(parents=True)
    (staging / "var/lib/dhcpc").chmod(0o700)
    (staging / "var/lib/laputa").mkdir(parents=True, exist_ok=True)
    (staging / "var/log").mkdir(parents=True, exist_ok=True)
    (staging / "format").write_text("laputa-maintained-state-1\n")
    install_agent(staging)
    run_xsh(args, APPLY_FIXTURE, staging)
    state.unlink(missing_ok=True)
    subprocess.run(
        ["/sbin/mkfs.ext4", "-q", "-F", "-d", str(staging), str(state), "256M"],
        check=True, capture_output=True,
    )
    state.chmod(0o600)
    shutil.rmtree(staging)
    return state


def launch(args, scratch, name, state, tap_fd, console):
    socket_dir = SCRATCH_ROOT / f"dlc{os.getpid()}"
    socket_dir.mkdir(parents=True, exist_ok=True)
    control = socket_dir / f"{name[:1]}c.sock"
    qmp = socket_dir / f"{name[:1]}q.sock"
    for path in (control, qmp):
        path.unlink(missing_ok=True)
    argv = [
        "qemu-system-x86_64", "-M", "q35,accel=kvm", "-cpu", "host", "-smp", "2", "-m", "1536M",
        "-kernel", str(args.bundle / "vmlinuz"), "-append", CMDLINE,
        "-drive", f"if=none,id=root,format=raw,file={args.bundle / 'disk.img'},snapshot=on",
        "-device", "virtio-blk-pci,drive=root",
        "-drive", f"if=none,id=state,format=raw,file={state}",
        "-device", "virtio-blk-pci,drive=state",
        "-netdev", f"tap,id=net0,fd={tap_fd}",
        "-device", f"virtio-net-pci,netdev=net0,mac={GUEST_MAC}",
        "-chardev", f"socket,id=ctl,path={control},server=on,wait=off",
        "-device", "virtio-serial-pci",
        "-device", "virtserialport,chardev=ctl,name=laputa-ctl",
        "-qmp", f"unix:{qmp},server=on,wait=off",
        "-display", "none", "-monitor", "none", "-no-reboot",
        "-serial", f"file:{console}",
    ]
    errlog = open(scratch / f"{name}.qemu.log", "wb")
    child = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=errlog, cwd=ROOT, pass_fds=(tap_fd,))
    return child, errlog, control, qmp


def stop_guest(child, errlog, qmp=None):
    if qmp is not None:
        try:
            qmp.execute("quit")
        except Exception:
            pass
    if child.poll() is None:
        child.send_signal(signal.SIGTERM)
        try:
            child.wait(timeout=15)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    try:
        errlog.close()
    except OSError:
        pass


def panic_guard(console):
    if console.exists() and "Kernel panic" in console.read_text(errors="replace"):
        fail(f"guest kernel panicked; inspect {console}")


def wait_console(console, needle, timeout, bad=()):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if console.exists():
            text = console.read_text(errors="replace")
            if "Kernel panic" in text:
                fail(f"guest kernel panicked; inspect {console}")
            for marker in bad:
                if marker in text:
                    fail(f"guest reported {marker}; inspect {console}")
            if needle in text:
                return text
        time.sleep(0.2)
    fail(f"timed out waiting for {needle} in {console}")


def wait_until(predicate, timeout, what, interval=0.2):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            result = predicate()
        except Exception as problem:
            last = f"error {problem}"
        else:
            last = result
            if result:
                return result
        time.sleep(interval)
    fail(f"timed out waiting for {what}; last={last}")


def ifindex_of(observation):
    value = observation.get("ifindex", "").strip()
    return int(value) if value else 0


def addresses(observation, ifindex):
    return [
        item for item in observation["addresses"]
        if item["ifindex"] == ifindex and item["family"] == "inet" and item["local"]
    ]


def routes(observation, ifindex):
    found = []
    for item in observation["routes"]:
        if item["family"] != "inet":
            continue
        hops = [hop for hop in item["hops"] if hop["ifindex"] == ifindex]
        if item["output_ifindex"] == ifindex or hops:
            found.append(item)
    return found


def route_present(observation, ifindex, destination, prefix):
    for item in routes(observation, ifindex):
        if item["destination"] == destination and item["prefix"] == prefix:
            return True
    return False


def default_count(observation, ifindex):
    return len([item for item in routes(observation, ifindex) if item["prefix"] == 0 and item["destination"] is None])


def nameservers(observation):
    return [line.split()[1] for line in observation["resolv"].splitlines() if line.strip().startswith("nameserver ")]


def state_of(observation):
    return (observation.get("status") or {}).get("state", "none")


def service_of(observation):
    return observation.get("service") or {}


def assert_config(observation, ifindex, address, dns, route, label):
    found = [item for item in addresses(observation, ifindex) if item["local"] == address]
    if not found:
        fail(f"{label}: lease address {address} is absent: {addresses(observation, ifindex)}")
    if len(addresses(observation, ifindex)) != 1:
        fail(f"{label}: expected one IPv4 address, found {addresses(observation, ifindex)}")
    if default_count(observation, ifindex) != 1:
        fail(f"{label}: expected one default route, found {default_count(observation, ifindex)} on {routes(observation, ifindex)}")
    if not route_present(observation, ifindex, route[0], route[1]):
        fail(f"{label}: route {route} is absent: {routes(observation, ifindex)}")
    servers = nameservers(observation)
    if servers != [dns]:
        fail(f"{label}: expected nameserver {dns}, found {servers}")
    if "# Managed by dhcpc" not in observation["resolv"]:
        fail(f"{label}: resolv.conf is not owned by dhcpc")


def sample_while(agent, seconds, interval=0.05):
    samples = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        samples.append(agent.observation())
        time.sleep(interval)
    return samples


def assert_no_duplicates(samples, ifindex, label):
    for sample in samples:
        held = addresses(sample, ifindex)
        if len(held) > 1:
            fail(f"{label}: duplicate addresses {held}")
        if default_count(sample, ifindex) > 1:
            fail(f"{label}: duplicate default routes {routes(sample, ifindex)}")
        servers = nameservers(sample)
        if len(servers) != len(set(servers)):
            fail(f"{label}: duplicate nameservers {servers}")


def run(args):
    require_prerequisites(args)
    SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
    (SCRATCH_ROOT / "tmp").mkdir(parents=True, exist_ok=True)
    scratch = pathlib.Path(__import__("tempfile").mkdtemp(prefix="dhcp-lifecycle.", dir=SCRATCH_ROOT))
    log(f"scratch {scratch}")
    server = dns_a = dns_b = None
    guest = None
    errlog = None
    qmp = None
    agent = None
    tap_fd = None
    offline = None
    offline_errlog = None
    offline_qmp = None
    offline_agent = None
    try:
        tap_fd = create_tap(args, TAP, SERVER_IP, DNS_B_IP)
        server = DhcpServer(TAP, SERVER_IP, GUEST_MAC)
        dns_a = DnsServer(TAP, SERVER_IP, DNS_A_ANSWER)
        dns_b = DnsServer(TAP, DNS_B_IP, DNS_B_ANSWER)
        world = World(server, dns_a, dns_b)
        server.start()
        dns_a.start()
        dns_b.start()

        state = provision_state(args, scratch, "lifecycle-state")
        console = scratch / "lifecycle-console.log"
        guest, errlog, control, qmp_path = launch(args, scratch, "lifecycle", state, tap_fd, console)
        os.close(tap_fd)
        tap_fd = None
        log("waiting for the guest control agent")
        wait_console(console, "LAPUTA_DHCP_AGENT_READY", 420, bad=("LAPUTA_DHCP_AGENT_FAILED",))
        agent = Agent(control)
        qmp = Qmp(qmp_path)
        agent.ping()
        log("guest control agent answered")

        observation = wait_until(
            lambda: (lambda item: item if state_of(item) == "bound" else None)(agent.observation()),
            180, "the initial lease",
        )
        ifindex = ifindex_of(observation)
        assert_config(observation, ifindex, LEASE_A, SERVER_IP, ROUTE_OLD, "initial")
        if service_of(observation).get("state") != "running":
            fail(f"dhcp-eth0 is {service_of(observation)}")
        if not observation["leases"]:
            fail("the client published no lease file")
        resolved = agent.request("resolve", name=DNS_NAME)
        if resolved["exit"] != 0 or DNS_A_ANSWER not in resolved["stdout"]:
            fail(f"initial resolver query failed: {resolved}")
        if not dns_a.queries:
            fail("the guest did not query the controlled resolver")
        log(f"PASS initial bind: {LEASE_A}/24, resolver {DNS_A_ANSWER}, routes {ROUTE_OLD}")

        world.set_mode("renew_change")
        transition = []
        stop_sampling = threading.Event()

        def sample_transition():
            while not stop_sampling.is_set():
                try:
                    transition.append(agent.observation())
                except Exception:
                    pass
                time.sleep(0.05)

        sampler = threading.Thread(target=sample_transition, daemon=True)
        sampler.start()
        try:
            renew = wait_until(
                lambda: next((item for item in server.entries()
                              if item.get("kind") == DHCPREQUEST and item.get("requested_ip") is None
                              and item.get("ciaddr") == LEASE_A and not is_broadcast_destination(item.get("destination", ""))
                              and item.get("reply") == "ack"), None),
                40, "the unicast renewal",
            )
            changed = wait_until(
                lambda: (lambda item: item if nameservers(item) == [DNS_B_IP] and route_present(item, ifindex, ROUTE_NEW[0], ROUTE_NEW[1]) else None)(agent.observation()),
                20, "the renewed resolver and route",
            )
        finally:
            stop_sampling.set()
            sampler.join(timeout=5)
        for sample in transition:
            servers = nameservers(sample)
            if SERVER_IP in servers and DNS_B_IP in servers:
                fail("the resolver owner exposed both nameservers during the renewal")
            if default_count(sample, ifindex) > 1:
                fail("the renewal exposed duplicate default routes")
        if route_present(changed, ifindex, ROUTE_OLD[0], ROUTE_OLD[1]):
            fail("the old route survived the renewal")
        if nameservers(changed) != [DNS_B_IP]:
            fail(f"the resolver did not move: {nameservers(changed)}")
        if default_count(changed, ifindex) != 1:
            fail(f"duplicate default routes after renewal: {routes(changed, ifindex)}")
        resolved = agent.request("resolve", name=DNS_NAME)
        if resolved["exit"] != 0 or DNS_B_ANSWER not in resolved["stdout"]:
            fail(f"renewed resolver query failed: {resolved}")
        if not dns_b.queries:
            fail("the guest did not query the renewed resolver")
        log(f"PASS renewal: DNS {DNS_B_IP} -> {DNS_B_ANSWER}, route {ROUTE_NEW}, old route gone")

        world.set_mode("silent_renew")
        rebind = wait_until(
            lambda: next((item for item in server.entries()
                          if item.get("kind") == DHCPREQUEST and item.get("requested_ip") is None
                          and item.get("ciaddr") == LEASE_A and is_broadcast_destination(item.get("destination", ""))
                          and item.get("reply") == "ack"), None),
            40, "a broadcast rebind",
        )
        rebound = wait_until(lambda: (lambda item: item if state_of(item) == "bound" else None)(agent.observation()), 10, "the rebind")
        assert_config(rebound, ifindex, LEASE_A, DNS_B_IP, ROUTE_NEW, "rebind")
        log("PASS rebind: broadcast request answered, lease and configuration kept")

        world.set_mode("nak_renew")
        nak = wait_until(
            lambda: next((item for item in server.entries() if item.get("reply") == "nak"), None),
            30, "a NAK",
        )
        withdrawn = wait_until(
            lambda: (lambda item: item if not any(entry["local"] == LEASE_A for entry in addresses(item, ifindex))
                     and not route_present(item, ifindex, ROUTE_NEW[0], ROUTE_NEW[1])
                     and DNS_B_IP not in nameservers(item) else None)(agent.observation()),
            12, "the NAK withdrawal",
        )
        if route_present(withdrawn, ifindex, ROUTE_NEW[0], ROUTE_NEW[1]):
            fail("the NAK left an owned route behind")
        if DNS_B_IP in nameservers(withdrawn):
            fail("the NAK left the DHCP resolver contribution behind")
        log("PASS NAK: owned address, route and resolver contribution withdrawn")

        selected = wait_until(
            lambda: (lambda item: item if state_of(item) == "bound" and any(entry["local"] == LEASE_B for entry in addresses(item, ifindex)) else None)(agent.observation()),
            30, "the replacement lease",
        )
        assert_config(selected, ifindex, LEASE_B, DNS_B_IP, ROUTE_B, "replacement")
        if any(entry["local"] == LEASE_A for entry in addresses(selected, ifindex)):
            fail("the replaced address survived the NAK")
        log(f"PASS replacement: {LEASE_B}/24 with {ROUTE_B}, old address absent")

        world.set_mode("expire")
        expired = wait_until(
            lambda: (lambda item: item if not addresses(item, ifindex) else None)(agent.observation()),
            30, "lease expiry",
        )
        if state_of(expired) == "bound":
            fail("the client stayed bound past expiry")
        if route_present(expired, ifindex, ROUTE_B[0], ROUTE_B[1]):
            fail("the expired lease left its route behind")
        if default_count(expired, ifindex) != 0:
            fail("the expired lease left a default route behind")
        if DNS_B_IP in nameservers(expired):
            fail("the expired lease left the DHCP resolver contribution behind")
        log("PASS expiry: owned address, default route and classless route withdrawn")

        world.set_mode("normal_long")
        rebound = wait_until(
            lambda: (lambda item: item if state_of(item) == "bound" and addresses(item, ifindex) else None)(agent.observation()),
            40, "a steady lease",
        )
        assert_config(rebound, ifindex, LEASE_B, SERVER_IP, ROUTE_B, "steady")
        leases_before = list(rebound["leases"])
        pid_before = service_of(rebound).get("pid")
        restarts_before = service_of(rebound).get("restarts", 0)
        restart_mark = time.monotonic()
        killed = agent.request("restart-dhcp")
        if not killed.get("killed"):
            fail("the daemon was not signalled")
        saved = wait_until(
            lambda: next((item for item in server.entries()
                          if item.get("at", 0) >= restart_mark and item.get("kind") == DHCPREQUEST
                          and item.get("requested_ip") == LEASE_B and item.get("server_id") is None
                          and item.get("reply") == "ack"), None),
            30, "a saved-lease request",
        )
        after_restart = wait_until(
            lambda: (lambda item: item if state_of(item) == "bound" and service_of(item).get("pid") not in (0, None, pid_before) else None)(agent.observation()),
            30, "the restarted client",
        )
        if service_of(after_restart).get("restarts", 0) <= restarts_before:
            fail("xinit did not record a restart")
        if list(after_restart["leases"]) != leases_before:
            fail(f"the saved lease changed: {leases_before} -> {after_restart['leases']}")
        assert_config(after_restart, ifindex, LEASE_B, SERVER_IP, ROUTE_B, "restart")
        log("PASS daemon restart: INIT-REBOOT used the saved lease and the address did not change")

        qmp.execute("set_link", {"name": "net0", "up": False})
        no_link = wait_until(
            lambda: (lambda item: item if state_of(item) in ("no_link", "init", "selecting") or item.get("carrier", "").strip() == "0" else None)(agent.observation()),
            15, "link loss",
        )
        qmp.execute("set_link", {"name": "net0", "up": True})
        relinked = wait_until(
            lambda: (lambda item: item if state_of(item) == "bound" and any(entry["local"] == LEASE_B for entry in addresses(item, ifindex)) else None)(agent.observation()),
            40, "the link-up rebind",
        )
        assert_config(relinked, ifindex, LEASE_B, SERVER_IP, ROUTE_B, "link up")
        log(f"PASS link loss: state {state_of(no_link)} -> bound {LEASE_B}")

        old_index = ifindex_of(relinked)
        cycle = agent.request("nic-cycle")
        reappeared = wait_until(
            lambda: (lambda item: item if ifindex_of(item) not in (0, old_index) and state_of(item) == "bound" and any(entry["local"] == LEASE_B for entry in addresses(item, ifindex_of(item))) else None)(agent.observation()),
            60, "the re-enumerated NIC lease",
        )
        new_index = ifindex_of(reappeared)
        assert_config(reappeared, new_index, LEASE_B, SERVER_IP, ROUTE_B, "NIC reappearance")
        log(f"PASS NIC reappearance: ifindex {old_index} -> {new_index}, lease {LEASE_B} rebuilt")

        ifindex = new_index
        pause_start = time.monotonic()
        qmp.execute("stop")
        time.sleep(5)
        qmp.execute("cont")
        time.sleep(2)
        resumed = agent.observation()
        if state_of(resumed) != "bound":
            fail(f"the lease was not bound after pause/resume: {state_of(resumed)}")
        if not any(entry["local"] == LEASE_B for entry in addresses(resumed, ifindex)):
            fail("the address disappeared across pause/resume")
        during = [item for item in server.entries() if pause_start <= item.get("at", 0) <= time.monotonic()]
        if any(item.get("kind") == DHCPDISCOVER for item in during):
            fail("the client restarted discovery across pause/resume")
        log("PASS pause/resume: the lease stayed bound with no fresh discovery")

        samples = sample_while(agent, 2.0)
        assert_no_duplicates(samples, ifindex, "steady state")
        log("PASS no duplicate or stale configuration in the steady-state sample")
        print("PASS dhcp lifecycle: renew, rebind, NAK, expiry, restart, link loss, NIC reappearance, pause/resume")

        stop_guest(guest, errlog, qmp)
        guest = None
        errlog = None
        qmp = None
        agent.close()
        agent = None
        server.close()
        server = None
        dns_a.close()
        dns_a = None
        dns_b.close()
        dns_b = None

        offline_tap = create_tap(args, "otap0", "192.0.3.1")
        offline_state = provision_state(args, scratch, "offline-state")
        offline_console = scratch / "offline-console.log"
        offline, offline_errlog, offline_control, offline_qmp_path = launch(args, scratch, "offline", offline_state, offline_tap, offline_console)
        os.close(offline_tap)
        offline_qmp = Qmp(offline_qmp_path)
        offline_agent = Agent(offline_control)
        offline_agent.ping()
        offline_wait = wait_until(
            lambda: (lambda item: item if service_of(item).get("state") == "running" and item.get("health") else None)(offline_agent.observation()),
            300, "offline service readiness and health",
        )
        if state_of(offline_wait) == "bound":
            fail("the offline guest acquired a lease")
        if service_of(offline_wait).get("ready") is not True:
            fail(f"dhcp-eth0 was not armed offline: {service_of(offline_wait)}")
        if addresses(offline_wait, ifindex_of(offline_wait)):
            fail("the offline guest configured an address")
        health = offline_wait.get("health") or {}
        if health.get("format") != "laputa-guest-health-1":
            fail(f"the health report is malformed: {offline_wait.get('health')}")
        service_states = {item["name"]: item["state"] for item in health.get("services", [])}
        for required in ("logger", "dropbear", "dhcp-eth0"):
            if service_states.get(required) != "running":
                fail(f"offline service {required} is {service_states.get(required)}: {service_states}")
        panic_guard(offline_console)
        log("PASS offline boot: services running, dhcp-eth0 armed without a lease, health reported")
        print("PASS offline boot: the maintained guest boots and stays locally administrable without DHCP")

        stop_guest(offline, offline_errlog, offline_qmp)
        offline_agent.close()
        offline = None
        offline_errlog = None
        offline_qmp = None
        offline_agent = None
    except Exception:
        if agent is not None and server is not None:
            try:
                print("DEBUG observation " + json.dumps(agent.observation(), sort_keys=True)[:4000], flush=True)
                print("DEBUG server " + json.dumps(server.entries()[-16:], default=str)[:4000], flush=True)
                print("DEBUG service log " + agent.request("log")[-6000:], flush=True)
            except Exception as problem:
                print(f"DEBUG unavailable: {problem}", flush=True)
        raise
    finally:
        if offline is not None:
            stop_guest(offline, offline_errlog, offline_qmp)
        if offline_agent is not None:
            offline_agent.close()
        if guest is not None:
            stop_guest(guest, errlog, qmp)
        for item in (server, dns_a, dns_b):
            if item is not None:
                item.close()
        if agent is not None:
            agent.close()
        if tap_fd is not None:
            os.close(tap_fd)
        shutil.rmtree(SCRATCH_ROOT / f"dlc{os.getpid()}", ignore_errors=True)
        if args.keep:
            log(f"kept {scratch}")
        else:
            shutil.rmtree(scratch, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="Prove the maintained guest's IPv4 DHCP lifecycle.")
    parser.add_argument("--xsh", type=pathlib.Path, default=DEFAULT_XSH)
    parser.add_argument("--core", type=pathlib.Path, default=DEFAULT_CORE)
    parser.add_argument("--bundle", type=pathlib.Path, default=DEFAULT_BUNDLE)
    parser.add_argument("--ip-tool", type=pathlib.Path, help="the XSH ip applet matching --core")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    if args.ip_tool is None:
        candidate = args.core / "ip"
        args.ip_tool = candidate if candidate.exists() else args.core / "ip.xsh"
    reexec_in_user_net_namespace()
    try:
        run(args)
    except AssertionError as problem:
        print(f"FAIL: {problem}", file=sys.stderr)
        return 1
    except Exception as problem:
        traceback.print_exc()
        print(f"ERROR: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
