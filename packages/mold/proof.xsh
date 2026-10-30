use pm.proof
use pm.util as pm_util

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "mold")
  proof.target_elf(root, p"usr/bin/mold", "mold")
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "mold ok: cross-built"
    return
  }
  let mold = fp"{root}/usr/bin/mold"
  let readelf = process.which("llvm-readelf")?
  let headers = run.text $readelf "-l" $mold
  proof.ensure("ld-musl" in headers and !("ld-linux" in headers), "proof-mold", "mold must use the musl interpreter")
  let version = run.text $mold "--version"
  proof.ensure(version.starts_with("mold 2.42.1"), "proof-mold", f"unexpected mold version: {version}")
  let tmp = fp"{root}/var/tmp/proof-mold"
  tmp.remove()
  tmp.mkdir(true)
  defer tmp.remove()
  fp"{tmp}/test.c".write("int main(void) { return 6 * 7 == 42 ? 0 : 1; }\n")
  let cc = process.which("cc")?
  let executable = fp"{tmp}/test"
  run $cc fp"{tmp}/test.c" f"--ld-path={mold}" "-o" $executable
  let comment = run.text $readelf "-p" ".comment" $executable
  proof.ensure("mold" in comment, "proof-mold", "C executable was not linked by mold")
  run $executable
  print "mold ok: native link"
}
