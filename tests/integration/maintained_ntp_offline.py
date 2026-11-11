#!/usr/bin/env python3
"""Prove ntpd-rs reaches initialization readiness on a maintained guest with no NTS route.

The guest boots the qemu-maintained bundle on a tap that has no DHCP server, so
eth0 carries no address, default route, or resolver and none of the configured
NTS-KE servers can be reached. The state disk mirrors the G2 activation drill's
provisioning, including the service state directory that drill creates. The
daemon must report readiness while unsynchronized (stratum 16) and stay up for
the observation window instead of exiting into the restart policy.
"""

import argparse
import os
import pathlib
import shutil
import sys
import time
import traceback

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import dhcp_lifecycle as dl

ROOT = dl.ROOT
SCRATCH_ROOT = dl.SCRATCH_ROOT
AGENT_FIXTURE = dl.AGENT_FIXTURE
APPLY_FIXTURE = dl.APPLY_FIXTURE
DEFAULT_XSH = dl.DEFAULT_XSH
DEFAULT_CORE = dl.DEFAULT_CORE
DEFAULT_BUNDLE = dl.DEFAULT_BUNDLE
STATE_SIZE = 256 * 1024 * 1024


def reexec_in_user_net_namespace():
    if os.environ.get("LAPUTA_NTP_OFFLINE_NETNS") == "1":
        return
    unshare = shutil.which("unshare")
    if unshare is None:
        print("SKIP: unshare is required to own the tap without host privileges", file=sys.stderr)
        sys.exit(77)
    os.environ["LAPUTA_NTP_OFFLINE_NETNS"] = "1"
    os.execv(unshare, [unshare, "-Urn", sys.executable, str(pathlib.Path(__file__).resolve()), *sys.argv[1:]])


def require_prerequisites(args):
    missing = []
    for name, path in (
        ("xsh", args.xsh),
        ("core", args.core),
        ("bundle", args.bundle),
        ("kernel", args.bundle / "vmlinuz"),
        ("disk", args.bundle / "disk.img"),
        ("state formatter", ROOT / "packages/laputa-fs/files/mkfs.ext4.xsh"),
        ("agent fixture", AGENT_FIXTURE),
        ("apply fixture", APPLY_FIXTURE),
        ("qemu-system-x86_64", pathlib.Path(shutil.which("qemu-system-x86_64") or "/nonexistent")),
        ("kvm", pathlib.Path("/dev/kvm")),
    ):
        if not path.exists():
            missing.append(f"{name}: {path}")
    if os.uname().machine != "x86_64":
        missing.append(f"host architecture {os.uname().machine} is not x86_64")
    if missing:
        print("SKIP: missing prerequisites:\n  " + "\n  ".join(missing), file=sys.stderr)
        sys.exit(77)


def seed_trust_store(staging):
    files = ROOT / "packages/ca-certificates/files"
    generation = staging / "var/lib/laputa/trust/generations/1"
    generation.mkdir(parents=True, exist_ok=True)
    shutil.copy(files / "cacert.pem", generation / "ca-certificates.crt")
    shutil.copy(files / "trust-policy", generation / "trust-policy")
    (generation / "owner").write_text("package-seed\n")
    (staging / "var/lib/laputa/trust/accepted").write_text("1\n")
    (staging / "var/lib/laputa/trust/active").symlink_to("generations/1")
    (staging / "etc/laputa").mkdir(parents=True, exist_ok=True)
    (staging / "etc/laputa/trust-policy").symlink_to("../../var/lib/laputa/trust/active/trust-policy")
    (staging / "etc/ssl/certs").mkdir(parents=True, exist_ok=True)
    (staging / "etc/ssl/cert.pem").symlink_to("certs/ca-certificates.crt")
    (staging / "etc/ssl/certs/ca-certificates.crt").symlink_to("../../../var/lib/laputa/trust/active/ca-certificates.crt")


def provision_state(args, scratch):
    staging = scratch / "state-staging"
    state = scratch / "state.ext4"
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
    for directory, mode in (("var/lib/dhcpc", 0o700), ("var/lib/laputa", 0o755), ("var/log", 0o755)):
        path = staging / directory
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(mode)
    (staging / "format").write_text("laputa-maintained-state-1\n")
    seed_trust_store(staging)
    dl.install_agent(staging)
    dl.run_xsh(args, APPLY_FIXTURE, staging)
    state.unlink(missing_ok=True)
    dl.run_xsh(
        args, ROOT / "system/maintained_state_image.xsh", "--",
        staging, state, str(STATE_SIZE),
        ROOT / "packages/laputa-fs/files/mkfs.ext4.xsh", args.xsh,
        timeout=300,
    )
    state.chmod(0o600)
    shutil.rmtree(staging)
    return state


def ntp_status(agent):
    return agent.request("ntp")


def describe(status):
    service = status.get("service") or {}
    return (
        f"service={service} ctl_exit={status.get('ctl_exit')} "
        f"ctl={status.get('ctl', '').strip()!r} ctl_error={status.get('ctl_error', '').strip()!r}"
    )


def stratum_of(text):
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("Stratum:"):
            return int(line.split(":", 1)[1].strip())
    return None


def wait_ready(agent, timeout):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            status = ntp_status(agent)
        except Exception as problem:
            last = f"error {problem}"
        else:
            last = status
            service = status.get("service") or {}
            if service.get("state") == "running" and service.get("ready") is True and service.get("pid", 0) > 0:
                return status
            if service.get("restarts", 0) >= 2 and service.get("state") != "running":
                raise AssertionError(f"ntpd-rs is restarting instead of ready: {describe(status)}")
        time.sleep(1)
    raise AssertionError(f"ntpd-rs did not become ready: {describe(last) if isinstance(last, dict) else last}")


def stability(agent, window):
    first = wait_ready(agent, 180)
    service = first["service"]
    pid = service["pid"]
    if service.get("restarts", 0) != 0:
        raise AssertionError(f"ntpd-rs restarted before readiness: {describe(first)}")
    if first.get("ctl_exit") != 0:
        raise AssertionError(f"ntp-ctl failed: {describe(first)}")
    if stratum_of(first.get("ctl", "")) != 16:
        raise AssertionError(f"readiness did not precede synchronization: {describe(first)}")
    print(f"PASS ntpd-rs ready: pid={pid} state=running ready=true restarts=0 stratum=16 (unsynchronized)")
    started = time.monotonic()
    deadline = started + window
    samples = 0
    while time.monotonic() < deadline:
        time.sleep(2)
        status = ntp_status(agent)
        current = status.get("service") or {}
        if current.get("state") != "running" or current.get("ready") is not True:
            raise AssertionError(f"ntpd-rs left readiness during the window: {describe(status)}")
        if current.get("pid") != pid or current.get("restarts", 0) != 0:
            raise AssertionError(f"ntpd-rs restarted during the window: {describe(status)}")
        samples += 1
    final = ntp_status(agent)
    if final.get("ctl_exit") != 0 or stratum_of(final.get("ctl", "")) != 16:
        raise AssertionError(f"ntpd-rs did not stay unsynchronized and serving: {describe(final)}")
    print(f"PASS ntpd-rs stayed up for {int(time.monotonic() - started)}s across {samples} samples: pid unchanged, restarts=0, stratum=16")


def run(args):
    require_prerequisites(args)
    SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
    (SCRATCH_ROOT / "tmp").mkdir(parents=True, exist_ok=True)
    scratch = pathlib.Path(__import__("tempfile").mkdtemp(prefix="ntp-offline.", dir=SCRATCH_ROOT))
    dl.log(f"scratch {scratch}")
    guest = errlog = qmp = agent = tap_fd = None
    try:
        tap_fd = dl.create_tap(args, "otap0", "192.0.3.1")
        state = provision_state(args, scratch)
        console = scratch / "offline-console.log"
        guest, errlog, control, qmp_path = dl.launch(args, scratch, "offline", state, tap_fd, console)
        os.close(tap_fd)
        tap_fd = None
        qmp = dl.Qmp(qmp_path)
        dl.wait_console(console, "LAPUTA_DHCP_AGENT_READY", 420, bad=("LAPUTA_DHCP_AGENT_FAILED",))
        agent = dl.Agent(control)
        agent.ping()
        dl.log("guest control agent answered")
        dl.wait_until(
            lambda: (lambda item: item if item.get("health") else None)(agent.observation()),
            300, "guest health",
        )
        try:
            stability(agent, args.window)
        except AssertionError:
            try:
                status = ntp_status(agent)
                print("DEBUG ntp " + describe(status), flush=True)
                print("DEBUG ntpd-rs log:\n" + (status.get("log") or ""), flush=True)
            except Exception as problem:
                print(f"DEBUG unavailable: {problem}", flush=True)
            raise
        print("PASS maintained ntpd-rs offline")
    finally:
        if guest is not None:
            dl.stop_guest(guest, errlog, qmp)
        if agent is not None:
            agent.close()
        if tap_fd is not None:
            os.close(tap_fd)
        if not args.keep:
            shutil.rmtree(scratch, ignore_errors=True)
        else:
            dl.log(f"kept {scratch}")


def main():
    parser = argparse.ArgumentParser(description="Prove ntpd-rs readiness without an NTS route.")
    parser.add_argument("--xsh", type=pathlib.Path, default=DEFAULT_XSH)
    parser.add_argument("--core", type=pathlib.Path, default=DEFAULT_CORE)
    parser.add_argument("--bundle", type=pathlib.Path, default=DEFAULT_BUNDLE)
    parser.add_argument("--ip-tool", type=pathlib.Path)
    parser.add_argument("--window", type=int, default=120, help="seconds to hold readiness")
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
