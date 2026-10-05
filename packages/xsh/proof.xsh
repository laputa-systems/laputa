use pm.proof

proc main(root: Path = /rootfs) [fs, error] {
  proof.package_metadata(root, "xsh")
  proof.ensure(fp"{root}/usr/bin/sh".exists()?, "proof-xsh", "missing sh runner")
  # `xsh` owns the canonical `usr/bin` runners.  A proof root deliberately
  # contains only the node's declared runtime closure, so it must not rely on
  # baselayout's optional `/bin -> usr/bin` compatibility symlink.
  proof.ensure(fp"{root}/usr/bin/xsh".exists()?, "proof-xsh", "missing xsh runner")
  proof.ensure(fp"{root}/usr/bin/xshi".exists()?, "proof-xsh", "missing xshi runner")
  proof.ensure(fp"{root}/usr/bin/xsht".exists()?, "proof-xsh", "missing xsht runner")
  proof.ensure(fp"{root}/usr/lib/xsh/core/cat".exists()?, "proof-xsh", "missing xsh core cat")
  proof.ensure(fp"{root}/usr/bin/cat".exists()?, "proof-xsh", "missing xsh cat applet")
  proof.ensure(fp"{root}/usr/bin/ifup".exists()?, "proof-xsh", "missing xsh ifup applet")
  proof.ensure(fp"{root}/usr/bin/env".exists()?, "proof-xsh", "missing xsh env applet")
  print "xsh ok"
}
