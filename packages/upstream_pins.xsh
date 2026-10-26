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
