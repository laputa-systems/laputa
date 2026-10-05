use pm.proof
use pm.util as pm_util

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(rootfs, "samurai")
  proof.target_elf(rootfs, p"usr/bin/samu", "samurai")

  if ! fp"{rootfs}/usr/bin/ninja".exists() {
    return Err(proof.ProofError.Failed(kind: "proof-samurai", message: "missing ninja symlink"))?
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "samurai ok: cross-built"
    return
  }

  let os = system.uname()?
  let dynlinker = fp"{rootfs}/usr/lib/ld-musl-{os.machine}.so.1"
  let samu = fp"{rootfs}/usr/bin/samu"
  let tmp = fp"{rootfs}/var/tmp/proof-samurai"
  tmp.remove(missing_ok: true)
  tmp.mkdir(true)
  defer tmp.remove(missing_ok: true)?

  # A dry run parses the manifest and orders the graph without spawning the
  # rule commands, so the proof needs no shell.
  fp"{tmp}/build.ninja".write(
    """ninja_required_version = 1.9
rule cc
  command = cc -c $in -o $out
rule link
  command = cc $in -o $out
build a.o: cc a.c
build b.o: cc b.c
build prog: link a.o b.o
default prog
""",
  )
  fp"{tmp}/a.c".write("")
  fp"{tmp}/b.c".write("")

  let version = run.text $dynlinker $samu "--version" ?
  proof.ensure(version.trim().starts_with("1."), "proof-samurai", f"unexpected samu --version: {version.trim()}")

  let plan = run.text $dynlinker $samu "-C" $tmp "-n" "-v" 2> /dev/null ?
  let lines = plan.trim().split("\n")
  proof.ensure(lines.len() == 3, "proof-samurai", f"dry run did not plan three edges: {plan.trim()}")
  proof.ensure("cc a.o b.o -o prog" in lines[2], "proof-samurai", f"link edge did not run last: {plan.trim()}")

  let query = run.text $dynlinker $samu "-C" $tmp "-t" "query" "prog" 2> /dev/null ?
  proof.ensure("a.o" in query and "b.o" in query, "proof-samurai", f"query did not report prog's inputs: {query.trim()}")
  print "samurai ok: manifest parse, dry-run order, query tool"
}

main(@args)
