##! XSH module `proof` package and build operations.
use pm.proof

proc main(root = /rootfs) [fs, error] {
  proof.package_metadata(root, "hwdata")
  let share = fp"{root}/usr/share/hwdata"

  let pnp = fp"{share}/pnp.ids".read_text()?
  proof.ensure("\nDEL\tDell Inc.\n" in pnp, "proof-hwdata", "pnp.ids lacks the DEL vendor")
  let pci = fp"{share}/pci.ids".read_text()?
  proof.ensure("\n1af4  Red Hat, Inc.\n" in pci, "proof-hwdata", "pci.ids lacks the 1af4 vendor")
  proof.ensure("\n8086  Intel Corporation\n" in pci, "proof-hwdata", "pci.ids lacks the 8086 vendor")
  let usb = fp"{share}/usb.ids".read_text()?
  proof.ensure("\n1d6b  Linux Foundation\n" in usb, "proof-hwdata", "usb.ids lacks the Linux Foundation vendor")
  let pc = fp"{root}/usr/share/pkgconfig/hwdata.pc".read_text()?
  proof.ensure("pkgdatadir=\${datadir}/hwdata\n" in pc, "proof-hwdata", "hwdata.pc lacks pkgdatadir")
  proof.ensure("\nVersion: 0." in pc, "proof-hwdata", "hwdata.pc lacks a version")
  print "hwdata ok: pnp, pci and usb vendor tables, pkg-config data dir"
}
