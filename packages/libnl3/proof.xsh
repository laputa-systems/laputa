##! XSH module `proof` package and build operations.
use pm.proof

pure exports_symbol(syms: Str, symbol: Str) -> Bool {
  for line in syms.lines() {
    return true when line.ends_with(f" {symbol}") and " UND " not in line
  }

  false
}

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libnl3")
  proof.ensure(fp"{root}/usr/include/netlink/netlink.h".exists()?, "libnl3", "missing netlink.h")
  proof.ensure(fp"{root}/usr/include/netlink/genl/genl.h".exists()?, "libnl3", "missing genl.h")
  proof.ensure(fp"{root}/usr/lib/libnl-3.so".exists()?, "libnl3", "missing libnl-3.so")
  proof.ensure(fp"{root}/usr/lib/libnl-genl-3.so".exists()?, "libnl3", "missing libnl-genl-3.so")
  proof.target_elf(root, p"usr/lib/libnl-3.so.200", "libnl3")
  proof.target_elf(root, p"usr/lib/libnl-genl-3.so.200", "libnl3")

  let readelf = proof.readelf_tool()?
  let core_syms = run.text $readelf "--dyn-syms" "-W" fp"{root}/usr/lib/libnl-3.so.200"
  let genl_syms = run.text $readelf "--dyn-syms" "-W" fp"{root}/usr/lib/libnl-genl-3.so.200"
  proof.ensure(exports_symbol(core_syms, "nl_cache_resync_v2"), "libnl3", "libnl-3 does not export nl_cache_resync_v2")
  proof.ensure(exports_symbol(genl_syms, "genl_connect"), "libnl3", "libnl-genl-3 does not export genl_connect")
  print "libnl3 ok"
}
