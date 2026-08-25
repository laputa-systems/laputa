##! Canonical in-guest dwl and foot keyboard-input proof for qemu-dwl-foot.
#!/bin/xsh
error GuestProofError = Failed(phase: Str, message: Str)

proc console(message: Str) [fs, error] {
  fs.write(/dev/console, f"${message}\n")?
}

proc fail(phase: Str, message: Str) [fs, error] {
  console(f"LAPUTA_DWL_FOOT_PROOF_FAILED ${phase}: ${message}")?
  return Err(GuestProofError.Failed(phase, message))
}

proc wait_for(path_value: Path, seconds: Int) [fs, time, error] {
  var elapsed = 0
  while ! fs.exists(path_value)? {
    if elapsed >= seconds {
      fail("wait", f"missing ${path_value}")?
    }
    time.sleep(1s)?
    elapsed += 1
  }
}

proc main() [fs, process, time, error] {
  let mdevd = process.which("mdevd-coldplug")?
  let seatd = process.which("seatd")?
  let dwl = process.which("dwl")?
  let foot = process.which("foot")?
  run $mdevd "-O" "4" ?

  for device in [p"/dev/input/event0", p"/dev/input/event1"] {
    wait_for(device, 20)?
  }

  let _seatd = spawn process.command_argv(seatd, ["seatd", "-g", "video"])?
  wait_for(p"/run/seatd.sock", 20)?
  fs.mkdir(p"/run/user/0")?
  fs.chmod(p"/run/user/0", 0o700)?
  fs.write(
    p"/run/laputa-foot-read.xsh",
    """#!/bin/xsh
print "LAPUTA_DWL_FOOT_VISUAL"
let input = io.stdin().read_to_end()?.utf8()?
fs.write(p"/run/laputa-foot-input.txt", input)?
""",
  )?
  fs.chmod(p"/run/laputa-foot-read.xsh", 0o755)?
  console("LAPUTA_DWL_FOOT_PROOF_READY")?
  let command = process.command_argv(
    dwl,
    ["dwl", "-s", f"${foot} /bin/xsh /run/laputa-foot-read.xsh"],
    env: {XDG_RUNTIME_DIR: "/run/user/0", WLR_BACKENDS: "drm,libinput", WLR_RENDERER: "pixman"},
  )
  let compositor = spawn command?
  let _ = compositor
  wait_for(p"/run/laputa-foot-input.txt", 90)?
  let input = fs.read_text(p"/run/laputa-foot-input.txt")?.trim()
  if input != "laputa" {
    fail("input", f"expected laputa, got ${input}")?
  }
  console("LAPUTA_DWL_FOOT_PROOF_OK")?
}

main()?
