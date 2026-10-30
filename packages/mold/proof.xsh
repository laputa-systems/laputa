use pm.proof
use pm.util as pm_util

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "mold")
  proof.target_elf(root, p"usr/bin/mold", "mold")
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "mold ok: cross-built"
    return
  }
  let tmp = fp"{root}/var/tmp/proof-mold"
  tmp.remove()
  tmp.mkdir(true)
  defer tmp.remove()
  fp"{tmp}/test.c".write("int main(void) { return 6 * 7 == 42 ? 0 : 1; }\n")
  let cc = process.which("cc")?
  let executable = fp"{tmp}/test"
  run $cc fp"{tmp}/test.c" "-static" f"-B{root}/usr/libexec/mold" "-o" $executable
  run $executable
  print "mold ok: native link"
}
