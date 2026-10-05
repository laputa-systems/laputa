##! Prove the installed uapi headers are complete and resolve.
use pm.proof
use pm.util as pm_util

proc require(condition: Bool, message: Str) [error] {
  if ! condition {
    Err(proof.ProofError.Failed(kind: "proof-linux-headers", message:))?
  }
}

proc main(root: Path = /rootfs) [fs, env, error] {
  proof.package_metadata(root, "linux-headers")
  let include = fp"{root}/usr/include"

  for header in ["linux/version.h", "linux/input.h", "asm/unistd.h", "asm/unistd_64.h", "asm-generic/errno-base.h"] {
    require(fs.exists(fp"{include}/{header}")?, f"missing {header}")
  }

  require("#define LINUX_VERSION_CODE " in fs.read_text(fp"{include}/linux/version.h")?, "version.h has no LINUX_VERSION_CODE")
  require("#define __NR_openat " in fs.read_text(fp"{include}/asm/unistd_64.h")?, "unistd_64.h has no __NR_openat")

  # Every asm-generic wrapper must name a header that exists.
  for entry in fs.children(fp"{include}/asm")? {
    let text = fs.read_text(entry.path)?
    continue unless text.starts_with("#include <asm-generic/") and text.lines().len() == 1
    let target = text.trim().replace("#include <", "").replace(">", "")
    require(fs.exists(fp"{include}/{target}")?, f"asm/{entry.name} wraps missing {target}")
  }

  # x86_64's struct stat differs from asm-generic's, so its own header must
  # never be replaced by a generic wrapper.
  if pm_util.target_arch()? == "x86_64" {
    require("struct stat {" in fs.read_text(fp"{include}/asm/stat.h")?, "asm/stat.h is not x86's own")
  }

  print "linux-headers ok"
}

main(@args)
