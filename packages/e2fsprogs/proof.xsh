##! Confirm the packaged e2fsck is the e2fsprogs binary and prints its version.
use pm.proof
use pm.util as pm_util

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "e2fsprogs")
  proof.target_elf(root, p"usr/bin/e2fsck", "e2fsprogs")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"e2fsprogs ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let os = system.uname()?
  let loader = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let e2fsck = fp"{root}/usr/bin/e2fsck"
  let version = run.capture --text $loader $e2fsck "-V"
  let banner = f"{version.stdout}{version.stderr}"
  proof.ensure(version.status.ok, "e2fsprogs-version", f"e2fsck -V failed: {banner.trim()}")
  proof.ensure(
    "e2fsck 1.47.2 (1-Jan-2025)" in banner,
    "e2fsprogs-version",
    f"unexpected version banner: {banner.trim()}",
  )
  print "e2fsprogs ok: e2fsck -V"
}
