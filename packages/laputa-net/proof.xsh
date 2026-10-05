##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, error] {
  proof.package_metadata(root, "laputa-net")
  proof.ensure(fp"{root}/usr/lib/xinit/services/net.xsh".exists()?, "laputa-net", "missing net service module")
  proof.ensure(fp"{root}/etc/network/interfaces".exists()?, "laputa-net", "missing /etc/network/interfaces")
  # ifup/ifdown belong to the runtime-only `xsh` dependency, which a package
  # proof root does not hold; generations install it beside this payload.
  proof.ensure(fp"{root}/etc/network/if-pre-down.d".is_dir()?, "laputa-net", "missing if-pre-down.d")
  proof.ensure(
    fp"{root}/etc/network/if-post-down.d".is_dir()?,
    "laputa-net",
    "missing if-post-down.d",
  )
  print "laputa-net ok"
}

main(@args)
