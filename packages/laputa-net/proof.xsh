##! XSH module `proof` package and build operations.
use pm.proof

proc main(root = /rootfs) [fs, error] {
  proof.package_metadata(root, "laputa-net")
  proof.ensure(fp"{root}/usr/lib/xinit/services/net.xsh".exists()?, "laputa-net", "missing net service module")
  proof.ensure(fp"{root}/etc/network/interfaces".exists()?, "laputa-net", "missing /etc/network/interfaces")
  proof.ensure(fp"{root}/etc/network/if-pre-down.d".is_dir()?, "laputa-net", "missing if-pre-down.d")
  proof.ensure(
    fp"{root}/etc/network/if-post-down.d".is_dir()?,
    "laputa-net",
    "missing if-post-down.d",
  )
  print "laputa-net ok"
}
