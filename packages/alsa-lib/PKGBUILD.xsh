##! XSH module `PKGBUILD` package and build operations.
use pm.make as make
use pm.util as pm_util

## Exported declaration `name`.
export const name = "alsa-lib"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1.2.16.1"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl"]

## The library's private copy of the sound uapi headers includes
## linux/types.h and linux/ioctl.h.
export const mkdeps_host = ["llvm-toolchain", "linux-headers"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://www.alsa-project.org/files/pub/lib/alsa-lib-VERSION.tar.bz2",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "f740db7f488255944ffd4428416ee3390a96742856916433df468c281436480e",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/include/alsa",
    kind: "tree",
  },
  {
    path: p"usr/include/asoundlib.h",
    kind: "file",
  },
  {
    path: p"usr/include/sys/asoundlib.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libasound.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libasound.so.2",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libasound.so.2.0.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/libatopology.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libatopology.so.2",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libatopology.so.2.0.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/alsa-topology.pc",
    kind: "file",
  },
  {
    path: p"usr/lib/pkgconfig/alsa.pc",
    kind: "file",
  },
  {
    path: p"usr/share/alsa",
    kind: "tree",
  },
]

# Captured from upstream `./configure --prefix=/usr --disable-python
# --disable-static --disable-resmgr --enable-rawmidi --enable-seq
# --enable-aload --disable-dependency-tracking --without-versioned` (Alpine's
# options) on an x86_64 musl host with clang, reduced to the defines the
# sources read. Every PCM, control, mixer, rawmidi, hwdep, seq, UCM, and
# topology component is on. The release tarball already ships the
# configure-generated include/asoundlib.h and include/version.h, and the
# generated plugin symbol lists only matter to static (non-PIC) builds.
# HAVE_MMX is configure's x86 probe for the dmix mixing assembly; aarch64
# fails that probe, so the define follows the target.
proc write_config_h() [fs, error] {
  fs.write(
    p"include/config.h",
    f"""#ifndef LAPUTA_ALSA_LIB_CONFIG_H
#define LAPUTA_ALSA_LIB_CONFIG_H

#ifndef _GNU_SOURCE
# define _GNU_SOURCE 1
#endif

#define ALOAD_DEVICE_DIRECTORY "/dev/"
#define ALSA_CONFIG_DIR "/usr/share/alsa"
#define ALSA_DEVICE_DIRECTORY "/dev/snd/"
#define ALSA_PKGCONF_DIR "/usr/lib/pkgconfig"
#define ALSA_PLUGIN_DIR "/usr/lib/alsa-lib"
#define BUILD_HWDEP "1"
#define BUILD_MIXER "1"
#define BUILD_PCM "1"
#define BUILD_PCM_PLUGIN_ADPCM "1"
#define BUILD_PCM_PLUGIN_ALAW "1"
#define BUILD_PCM_PLUGIN_IEC958 "1"
#define BUILD_PCM_PLUGIN_LFLOAT "1"
#define BUILD_PCM_PLUGIN_MMAP_EMUL "1"
#define BUILD_PCM_PLUGIN_MULAW "1"
#define BUILD_PCM_PLUGIN_RATE "1"
#define BUILD_PCM_PLUGIN_ROUTE "1"
#define BUILD_RAWMIDI "1"
#define BUILD_SEQ "1"
#define BUILD_TOPOLOGY "1"
#define BUILD_UCM "1"
#define HAVE_ATTRIBUTE_SYMVER 0
#define HAVE_CLOCK_GETTIME 1
#define HAVE_DECL_CLOSEFROM 0
#define HAVE_DLFCN_H 1
#define HAVE_EACCESS 1
#define HAVE_ENDIAN_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIBDL 1
#define HAVE_LIBPTHREAD 1
#define HAVE_LIBRT 1
#define HAVE_MALLOC_H 1
#if defined(__i386__) || defined(__x86_64__)
#define HAVE_MMX "1"
#endif
#define HAVE_PTHREAD_MUTEX_RECURSIVE /**/
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_SHM_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_USELOCALE 1
#define HAVE_WCHAR_H 1
#define HAVE___THREAD 1
#define PACKAGE "alsa-lib"
#define PACKAGE_BUGREPORT ""
#define PACKAGE_NAME "alsa-lib"
#define PACKAGE_STRING "alsa-lib {ver}"
#define PACKAGE_TARNAME "alsa-lib"
#define PACKAGE_URL ""
#define PACKAGE_VERSION "{ver}"
#define SND_MAX_CARDS 32
#define STDC_HEADERS 1
#define SUPPORT_ALOAD "1"
#define THREAD_SAFE_API "1"
#define TMPDIR "/tmp"
#define VERSION "{ver}"
#define __SYMBOL_PREFIX ""

#endif
""",
  )?
}

# src/Makefile.am libasound_la_SOURCES plus each component's convenience
# library (control, mixer, pcm, timer, rawmidi, hwdep, seq, ucm), in the
# order the captured libtool link names them.
pure libasound_sources() -> List[Path] {
  let core = """
conf.c confeval.c confmisc.c input.c output.c async.c error.c dlmisc.c
socket.c shmarea.c userfile.c names.c
""".words()

  let control = """
cards.c tlv.c eld.c namehint.c hcontrol.c control.c control_hw.c
control_empty.c setup.c ctlparse.c control_plugin.c control_symbols.c
control_remap.c control_shm.c control_ext.c
""".words()

  let mixer = "bag.c mixer.c simple.c simple_none.c simple_abst.c".words()

  let pcm = """
mask.c interval.c pcm.c pcm_params.c pcm_simple.c pcm_hw.c pcm_misc.c
pcm_mmap.c pcm_symbols.c pcm_generic.c pcm_plugin.c pcm_copy.c pcm_linear.c
pcm_route.c pcm_mulaw.c pcm_alaw.c pcm_adpcm.c pcm_rate.c pcm_rate_linear.c
pcm_plug.c pcm_multi.c pcm_shm.c pcm_file.c pcm_null.c pcm_empty.c
pcm_share.c pcm_meter.c pcm_hooks.c pcm_lfloat.c pcm_ladspa.c pcm_dmix.c
pcm_dshare.c pcm_dsnoop.c pcm_direct.c pcm_asym.c pcm_iec958.c pcm_softvol.c
pcm_extplug.c pcm_ioplug.c pcm_mmap_emul.c
""".words()

  let timer = "timer.c timer_hw.c timer_query.c timer_query_hw.c timer_symbols.c".words()
  let rawmidi = "rawmidi.c rawmidi_hw.c rawmidi_symbols.c ump.c rawmidi_virt.c".words()
  let hwdep = "hwdep.c hwdep_hw.c hwdep_symbols.c".words()
  let seq = "seq_hw.c seq.c seq_event.c seqmid.c seq_midi_event.c seq_symbols.c seq_old.c".words()

  let ucm = """
utils.c parser.c ucm_cond.c ucm_subs.c ucm_include.c ucm_regex.c
ucm_repeat.c ucm_exec.c main.c
""".words()

  [
    @[fp"src/{source}" for source in core],
    @[fp"src/control/{source}" for source in control],
    @[fp"src/mixer/{source}" for source in mixer],
    @[fp"src/pcm/{source}" for source in pcm],
    @[fp"src/timer/{source}" for source in timer],
    @[fp"src/rawmidi/{source}" for source in rawmidi],
    @[fp"src/hwdep/{source}" for source in hwdep],
    @[fp"src/seq/{source}" for source in seq],
    @[fp"src/ucm/{source}" for source in ucm],
  ]
}

# src/topology/Makefile.am libatopology_la_SOURCES.
pure libatopology_sources() -> List[Path] {
  let sources = """
parser.c builder.c ctl.c dapm.c pcm.c data.c text.c channel.c ops.c elem.c
save.c decoder.c log.c
""".words()

  [fp"src/topology/{source}" for source in sources]
}

# include/Makefile.am alsainclude_HEADERS with every component enabled, and
# the installed halves of include/sound and include/sound/uapi (asound.h and
# asequencer.h stay private).
pure alsa_headers() -> List[Str] {
  """
asoundlib.h asoundef.h version.h global.h input.h output.h error.h conf.h
control.h control_plugin.h control_external.h pcm.h pcm_old.h timer.h
pcm_plugin.h pcm_rate.h pcm_external.h pcm_extplug.h pcm_ioplug.h rawmidi.h
ump.h ump_msg.h hwdep.h mixer.h mixer_abst.h seq_event.h seq.h seqmid.h
seq_midi_event.h use-case.h topology.h
""".words()
}

pure sound_headers() -> List[Str] {
  "asound_fm.h hdsp.h hdspm.h sb16_csp.h sscape_ioctl.h emu10k1.h asoc.h tlv.h".words()
}

proc install_headers(dest: Path) [fs, error] {
  let inc = fp"{dest}/usr/include"

  for header in alsa_headers() {
    fs.install(fp"include/{header}", fp"{inc}/alsa/{header}", 0o644, parents: true, overwrite: true)?
  }

  for header in [@sound_headers(), "type_compat.h"] {
    fs.install(fp"include/sound/{header}", fp"{inc}/alsa/sound/{header}", 0o644, parents: true, overwrite: true)?
  }

  for header in sound_headers() {
    fs.install(fp"include/sound/uapi/{header}", fp"{inc}/alsa/sound/uapi/{header}", 0o644, parents: true, overwrite: true)?
  }

  # include/Makefile.am's install-data-hook: deprecated forwarding headers.
  fs.install(p"include/sys.h", fp"{inc}/asoundlib.h", 0o644, parents: true, overwrite: true)?
  fs.install(p"include/sys.h", fp"{inc}/sys/asoundlib.h", 0o644, parents: true, overwrite: true)?
}

# utils/alsa.pc.in and utils/alsa-topology.pc.in as configure fills them.
proc install_pkg_config(dest: Path) [fs, error] {
  fs.mkdir(fp"{dest}/usr/lib/pkgconfig")?

  fs.write(
    fp"{dest}/usr/lib/pkgconfig/alsa.pc",
    f"""prefix=/usr
exec_prefix=${{prefix}}
libdir=${{exec_prefix}}/lib
includedir=${{prefix}}/include

Name: alsa
Description: Advanced Linux Sound Architecture (ALSA) - Library
Version: {ver}
Requires:
Libs: -L${{libdir}} -lasound
Libs.private: -lm -lpthread -lrt
Cflags: -I${{includedir}}
""",
  )?

  fs.write(
    fp"{dest}/usr/lib/pkgconfig/alsa-topology.pc",
    f"""prefix=/usr
exec_prefix=${{prefix}}
libdir=${{exec_prefix}}/lib
includedir=${{prefix}}/include

Name: alsa-topology
Description: Advanced Linux Sound Architecture (ALSA) - Topology Library
Version: {ver}
Requires: alsa >= {ver}
Libs: -L${{libdir}} -latopology
Cflags: -I${{includedir}}
""",
  )?
}

# src/conf and its cards, ctl, and pcm subdirectories install every .conf
# file under ALSA_CONFIG_DIR with the same layout.
proc install_config_tree(dest: Path) [fs, error] {
  let conf_root = path.absolute(p"src/conf")?

  for entry in fs.walk(conf_root, gitignore: false)? {
    continue unless entry.kind == "file" and entry.ext == "conf"
    let rel = entry.path.relative_to(conf_root)
    fs.install(entry.path, fp"{dest}/usr/share/alsa/{rel}", 0o644, parents: true, overwrite: true)?
  }
}

proc install_library(output: Path, dest: Path, stem: Str) [fs, error] {
  fs.install(output, fp"{dest}/usr/lib/{stem}.so.2.0.0", 0o755, parents: true, overwrite: true)?
  fs.symlink(fp"{stem}.so.2.0.0", fp"{dest}/usr/lib/{stem}.so.2")?
  fs.symlink(fp"{stem}.so.2.0.0", fp"{dest}/usr/lib/{stem}.so")?
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let triple = f"{pm_util.target_arch()?}-linux-musl"
  write_config_h()?

  # src/*/Makefile.am compile every object with -I. -I$(top_srcdir)/include
  # and DEFS=-DHAVE_CONFIG_H; include/alsa is upstream's link back to include,
  # so <alsa/...> resolves inside the tree.
  let cflags = ["-O2", "-DHAVE_CONFIG_H", "-Iinclude"]
  # Upstream links -lm -lpthread -lrt -ldl; musl's libc holds all four, so
  # -z defs alone proves every reference resolves and no empty DT_NEEDED
  # entries are recorded.
  let libasound = make.c_shared_library({
    cc,
    triple,
    cflags,
    defs: [],
    includes: [],
    root: p".",
    sources: libasound_sources(),
    out_dir: p"obj/asound",
    out: p"obj/libasound.so.2.0.0",
    soname: "libasound.so.2",
    ldflags: ["-Wl,-z,defs"],
    deps: [],
  })

  let topology = make.compile_lo_tasks(cc, triple, cflags, [], [], p".", libatopology_sources(), p"obj/atopology")

  let topology_link = make.link_shared_task(
    cc,
    triple,
    topology.objects,
    "libatopology.so.2",
    ["-Wl,-z,defs", libasound.output.display()],
    p"obj/libatopology.so.2.0.0",
    [@topology.deps, make.task_deps(libasound.tasks, [libasound.output])[0]],
  )

  make.run_tasks([@libasound.tasks, @topology.tasks, topology_link], make.jobs()?)?
  install_library(libasound.output, dest, "libasound")?
  install_library(topology_link.outputs[0], dest, "libatopology")?
  install_headers(dest)?
  install_pkg_config(dest)?
  install_config_tree(dest)?
}
