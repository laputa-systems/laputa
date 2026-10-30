#!/bin/xsh

proc main() {
  let cmdline = p"/proc/cmdline".read_text()?
  let writing = "LAPUTA_STORAGE_WRITE=1" in cmdline
  let full = "LAPUTA_STORAGE_FULL=1" in cmdline
  var block = "x"
  for index in range(16) { block += block }
  p"/run/data".mkdir()
  if writing {
    linux.mount(b"/dev/vdb", /run/data, fstype: "ext4")?
    p"/run/data/payload".write("laputa durable payload\n", mode: 0o640)
    fs.fsync(p"/run/data/payload")
    fs.fsync(p"/run/data")
    if full {
      var index = 0
      while true {
        let target = fp"/run/data/fill-{index}"
        match target.write(block) {
          Ok(_) => {}
          Err(problem) => {
            guard problem.errno == 28 else { fail problem.message }
            break
          }
        }
        index += 1
      }
      fs.fsync(p"/run/data")
      p"/dev/console".write("LAPUTA_STORAGE_FULL\n")
      return
    }
    p"/dev/console".write("LAPUTA_STORAGE_WRITING\n")
    var index = 0
    while true {
      fp"/run/data/pending-{index % 32}".write(block)
      index += 1
    }
  } else {
    let status = process.run(process.command_argv(/usr/bin/e2fsck, ["e2fsck", "-f", "-p", "/dev/vdb"]))?
    let code = status.shell_code()?
    guard code == 0 or code == 1 or code == 2 else { fail f"repair failed: {code}" }
    linux.mount(b"/dev/vdb", /run/data, fstype: "ext4", options: ["ro"])?
    guard p"/run/data/payload".read_text()? == "laputa durable payload\n" else { fail "durable payload changed" }
    guard fs.stat(p"/run/data/payload")?.mode % 4096 == 0o640 else { fail "durable payload mode changed" }
    linux.umount(/run/data)?
    p"/dev/console".write(f"LAPUTA_STORAGE_RECOVERED {code}\n")
  }
}
