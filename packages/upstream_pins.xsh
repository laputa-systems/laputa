##! Shared upstream pin records for package recipes.
## The dated upstream path segment used by Rust distribution sources.
export const rust_distribution_date = "2026-10-01"

## Target checksums for Rust distribution standard-library archives.
export const rust_std_checksums = [
  {
    arch: "aarch64",
    sha256: "ea8fd309578a09c9e12401621a470e6d6b1047f25933207fb8a39d66647d4561",
  },
  {
    arch: "x86_64",
    sha256: "b106b0aa4565cc3525fd3161c69203a9e39044e6e6b4d618f261c3eeda14ad50",
  },
]

## The kernel release shared by the kernel, headers, and perf packages.
export const linux_kernel_version = "7.2.9"

## The canonical source record for the pinned Linux kernel tarball.
export let linux_kernel_source = {
  source: fp"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-{linux_kernel_version}.tar.xz",
  kind: "auto",
  architectures: ["all"],
  checksums: [
    {
      arch: "all",
      sha256: "b4c5dfbe51a364a6c7f03869200f88c8e1f77403539005f14b7fc6bc91b8d8ba",
    },
  ],
}

## The shared compositor, daemon, and protocol workspace commit.
export const tinyland_revision = "f5865e9804321f3339299ebb875e0748c3b8c9dc"

## Checksum-pinned workspace and dependency sources shared by its packages.
export let tinyland_workspace_sources = [
  {
    source: fp"https://github.com/laputa-systems/tinyland/archive/{tinyland_revision}.tar.gz",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "c5c60d186ba3c72989c0db664ea41b5d2ef80ea2ed351dfb659c985eb923a689"}],
  },
  {
    source: fp"https://raw.githubusercontent.com/laputa-systems/tinyland/{tinyland_revision}/Cargo.lock => vendor",
    kind: "cargo-vendor",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "9e0a7eea02168f35f0332d7197b8cd27e4c1f45f0b23ac2620b7deddff30aafa"}],
  },
  {
    source: p"https://github.com/laputa-systems/kbvm/archive/c21a0508a6505639ec0d46e6f21a60de2d83e2e4.tar.gz => git-kbvm",
    kind: "cargo-git-workspace",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "f100ee351808d32f0227d4f29938d51f266a83faea6d37615dd4893856d327f3"}],
  },
]
