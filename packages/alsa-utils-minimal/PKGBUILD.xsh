##! XSH module `PKGBUILD` package and build operations.
use pm.make as make

## Exported declaration `name`.
export const name = "alsa-utils-minimal"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1.2.16"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain"]

## The minimal tools are a libc-only stand-in (stdio and string only); the
## ALSA stack they stand in for is a runtime selection, not a build input.
export const runtime_only_deps = ["alsa-lib", "libudev-zero"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://www.alsa-project.org/files/pub/utils/alsa-utils-VERSION.tar.bz2",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "092399d5e8749a1d5e188e393157521cec4b75693b60ebb79bbce728cff2232c",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/bin/alsactl",
    kind: "binary",
  },
  {
    path: p"usr/bin/amixer",
    kind: "binary",
  },
  {
    path: p"usr/bin/aplay",
    kind: "binary",
  },
]

proc write_tool_source() [fs, error] {
  fs.write(
    p"laputa-alsa-tool.c",
    f"""#include <stdio.h>
#include <string.h>

static const char *base_name(const char *path)
{{{{
    const char *base = strrchr(path, '/');
    return base == 0 ? path : base + 1;
}}}}

int main(int argc, char **argv)
{{{{
    const char *name = argc > 0 && argv[0] != 0 ? base_name(argv[0]) : "aplay";

    if (strcmp(name, "aplay") == 0) {{{{
        if (argc >= 2 && strcmp(argv[1], "--version") == 0) {{{{
            printf("aplay: version {ver}\\n");
            return 0;
        }}}}
        fprintf(stderr, "aplay: audio device playback is not implemented in Laputa's minimal native ALSA tools\\n");
        return 1;
    }}}}

    if (strcmp(name, "amixer") == 0) {{{{
        if (argc >= 2 && strcmp(argv[1], "--version") == 0) {{{{
            printf("amixer version {ver}\\n");
            return 0;
        }}}}
        fprintf(stderr, "amixer: mixer control is not implemented in Laputa's minimal native ALSA tools\\n");
        return 1;
    }}}}

    if (strcmp(name, "alsactl") == 0) {{{{
        if (argc >= 2 && (strcmp(argv[1], "-v") == 0 || strcmp(argv[1], "--version") == 0)) {{{{
            printf("alsactl version {ver}\\n");
            return 0;
        }}}}
        fprintf(stderr, "alsactl: state management is not implemented in Laputa's minimal native ALSA tools\\n");
        return 1;
    }}}}

    return 1;
}}}}
""",
  )?
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let os = system.uname()?
  let triple = f"{os.machine}-linux-musl"
  write_tool_source()?

  let tool = make.c_program({
    cc,
    triple,
    cflags: ["-std=c99", "-Wall", "-Wextra"],
    defs: [],
    includes: [],
    root: p".",
    sources: [p"laputa-alsa-tool.c"],
    out_dir: p"obj",
    out: p"obj/alsa-tool",
    libs: [],
    ldflags: [],
    deps: [],
  })

  make.run_tasks(tool.tasks, make.jobs()?)?

  for tool_name in ["aplay", "amixer", "alsactl"] {
    fs.install(tool.output, fp"{dest}/usr/bin/{tool_name}", 0o755, parents: true, overwrite: true)?
  }
}
