##! The OxiSH SSH server, session helper, interactive and file-transfer clients and key generator,
##! installed from the checksum-pinned ssh-build release archive.
##! Laputa builds no SSH implementation; the archive is the only source.

## Package name.
export const name = "oxish"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## The `oxish` product version named by the release archive, `oxish-VERSION-<triple>.tar.xz`.
export const ver = "0.2.0"

## Package release revision.
export const rel = "1"

## The archive executables are static-pie; they link no shared library.
export const deps: List[Str] = []

## Host-side build dependencies: none, the build only installs files.
export const mkdeps_host: List[Str] = []

## The service modules are xinit services and the host-key oneshot runs under `xsh`.
export const runtime_only_deps = ["xinit", "xsh"]

## Preserve the released binaries without stripping; the archive provenance names their digests.
export const nostrip = true

const release_tag = "release-ba4e5e269b1737b32cf7cdaa08e739ec06712cf5"
const release_sha256_x86_64 = "6d20f301b1957cbf612630627730e0b219fd8a63c9c91879368751a84ed4202c"
const release_sha256_aarch64 = "0822b5ddaf85ff0347d53ab21ab7b306e512227ca88c85ef7bad41cce7a94857"

## Upstream release archives and checksums. The archive has no top-level directory:
## `bin/`, the licenses and `provenance.json`.
export let upstream_sources = [
  {
    source: fp"https://github.com/laputa-systems/ssh-build/releases/download/{release_tag}/oxish-VERSION-ARCH-unknown-linux-musl.tar.xz => oxish",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: release_sha256_aarch64,
      },
      {
        arch: "x86_64",
        sha256: release_sha256_x86_64,
      },
    ],
  },
  {
    source: p"service.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
  {
    source: p"hostkey.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
]

## Installed package file tree.
export const filetree = [
  {
    path: p"usr/bin/oxish",
    kind: "binary",
  },
  {
    path: p"usr/bin/oxish-keygen",
    kind: "binary",
  },
  {
    path: p"usr/bin/oxish-scp",
    kind: "binary",
  },
  {
    path: p"usr/bin/oxish-server",
    kind: "binary",
  },
  {
    path: p"usr/bin/oxish-session",
    kind: "binary",
  },
  {
    path: p"usr/bin/oxish-sftp",
    kind: "binary",
  },
  {
    path: p"usr/lib/xinit/services/oxish.xsh",
    kind: "file",
  },
  {
    path: p"usr/lib/xinit/services/oxish-hostkey.xsh",
    kind: "file",
  },
  {
    path: p"usr/share/oxish/LICENSE-APACHE",
    kind: "file",
  },
  {
    path: p"usr/share/oxish/LICENSE-MIT",
    kind: "file",
  },
  {
    path: p"usr/share/oxish/THIRD-PARTY.md",
    kind: "file",
  },
  {
    path: p"usr/share/oxish/provenance.json",
    kind: "file",
  },
]

const executables = ["oxish", "oxish-keygen", "oxish-scp", "oxish-server", "oxish-session", "oxish-sftp"]
const documents = ["LICENSE-APACHE", "LICENSE-MIT", "THIRD-PARTY.md", "provenance.json"]

## Install an unpacked release archive (`release/bin/<executable>`, the licenses and
## `provenance.json`) and the two service modules from `files` under `dest`. A missing
## member fails the build, so a release that drops an executable never produces a package.
export proc install_release(release: Path, files: Path, dest: Path) [fs, error] {
  for tool in executables {
    let source = fp"{release}/bin/{tool}"

    guard source.exists() else {
      fail f"oxish release archive is missing bin/{tool}"
    }

    fs.install(source, fp"{dest}/usr/bin/{tool}", 0o755, parents: true, overwrite: true)
  }

  for document in documents {
    let source = fp"{release}/{document}"

    guard source.exists() else {
      fail f"oxish release archive is missing {document}"
    }

    fs.install(source, fp"{dest}/usr/share/oxish/{document}", 0o644, parents: true, overwrite: true)
  }

  fs.install(fp"{files}/service.xsh", fp"{dest}/usr/lib/xinit/services/oxish.xsh", 0o644, parents: true, overwrite: true)
  fs.install(
    fp"{files}/hostkey.xsh",
    fp"{dest}/usr/lib/xinit/services/oxish-hostkey.xsh",
    0o644,
    parents: true,
    overwrite: true,
  )
}

## Build and install the oxish package from the staged release archive.
export proc build(dest: Path) [fs, error] {
  install_release(p"oxish", p".", dest)
}
