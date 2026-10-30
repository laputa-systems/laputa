#!/bin/xsh

proc main() {
  p"/run/restore".mkdir()
  linux.mount(b"/dev/vdb1", /run/restore, fstype: "ext4")?
  let target = p"/run/restore/usr/bin/xinit"
  guard hash.sha256(target)?.hex() == hash.sha256(p"/usr/bin/xinit")?.hex() else {
    fail "detached xinit differs from the rescue copy"
  }
  guard ! p"/run/restore/init".exists()? else { fail "detached init already exists" }
  p"/run/restore/init".symlink(to: p"usr/bin/xinit")
  fs.fsync(p"/run/restore")
  linux.umount(/run/restore)?
  p"/dev/console".write("LAPUTA_INIT_RESTORE_OK\n")
}
