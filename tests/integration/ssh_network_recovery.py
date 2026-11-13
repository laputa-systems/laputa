#!/usr/bin/env python3
"""Prove SSH administration of the maintained guest over its declared DHCPv4 lease.

The test owns one unprivileged user+network namespace, one tap, a scripted
DHCPv4 server, and a virtio-serial control agent running as root in the guest.
The guest reaches the address this server declares; the host side is the tap
address inside the same namespace. SSH therefore travels over the network under
test, not a control channel.

After each network disruption the test proves a fresh, host-key-verified native
SSH connection recovers on the declared lease address, and reads the guest's own
lease and IPv6 status over that connection. The IPv6 assertions prove the
packaged policy disables autoconfiguration and that no SLAAC address or IPv6
route survives, and that the service status reports IPv6 explicitly rather than
as a silently empty cohort.

The guest control agent is installed only on the disposable state disk. The
profile and the immutable generation image are unchanged.
"""

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import dhcp_lifecycle as lifecycle

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRATCH_ROOT = ROOT / ".work/tmp"
PROBE_FIXTURE = ROOT / "tests/integration/fixtures/ssh-network-probe.xsh"
DEFAULT_XSH = ROOT / ".out/seed/x86_64/xsh"
DEFAULT_CORE = ROOT / ".out/seed/x86_64/core"
DEFAULT_BUNDLE = ROOT / "target/laputa/qemu-maintained/current"
DEFAULT_ARTIFACT_STORE = ROOT / ".out/artifacts/x86_64/v2/sha256"

OPERATOR = "probe"
DECLARED = lifecycle.LEASE_A
DECLARED_PREFIX = 24
SSH_PORT = 22
DHCPACK = 5

PROVISION_DRIVER = r'''use system.first_boot

proc main(...argv: List[Str]) [fs, error] {
  let root = Path(argv[0])
  let operator = argv[1]
  let hostname = argv[2]
  let key = argv[3]
  let document = f"hostname {hostname}\noperator {operator}\nauthorized-key {key}\nnetwork dhcp\ntailscale no\nidentity restore\n"
  first_boot.apply(root, document)?
  print "applied"
}
main(@args)?
'''


def log(message):
    print(f"[ssh-recovery] {message}", flush=True)


def fail(message):
    raise AssertionError(message)


def find_oxish_keygen(store):
    if store.exists():
        for entry in sorted(store.iterdir()):
            metadata = entry / "artifact.json"
            payload = entry / "payload.tar.gz"
            if not metadata.exists() or not payload.exists():
                continue
            if json.loads(metadata.read_text()).get("package_name") != "oxish":
                continue
            tools = SCRATCH_ROOT / "ssh-recovery-tools"
            tools.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["tar", "xzf", str(payload), "-C", str(tools), "usr/bin/oxish-keygen"],
                check=True, capture_output=True,
            )
            binary = tools / "usr/bin/oxish-keygen"
            binary.chmod(0o755)
            return binary
    return None


def require_prerequisites(args):
    missing = []
    for label, path in (
        ("xsh", args.xsh),
        ("core", args.core),
        ("bundle", args.bundle),
        ("kernel", args.bundle / "vmlinuz"),
        ("disk", args.bundle / "disk.img"),
        ("probe fixture", PROBE_FIXTURE),
        ("agent fixture", lifecycle.AGENT_FIXTURE),
        ("apply fixture", lifecycle.APPLY_FIXTURE),
        ("mkfs.ext4", pathlib.Path("/sbin/mkfs.ext4")),
        ("ssh-keygen", pathlib.Path(shutil.which("ssh-keygen") or "/nonexistent")),
        ("qemu-system-x86_64", pathlib.Path(shutil.which("qemu-system-x86_64") or "/nonexistent")),
        ("unshare", pathlib.Path(shutil.which("unshare") or "/nonexistent")),
        ("kvm", pathlib.Path("/dev/kvm")),
    ):
        if not path.exists():
            missing.append(f"{label}: {path}")
    if os.uname().machine != "x86_64":
        missing.append(f"host architecture {os.uname().machine} is not x86_64")
    if args.oxish_keygen is None or not args.oxish_keygen.exists():
        missing.append("oxish-keygen (pass --oxish-keygen or populate the artifact store)")
    if missing:
        print("SKIP: missing prerequisites:\n  " + "\n  ".join(missing), file=sys.stderr)
        sys.exit(77)


LIFECYCLE_NETNS_ENV = "LAPUTA_SSH_RECOVERY_NETNS"


def reexec_in_user_net_namespace():
    if os.environ.get(LIFECYCLE_NETNS_ENV) == "1":
        return
    unshare = shutil.which("unshare")
    if unshare is None:
        print("SKIP: unshare is required to own the tap without host privileges", file=sys.stderr)
        sys.exit(77)
    os.environ[LIFECYCLE_NETNS_ENV] = "1"
    os.execv(unshare, [unshare, "-Urn", sys.executable, str(pathlib.Path(__file__).resolve()), *sys.argv[1:]])


def run_command(argv, env, timeout=120, check=True):
    result = subprocess.run(argv, env=env, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(str(item) for item in argv)}\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return result


def provision_state(args, scratch):
    work = scratch / "provision"
    work.mkdir(parents=True)
    client_key = work / "client"
    run_command(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "ssh-recovery", "-f", str(client_key)], lifecycle.xsh_env(args.core), timeout=30)

    staging = work / "state-staging"
    for name in ("etc", "home", "var"):
        (staging / name).mkdir(parents=True)
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

    host_key = staging / "etc/oxish/host_ed25519_key"
    host_key.parent.mkdir(parents=True)
    run_command([str(args.oxish_keygen), "-f", str(host_key), "-C", "laputa-host"], lifecycle.xsh_env(args.core), timeout=60)
    fingerprint = run_command([str(args.oxish_keygen), "-l", "-f", str(host_key)], lifecycle.xsh_env(args.core), timeout=60).stdout.split()[1]
    public = client_key.with_suffix(".pub").read_text().strip()

    provision_script = work / "provision.xsh"
    provision_script.write_text(PROVISION_DRIVER)
    hostname = f"laputa-ssh-{os.urandom(3).hex()}"
    run_command(
        [str(args.xsh), str(provision_script), "--", str(staging), OPERATOR, hostname, public],
        lifecycle.xsh_env(args.core), timeout=60,
    )

    lifecycle.install_agent(staging)
    state = work / "state.ext4"
    run_command(
        [
            str(args.xsh), str(ROOT / "system/maintained_state_image.xsh"), "--",
            str(staging), str(state), str(256 * 1024 * 1024),
            str(ROOT / "packages/laputa-fs/files/mkfs.ext4.xsh"), str(args.xsh),
        ],
        lifecycle.xsh_env(args.core), timeout=300,
    )
    state.chmod(0o600)
    shutil.rmtree(staging)
    log(f"provisioned {OPERATOR} on a fresh state disk with host key {fingerprint}")
    return client_key, fingerprint, state


def ssh(args, scratch, host, operation, argument="", connect_ms=6000, check=True):
    argv = [
        str(args.xsh), str(PROBE_FIXTURE), "--",
        host, str(SSH_PORT), str(scratch / "provision/client"), args.probe_pin, operation,
    ]
    if argument != "":
        argv.append(str(argument))
    result = subprocess.run(
        argv, env=lifecycle.xsh_env(args.core), cwd=ROOT, capture_output=True, text=True, timeout=90,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"SSH {operation} to {host} failed ({result.returncode})\n{result.stdout}\n{result.stderr}"
        )
    return result


def expect_ssh(scratch, args, host, operation, needle, timeout, argument=""):
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        result = ssh(args, scratch, host, operation, argument, check=False)
        if result.returncode == 0 and needle in result.stdout:
            return result.stdout
        last = (result.stdout + result.stderr).strip().splitlines()[-1] if (result.stdout + result.stderr).strip() else ""
        time.sleep(1)
    fail(f"SSH {operation} on {host} never returned {needle!r}; last={last!r}")


def expect_ssh_failure(args, scratch, host, operation, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = ssh(args, scratch, host, operation, check=False)
        if result.returncode != 0:
            return True
        time.sleep(1)
    fail(f"SSH {operation} on {host} unexpectedly stayed available")


def assert_leveraged_status(text, label):
    if f"address={DECLARED}/{DECLARED_PREFIX}" not in text:
        fail(f"{label}: the guest status does not name the declared address {DECLARED}/{DECLARED_PREFIX}: {text}")
    if "ipv6=unsupported" not in text:
        fail(f"{label}: the guest status does not report IPv6 as unsupported: {text}")
    if "disabled=1" not in text:
        fail(f"{label}: the guest status does not report the applied IPv6 disable: {text}")
    if "addresses=0" not in text or "routes=0" not in text or "enumerated=1" not in text:
        fail(f"{label}: the guest status does not report a complete, empty IPv6 cohort: {text}")
    if "policy=installed" not in text or "sysctl=1" not in text:
        fail(f"{label}: the guest status does not report the applied policy: {text}")


def assert_ipv6_disabled(agent, label):
    state = agent.request("ipv6")
    if not state["policy"]:
        fail(f"{label}: the packaged IPv6 policy drop-in is absent")
    if state["all_switch"] != "1" or state["default_switch"] != "1":
        fail(f"{label}: IPv6 is not disabled on all/default: {state}")
    if state["accept_ra"] != "0" or state["autoconf"] != "0":
        fail(f"{label}: router advertisements or autoconfiguration are enabled: {state}")
    if state["addresses"] != 0:
        fail(f"{label}: the guest still holds IPv6 addresses: {state}")
    if state["routes"] != 0:
        fail(f"{label}: the guest still holds IPv6 routes: {state}")
    if not state["enumeration"]:
        fail(f"{label}: the network observation was incomplete: {state}")


def run(args):
    require_prerequisites(args)
    SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
    (SCRATCH_ROOT / "tmp").mkdir(parents=True, exist_ok=True)
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="ssh-recovery.", dir=SCRATCH_ROOT))
    log(f"scratch {scratch}")
    server = guest = errlog = qmp = agent = tap_fd = None
    try:
        tap_fd = lifecycle.create_tap(args, lifecycle.TAP, lifecycle.SERVER_IP)
        server = lifecycle.DhcpServer(lifecycle.TAP, lifecycle.SERVER_IP, lifecycle.GUEST_MAC)

        class Script:
            mode = "normal"

            def respond(self, message):
                if self.mode == "silent":
                    return None
                kind = message["kind"]
                if kind == lifecycle.DHCPDISCOVER:
                    return dict({"type": lifecycle.DHCPOFFER, "type_name": "offer", "address": DECLARED}, **lifecycle.CFG_A)
                if kind == lifecycle.DHCPREQUEST:
                    return dict({"type": DHCPACK, "type_name": "ack", "address": DECLARED}, **lifecycle.CFG_A)
                return None

        script = Script()
        server.responder = script.respond
        server.start()

        client_key, fingerprint, state = provision_state(args, scratch)
        args.probe_pin = fingerprint
        console = scratch / "console.log"
        guest, errlog, control, qmp_path = lifecycle.launch(args, scratch, "recovery", state, tap_fd, console)
        os.close(tap_fd)
        tap_fd = None
        log("waiting for the guest control agent")
        lifecycle.wait_console(console, "LAPUTA_DHCP_AGENT_READY", 420, bad=("LAPUTA_DHCP_AGENT_FAILED",))
        agent = lifecycle.Agent(control)
        qmp = lifecycle.Qmp(qmp_path)
        agent.ping()

        observation = lifecycle.wait_until(
            lambda: (lambda item: item if lifecycle.state_of(item) == "bound" else None)(agent.observation()),
            180, "the initial lease",
        )
        ifindex = lifecycle.ifindex_of(observation)
        lifecycle.assert_config(observation, ifindex, DECLARED, lifecycle.SERVER_IP, lifecycle.ROUTE_OLD, "initial")
        log(f"PASS initial lease: {DECLARED}/{DECLARED_PREFIX} from {lifecycle.SERVER_IP}")

        assert_ipv6_disabled(agent, "initial")
        log("PASS IPv6 policy: drop-in installed, autoconfiguration off, no address or route")

        expect_ssh(scratch, args, DECLARED, "probe", "ssh-probe-ok", 180)
        log(f"PASS SSH: verified host key {fingerprint} on the DHCP-assigned address {DECLARED}")

        status = expect_ssh(scratch, args, DECLARED, "status", "dhcp-eth0", 30)
        assert_leveraged_status(status, "initial")
        log(f"PASS status over SSH: {status.splitlines()[-1]}")

        info = ssh(args, scratch, DECLARED, "info")
        if fingerprint not in info.stdout:
            fail(f"SSH info did not report the pinned host key: {info.stdout}")
        log("PASS SSH session reports the pinned host key from the guest side")

        qmp.execute("set_link", {"name": "net0", "up": False})
        down = lifecycle.wait_until(
            lambda: (lambda item: item if lifecycle.state_of(item) in ("no_link", "init", "selecting")
                     or item.get("carrier", "").strip() == "0" else None)(agent.observation()),
            15, "link loss",
        )
        expect_ssh_failure(args, scratch, DECLARED, "probe", 20)
        qmp.execute("set_link", {"name": "net0", "up": True})
        lifecycle.wait_until(
            lambda: (lambda item: item if lifecycle.state_of(item) == "bound"
                     and any(entry["local"] == DECLARED for entry in lifecycle.addresses(item, ifindex)) else None)(agent.observation()),
            40, "the link-up rebind",
        )
        status = expect_ssh(scratch, args, DECLARED, "status", "dhcp-eth0", 120)
        assert_leveraged_status(status, "link loss")
        log(f"PASS link loss: state {lifecycle.state_of(down)} dropped SSH, lease and SSH recovered on {DECLARED}")

        script.mode = "silent"
        expired = lifecycle.wait_until(
            lambda: (lambda item: item if not lifecycle.addresses(item, ifindex) else None)(agent.observation()),
            45, "lease expiry",
        )
        expect_ssh_failure(args, scratch, DECLARED, "probe", 20)
        script.mode = "normal"
        lifecycle.wait_until(
            lambda: (lambda item: item if lifecycle.state_of(item) == "bound"
                     and any(entry["local"] == DECLARED for entry in lifecycle.addresses(item, ifindex)) else None)(agent.observation()),
            40, "re-acquisition after expiry",
        )
        status = expect_ssh(scratch, args, DECLARED, "status", "dhcp-eth0", 120)
        assert_leveraged_status(status, "expiry")
        if lifecycle.addresses(expired, ifindex):
            fail("the expired lease kept its address")
        log(f"PASS expiry and re-acquisition: the declared address was withdrawn, then SSH recovered on {DECLARED}")

        before = lifecycle.service_of(agent.observation())
        killed = agent.request("restart-dhcp")
        if not killed.get("killed"):
            fail("the DHCP daemon was not signalled")
        lifecycle.wait_until(
            lambda: (lambda item: item if lifecycle.service_of(item).get("pid") not in (0, None, before.get("pid"))
                     and lifecycle.state_of(item) == "bound" else None)(agent.observation()),
            40, "the restarted DHCP client",
        )
        status = expect_ssh(scratch, args, DECLARED, "status", "dhcp-eth0", 120)
        assert_leveraged_status(status, "daemon restart")
        log(f"PASS daemon restart: dhcp-eth0 restarted, the saved lease kept {DECLARED}, SSH recovered")

        old_index = lifecycle.ifindex_of(agent.observation())
        agent.request("nic-cycle")
        reappeared = lifecycle.wait_until(
            lambda: (lambda item: item if lifecycle.ifindex_of(item) not in (0, old_index)
                     and lifecycle.state_of(item) == "bound"
                     and any(entry["local"] == DECLARED for entry in lifecycle.addresses(item, lifecycle.ifindex_of(item))) else None)(agent.observation()),
            90, "the re-enumerated NIC lease",
        )
        new_index = lifecycle.ifindex_of(reappeared)
        status = expect_ssh(scratch, args, DECLARED, "status", "dhcp-eth0", 120)
        assert_leveraged_status(status, "NIC reappearance")
        log(f"PASS NIC reappearance: ifindex {old_index} -> {new_index}, SSH recovered on {DECLARED}")

        assert_ipv6_disabled(agent, "steady state")
        log("PASS IPv6 policy unchanged after every disruption")
        print("PASS ssh network recovery: verified SSH on the DHCP address survived link loss, lease expiry, "
              "daemon restart and NIC reappearance, with explicit unsupported IPv6")
    except Exception:
        if agent is not None and server is not None:
            try:
                print("DEBUG observation " + json.dumps(agent.observation(), sort_keys=True)[:4000], flush=True)
                print("DEBUG ipv6 " + json.dumps(agent.request("ipv6"), sort_keys=True), flush=True)
                print("DEBUG server " + json.dumps(server.entries()[-16:], default=str)[:4000], flush=True)
            except Exception as problem:
                print(f"DEBUG unavailable: {problem}", flush=True)
        traceback.print_exc()
        raise
    finally:
        if guest is not None:
            lifecycle.stop_guest(guest, errlog, qmp)
        if server is not None:
            server.close()
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
    parser = argparse.ArgumentParser(description="Prove SSH administration over the maintained guest's DHCP lease.")
    parser.add_argument("--xsh", type=pathlib.Path, default=DEFAULT_XSH)
    parser.add_argument("--core", type=pathlib.Path, default=DEFAULT_CORE)
    parser.add_argument("--bundle", type=pathlib.Path, default=DEFAULT_BUNDLE)
    parser.add_argument("--artifact-store", type=pathlib.Path, default=DEFAULT_ARTIFACT_STORE)
    parser.add_argument("--oxish-keygen", type=pathlib.Path, default=None)
    parser.add_argument("--ip-tool", type=pathlib.Path, help="the XSH ip applet matching --core")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    if args.ip_tool is None:
        candidate = args.core / "ip"
        args.ip_tool = candidate if candidate.exists() else args.core / "ip.xsh"
    if args.oxish_keygen is None:
        args.oxish_keygen = find_oxish_keygen(args.artifact_store)
    args.probe_pin = ""
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
