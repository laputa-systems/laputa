#!/bin/xsh
use pm.generation

proc main(root: Path) [fs, process, env, error] -> Result[Unit, Error] {
  let receipt = generation.read_generation_receipt(/)?
  assert receipt.profile.name == "qemu-self-hosting"
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  linux.mount(b"/dev/vdc", fp"{root}/output", fstype: "ext4", options: ["nosuid", "nodev"])?
  linux.mount(b"scratch", fp"{root}/scratch", fstype: "tmpfs", options: ["mode=1777", "size=1G", "nosuid", "nodev"])?
  linux.mount(b"proc", fp"{root}/proc", fstype: "proc", options: ["nosuid", "noexec", "nodev"])?
  linux.mount(b"dev", fp"{root}/dev", fstype: "devtmpfs", options: ["nosuid"])?
  fs.set_owner(fp"{root}/output", uid: 65534, gid: 65534)?
  assert ! fp"{root}/output/target".exists()?
  assert ! fp"{root}/output/kache".exists()?
  print "LAPUTA_SELF_HOSTING_EMPTY_CACHE"
  for name in ["bin/kache", "seed/rust/bin/rustc", "lib/ld-musl-x86_64.so.1", "dev/null"] {
    let value = fp"{root}/{name}".metadata()?
    print "LAPUTA_SEED_INPUT" $name $value.kind $value.mode $value.size
  }
  fp"{root}/scratch/seed-version.xsh".write("run /bin/kache \"--version\"\nrun /seed/rust/bin/rustc \"-vV\"\n")?
  let diagnostic = process.command_argv(/bin/xsh, ["/bin/xsh", "/scratch/seed-version.xsh"])
  let diagnostic_status = linux.run_in_namespaces(diagnostic, unshare: ["net"], root: root, cwd: root, uid: 65534, gid: 65534, drop_groups: true)?
  fail "guest kache seed diagnostic failed" unless diagnostic_status.ok
  let command = process.command_argv(/bin/xsh, ["/bin/xsh", "/inputs/build.xsh"])
  let status = linux.run_in_namespaces(command, unshare: ["net"], root: root, cwd: root, uid: 65534, gid: 65534, drop_groups: true)?
  fs.sync()?
  fail "in-guest source build failed" unless status.ok
  print "LAPUTA_SELF_HOSTING_SOURCE_BUILD_DONE"
}

main(@args)?
