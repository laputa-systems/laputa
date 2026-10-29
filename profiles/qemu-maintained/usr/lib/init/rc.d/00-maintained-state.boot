#!/bin/xsh

proc main() {
  let receipt = p"/var/lib/laputa/generation.json".read_text()?
  p"/run/laputa-running-generation.json".write(receipt)
  let state = p"/run/laputa-state"
  state.mkdir()
  linux.mount(b"/dev/vdb", state, fstype: "ext4", options: ["nosuid", "nodev"])
  guard fp"{state}/format".read_text()? == "laputa-maintained-state-1\n" else {
    fail "unsupported maintained state format"
  }
  for name in ["etc", "home", "var"] {
    let source = fp"{state}/{name}"
    guard source.is_dir()? else { fail f"maintained state is missing {name}" }
    let target = fp"/{name}"
    target.mkdir()
    linux.mount(source.bytes(), target, options: ["bind"])
  }
  unix.set_hostname(p"/etc/hostname".read_text()?.trim())
}
