#!/bin/xsh
##! Explicit filesystem-only discovery over a controller-prepared pinned kernel source.
use packages.linux.kbuild_verify
use pm.recipe
use pm.types

proc main(source_root: Path) [fs, env, error, io] {
  let target = types.X86_64LinuxMusl
  let pkg = recipe.load_package_for_target(p"packages/linux", target)?
  let plan = kbuild_verify.linux_kbuild_discover_prepared(source_root, pkg, target)?
  print "xsh-kbuild-plan" plan.dirs.len() "dirs" plan.objects.len() "objects" plan.unsupported.len() "unsupported"
}

main(@args)?
