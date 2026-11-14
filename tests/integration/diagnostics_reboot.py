import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[2]
scratch = root / ".work/tmp"
scratch.mkdir(parents=True, exist_ok=True)
work = scratch / "diagnostics-reboot"

xsh_root = pathlib.Path(os.environ.get("XSH_ROOT", root.parent / "xsh"))
if not (xsh_root / "core").exists():
    xsh_root = root.parents[2].parent / "xsh"

env = dict(
    os.environ,
    XSH_MODULE_PATH=f"{root}:{xsh_root / 'core'}",
    TMPDIR=str(scratch),
)
binary = pathlib.Path(os.environ.get("LAPUTA_XSH", root / ".out/host/x86_64/xsh"))
image_root = pathlib.Path(
    os.environ.get("LAPUTA_QEMU_OUTPUTS", root / "target/laputa/qemu-maintained")
)
apply_fixture = root / "tests/integration/fixtures/maintained-state-apply.xsh"

outputs = work / "outputs"
state_dir = work / "state"
state_image = outputs / "state.ext4"

BOOT = "LAPUTA_DIAGNOSTICS_BOOT"
PERSISTED = "LAPUTA_DIAGNOSTICS_PERSISTED"
HISTORY = "LAPUTA_DIAGNOSTICS_HISTORY"
DEGRADED = "LAPUTA_DIAGNOSTICS_DEGRADED"
BOUND = "LAPUTA_DIAGNOSTICS_BOUND"
BUNDLE = "LAPUTA_DIAGNOSTICS_BUNDLE"
BUNDLE_FAILED = "LAPUTA_DIAGNOSTICS_BUNDLE_FAILED"
SECRET_ABSENT = "LAPUTA_DIAGNOSTICS_SECRET_ABSENT"
SECRET_PRESENT = "LAPUTA_DIAGNOSTICS_SECRET_PRESENT"
DONE = "LAPUTA_DIAGNOSTICS_SELFTEST_DONE"
FAILED = "LAPUTA_DIAGNOSTICS_FAILED"
SENTINEL = "test-only-diagnostics-reboot-sentinel-2d7a"

MAX_EVENT_LINES = 512
MAX_EVENT_BYTES = 65536
MAX_BUNDLE_BYTES = 262144
MAX_STORE_BYTES = 393216
MAX_BOOT_HISTORY = 20

DRILL = r'''##! Diagnostics reboot drill fixture.
use system.activation
use system.build
use system.qemu
use system.types as types
use profiles.qemu-maintained as maintained

proc receipt(id: Str) -> activation.GenerationReceipt {
  {id, kernel: "boot/vmlinuz", root_digest: bytes.from_text(id).sha256().hex()}
}

proc main(operation: Str, state_text: Str, outputs_text: Str, image_text: Str) [fs, process, env, time, error] {
  let state = Path(state_text)
  let images = Path(image_text)
  let outputs = build.outputs(Path(outputs_text))
  if operation == "setup" {
    let kernel = fp"{images}/current/vmlinuz"
    let disk = fp"{images}/current/disk.img"
    guard kernel.exists()? and disk.exists()? else { fail "maintained image is missing" }
    let admitted_a = activation.activation_publish_image(state, receipt("a"), kernel, disk, activation.ACTIVATION_STATE_FORMAT)?
    let admitted_b = activation.activation_publish_image(state, receipt("b"), kernel, disk, activation.ACTIVATION_STATE_FORMAT)?
    activation.activation_install(state, receipt("a"), {revision: 1, images: [admitted_a, admitted_b]})?
    activation.activation_stage(state, receipt("b"))?
    print "acknowledged"
  } else if operation == "argv" {
    let target = qemu.host_qemu_target()?
    let config = qemu.qemu_config(target)?
    let argv = qemu.boot_command_argv(config, maintained.profile, outputs, types.Test, state)?
    print json.encode({argv})?
  } else if operation == "status" {
    let record = activation.activation_status(state)?
    let pending = if record.pending == null { null } else { record.pending.id }
    print json.encode({current: record.current.id, pending: pending, attempts: record.boot_attempts, serial: record.boot_serial, last: record.last_operation})?
  } else {
    fail "unknown drill operation"
  }
}
'''

SELFTEST = r'''#!/bin/xsh
proc note(text: Str) [fs, error] {
  p"/dev/console".write(text + "\n")
}

proc run_diag(phase: Str) [process, error] {
  match process.run(process.command_argv(
    p"/usr/bin/xsh",
    ["xsh", "/etc/laputa/diagnostics.xsh", "--phase", phase, "--canary", "/etc/laputa/diagnostics-canary"],
    env: {XSH_MODULE_PATH: "/usr/lib/xsh/core"},
    stdout: p"/dev/console",
    stderr: p"/dev/console",
  )) {
    Ok(status) => {
      guard status.ok else { fail f"diagnostics {phase} failed" }
    }
    Err(_) => {
      fail f"diagnostics {phase} did not start"
    }
  }
}

proc main() [fs, process, time, error] {
  p"/dev/console".write("LAPUTA_DIAGNOSTICS_SELFTEST_START\n")
  wait until p"/run/laputa-health.json".exists()? within 90s every 200ms
  p"/dev/console".write("LAPUTA_DIAGNOSTICS_SELFTEST_HEALTH\n")
  time.sleep(2s)?
  run_diag("boot")?
  let cmdline = p"/proc/cmdline".read_text()?
  if "LAPUTA_FAILED_GENERATION=" in cmdline {
    let filled = process.run(process.command_argv(p"/usr/bin/xsh", ["xsh", "/etc/laputa/diagnostics-fill.xsh", "fill"]))?
    guard filled.ok else { fail "disk fill failed" }
    run_diag("full")?
    let cleaned = process.run(process.command_argv(p"/usr/bin/xsh", ["xsh", "/etc/laputa/diagnostics-fill.xsh", "clean"]))?
    guard cleaned.ok else { fail "disk clean failed" }
    run_diag("recovered")?
  }
  p"/dev/console".write("LAPUTA_DIAGNOSTICS_SELFTEST_DONE\n")
}
'''

HOOK = r'''#!/bin/xsh
proc main() [process, error] -> Result[Unit, Error] {
  let _ = process.spawn(process.command_argv(
    p"/usr/bin/xsh",
    ["xsh", "/etc/laputa/diagnostics-selftest.xsh"],
    stdin: p"/dev/null",
    stdout: p"/dev/console",
    stderr: p"/dev/console",
    detach: true,
  ))?
  Ok()
}
'''

FILL = r'''#!/bin/xsh
proc fill() [fs, error] {
  let directory = p"/var/log/fill"
  directory.remove()
  directory.mkdir()
  let block = bytes.zero(1048576)?
  var index = 0
  while index < 4096 {
    match fp"{directory}/chunk-{index}".write(block) {
      Ok(_) => { index += 1 }
      Err(problem) => {
        guard problem.errno == 28 else { fail problem.message }
        break
      }
    }
  }
  let _ = fs.fsync(directory)
  p"/dev/console".write(f"LAPUTA_DIAGNOSTICS_FILL_OK files={index}\n")
}

proc clean() [fs, error] {
  p"/var/log/fill".remove()
  p"/dev/console".write("LAPUTA_DIAGNOSTICS_FILL_CLEAN\n")
}

proc main(operation: Str) [fs, error] {
  if operation == "fill" {
    fill()?
  } else if operation == "clean" {
    clean()?
  } else {
    fail "unknown operation"
  }
}
'''


def run_xsh(*args, timeout=600):
    result = subprocess.run(
        [str(binary), *args], env=env, cwd=root,
        capture_output=True, timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return result.stdout.decode()


def drill(*args):
    return run_xsh(str(work / "drill.xsh"), "--", *[str(a) for a in args])


def preflight():
    if not binary.exists():
        raise SystemExit(f"host xsh is missing: {binary} (set LAPUTA_XSH)")
    for name in ("current/vmlinuz", "current/disk.img"):
        if not (image_root / name).exists():
            raise SystemExit(
                f"maintained image is missing {name} under {image_root} "
                "(build qemu-maintained or set LAPUTA_QEMU_OUTPUTS)"
            )


def stage_state(staging):
    for name in ("etc", "home", "var"):
        (staging / name).mkdir(parents=True)
    base_etc = root / "packages/baselayout/files/rootfs/etc"
    for entry in sorted(base_etc.iterdir()):
        if entry.name == "inittab":
            continue
        dest = staging / "etc" / entry.name
        if entry.is_symlink() or entry.is_file():
            subprocess.run(["cp", "-a", str(entry), str(dest)], check=True)
        elif entry.is_dir():
            subprocess.run(["cp", "-a", str(entry), str(staging / "etc")], check=True)
    subprocess.run(
        ["cp", str(root / "profiles/qemu-maintained/etc/inittab"), str(staging / "etc/inittab")],
        check=True,
    )
    subprocess.run(
        ["cp", str(root / "packages/crabtables/nftables.conf"), str(staging / "etc/nftables.conf")],
        check=True,
    )
    (staging / "etc/network").mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["cp", str(root / "packages/laputa-net/interfaces"), str(staging / "etc/network/interfaces")],
        check=True,
    )
    (staging / "var/lib/dhcpc").mkdir(parents=True)
    (staging / "var/lib/dhcpc").chmod(0o700)
    (staging / "var/lib/laputa").mkdir(parents=True, exist_ok=True)
    (staging / "var/log").mkdir(parents=True, exist_ok=True)
    (staging / "format").write_text("laputa-maintained-state-1\n")
    run_xsh(str(apply_fixture), "--", str(staging))

    laputa_etc = staging / "etc/laputa"
    laputa_etc.mkdir(parents=True, exist_ok=True)
    shutil.copy(str(root / "system/diagnostics.xsh"), str(laputa_etc / "diagnostics.xsh"))
    (laputa_etc / "diagnostics-selftest.xsh").write_text(SELFTEST)
    (laputa_etc / "diagnostics-fill.xsh").write_text(FILL)
    hooks = staging / "etc/network/if-up.d"
    hooks.mkdir(parents=True, exist_ok=True)
    (hooks / "diagnostics-selftest").write_text(HOOK)
    (hooks / "diagnostics-selftest").chmod(0o755)
    (laputa_etc / "diagnostics-canary").write_text(SENTINEL + "\n")
    (laputa_etc / "diagnostics-canary").chmod(0o600)
    (staging / "var/log/logger").mkdir(parents=True, exist_ok=True)
    (staging / "var/log/logger/current").write_text(
        f"event=seeded token={SENTINEL} lease=bound\n"
    )


def setup():
    if work.exists():
        shutil.rmtree(work)
    outputs.mkdir(parents=True)
    (outputs / "current").symlink_to(image_root / "current")
    state_dir.mkdir()
    (work / "drill.xsh").write_text(DRILL)
    drill("setup", state_dir, outputs, image_root)
    staging = work / "state-staging"
    stage_state(staging)
    subprocess.run(
        ["unshare", "-Ur", "/sbin/mkfs.ext4", "-q", "-F", "-d", str(staging), str(state_image), "256M"],
        check=True,
    )
    state_image.chmod(0o600)
    shutil.rmtree(staging)


def boot_argv():
    return json.loads(drill("argv", state_dir, outputs, image_root))["argv"]


def launch(argv, console, errlog):
    fixed = list(argv)
    serial = fixed.index("-serial")
    fixed[serial + 1] = f"file:{console}"
    append = fixed.index("-append")
    fixed[append + 1] = " ".join(
        token for token in fixed[append + 1].split(" ")
        if token != "LAPUTA_MAINTAINED_PROOF_FLAG=1"
    )
    try:
        qmp = fixed.index("-qmp")
        socket = fixed[qmp + 1].split("unix:", 1)[1].split(",", 1)[0]
        pathlib.Path(socket).unlink(missing_ok=True)
    except (ValueError, IndexError):
        pass
    console.unlink(missing_ok=True)
    err = open(errlog, "wb")
    child = subprocess.Popen(fixed, stdout=subprocess.DEVNULL, stderr=err, cwd=root)
    return child, err


def wait_for(path, needle, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            text = path.read_text(errors="replace")
            if "Kernel panic" in text:
                raise RuntimeError(f"guest kernel panicked; inspect {path}")
            if needle in text:
                return
        time.sleep(2)
    raise RuntimeError(f"timed out waiting for {needle}; inspect {path}")


def fail_if_bad(console):
    text = console.read_text(errors="replace")
    for marker in ("Kernel panic", "not syncing", FAILED, SECRET_PRESENT):
        if marker in text:
            raise RuntimeError(f"guest proof failed with {marker}; inspect {console}")


def markers(text, prefix):
    joined = []
    for line in text.splitlines():
        if line.startswith(" ") and joined:
            joined[-1] += line
        else:
            joined.append(line)
    found = []
    for line in joined:
        if not line.startswith(prefix + " "):
            continue
        fields = {}
        for token in line[len(prefix) + 1:].split():
            if "=" in token:
                key, value = token.split("=", 1)
                fields[key] = value
        found.append(fields)
    return found


def wait_boot(console, timeout=480):
    wait_for(console, f"{PERSISTED} phase=boot", timeout)
    fail_if_bad(console)
    text = console.read_text(errors="replace")
    boots = markers(text, BOOT)
    persisted = markers(text, PERSISTED)
    assert boots and boots[-1]["phase"] == "boot", boots
    assert persisted and persisted[-1]["phase"] == "boot", persisted
    return boots[-1], persisted[-1]


def stop_kill(guest, err):
    err.close()
    if guest.poll() is None:
        guest.kill()
    try:
        guest.wait(timeout=60)
    except subprocess.TimeoutExpired:
        raise RuntimeError("QEMU did not exit after SIGKILL")


def stop_term(guest, err):
    err.close()
    if guest.poll() is None:
        guest.terminate()
    try:
        guest.wait(timeout=120)
    except subprocess.TimeoutExpired:
        guest.kill()
        guest.wait(timeout=60)
        raise RuntimeError("QEMU did not exit in time")


def force_reboot(attempt):
    console = work / f"console-{attempt}.log"
    guest, err = launch(boot_argv(), console, work / f"console-{attempt}.qemu.log")
    try:
        boot, persisted = wait_boot(console)
        assert boot["generation"] == "b", boot
        assert boot["serial"] == str(attempt), boot
        if attempt == 2:
            assert int(persisted["existing"]) > 0, persisted
        print(f"PASS forced reboot {attempt}: diagnostics persisted before QEMU was killed")
        return persisted
    finally:
        stop_kill(guest, err)


def validate_fallback(console):
    text = console.read_text(errors="replace")
    fail_if_bad(console)
    assert DONE in text, "fallback diagnostics selftest did not finish"
    boots = markers(text, BOOT)
    final = boots[-1]
    assert final["generation"] == "a", final
    assert final["serial"] == "2", final
    assert final["failed"] == "b", final
    assert int(final["boottime_ns"]) > 0 and int(final["wall_ns"]) > 0, final
    for service in ("logger=running", "dhcp-eth0=running", "oxish=running"):
        assert service in final["services"], final
    assert final["markers"] == "3", final

    persisted = markers(text, PERSISTED)[-1]
    assert int(persisted["existing"]) > 0, persisted
    history = markers(text, HISTORY)[-1]
    assert history["markers"] == "3", history
    assert history["failed"] == "b", history
    for entry in ("b/1/", "b/2/", "a/2/b"):
        assert entry in history["entries"], history

    assert markers(text, DEGRADED), "the full-disk collection did not degrade"
    assert "LAPUTA_DIAGNOSTICS_FILL_OK" in text, "disk fill did not reach ENOSPC"
    assert "LAPUTA_DIAGNOSTICS_FILL_CLEAN" in text, "disk cleanup did not run"
    full_failed = [m for m in markers(text, BUNDLE_FAILED) if m.get("phase") == "full"]
    assert full_failed, "the full disk did not fail the bundle build"
    assert int(full_failed[-1]["preserved"]) > 0, full_failed[-1]
    recovered = [m for m in markers(text, BUNDLE) if m.get("phase") == "recovered"]
    assert recovered, "the recovered collection published no bundle"
    assert int(recovered[-1]["bytes"]) > 0, recovered[-1]

    for item in markers(text, BOUND):
        assert item["ok"] in ("1", "true"), item
        assert int(item["bytes"]) <= MAX_STORE_BYTES, item
    for item in markers(text, BUNDLE):
        assert int(item["bytes"]) <= MAX_BUNDLE_BYTES, item
    for phase in ("boot", "recovered"):
        assert any(
            m.get("phase") == phase for m in markers(text, SECRET_ABSENT)
        ), f"no secret-absence proof for {phase}"
    assert "LAPUTA_BOOT_MARKER_COUNT 3" in text, "boot marker history did not accumulate"
    print("PASS fallback: persistent diagnostics name failed generation b with service history")
    print("PASS retention: bounded store held under ENOSPC and recovered")
    print("PASS secrets: the seeded sentinel is absent from the store and bundle")


def main():
    raw = sys.argv[1:]
    if "--help" in raw or "-h" in raw:
        print("usage: diagnostics_reboot.py")
        print("  Kills two pending-generation boots, then proves the fallback boot")
        print("  persists activation history, survives a full state disk, and")
        print("  publishes a redacted bounded support bundle.")
        print("  LAPUTA_XSH and LAPUTA_QEMU_OUTPUTS override the host tools and image.")
        return 0
    preflight()
    setup()
    force_reboot(1)
    force_reboot(2)
    console = work / "console-3.log"
    guest, err = launch(boot_argv(), console, work / "console-3.qemu.log")
    try:
        wait_for(console, DONE, 600)
        validate_fallback(console)
    finally:
        stop_term(guest, err)
    status = json.loads(drill("status", state_dir, outputs, image_root))
    assert status["current"] == "a", status
    assert status["pending"] is None, status
    assert status["attempts"] == 2, status
    assert status["serial"] == 2, status
    assert status["last"] == "fell-back", status
    print(f"PASS activation: {status}")
    print("PASS diagnostics-reboot")
    return 0


if __name__ == "__main__":
    sys.exit(main())
