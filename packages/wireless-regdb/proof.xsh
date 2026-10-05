##! wireless-regdb proof: the signed database sits where the kernel firmware loader finds it.
use pm.proof

proc ensure_sha256(root: Path, rel: Path, expected: Str) {
  let file = fp"{root}/{rel}"
  proof.ensure(file.exists()?, "wireless-regdb", f"missing {rel}")
  let actual = hash.sha256(file)?.hex()
  proof.ensure(actual == expected, "wireless-regdb", f"{rel} has sha256 {actual}, expected {expected}")
}

proc main(root: Path = /rootfs) [fs, error] {
  proof.package_metadata(root, "wireless-regdb")

  # The 2026.09.03 release's regulatory.db and its signature, byte for byte.
  ensure_sha256(root, p"usr/lib/firmware/regulatory.db", "7e236caecd939c8ec98be4870bf30422f28ffef2565a38aaaa2d9ddabd0c2641")
  ensure_sha256(root, p"usr/lib/firmware/regulatory.db.p7s", "50332f0db09b8bcc719235ec4985c27377f2cc2f42abb7b5dcf951866c5a888a")

  # cfg80211 rejects a database without the big-endian "RGDB" magic.
  let magic = bytes.read_at(fp"{root}/usr/lib/firmware/regulatory.db", 0, 4)?
  proof.ensure(magic == bytes.from_text("RGDB"), "wireless-regdb", "regulatory.db lacks the RGDB magic")

  proof.ensure(
    fp"{root}/usr/share/licenses/wireless-regdb/LICENSE".exists()?,
    "wireless-regdb",
    "missing license",
  )
  print "wireless-regdb ok"
}

main(@args)
