#!/bin/xsh

proc main() {
  let devices = [p"/dev/vdb", p"/dev/vdc", p"/dev/vdd"]
  let expected = [0, 1, 8]
  for index in range(3) {
    let status = process.run(process.command_argv(/usr/bin/e2fsck, ["e2fsck", "-f", "-p", devices[index].display()]))?
    let code = status.shell_code()?
    guard code == expected[index] else { fail f"rescue case {index}: expected {expected[index]}, got {code}" }
    p"/dev/console".write(f"LAPUTA_RESCUE_RESULT {index} {code}\n")
  }
  p"/run/repaired".mkdir()
  linux.mount(b"/dev/vdc", /run/repaired, fstype: "ext4", options: ["ro"])?
  let actual = hash.sha256(p"/run/repaired/payload")?.hex()
  guard actual == "9bb5b5c962e4845752dfcfb930bfcf351919828bd7713e220d48ad6df5c88081" else {
    fail "repaired payload differs"
  }
  p"/dev/console".write(f"LAPUTA_RESCUE_PROOF_OK payload {actual}\n")
  linux.umount(/run/repaired)?
}
