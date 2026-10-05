##! amd-ucode proof: the pinned containers are installed for late loading, and the early-load cpio carries their concatenation.
use pm.proof

# The linux-firmware 20260916 amd-ucode containers, in the order the early
# image concatenates them.
const containers = [
  {name: "microcode_amd.bin", sha256: "8a9d9e8b788e31e61cddc03cb1eeab5db99e0f667128943ff0780e6437d2e43e"},
  {name: "microcode_amd_fam15h.bin", sha256: "9d4a668410e72a4bdb86dc23e4261eca04daa83456ada02504115223f356981a"},
  {name: "microcode_amd_fam16h.bin", sha256: "e02ad653b39c975d6c52674b50f23727bb6706bab7b4e5b391a4ce229e7ff121"},
  {name: "microcode_amd_fam17h.bin", sha256: "966e4b796ec689c618868d08f8a37f347b0e7bfce4ae9df793e08471d363b7d0"},
  {name: "microcode_amd_fam19h.bin", sha256: "c614d6db8056c5c67a9189b225124127d56990a190305bcb3927d50e132de7dd"},
  {name: "microcode_amd_fam1ah.bin", sha256: "605aecca9583a3710efb482b4940fe3dd1f96b1cea19818e766f298d8ba06a5d"},
]

# sha256 of `cat microcode_amd*.bin` over the containers above.
const early_sha256 = "49995102b0a6eac9c25e601d148f0a46176ae3a85fe644b13a66dcbcc47e2e18"

const early_member = "kernel/x86/microcode/AuthenticAMD.bin"

proc ensure_sha256(file: Path, expected: Str) [fs, error] {
  proof.ensure(fs.exists(file)?, "amd-ucode", f"missing {file}")
  let actual = hash.sha256(file)?.hex()
  proof.ensure(actual == expected, "amd-ucode", f"{file} has sha256 {actual}, expected {expected}")
}

proc main(root: Path = /rootfs) [fs, error] {
  proof.package_metadata(root, "amd-ucode")
  var concatenated: List[Bytes] = []

  for container in containers {
    let file = fp"{root}/usr/lib/firmware/amd-ucode/{container.name}"
    ensure_sha256(file, container.sha256)
    concatenated += [file.read_bytes()?]
  }

  ensure_sha256(
    fp"{root}/usr/share/licenses/amd-ucode/LICENSE.amd-ucode",
    "2103bd999f77522c5ab5fd35df0579ed00e2a6b885f6f8ebd444e97ffa482991",
  )

  # The early loader scans the initrd for an uncompressed newc ("070701")
  # archive, so the image must start with that header, not a compressor's.
  let image = fp"{root}/boot/amd-ucode.img"
  proof.ensure(fs.exists(image)?, "amd-ucode", "missing boot/amd-ucode.img")
  let magic = bytes.read_at(image, 0, 6)?
  proof.ensure(magic == bytes.from_text("070701"), "amd-ucode", "amd-ucode.img is not an uncompressed newc cpio")

  var members: List[Str] = []

  for entry in archive.cpio_list(image)? {
    members += [entry.path.display()]
  }

  proof.ensure(early_member in members, "amd-ucode", f"amd-ucode.img lacks {early_member}: {members.join(", ")}")

  let extracted_handle = fs.tempdir()?
  defer extracted_handle.close()?
  let extracted = extracted_handle.host_path()?
  archive.cpio_extract(image, extracted)
  let early = fp"{extracted}/{early_member}"
  ensure_sha256(early, early_sha256)
  proof.ensure(
    early.read_bytes()? == bytes.concat(concatenated),
    "amd-ucode",
    f"{early_member} is not the concatenation of the installed containers",
  )
  print "amd-ucode ok"
}

main(@args)
