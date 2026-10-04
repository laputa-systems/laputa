##! perf, the Linux performance tool, built from the kernel tarball's tools/perf.
use pm.make as make
use pm.util as pm_util

error PerfBuildError = UnsupportedArch(message: Str) | MissingKernelVersion(message: Str)

## Package recipe export.
export const name = "perf"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## The kernel release whose tools/perf this is; `perf --version` reports it.
export const ver = "7.2.9"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## perf includes the kernel UAPI headers (<linux/...>, <asm/...>) beside the
## tree's own tools/include copies.
export const mkdeps_host = ["llvm-toolchain", "linux-headers"]

# Everything under files/generated/ is what the upstream build generates into
# its output directory; each file stages into `build/` at the same relative
# path. Regenerate on a host from a pristine linux-7.2.9 tree T with bison
# 3.8.2 and flex 2.6.4 (the Laputa versions): copy util/{parse-events,pmu,
# expr}.{y,l} from T/tools/perf into util/ of an empty directory G, and in G run
#   bison util/parse-events.y -d -o util/parse-events-bison.c -p parse_events_
#   bison util/pmu.y -d -o util/pmu-bison.c -p perf_pmu_
#   bison util/expr.y -d -o util/expr-bison.c -p expr_
#   flex -o util/parse-events-flex.c --header-file=util/parse-events-flex.h util/parse-events.l
#   flex -o util/pmu-flex.c --header-file=util/pmu-flex.h util/pmu.l
#   flex -o util/expr-flex.c --header-file=util/expr-flex.h util/expr.l
#   awk -f T/tools/arch/x86/tools/gen-insn-attr-x86.awk T/tools/arch/x86/lib/x86-opcode-map.txt > util/intel-pt-decoder/inat-tables.c
#   awk -f T/arch/arm64/tools/gen-sysreg.awk T/arch/arm64/tools/sysreg > arch/arm64/include/generated/asm/sysreg-defs.h
# then delete the .y and .l copies, and from T/tools/perf run
#   sh trace/beauty/arch_errno_names.sh clang T/tools > G/trace/beauty/generated/arch_errno_name_array.c
#   sh trace/beauty/syscalltbl.sh T/tools G/trace/beauty/generated/syscalltbl.c
# The syscall and errno tables cover every architecture behind #ifdefs, and
# arm-spe decoding needs the arm64 sysreg header on every architecture, so one
# set serves both targets.
## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.9.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "b4c5dfbe51a364a6c7f03869200f88c8e1f77403539005f14b7fc6bc91b8d8ba",
      },
    ],
  },
  {
    source: p"files/generated/arch/arm64/include/generated/asm/sysreg-defs.h => build/arch/arm64/include/generated/asm",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "30a702fcb9e77bbe2d2e699f8b8f1986f2e42b362115723faf508087505fd422",
      },
    ],
  },
  {
    source: p"files/generated/trace/beauty/generated/arch_errno_name_array.c => build/trace/beauty/generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "b319913743c664a62f5360c3208ece57bd9642ab19390e73058dd5d6fa40b00c",
      },
    ],
  },
  {
    source: p"files/generated/trace/beauty/generated/syscalltbl.c => build/trace/beauty/generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "6754019c2e397cef7d0cd9348fa8cefe8ac485811926f0dbd3c264c0037b565d",
      },
    ],
  },
  {
    source: p"files/generated/util/expr-bison.c => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "11ca9437cc867d8320f0cf15604900144ce03245676c35baa2f4cc134076296b",
      },
    ],
  },
  {
    source: p"files/generated/util/expr-bison.h => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "af2f51c9ebb7c5eef21eede7ad2d76dee9a6ef256769b2b1321d8230e2183ebd",
      },
    ],
  },
  {
    source: p"files/generated/util/expr-flex.c => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "d831d80ccfc266867efbf6e137d70e0dd211e780edd92102b0545e7f63463791",
      },
    ],
  },
  {
    source: p"files/generated/util/expr-flex.h => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "5241b61c61afe048dc12d4401f3be02dfd8a35dad34156f4c557b006d869f4c6",
      },
    ],
  },
  {
    source: p"files/generated/util/intel-pt-decoder/inat-tables.c => build/util/intel-pt-decoder",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "5bc098c57c3bfaa8d3fbd05f6d7703c5573417431a48160a194961e7cf334525",
      },
    ],
  },
  {
    source: p"files/generated/util/parse-events-bison.c => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "c3b085dec7c6688d33a1981da3116b1ac9c1f8a8b8d125121eee767d2ae69d55",
      },
    ],
  },
  {
    source: p"files/generated/util/parse-events-bison.h => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "2a397a414e415718068049ce9c89e819c7508bcb2cc92c2e383dba667fa866ff",
      },
    ],
  },
  {
    source: p"files/generated/util/parse-events-flex.c => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "eb9a43f4e5159cbc7c1aa082660db53e52d6bd7845ff2fd3bc2bf3f027e755d7",
      },
    ],
  },
  {
    source: p"files/generated/util/parse-events-flex.h => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "b061cace5ffc5ab29d697343c9a08659dfcd2a83a9298c1758aedf0a4b7b08b2",
      },
    ],
  },
  {
    source: p"files/generated/util/pmu-bison.c => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "f02df9f43a0bd09692052e799b73081c30e47a23c1cad240a13aab68472433ed",
      },
    ],
  },
  {
    source: p"files/generated/util/pmu-bison.h => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "ceb19e46d0c6336dac57adf993f3c79566f43b1b8fb6475c7cf91d1b6fa64c48",
      },
    ],
  },
  {
    source: p"files/generated/util/pmu-flex.c => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "f35a8e2e107634a2c227ba239fbd9fb7637e881088aa1454a36eb1f861213b09",
      },
    ],
  },
  {
    source: p"files/generated/util/pmu-flex.h => build/util",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "ee9cd9e97c08bd10213f2ed532fe3946284331439aabe59a30cc0050a6fd23d6",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {path: p"usr/bin/perf", kind: "binary"},
  {path: p"usr/share/doc/perf-tip/tips.txt", kind: "file"},
]

# The upstream output directory: generated inputs stage here, the libraries'
# public headers install here, and every object lands here.
const out = "build"

# One compiled unit: its object path under `build/` and its source path from
# the tree root.
type PerfUnit = {obj: Str, src: Str}

# What differs between architectures: the kernel's name for the architecture,
# the defines it adds, and its tools/perf sources.
type PerfArch = {srcarch: Str, defs: List[Str], sources: List[Str]}

# A library's public headers, copied from `src` to `build/<dest>` the way its
# Makefile's install_headers does; perf includes them from there.
type HeaderSet = {src: Str, dest: Str, names: List[Str]}

# The object lists below transcribe a host run of the upstream build
# (`make -C tools/perf V=1 prefix=/usr`, ARCH=x86_64 and ARCH=arm64) with
# NO_LIBELF NO_LIBTRACEEVENT NO_JEVENTS NO_LIBPYTHON NO_SLANG NO_LIBNUMA
# NO_LIBBABELTRACE NO_ZLIB NO_LZMA NO_LIBZSTD NO_LIBPFM4 NO_SDT NO_LIBLLVM
# NO_CAPSTONE NO_DEMANGLE NO_RUST NO_LIBDEBUGINFOD NO_AIO and BUILD_BPF_SKEL=0:
# perf then links only musl. The upstream build links the same objects through
# nested `ld -r` objects and --whole-archive libraries; linking them directly
# is equivalent. The dlfilter examples, the shell scripts (perf-archive,
# perf-iostat, tests/shell), and the documentation are not built.
proc perf_sources() [] -> List[Str] {
  """
perf.c builtin-annotate.c builtin-bench.c builtin-buildid-cache.c
builtin-buildid-list.c builtin-c2c.c builtin-check.c builtin-config.c
builtin-daemon.c builtin-data.c builtin-diff.c builtin-evlist.c
builtin-ftrace.c builtin-help.c builtin-inject.c builtin-kallsyms.c
builtin-kvm.c builtin-list.c builtin-mem.c builtin-record.c builtin-report.c
builtin-script.c builtin-stat.c builtin-top.c builtin-version.c
arch/common.c
bench/breakpoint.c bench/epoll-ctl.c bench/epoll-wait.c
bench/evlist-open-close.c bench/find-bit-bench.c bench/futex-hash.c
bench/futex-lock-pi.c bench/futex-requeue.c bench/futex-wake-parallel.c
bench/futex-wake.c bench/futex.c bench/inject-buildid.c bench/kallsyms-parse.c
bench/mem-functions.c bench/pmu-scan.c bench/sched-messaging.c
bench/sched-pipe.c bench/sched-seccomp-notify.c bench/synthesize.c
bench/syscall.c bench/uprobe.c
tests/api-io.c tests/backward-ring-buffer.c
tests/bitmap.c tests/bp_account.c tests/bp_signal.c tests/bp_signal_overflow.c
tests/builtin-test.c tests/code-reading.c tests/cpumap.c
tests/demangle-java-test.c tests/demangle-ocaml-test.c
tests/demangle-rust-v0-test.c tests/dlfilter-test.c tests/dso-data.c
tests/event-times.c tests/event_groups.c tests/event_update.c
tests/evsel-roundtrip-name.c tests/expand-cgroup.c tests/expr.c
tests/fdarray.c tests/genelf.c tests/hists_common.c tests/hists_cumulate.c
tests/hists_filter.c tests/hists_link.c tests/hists_output.c tests/hwmon_pmu.c
tests/is_printable_array.c tests/kallsyms-split.c tests/keep-tracking.c
tests/kmod-path.c tests/maps.c tests/mem.c tests/mem2node.c tests/mmap-basic.c
tests/mmap-thread-lookup.c tests/openat-syscall-all-cpus.c
tests/openat-syscall.c tests/parse-events.c tests/parse-metric.c
tests/parse-no-sample-id-all.c tests/pe-file-parsing.c tests/perf-hooks.c
tests/perf-record.c tests/perf-time-to-tsc.c tests/pfm.c tests/pmu-events.c
tests/pmu.c tests/sample-parsing.c tests/sdt.c tests/sigtrap.c tests/stat.c
tests/subcmd-help.c tests/sw-clock.c tests/symbols.c tests/task-exit.c
tests/tests-scripts.c tests/thread-map.c tests/thread-maps-share.c
tests/time-utils-test.c tests/tool_pmu.c tests/topology.c
tests/uncore-event-sorting.c tests/unit_number__scnprintf.c tests/util.c
tests/vmlinux-kallsyms.c tests/wp.c
tests/workloads/brstack.c tests/workloads/context_switch_loop.c
tests/workloads/datasym.c tests/workloads/deterministic.c
tests/workloads/inlineloop.c tests/workloads/jitdump.c
tests/workloads/landlock.c tests/workloads/leafloop.c
tests/workloads/named_threads.c tests/workloads/noploop.c
tests/workloads/sqrtloop.c tests/workloads/thloop.c tests/workloads/traploop.c
trace/beauty/arch_errno_names.c trace/beauty/syscalltbl.c
ui/helpline.c ui/hist.c ui/progress.c ui/setup.c ui/stdio/hist.c ui/util.c
util/addr2line.c util/addr_location.c
util/affinity.c util/amd-sample-raw.c util/annotate-arch/annotate-arc.c
util/annotate-arch/annotate-arm.c util/annotate-arch/annotate-arm64.c
util/annotate-arch/annotate-csky.c util/annotate-arch/annotate-loongarch.c
util/annotate-arch/annotate-mips.c util/annotate-arch/annotate-powerpc.c
util/annotate-arch/annotate-riscv64.c util/annotate-arch/annotate-s390.c
util/annotate-arch/annotate-sparc.c util/annotate-arch/annotate-x86.c
util/annotate.c util/arm-spe-decoder/arm-spe-decoder.c
util/arm-spe-decoder/arm-spe-pkt-decoder.c util/arm-spe.c
util/arm64-frame-pointer-unwind-support.c util/aslr.c util/auxtrace.c
util/blake2s.c util/block-info.c util/block-range.c util/branch.c
util/build-id.c util/cacheline.c util/call-path.c util/callchain.c util/cap.c
util/cgroup.c util/clockid.c util/cloexec.c util/color.c util/color_config.c
util/comm.c util/config.c util/copyfile.c util/counts.c util/cpumap.c
util/cputopo.c util/cs-etm-base.c util/data-convert-json.c util/data.c
util/db-export.c util/debug.c util/demangle-java.c util/demangle-ocaml.c
util/demangle-rust-v0.c util/disasm.c util/dlfilter.c util/drm_pmu.c
util/dso.c util/dsos.c util/env.c util/event.c util/evlist.c util/evsel.c
util/evsel_fprintf.c util/evswitch.c util/expr.c util/fncache.c util/hashmap.c
util/header.c util/help-unknown-cmd.c
util/hisi-ptt-decoder/hisi-ptt-pkt-decoder.c util/hisi-ptt.c util/hist.c
util/hwmon_pmu.c util/intel-bts.c util/intel-pt-decoder/intel-pt-decoder.c
util/intel-pt-decoder/intel-pt-insn-decoder.c
util/intel-pt-decoder/intel-pt-log.c
util/intel-pt-decoder/intel-pt-pkt-decoder.c util/intel-pt.c
util/intel-tpebs.c util/intlist.c util/iostat.c util/levenshtein.c util/llvm.c
util/lock-contention.c util/machine.c util/map.c util/map_symbol.c util/maps.c
util/mem-events.c util/mem-info.c util/mem2node.c util/memswap.c
util/metricgroup.c util/mmap.c util/mutex.c util/namespaces.c
util/ordered-events.c util/parse-branch-options.c util/parse-events.c
util/parse-regs-options.c util/parse-sublevel-options.c util/path.c
util/perf-hooks.c util/perf-regs-arch/perf_regs_aarch64.c
util/perf-regs-arch/perf_regs_arm.c util/perf-regs-arch/perf_regs_csky.c
util/perf-regs-arch/perf_regs_loongarch.c util/perf-regs-arch/perf_regs_mips.c
util/perf-regs-arch/perf_regs_powerpc.c util/perf-regs-arch/perf_regs_riscv.c
util/perf-regs-arch/perf_regs_s390.c util/perf-regs-arch/perf_regs_x86.c
util/perf_api_probe.c util/perf_event_attr_fprintf.c util/perf_regs.c
util/pmu.c util/pmus.c util/powerpc-vpadtl.c util/print-events.c
util/print_binary.c util/print_insn.c util/pstack.c util/rblist.c
util/record.c util/rlimit.c util/rwsem.c util/s390-cpumsf.c
util/s390-sample-raw.c util/sample-raw.c util/sample.c util/session.c
util/sharded_mutex.c util/sideband_evlist.c util/smt.c util/sort.c
util/spark.c util/srccode.c util/srcline.c util/stat-display.c
util/stat-shadow.c util/stat.c util/strbuf.c util/stream.c util/strfilter.c
util/string.c util/strlist.c util/svghelper.c util/symbol-minimal.c
util/symbol.c util/symbol_fprintf.c util/synthetic-events.c util/target.c
util/term.c util/thread-stack.c util/thread.c util/thread_map.c util/threads.c
util/time-utils.c util/tool.c util/tool_pmu.c util/top.c util/topdown.c
util/tp_pmu.c util/trace-event-info.c util/trace-event-scripting.c
util/tracepoint.c util/tsc.c util/units.c util/unwind.c util/usage.c
util/util.c util/values.c util/vdso.c
""".words()
}

# perf objects whose source is outside tools/perf, generated, or renamed.
const perf_moved_units: List[PerfUnit] = [
  {obj: "pmu-events/pmu-events.o", src: "tools/perf/pmu-events/empty-pmu-events.c"},
  {obj: "util/argv_split.o", src: "tools/lib/argv_split.c"},
  {obj: "util/bitmap.o", src: "tools/lib/bitmap.c"},
  {obj: "util/ctype.o", src: "tools/lib/ctype.c"},
  {obj: "util/find_bit.o", src: "tools/lib/find_bit.c"},
  {obj: "util/hweight.o", src: "tools/lib/hweight.c"},
  {obj: "util/libstring.o", src: "tools/lib/string.c"},
  {obj: "util/list_sort.o", src: "tools/lib/list_sort.c"},
  {obj: "util/rbtree.o", src: "tools/lib/rbtree.c"},
  {obj: "util/vsprintf.o", src: "tools/lib/vsprintf.c"},
  {obj: "util/intel-pt-decoder/inat.o", src: "tools/arch/x86/lib/inat.c"},
  {obj: "util/intel-pt-decoder/insn.o", src: "tools/arch/x86/lib/insn.c"},
  {obj: "util/expr-bison.o", src: "build/util/expr-bison.c"},
  {obj: "util/expr-flex.o", src: "build/util/expr-flex.c"},
  {obj: "util/parse-events-bison.o", src: "build/util/parse-events-bison.c"},
  {obj: "util/parse-events-flex.o", src: "build/util/parse-events-flex.c"},
  {obj: "util/pmu-bison.o", src: "build/util/pmu-bison.c"},
  {obj: "util/pmu-flex.o", src: "build/util/pmu-flex.c"},
]

# The aarch64 list comes from an ARCH=arm64 cross run against musl and kernel
# headers for arm64; nothing built from it has run on aarch64 yet.
proc perf_arch(target: Str) [error] -> Result[PerfArch] {
  if target == "x86_64" {
    return {
      srcarch: "x86",
      defs: ["-DHAVE_ARCH_X86_64_SUPPORT"],
      sources: """
arch/x86/tests/amd-ibs-period.c arch/x86/tests/amd-ibs-via-core-pmu.c
arch/x86/tests/arch-tests.c arch/x86/tests/bp-modify.c arch/x86/tests/hybrid.c
arch/x86/tests/intel-pt-test.c arch/x86/tests/topdown.c
arch/x86/util/auxtrace.c arch/x86/util/event.c arch/x86/util/evlist.c
arch/x86/util/evsel.c arch/x86/util/header.c arch/x86/util/intel-bts.c
arch/x86/util/intel-pt.c arch/x86/util/iostat.c arch/x86/util/machine.c
arch/x86/util/mem-events.c arch/x86/util/pmu.c arch/x86/util/topdown.c
arch/x86/util/tsc.c bench/mem-memcpy-x86-64-asm.S
bench/mem-memset-x86-64-asm.S
""".words(),
    }
  }

  if target == "aarch64" {
    return {
      srcarch: "arm64",
      defs: [],
      sources: """
arch/arm64/tests/arch-tests.c arch/arm64/tests/cpuid-match.c
arch/arm64/tests/regs_load.S arch/arm/util/auxtrace.c arch/arm/util/cs-etm.c
arch/arm/util/pmu.c arch/arm64/util/arm-spe.c arch/arm64/util/header.c
arch/arm64/util/hisi-ptt.c arch/arm64/util/mem-events.c arch/arm64/util/pmu.c
arch/arm64/util/tsc.c
""".words(),
    }
  }

  Err(PerfBuildError.UnsupportedArch(f"perf has no object list for {target}"))
}

proc library_headers() [] -> List[HeaderSet] {
  [
    {
      src: "tools/lib/api",
      dest: "libapi/include/api",
      names: "cpu.h debug.h io.h io_dir.h fd/array.h fs/fs.h fs/tracing_path.h".words(),
    },
    {
      src: "tools/lib/subcmd",
      dest: "libsubcmd/include/subcmd",
      names: "exec-cmd.h help.h pager.h parse-options.h run-command.h".words(),
    },
    {src: "tools/lib/symbol", dest: "libsymbol/include/symbol", names: ["kallsyms.h"]},
    {
      src: "tools/lib/perf/include/perf",
      dest: "libperf/include/perf",
      names: """
bpf_perf.h core.h cpumap.h event.h evlist.h evsel.h mmap.h schedstat-v15.h
schedstat-v16.h schedstat-v17.h threadmap.h
""".words(),
    },
    {
      src: "tools/lib/perf/include/internal",
      dest: "libperf/include/internal",
      names: "cpumap.h evlist.h evsel.h lib.h mmap.h rc_check.h threadmap.h xyarray.h".words(),
    },
  ]
}

pure tree_units(obj_prefix: Str, src_dir: Str, sources: List[Str]) -> List[PerfUnit] {
  [{obj: fp"{obj_prefix}{source}".with_ext("o").display(), src: f"{src_dir}/{source}"} for source in sources]
}

const extra_warnings = [
  "-Wbad-function-cast",
  "-Wdeclaration-after-statement",
  "-Wformat-security",
  "-Wformat-y2k",
  "-Winit-self",
  "-Wmissing-declarations",
  "-Wmissing-prototypes",
  "-Wnested-externs",
  "-Wno-system-headers",
  "-Wold-style-definition",
  "-Wpacked",
  "-Wredundant-decls",
  "-Wstrict-prototypes",
  "-Wswitch-default",
  "-Wswitch-enum",
  "-Wundef",
  "-Wwrite-strings",
  "-Wformat",
  "-Wno-type-limits",
  "-Wshadow",
]

# The upstream feature probes' results against musl; none depends on the
# architecture.
const musl_feature_defs = [
  "-DHAVE_PTHREAD_BARRIER",
  "-DHAVE_EVENTFD_SUPPORT",
  "-DHAVE_GETTID",
  "-DHAVE_SCHED_GETCPU_SUPPORT",
  "-DHAVE_SETNS_SUPPORT",
]

# perf's CFLAGS between the compiler and BUILD_STR, in upstream order. perf
# drops -Wnested-externs from the shared warning set.
pure perf_cflags(arch: PerfArch) -> List[Str] {
  let a = arch.srcarch
  let warnings = [warning for warning in extra_warnings if warning != "-Wnested-externs"]

  [
    @warnings,
    "-fno-strict-aliasing",
    "-Wthread-safety",
    f"-I{out}/arch/{a}/include/generated",
    @arch.defs,
    "-Werror",
    "-DNDEBUG=1",
    "-O3",
    "-fno-omit-frame-pointer",
    "-Wall",
    "-Wextra",
    "-std=gnu11",
    "-funsigned-char",
    "-fstack-protector-all",
    "-U_FORTIFY_SOURCE",
    "-D_FORTIFY_SOURCE=2",
    "-D_LARGEFILE64_SOURCE",
    "-D_FILE_OFFSET_BITS=64",
    "-D_GNU_SOURCE",
    "-Itools/perf/util/include",
    f"-Itools/perf/arch/{a}/include",
    "-Itools/include/",
    f"-Itools/arch/{a}/include/uapi",
    "-Itools/include/uapi",
    f"-Itools/arch/{a}/include/",
    f"-Itools/arch/{a}/",
    f"-I{out}/util",
    f"-I{out}/",
    "-Itools/perf/util",
    "-Itools/perf",
    @musl_feature_defs,
    "-DNO_LIBPYTHON",
    f"-I{out}/libapi/include",
    f"-I{out}/libsubcmd/include",
    f"-I{out}/libsymbol/include",
    f"-I{out}/libperf/include",
    f"-I{out}/",
    # Not upstream: the temporary __NR_* names that write_musl_syscall_names restores.
    "-include",
    f"{out}/musl-syscall-nr.h",
  ]
}

const bison_cflags = ["-DYYLTYPE_IS_TRIVIAL=0", "-DYYENABLE_NLS=0", "-Wno-unused-but-set-variable", "-Wno-switch-enum"]

const flex_cflags = [
  "-Wno-redundant-decls",
  "-Wno-switch-default",
  "-Wno-unused-function",
  "-Wno-misleading-indentation",
  "-Wno-unused-but-set-variable",
]

const workload_cflags = ["-g", "-O0", "-fno-inline"]

# Per-object CFLAGS from the Build files, appended after the shared flags.
# DOCDIR is upstream's fallback tips location for running perf from its source
# tree; it points at the installed tips so no build path leaks into the binary.
pure unit_cflags(obj: Str) -> List[Str] {
  match obj {
    "perf.o" => [
      "-DPERF_HTML_PATH=BUILD_STR(share/doc/perf-doc)",
      "-DPERF_EXEC_PATH=BUILD_STR(libexec/perf-core)",
      "-DPREFIX=BUILD_STR(/usr)",
    ]
    "builtin-help.o" => [
      "-DPERF_HTML_PATH=BUILD_STR(share/doc/perf-doc)",
      "-DPERF_INFO_PATH=BUILD_STR(share/info)",
      "-DPERF_MAN_PATH=BUILD_STR(share/man)",
    ]
    "builtin-report.o" => ["-DTIPDIR=BUILD_STR(share/doc/perf-tip)", "-DDOCDIR=BUILD_STR(share/doc/perf-tip)"]
    "ui/setup.o" => ["-DLIBDIR=BUILD_STR()"]
    "util/config.o" => ["-DETC_PERFCONFIG=BUILD_STR(/etc/perfconfig)"]
    "util/bitmap.o" | "util/find_bit.o" | "util/hweight.o" | "util/libstring.o" | "util/rbtree.o" => [
      "-Wno-unused-parameter",
      "-DETC_PERFCONFIG=BUILD_STR(/etc/perfconfig)",
    ]
    "util/header.o" => ["-include", f"{out}/PERF-VERSION-FILE"]
    "util/arm-spe.o" | "util/arm-spe-decoder/arm-spe-pkt-decoder.o" => [
      "-Itools/arch/arm64/include/",
      f"-I{out}/arch/arm64/include/generated/",
    ]
    "util/intel-pt-decoder/inat.o" => [f"-I{out}/util/intel-pt-decoder"]
    "util/intel-pt-decoder/insn.o" => ["-Wno-packed"]
    "util/demangle-rust-v0.o" => [
      "-Wno-shadow",
      "-Wno-declaration-after-statement",
      "-Wno-switch-default",
      "-Wno-switch-enum",
      "-Wno-missing-field-initializers",
    ]
    "util/expr-bison.o" | "util/pmu-bison.o" => bison_cflags
    "util/parse-events-bison.o" => [flag for flag in bison_cflags if flag != "-DYYLTYPE_IS_TRIVIAL=0"]
    "util/expr-flex.o" | "util/pmu-flex.o" => flex_cflags
    "util/parse-events-flex.o" => flex_cflags.push("-Wno-unused-label")
    "tests/workloads/brstack.o" | "tests/workloads/datasym.o" | "tests/workloads/deterministic.o" | "tests/workloads/leafloop.o" | "tests/workloads/named_threads.o" | "tests/workloads/sqrtloop.o" | "tests/workloads/traploop.o" => workload_cflags
    "tests/workloads/inlineloop.o" => ["-g", "-O2"]
    _ => []
  }
}

# Temporary: the musl recipe writes bits/syscall.h with only the SYS_* names,
# while upstream musl's header also carries the __NR_* names that perf-sys.h,
# libperf, and the benchmarks call syscall() with. This header restores them
# from the build root's SYS_* list; delete it, and its -include, once the musl
# recipe emits both name sets.
proc write_musl_syscall_names() [fs, env, error] {
  let build_root = env.get("XSH_PM_BUILD_ROOT")?
  var lines = ["#include <sys/syscall.h>"]

  for line in fp"{build_root}/usr/include/bits/syscall.h".read_text()?.lines() {
    let words = line.words()
    continue unless words.len() == 3 and words[0] == "#define" and words[1].starts_with("SYS_")
    let syscall = words[1].replace("SYS_", "")
    lines += [f"#ifndef __NR_{syscall}", f"#define __NR_{syscall} SYS_{syscall}", "#endif"]
  }

  fs.write(fp"{out}/musl-syscall-nr.h", lines.join("\n") + "\n")?
}

# PERF-VERSION-GEN outside a git checkout writes the top Makefile's
# `kernelversion`: VERSION.PATCHLEVEL.SUBLEVEL followed by EXTRAVERSION.
proc write_perf_version_file() [fs, error] {
  var fields: Map[Str] = {}

  for line in p"Makefile".read_text()?.lines() {
    let parts = line.split("=")
    continue unless parts.len() == 2
    let key = parts[0].trim()

    if key in ["VERSION", "PATCHLEVEL", "SUBLEVEL", "EXTRAVERSION"] and key not in fields {
      fields[key] = parts[1].trim()
    }
  }

  for key in ["VERSION", "PATCHLEVEL", "SUBLEVEL", "EXTRAVERSION"] {
    guard key in fields else {
      return Err(PerfBuildError.MissingKernelVersion(f"the kernel Makefile does not set {key}"))
    }
  }

  let release = f"{fields["VERSION"]}.{fields["PATCHLEVEL"]}.{fields["SUBLEVEL"]}{fields["EXTRAVERSION"]}"
  fs.write(fp"{out}/PERF-VERSION-FILE", f"#define PERF_VERSION \"{release}\"\n")?
}

proc compile_units(cc: Path, triple: Str, units: List[PerfUnit], cflags: List[Str]) [] -> List[make.MakeTask] {
  [
    make.compile_c_task(
      cc,
      triple,
      [@cflags, @unit_cflags(unit.obj)],
      [],
      [],
      fp"{unit.src}",
      fp"{out}/{unit.obj}",
    ) for unit in units
  ]
}

proc install_library_headers() [fs, error] {
  for headers in library_headers() {
    for header in headers.names {
      fs.install(fp"{headers.src}/{header}", fp"{out}/{headers.dest}/{header}", 0o644, parents: true, overwrite: true)?
    }
  }
}

proc build_perf(cc: Path) [fs, process, env, error] -> Result[Path] {
  let target = pm_util.target_arch()?
  let arch = perf_arch(target)?
  let a = arch.srcarch
  let triple = f"{target}-linux-musl"
  install_library_headers()?
  write_perf_version_file()?
  write_musl_syscall_names()?

  let lib_cflags = [
    @extra_warnings,
    "-ggdb3",
    "-Wall",
    "-Wextra",
    "-std=gnu99",
    "-U_FORTIFY_SOURCE",
    "-fPIC",
    "-Werror",
    "-D_LARGEFILE64_SOURCE",
    "-D_FILE_OFFSET_BITS=64",
  ]

  let libapi = compile_units(
    cc,
    triple,
    tree_units("libapi/", "tools/lib/api", "cpu.c debug.c fd/array.c fs/fs.c fs/tracing_path.c fs/cgroup.c".words()).push(
      {obj: "libapi/str_error_r.o", src: "tools/lib/str_error_r.c"},
    ),
    ["-fintegrated-as", @lib_cflags, "-Itools/lib/api", "-Itools/include", "-DBUILD_STR(s)=#s"],
  )

  let libsymbol = compile_units(
    cc,
    triple,
    tree_units("libsymbol/", "tools/lib/symbol", ["kallsyms.c"]),
    [
      "-fintegrated-as",
      @[flag for flag in lib_cflags if flag != "-std=gnu99"],
      "-std=gnu11",
      "-Itools/lib",
      "-Itools/include",
      "-DBUILD_STR(s)=#s",
    ],
  )

  let libsubcmd = compile_units(
    cc,
    triple,
    tree_units(
      "libsubcmd/",
      "tools/lib/subcmd",
      "exec-cmd.c help.c pager.c parse-options.c run-command.c sigchain.c subcmd-config.c".words(),
    ),
    [
      "-fintegrated-as",
      "-ggdb3",
      "-Wall",
      "-Wextra",
      "-std=gnu99",
      "-fPIC",
      "-O3",
      "-Werror",
      "-D_LARGEFILE64_SOURCE",
      "-D_FILE_OFFSET_BITS=64",
      "-D_GNU_SOURCE",
      "-Itools/include/",
      @extra_warnings,
      "-DBUILD_STR(s)=#s",
    ],
  )

  let libperf = compile_units(
    cc,
    triple,
    tree_units("libperf/", "tools/lib/perf", "core.c cpumap.c threadmap.c evsel.c evlist.c mmap.c xyarray.c lib.c".words()).push(
      {obj: "libperf/zalloc.o", src: "tools/lib/zalloc.c"},
    ),
    [
      "-fintegrated-as",
      "-Itools/lib/perf/include",
      "-Itools/lib/",
      "-Itools/include",
      f"-Itools/arch/{a}/include/",
      f"-Itools/arch/{a}/include/uapi",
      "-Itools/include/uapi",
      @perf_cflags(arch),
      "-g",
      "-Werror",
      "-Wall",
      "-fPIC",
      "-fvisibility=hidden",
      @extra_warnings,
      "-DBUILD_STR(s)=#s",
    ],
  )

  let perf_units = [
    @tree_units("", "tools/perf", perf_sources()),
    @tree_units("", "tools/perf", arch.sources),
    @perf_moved_units,
  ]

  let perf = compile_units(cc, triple, perf_units, ["-fintegrated-as", @perf_cflags(arch), "-DBUILD_STR(s)=#s"])
  let compiled = [@libapi, @libsymbol, @libsubcmd, @libperf, @perf]

  let link = make.link_executable_task(
    cc,
    triple,
    [task.outputs[0] for task in compiled],
    [],
    ["-Wl,-z,noexecstack", "-lpthread", "-lrt", "-lm", "-ldl"],
    fp"{out}/perf",
    [task.name for task in compiled],
  )

  make.run_tasks(compiled.push(link), make.jobs()?)?
  link.outputs[0]
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let perf = build_perf(cc)?
  fs.install(perf, fp"{dest}/usr/bin/perf", 0o755, parents: true, overwrite: true)?

  fs.install(
    p"tools/perf/Documentation/tips.txt",
    fp"{dest}/usr/share/doc/perf-tip/tips.txt",
    0o644,
    parents: true,
    overwrite: true,
  )?
}
