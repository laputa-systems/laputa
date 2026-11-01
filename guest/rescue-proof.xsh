#!/bin/xsh

proc expected_status() -> Result[Int] {
  for token in p"/proc/cmdline".read_text()?.words() {
    if token.starts_with("LAPUTA_RESCUE_EXPECT=") {
      return token.split("=")[1] as Int
    }
  }
  fail "LAPUTA_RESCUE_EXPECT is missing from the kernel command line"
}

proc mounted_read_only(mount_point: Str) -> Result[Bool] {
  for line in p"/proc/mounts".read_text()?.lines() {
    let fields = line.words()
    if fields.len() > 3 and fields[1] == mount_point {
      return "ro" in fields[3].split(",")
    }
  }
  fail f"{mount_point} is not mounted"
}

proc network_free() -> Result[Bool] {
  for entry in fs.children(p"/sys/class/net")? {
    if fp"/sys/class/net/{entry.name}/device".exists()? {
      return false
    }
  }
  true
}

proc run_proof() {
  let expected = expected_status()?
  guard mounted_read_only("/")? else { fail "rescue root is not read-only" }
  guard network_free()? else { fail "rescue guest has a network device" }
  p"/dev/console".write("LAPUTA_RESCUE_ISOLATED read-only root, no network\n")
  wait until p"/dev/vdb".exists()? within 30s every 100ms
  let status = process.run(process.command_argv(/usr/bin/e2fsck, ["e2fsck", "-f", "-p", "/dev/vdb"]))?
  let code = status.shell_code()?
  p"/dev/console".write(f"LAPUTA_RESCUE_RESULT {code}\n")
  guard code == expected else { fail f"expected e2fsck status {expected}, got {code}" }
  if code == 0 or code == 1 or code == 2 {
    p"/run/repaired".mkdir()
    linux.mount(b"/dev/vdb", /run/repaired, fstype: "ext4", options: ["ro"])?
    let actual = hash.sha256(p"/run/repaired/payload")?.hex()
    p"/dev/console".write(f"LAPUTA_RESCUE_PAYLOAD {actual}\n")
    linux.umount(/run/repaired)?
  }
  p"/dev/console".write(f"LAPUTA_RESCUE_PROOF_OK status {code}\n")
}

proc main() -> Result[Unit, Error] {
  match run_proof() {
    Ok(_) => {}
    Err(problem) => {
      p"/dev/console".write(f"LAPUTA_RESCUE_PROOF_FAILED {problem.message}\n")
      return Err(problem)
    }
  }
}

main()?
