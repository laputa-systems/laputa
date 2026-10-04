##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, error] {
  proof.package_metadata(root, "laputa-net")?
  proof.ensure(fs.exists(fp"{root}/usr/lib/xinit/services/net.xsh")?, "laputa-net", "missing net service module")?
  proof.ensure(fs.exists(fp"{root}/etc/network/interfaces")?, "laputa-net", "missing /etc/network/interfaces")?
  # ifup/ifdown belong to the runtime-only `xsh` dependency, which a package
  # proof root does not hold; generations install it beside this payload.
  proof.ensure(fs.metadata(fp"{root}/etc/network/if-pre-down.d")?.kind == "dir", "laputa-net", "missing if-pre-down.d")?
  proof.ensure(
    fs.metadata(fp"{root}/etc/network/if-post-down.d")?.kind == "dir",
    "laputa-net",
    "missing if-post-down.d",
  )?
  print "laputa-net ok"
}

main(@args)?
