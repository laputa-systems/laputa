##! Package recipe for the supervised timer scheduler.
## Package name.
export const name = "laputa-timers"

## Payload package.
export const package_kind = "payload"

## Package version.
export const ver = "1"

## Package release.
export const rel = "1"

## Runtime packages are provided by the image roots.
export let deps = []

## The scheduler is XSH and is owned by xinit.
export const runtime_only_deps = ["xinit", "xsh"]

## No host build tools.
export let mkdeps_host = []

## The scheduler and its xinit entry point live in this checkout.
export const upstream_sources = [
  {
    source: p"repository/system/timers.xsh",
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
    source: p"run.xsh",
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
]

## The scheduler, its entry point, the xinit service, and the job directory.
export const filetree = [
  {
    path: p"usr/lib/laputa/timers.xsh",
    kind: "file",
  },
  {
    path: p"usr/lib/laputa/timers-run.xsh",
    kind: "file",
  },
  {
    path: p"usr/lib/xinit/services/laputa-timers.xsh",
    kind: "file",
  },
  {
    path: p"usr/lib/laputa/lib/monotonic.xsh",
    kind: "symlink",
  },
  {
    path: p"etc/laputa/timers/jobs.d",
    kind: "tree",
  },
]

## Install the scheduler, its entry point, and the service module.
export proc build(dest: Path) [fs, error] {
  fs.install(p"timers.xsh", fp"{dest}/usr/lib/laputa/timers.xsh", 0o644, parents: true, overwrite: true)
  fs.install(p"run.xsh", fp"{dest}/usr/lib/laputa/timers-run.xsh", 0o755, parents: true, overwrite: true)
  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/laputa-timers.xsh", 0o644, parents: true, overwrite: true)
  fp"{dest}/usr/lib/laputa/lib".mkdir()
  fp"{dest}/etc/laputa/timers/jobs.d".mkdir()
  fp"{dest}/usr/lib/laputa/lib/monotonic.xsh".symlink(to: p"../../xsh/core/lib/monotonic.xsh")
}
