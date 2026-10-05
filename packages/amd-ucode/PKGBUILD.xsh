##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "amd-ucode"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## The linux-firmware release tag the microcode containers come from.
export const ver = "20260916"

## Package recipe export.
export const rel = "1"

## AMD CPU microcode only applies to x86 processors.
export const architectures = ["x86_64"]

## Package recipe export.
export const deps: List[Str] = []

## Package recipe export.
export const mkdeps_host: List[Str] = []

# Each file is fetched from the linux-firmware tree at the release tag through
# cgit's plain/ view; the sha256 makes every one content-addressed, so the
# fetch does not depend on a regenerated archive. The microcode containers
# stage into amd-ucode/, the license at the source root.
## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amd-ucode/microcode_amd.bin?h=VERSION => amd-ucode",
    kind: "file",
    architectures: [
      "x86_64",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "8a9d9e8b788e31e61cddc03cb1eeab5db99e0f667128943ff0780e6437d2e43e",
      },
    ],
  },
  {
    source: p"https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amd-ucode/microcode_amd_fam15h.bin?h=VERSION => amd-ucode",
    kind: "file",
    architectures: [
      "x86_64",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "9d4a668410e72a4bdb86dc23e4261eca04daa83456ada02504115223f356981a",
      },
    ],
  },
  {
    source: p"https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amd-ucode/microcode_amd_fam16h.bin?h=VERSION => amd-ucode",
    kind: "file",
    architectures: [
      "x86_64",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "e02ad653b39c975d6c52674b50f23727bb6706bab7b4e5b391a4ce229e7ff121",
      },
    ],
  },
  {
    source: p"https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amd-ucode/microcode_amd_fam17h.bin?h=VERSION => amd-ucode",
    kind: "file",
    architectures: [
      "x86_64",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "966e4b796ec689c618868d08f8a37f347b0e7bfce4ae9df793e08471d363b7d0",
      },
    ],
  },
  {
    source: p"https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amd-ucode/microcode_amd_fam19h.bin?h=VERSION => amd-ucode",
    kind: "file",
    architectures: [
      "x86_64",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "c614d6db8056c5c67a9189b225124127d56990a190305bcb3927d50e132de7dd",
      },
    ],
  },
  {
    source: p"https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amd-ucode/microcode_amd_fam1ah.bin?h=VERSION => amd-ucode",
    kind: "file",
    architectures: [
      "x86_64",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "605aecca9583a3710efb482b4940fe3dd1f96b1cea19818e766f298d8ba06a5d",
      },
    ],
  },
  {
    source: p"https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/LICENSES/LICENSE.amd-ucode?h=VERSION",
    kind: "file",
    architectures: [
      "x86_64",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "2103bd999f77522c5ab5fd35df0579ed00e2a6b885f6f8ebd444e97ffa482991",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"boot/amd-ucode.img",
    kind: "file",
  },
  {
    path: p"usr/lib/firmware/amd-ucode/microcode_amd.bin",
    kind: "file",
  },
  {
    path: p"usr/lib/firmware/amd-ucode/microcode_amd_fam15h.bin",
    kind: "file",
  },
  {
    path: p"usr/lib/firmware/amd-ucode/microcode_amd_fam16h.bin",
    kind: "file",
  },
  {
    path: p"usr/lib/firmware/amd-ucode/microcode_amd_fam17h.bin",
    kind: "file",
  },
  {
    path: p"usr/lib/firmware/amd-ucode/microcode_amd_fam19h.bin",
    kind: "file",
  },
  {
    path: p"usr/lib/firmware/amd-ucode/microcode_amd_fam1ah.bin",
    kind: "file",
  },
  {
    path: p"usr/share/licenses/amd-ucode/LICENSE.amd-ucode",
    kind: "file",
  },
]

# The containers in the byte order of the shell glob microcode_amd*.bin in the
# C locale, which is the order the kernel's x86 microcode documentation
# concatenates them in for the early-load image.
const microcode_containers = [
  "microcode_amd.bin",
  "microcode_amd_fam15h.bin",
  "microcode_amd_fam16h.bin",
  "microcode_amd_fam17h.bin",
  "microcode_amd_fam19h.bin",
  "microcode_amd_fam1ah.bin",
]

# The containers go where the kernel firmware loader looks for late loading
# (/lib/firmware, which baselayout links to usr/lib). The early loader instead
# reads kernel/x86/microcode/AuthenticAMD.bin from an uncompressed newc cpio
# that the boot loader places first in the initrd; /boot/amd-ucode.img is that
# cpio, under the name other distributions give it.
## Package recipe export.
export proc build(dest: Path) [fs, error] {
  let src = fs.cwd()?
  let firmware = fp"{dest}/usr/lib/firmware/amd-ucode"
  var containers: List[Bytes] = []

  for container in microcode_containers {
    let staged = fp"{src}/amd-ucode/{container}"
    fs.install(staged, fp"{firmware}/{container}", 0o644, parents: true, overwrite: true)
    containers += [staged.read_bytes()?]
  }

  fs.install(
    fp"{src}/LICENSE.amd-ucode",
    fp"{dest}/usr/share/licenses/amd-ucode/LICENSE.amd-ucode",
    0o644,
    parents: true,
    overwrite: true,
  )

  tempdir early {
    fs.mkdir(fp"{early}/kernel/x86/microcode")
    fs.write(fp"{early}/kernel/x86/microcode/AuthenticAMD.bin", bytes.concat(containers))
    fs.mkdir(fp"{dest}/boot")
    archive.cpio_create(fp"{dest}/boot/amd-ucode.img", early, [p"kernel"], overwrite: true)
  }
}
