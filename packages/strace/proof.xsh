##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

# strace traces the root's musl loader running `strace -V`: the loader opens
# the program it was given (open on x86_64, openat on aarch64), and the
# program writes its version banner to stdout (musl's stdio flushes with
# writev). `-s 256` keeps the root's long paths from being truncated. Tracing a child it forked needs only
# ptrace on that child, which Docker's default seccomp profile allows.
proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "strace")
  proof.target_elf(root, p"usr/bin/strace", "strace")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"strace ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let os = system.uname()?
  let loader = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let strace = fp"{root}/usr/bin/strace"
  tempdir tmp at fp"{root}/var/tmp/proof-strace" {

    let version = run.text $loader $strace "-V"
    let banner = version.lines().get(0) ?? ""
    proof.ensure(banner == "strace -- version 7.2", "strace-version", f"unexpected version banner: {banner}")

    let out = fp"{tmp}/trace.out"
    let traced = run.text $loader $strace "-f" "-s" "256" "-e" "trace=execve,open,openat,write,writev" "-o" $out $loader \
      $strace "-V"
    proof.ensure(
      (traced.lines().get(0) ?? "") == "strace -- version 7.2",
      "strace-traced",
      f"traced program printed: {traced.trim()}",
    )

    let lines = out.read_lines()?
    let execve = [
      line
      for line in lines
      if f"execve(\"{loader}\", [\"{loader}\", \"{strace}\", \"-V\"]" in line and line.ends_with(" = 0")
    ]
    let opened = [
      line
      for line in lines
      if f"\"{strace}\", O_RDONLY" in line and (" open(" in line or " openat(AT_FDCWD, " in line)
    ]
    let wrote = [
      line
      for line in lines
      if (" write(1, " in line or " writev(1, " in line) and "\"strace -- version 7.2" in line
    ]
    let exited = [line for line in lines if line.ends_with("+++ exited with 0 +++")]
    let trace = lines.join("\n")
    proof.ensure(execve.len() == 1, "strace-execve", f"no decoded execve of the loader in:\n{trace}")
    proof.ensure(opened.len() >= 1, "strace-open", f"no decoded open of the program in:\n{trace}")
    proof.ensure(wrote.len() == 1, "strace-write", f"no decoded banner write in:\n{trace}")
    proof.ensure(exited.len() == 1, "strace-exit", f"no clean exit in:\n{trace}")
    print f"strace ok: {opened[0]}"
    print f"strace ok: {wrote[0]}"
  }
}
