proc main(root: Path) [fs, process, time, error] {
  let cmdline = p"/proc/cmdline".read_text()?.trim().split(" ")
  let writing = "LAPUTA_STORAGE_WRITE=1" in cmdline
  p"/run/storage".mkdir()?
  if writing {
    linux.mount(b"/dev/vdc", /run/storage, fstype: "ext4")?
    p"/run/storage/record".write("old\n")?
    fs.fsync(p"/run/storage/record")?
    fs.fsync(p"/run/storage")?
    p"/run/storage/next".write("new\n")?
    fs.fsync(p"/run/storage/next")?
    p"/dev/console".write("STORAGE_STAGED\n")?
    if "LAPUTA_STORAGE_STAGE=1" not in cmdline {
      p"/run/storage/next".rename(to: /run/storage/record, overwrite: true)?
      p"/dev/console".write("STORAGE_RENAMED\n")?
      if "LAPUTA_STORAGE_SYNC=1" in cmdline {
        fs.fsync(p"/run/storage")?
        p"/dev/console".write("STORAGE_SYNCED\n")?
      }
    }
    while true { time.sleep(1s) }
  } else {
    let checker = fp"{root}/inputs/e2fsck"
    let status = process.run(process.command_argv(checker, [checker.display(), "-f", "-p", "/dev/vdc"], env: {LD_LIBRARY_PATH: fp"{root}/inputs/lib".display()}))?
    let code = status.shell_code()?
    assert code == 0 or code == 1 or code == 2, f"e2fsck failed: {code}"
    linux.mount(b"/dev/vdc", /run/storage, fstype: "ext4", options: ["ro"]) ?
    let actual = p"/run/storage/record".read_text()?
    let expected = fp"{root}/inputs/expected".read_text()?
    assert actual == expected or (expected == "either\n" and actual in ["old\n", "new\n"]), f"record differs: {actual}"
    linux.umount(/run/storage)?
    print f"STORAGE_RECOVERED {code} {actual.trim()}"
  }
}
main(@args)?
