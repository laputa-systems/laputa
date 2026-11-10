#!/bin/xsh --
proc root_is_rw() -> Result[Bool] {
  let text = p"/proc/mounts".read_text()?
  for line in text.lines() {
    let fields = line.split(" ")
    if fields.len() >= 4 and fields[1] == "/" {
      return "rw" in fields[3].split(",")
    }
  }
  false
}

proc main() [fs, process, error] {
  var survivors: List[Str] = []
  for entry in process.list()? {
    if entry.status != "Z" and "worker.xsh" in entry.argv {
      survivors += [f"{entry.pid}"]
    }
  }
  let rw = root_is_rw()?
  let console = p"/dev/console"
  console.write(f"R1_REBOOT_PRE {json.encode({root_rw: rw, survivors: survivors.len()})?}\n")?
  if survivors.is_empty() and rw {
    console.write("R1_REBOOT_OWNED_STOPPED_BEFORE_FS_SHUTDOWN\n")?
  } else {
    console.write(f"R1_FAIL reboot survivors={survivors.len()} root_rw={rw}\n")?
  }
}

main()?
