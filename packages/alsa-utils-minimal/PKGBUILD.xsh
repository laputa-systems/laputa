##! XSH module `PKGBUILD` package and build operations.
use pm.make
use pm.util as pm_util

## Exported declaration `name`.
export const name = "alsa-utils-minimal"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1.2.16"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl", "alsa-lib"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain"]

## alsactl's card initialization and alsaucm read the UCM profiles at run
## time; no tool reads them while building.
export const runtime_only_deps = ["alsa-ucm-conf"]

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
    path: p"usr/bin/alsaucm",
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
  {
    path: p"usr/bin/arecord",
    kind: "symlink",
  },
  {
    path: p"usr/bin/speaker-test",
    kind: "binary",
  },
  {
    path: p"usr/share/alsa/init",
    kind: "tree",
  },
  {
    path: p"usr/share/man/man1/alsactl.1",
    kind: "file",
  },
  {
    path: p"usr/share/man/man1/amixer.1",
    kind: "file",
  },
  {
    path: p"usr/share/man/man1/aplay.1",
    kind: "file",
  },
  {
    path: p"usr/share/man/man1/arecord.1",
    kind: "symlink",
  },
  {
    path: p"usr/share/man/man1/speaker-test.1",
    kind: "file",
  },
]

# Captured from upstream `./configure --prefix=/usr --disable-nls
# --disable-alsamixer --disable-bat --disable-alsaconf --disable-alsaloop
# --disable-nhlt --disable-xmlto --disable-rst2man --without-curses
# --with-alsactl-lock-dir=/run/lock --with-systemdsystemunitdir=no` against
# this alsa-lib on an x86_64 musl host with clang, reduced to the defines the
# built tools read. ENABLE_NLS stays undefined, so gettext.h maps every
# message to itself. The release tarball ships include/version.h.
proc write_aconfig_h() [fs, error] {
  p"include/aconfig.h".write(
    f"""#ifndef LAPUTA_ALSA_UTILS_ACONFIG_H
#define LAPUTA_ALSA_UTILS_ACONFIG_H

#define ALSA_TOPOLOGY_PLUGIN_DIR "/usr/lib/alsa-topology"
#define DATADIR "/usr/share/alsa"
#define HAVE_ALSA_MIXER_H 1
#define HAVE_ALSA_PCM_H 1
#define HAVE_ALSA_RAWMIDI_H 1
#define HAVE_ALSA_SEQ_H 1
#define HAVE_ALSA_TOPOLOGY_H 1
#define HAVE_ALSA_USE_CASE_H 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_DLFCN_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIBRT 1
#define HAVE_MALLOC_H 1
#define HAVE_MEMFD_CREATE 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define PACKAGE "alsa-utils"
#define PACKAGE_BUGREPORT ""
#define PACKAGE_NAME "alsa-utils"
#define PACKAGE_STRING "alsa-utils {ver}"
#define PACKAGE_TARNAME "alsa-utils"
#define PACKAGE_URL ""
#define PACKAGE_VERSION "{ver}"
#define SOUNDSDIR "/usr/share/sounds/alsa"
#define STDC_HEADERS 1
#define VERSION "{ver}"

#endif
""",
  )
}

# The minimal set is playback and capture (aplay, with arecord as its other
# name), the mixer CLI (amixer), card state save/restore/init (alsactl), the
# UCM CLI (alsaucm), and speaker-test. alsamixer needs ncurses and alsabat
# needs fftw; the sequencer, MIDI, IEC958, loop, and topology tools, and the
# udev rule (it runs /bin/sh) and systemd units, are left out. The sources and
# per-tool flags come from each tool's Makefile.am.
type AlsaTool = {name: Str, sources: List[Str], cflags: List[Str]}

pure alsa_tools() -> List[AlsaTool] {
  [
    {
      name: "aplay",
      sources: [
        "aplay/aplay.c",
      ],
      cflags: [],
    },
    {
      name: "amixer",
      sources: [
        "amixer/amixer.c",
        "amixer/volume_mapping.c",
      ],
      cflags: [
        "-D_GNU_SOURCE",
      ],
    },
    {
      name: "alsactl",
      sources: [
        f"alsactl/{source}"
        for source in """
alsactl.c state.c lock.c utils.c wait.c init_parse.c init_ucm.c
boot_params.c daemon.c monitor.c clean.c info.c export.c
""".words()
      ],
      cflags: [
        "-D_GNU_SOURCE",
        "-D__USE_GNU",
        "-DSYS_ASOUNDRC=\"/var/lib/alsa/asound.state\"",
        "-DSYS_LOCKPATH=\"/run/lock\"",
        "-DSYS_LOCKFILE=\"asound.state.lock\"",
        "-DSYS_PIDFILE=\"/var/run/alsactl.pid\"",
      ],
    },
    {
      name: "alsaucm",
      sources: [
        "alsaucm/usecase.c",
        "alsaucm/dump.c",
      ],
      cflags: [
        "-Wall",
      ],
    },
    {
      name: "speaker-test",
      sources: [
        "speaker-test/speaker-test.c",
        "speaker-test/pink.c",
        "speaker-test/st2095.c",
      ],
      cflags: [],
    },
  ]
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let triple = f"{pm_util.target_arch()?}-linux-musl"
  write_aconfig_h()

  # Upstream links -lasound -lrt -lm -lpthread; musl's libc holds the last
  # three.
  var tasks = []
  var outputs: Map[Path] = {}

  for tool in alsa_tools() {
    let target = make.c_program({
      cc,
      triple,
      cflags: ["-O2", "-DHAVE_CONFIG_H", "-Iinclude", @tool.cflags],
      defs: [],
      includes: [],
      root: p".",
      sources: [fp"{source}" for source in tool.sources],
      out_dir: fp"obj/{tool.name}",
      out: fp"obj/bin/{tool.name}",
      libs: [],
      ldflags: ["-lasound"],
      deps: [],
    })

    tasks = [@tasks, @target.tasks]
    outputs[tool.name] = target.output
  }

  make.run_tasks(tasks, make.jobs()?)

  for tool in alsa_tools() {
    fs.install(outputs[tool.name], fp"{dest}/usr/bin/{tool.name}", 0o755, parents: true, overwrite: true)
  }

  fp"{dest}/usr/bin/arecord".symlink(to: p"aplay")

  # alsactl init reads its card database from DATADIR/init; `alsactl store`
  # writes SYS_ASOUNDRC, whose directory it does not create.
  for init in "00main ca0106 default hda help info test".words() {
    fs.install(fp"alsactl/init/{init}", fp"{dest}/usr/share/alsa/init/{init}", 0o644, parents: true, overwrite: true)
  }

  fp"{dest}/var/lib/alsa".mkdir()

  for page in [p"aplay/aplay.1", p"amixer/amixer.1", p"alsactl/alsactl.1", p"speaker-test/speaker-test.1"] {
    fs.install(page, fp"{dest}/usr/share/man/man1/{page.name}", 0o644, parents: true, overwrite: true)
  }

  fp"{dest}/usr/share/man/man1/arecord.1".symlink(to: p"aplay.1")
}
