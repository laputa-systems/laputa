import pathlib
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import maintained_guest as guest

outputs = guest.outputs
OK = "LAPUTA_NTP_DRILL_OK"
FAILED = "LAPUTA_NTP_DRILL_FAILED"
PHASES = [("sync", 1, 600), ("offline", 2, 600)]


def boot(phase, serial, timeout):
    argv = guest.boot_argv(False)
    if sys.platform == "darwin":
        argv[argv.index("-netdev") + 1] = "user,id=net0"
        for index, value in enumerate(argv):
            if value.startswith("if=none,id=state,"):
                argv[index] = f"if=none,id=state,format=raw,file={guest.state_image}"
        argv[argv.index("-qmp") + 1] = f"unix:{outputs / 'qmp.sock'},server=on,wait=off"
    append = argv.index("-append") + 1
    argv[append] = " ".join(token for token in argv[append].split(" ") if token != "LAPUTA_MAINTAINED_PROOF_FLAG=1")
    console = outputs / f"ntp-{phase}.log"
    console.unlink(missing_ok=True)
    child, err = guest.launch(
        argv, console, outputs / f"ntp-{phase}.qemu.log",
        f" LAPUTA_GENERATION_ID=current LAPUTA_BOOT_SERIAL={serial} LAPUTA_NTP_DRILL={phase}",
    )
    try:
        deadline = time.time() + timeout
        while time.time() < deadline:
            text = console.read_text(errors="replace") if console.exists() else ""
            if FAILED in text:
                raise RuntimeError(f"clock drill failed: {text[text.index(FAILED):][:400]}")
            if f"{OK} {phase}" in text:
                break
            if "Kernel panic" in text:
                raise RuntimeError(f"guest kernel panicked; inspect {console}")
            time.sleep(2)
        else:
            raise RuntimeError(f"timed out waiting for {phase}; inspect {console}")
        if phase == "sync":
            guest.wait_exit(child, 120)
    finally:
        err.close()
        if child.poll() is None:
            child.send_signal(signal.SIGKILL)
            child.wait(timeout=60)
    lines = [line for line in console.read_text(errors="replace").splitlines() if line.startswith("LAPUTA_NTP_DRILL_")]
    print(f"PASS maintained clock: {phase}")
    for line in lines:
        print("  " + line)


def main():
    global outputs
    if sys.platform == "darwin":
        outputs = pathlib.Path(tempfile.mkdtemp(prefix="maintained-ntp.", dir=guest.scratch))
        guest.outputs = outputs
        guest.state_image = outputs / "state.ext4"
    subprocess.run(["rm", "-rf", str(guest.state_image)], check=True)
    guest.ensure_state_image(trust_store=True)
    for phase, serial, timeout in PHASES:
        boot(phase, serial, timeout)


if __name__ == "__main__":
    main()
