##! Package recipe metadata and build operations.
use pm.make
use pm.util as pm_util

## Package recipe export.
export const name = "strace"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "7.2"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## strace compiles against the kernel's userspace API: its bundled copy of
## the `linux/` headers takes precedence, and `asm/` comes from linux-headers.
export const mkdeps_host = ["llvm-toolchain", "linux-headers"]

# `files/ARCH/config.h` is `src/config.h` exactly as strace's configure writes
# it for musl and clang. It was captured on the host from this tarball against
# a sysroot holding this tree's musl and linux-headers payloads:
#
#   ./configure CC="clang --target=x86_64-linux-musl --sysroot=SYSROOT \
#     -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld" --disable-mpers \
#     --without-libdw --without-libunwind --without-libselinux \
#     --disable-gcc-Werror --prefix=/usr
#
# and for aarch64 the same with `--host=aarch64-linux-musl` and a clang
# wrapper over an aarch64 musl 1.2.6 sysroot with the arm64 headers. The two
# differ only in the architecture macros and five x86-only kernel structures.
# With linux-headers no newer than the bundled 7.2 headers, configure selects
# the bundled `linux/` headers, so their values are what the build sees.
## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/strace/strace/releases/download/vVERSION/strace-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "4bde6246926890dcee824f6e6ac42a06752f47d77e5097d86e3c0d6d4b709fe5",
      },
    ],
  },
  {
    source: p"files/ARCH/config.h",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "SKIP",
      },
      {
        arch: "x86_64",
        sha256: "SKIP",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [{path: p"usr/bin/strace", kind: "binary"}]

# libstrace_a_SOURCES (its .c files) from src/Makefile.am, as the configured
# Makefile compiles them with mpers, libdw, libunwind, and SELinux disabled.
const libstrace_sources = """
access.c affinity.c aio.c alarm.c alpha.c basic_filters.c bind.c bjm.c
block.c bpf.c bpf_filter.c bpf_seccomp_filter.c bpf_sock_filter.c btrfs.c
cacheflush.c cachestat.c capability.c chdir.c chmod.c clone.c close_range.c
color.c copy_file_range.c count.c counter_ioctl.c delay.c desc.c dirent.c
dirent64.c dirent_types.c dm.c dup.c dyxlat.c epoll.c epoll_ioctl.c
error_prints.c evdev.c evdev_mpers.c eventfd.c execve.c exit.c exitkill.c
fadvise.c fallocate.c fanotify.c fchownat.c fcntl.c fetch_bpf_fprog.c
fetch_indirect_syscall_args.c fetch_struct_flock.c fetch_struct_iovec.c
fetch_struct_keyctl_kdf_params.c fetch_struct_mmsghdr.c
fetch_struct_msghdr.c fetch_struct_stat.c fetch_struct_stat64.c
fetch_struct_statfs.c fetch_struct_xfs_quotastat.c file_attr.c
file_handle.c filter_qualify.c filter_seccomp.c flock.c fs_0x15_ioctl.c
fs_0x94_ioctl.c fs_f_ioctl.c fs_x_ioctl.c fsconfig.c fsmount.c fsopen.c
fspick.c fstatfs.c fstatfs64.c futex.c futex2.c get_personality.c
get_robust_list.c getcpu.c getcwd.c getpagesize.c getpid.c getrandom.c
gpio_ioctl.c hdio.c hostname.c inotify.c inotify_ioctl.c io.c io_uring.c
ioctl.c ioperm.c iopl.c ioprio.c ipc.c ipc_msg.c ipc_msgctl.c ipc_sem.c
ipc_semctl.c ipc_shm.c ipc_shmctl.c kcmp.c kd_ioctl.c kd_mpers_ioctl.c
kexec.c keyctl.c kvm.c landlock.c ldt.c link.c lirc_ioctl.c listen.c
listmount.c listns.c lookup_dcookie.c loop.c lseek.c lsm.c
map_shadow_stack.c mem.c membarrier.c memfd_create.c memfd_secret.c mknod.c
mmap_cache.c mmap_notify.c mmsghdr.c mount.c mount_setattr.c move_mount.c
mq.c msghdr.c mtd.c nbd_ioctl.c net.c netlink.c netlink_crypto.c
netlink_generic.c netlink_inet_diag.c netlink_kobject_uevent.c
netlink_netfilter.c netlink_netlink_diag.c netlink_nlctrl.c
netlink_packet_diag.c netlink_route.c netlink_selinux.c netlink_smc_diag.c
netlink_sock_diag.c netlink_unix_diag.c nice.c nlattr.c nsfs.c numa.c
number_set.c oldstat.c open.c or1k_atomic.c pathtrace.c perf.c perf_ioctl.c
personality.c pidfd_getfd.c pidfd_ioctl.c pidfd_open.c pidns.c pkeys.c
poke.c poll.c prctl.c print_dev_t.c print_fields.c print_group_req.c
print_ifindex.c print_instruction_pointer.c print_kernel_sigset.c
print_kernel_version.c print_mac.c print_mq_attr.c print_msgbuf.c
print_sg_req_info.c print_sigevent.c print_statfs.c print_struct_stat.c
print_syscall_number.c print_time.c print_timespec32.c print_timespec64.c
print_timeval.c print_timeval64.c print_timex.c printmode.c printrusage.c
printsiginfo.c process_vm.c ptp.c ptrace.c ptrace_syscall_info.c quota.c
random_ioctl.c readahead.c readlink.c reboot.c regset.c renameat.c
resource.c rseq.c retval.c riscv.c rt_sigframe.c rt_sigreturn.c rtc.c
rtnl_addr.c rtnl_addrlabel.c rtnl_cachereport.c rtnl_dcb.c rtnl_link.c
rtnl_mdb.c rtnl_neigh.c rtnl_neightbl.c rtnl_netconf.c rtnl_nh.c
rtnl_nsid.c rtnl_route.c rtnl_rule.c rtnl_stats.c rtnl_tc.c
rtnl_tc_action.c s390.c sched.c scsi.c seccomp.c seccomp_ioctl.c sendfile.c
set_tid_address.c sg_io_v3.c sg_io_v4.c shutdown.c sigaltstack.c signal.c
signalfd.c sigreturn.c sock.c sockaddr.c socketcall.c socketutils.c sparc.c
sram_alloc.c stage_output.c stat.c stat64.c statfs.c statfs64.c statmount.c
statx.c strauss.c string_to_uint.c swapon.c sync_file_range.c
sync_file_range2.c syscall.c syscall_name.c sysctl.c sysinfo.c syslog.c
sysmips.c tee.c term.c time.c times.c trie.c truncate.c ubi.c ucopy.c
udmabuf.c uid.c uid16.c umask.c umount.c uname.c upeek.c upoke.c
userfaultfd.c ustat.c util.c utime.c utimes.c v4l2.c wait.c
watchdog_ioctl.c xattr.c xgetdents.c xlat.c xmalloc.c bpf_attr_check.c
gen/gen_hdio.c
"""

# The syscall tables sen.h enumerates: every architecture's, as the Makefile
# filters them out of EXTRA_DIST, so SEN_* values are the same on every target.
const syscallent_names = [
  "subcallent.h",
  "syscallent.h",
  "syscallent1.h",
  "syscallent-common.h",
  "syscallent-common-32.h",
  "syscallent-n32.h",
  "syscallent-n64.h",
  "syscallent-o32.h",
]

# The upstream generators are sed programs over whole lines; these are their
# patterns with POSIX classes spelled out ([[:space:]] and [[:xdigit:]]).
const sen_pattern = rx"^.*SEN\(([^)]+)\).*$"
const scno_pattern = rx"""^\[[ \t\n\v\f\r]*([0-9]+([ \t\n\v\f\r]*\+[ \t\n\v\f\r]*[0-9]+)?)\][ \t\n\v\f\r]*=[ \t\n\v\f\r]*\{[^,]*,[^,]*,[^,]*,[ \t\n\v\f\r]*"([A-Za-z0-9_]+)"[ \t\n\v\f\r]*\},.*$"""
const printer_pattern = rx"^MPERS_PRINTER_DECL\(([^,)]+),[ \t\n\v\f\r]*([^,)]+),[ \t\n\v\f\r]*([^)]+)\)$"
const ioctlent_pattern = rx"""^\{ "([^"]+)", (0x[0-9A-Fa-f]+) \},$"""

# Map keys iterate in byte order, which is `LC_ALL=C sort -u`.
pure sorted_unique(items: List[Str]) -> List[Str] {
  let seen = {[item]: true for item in items}
  seen.keys()
}

pure kernel_arch(arch: Str) -> Str {
  return "arm64" when arch == "aarch64"

  return "x86" when arch == "x86_64"

  arch
}

# AM_CPPFLAGS plus DEFS: the arch and generic headers, the source directory,
# and the bundled kernel headers ahead of the system's.
pure strace_cppflags(arch: Str) -> List[Str] {
  [
    "-DHAVE_CONFIG_H",
    f"-Isrc/linux/{arch}",
    "-Isrc/linux/generic",
    "-Isrc",
    "-isystem",
    f"bundled/linux/arch/{kernel_arch(arch)}/include/uapi",
    "-isystem",
    "bundled/linux/include/uapi",
  ]
}

# `sys_func.h`: `sed -n 's/^SYS_FUNC(.*/extern &;/p'` over the strace sources,
# then `sort -u`.
proc write_sys_func_h(sources: List[Path]) [fs, error] {
  var decls = []

  for src in sources {
    for line in src.read_text()?.lines() {
      if line.starts_with("SYS_FUNC(") {
        decls += [f"extern {line};"]
      }
    }
  }

  fs.write(p"src/sys_func.h", [f"{decl}\n" for decl in sorted_unique(decls)].join(""))?
}

# `sen.h`: generate_sen.sh, the SEN() names of every syscall table entry that
# does not mention printargs, sorted and unique.
proc write_sen_h() [fs, error] {
  let tables = fs.walk(p"src/linux")? |> where .kind == "file" and .name in syscallent_names |> map .path |> sort
  var names = []

  for table in tables {
    for line in table.read_text()?.lines() {
      continue when "printargs" in line

      if let [_, sen] = sen_pattern.captures(line) {
        names += [sen]
      }
    }
  }

  let body = [f"SEN_{sen},\n" for sen in sorted_unique(names)].join("")
  fs.write(p"src/sen.h", "enum {\nSEN_printargs = 0,\n" + body + "};\n")?
}

# `scno.h` (scno.am): scno.head, then an `__NR_` fallback for every named
# entry of the preprocessed native syscall table.
proc write_scno_h(syscallent_i: Path) [fs, error] {
  var out = "/* Generated by Makefile from ../src/scno.head syscallent.i; do not edit. */\n"
  out = out + p"src/scno.head".read_text()?

  for line in syscallent_i.read_text()?.lines() {
    continue when "TRACE_INDIRECT_SUBCALL" in line

    if let [_, number, _, syscall] = scno_pattern.captures(line) {
      out = out + f"#ifndef __NR_{syscall}\n# define __NR_{syscall} (SYSCALL_BIT | ({number}))\n#endif\n"
    }
  }

  fs.write(p"src/scno.h", out)?
}

# printers.h, native_printer_decls.h, and native_printer_defs.h: the
# MPERS_PRINTER_DECL lines of each preprocessed mpers source, in mpers.am
# order. Without mpers personalities only the native printer table exists.
proc write_printer_headers(mpers_sources: List[Str], preprocessed: List[Path]) [fs, error] {
  let inputs = [f"{src}.mpers.i" for src in mpers_sources].join(" ")
  let banner = f"/* Generated by Makefile from {inputs}; do not edit. */\n"
  var printers = banner + "typedef struct {\n"
  var decls = banner
  var defs = banner

  for file in preprocessed {
    for line in file.read_text()?.lines() {
      if let [_, result, printer, params] = printer_pattern.captures(line) {
        printers = printers + f" {result} (*{printer})({params});\n#define {printer} MPERS_PRINTER_NAME({printer})\n\n"
        decls = decls + f"extern {result} {printer}({params});\n"
        defs = defs + f".{printer} = {printer},\n"
      }
    }
  }

  printers = printers + "} struct_printers;\nextern const struct_printers *printers;\n"
  printers = printers + "#define MPERS_PRINTER_NAME(printer_name) printers->printer_name\n"
  fs.write(p"src/printers.h", printers)?
  fs.write(p"src/native_printer_decls.h", decls)?
  fs.write(p"src/native_printer_defs.h", defs)?
}

# ioctl_redefs<N>.h: `sort ioctlent<N>.h | comm -23 - <(sort ioctlent0.h)`
# rewritten into #undef/#define pairs, so a personality's ioctl numbers
# replace the native ones where they differ.
proc write_ioctl_redefs(personality: Str) [fs, error] {
  let native = {[line]: true for line in p"src/ioctlent0.h".read_text()?.lines()}
  var out = ""

  for line in sorted_unique(fp"src/ioctlent{personality}.h".read_text()?.lines()) {
    continue when native.get(line) ?? false

    if let [_, ioctl, code] = ioctlent_pattern.captures(line) {
      out = out + f"#ifdef {ioctl}\n# undef {ioctl}\n# define {ioctl} {code}\n#endif\n"
    }
  }

  fs.write(fp"src/ioctl_redefs{personality}.h", out)?
}

# A preprocessor-only task (`$(CPP) -P`) with no depfile.
pure cpp_task(cc: Path, triple: Str, flags: List[Str], src: Path, out: Path) -> make.MakeTask {
  var argv: List[Any] = [cc, "-target", triple, "-E", "-P"]
  argv = [@argv, @flags, src, "-o", out]

  {
    name: out.display(),
    outputs: [
      out,
    ],
    inputs: [
      src,
    ],
    deps: [],
    argv,
    cwd: p".",
    env: {},
    depfile: p"",
    stamp: fp"{out}.cmd",
  }
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let arch = pm_util.target_arch()?
  let build_arch = pm_util.build_arch()?
  let triple = f"{arch}-linux-musl"
  let build_triple = f"{build_arch}-linux-musl"
  let cppflags = strace_cppflags(arch)
  var build_cc = cc
  var build_task_env: Record = {}

  if build_arch != arch {
    let build_root = fp"{e"XSH_PM_BUILD_ROOT" ?? ""}"
    build_cc = fp"{build_root}/usr/bin/cc"

    build_task_env = {
      XSH_MAKE_NATIVE_CROSS: "0",
      PATH: f"{build_root}/usr/bin:{build_root}/usr/lib/llvm-toolchain/bin:{e"PATH" ?? ""}",
      LD_LIBRARY_PATH: f"{build_root}/usr/lib:{build_root}/usr/lib/llvm23/lib",
    }
  }

  fs.install(p"config.h", p"src/config.h", 0o644, overwrite: true)?

  # configure's workaround for musl, whose <signal.h> conflicts with the
  # kernel's <linux/signal.h>: shadow the latter with the libc header.
  fs.install(p"src/linux/generic/signal.h.in", p"src/linux/generic/linux/signal.h", 0o644, parents: true, overwrite: true)?

  let library_sources = [fp"src/{src}" for src in libstrace_sources.words()]
  let sources = [p"src/strace.c", @library_sources]
  write_sys_func_h([src for src in sources if src != p"src/bpf_attr_check.c"])?
  write_sen_h()?

  let mpers_line = [line for line in p"src/mpers.am".read_text()?.lines() if line.starts_with("mpers_source_files = ")]
  let mpers_sources = mpers_line[0].split(" = ")[1].words()
  fs.mkdir(p"obj/cpp", parents: true)?

  # Each preprocessed input is target code: the syscall table (with config.h
  # forced in), the mpers sources in bootstrap mode, and the target's <linux/ioctl.h>
  # encoding that ioctlsort, a build-machine program, must use.
  let syscallent_i = p"obj/cpp/syscallent.i"
  let iocdef_i = p"obj/cpp/ioctl_iocdef.i"
  var cpp_tasks = [
    cpp_task(cc, triple, [@cppflags, "-include", "src/config.h"], fp"src/linux/{arch}/syscallent.h", syscallent_i),
    cpp_task(cc, triple, [@cppflags, "-DIN_STRACE=1"], p"src/ioctl_iocdef.c", iocdef_i),
  ]
  var mpers_i = []

  for src in mpers_sources {
    let out = fp"obj/cpp/{src}.mpers.i"
    cpp_tasks += [cpp_task(cc, triple, [@cppflags, "-DIN_STRACE=1", "-DIN_MPERS_BOOTSTRAP"], fp"src/{src}", out)]
    mpers_i += [out]
  }

  make.run_tasks(cpp_tasks, make.jobs()?)?
  write_scno_h(syscallent_i)?
  write_printer_headers(mpers_sources, mpers_i)?

  let iocdef = [f"#define {line.split("DEFINE HOST")[1]}\n" for line in iocdef_i.read_text()?.lines() if line.starts_with("DEFINE HOST")]
  fs.write(p"src/ioctl_iocdef.h", iocdef.join(""))?

  # One ioctl table per personality the architecture ships ioctls_inc<N>.h
  # for (x86_64: native, i386, x32; aarch64: native, arm). ioctlsort runs on
  # the build machine and prints each table sorted by code.
  let personalities = fs.walk(fp"src/linux/{arch}")?
    |> where .kind == "file" and .name.starts_with("ioctls_inc") and .name.ends_with(".h")
    |> map { |entry| entry.name.split("ioctls_inc")[1].split(".h")[0] }
    |> sort

  var ioctlsort_tasks = []

  for personality in personalities {
    let all = fp"src/ioctls_all{personality}.h"
    let inc = fp"src/linux/{arch}/ioctls_inc{personality}.h".read_text()?
    let arch_ioctls = fp"src/linux/{arch}/ioctls_arch{personality}.h".read_text()?
    fs.write(all, inc + arch_ioctls)?

    let ioctlsort = make.c_program({
      cc: build_cc,
      triple: build_triple,
      cflags: ["-O2", f"-DIOCTLSORT_INC=\"ioctls_all{personality}.h\""],
      defs: [],
      includes: cppflags,
      root: p".",
      sources: [p"src/ioctlsort.c"],
      out_dir: fp"obj/ioctlsort{personality}-objs",
      out: fp"obj/ioctlsort{personality}",
      libs: [],
      ldflags: [],
      deps: [],
    })

    ioctlsort_tasks += ioctlsort.tasks
  }

  if build_arch != arch {
    ioctlsort_tasks = [{...task, env: build_task_env} for task in ioctlsort_tasks]
  }

  make.run_tasks(ioctlsort_tasks, make.jobs()?)?

  for personality in personalities {
    let ioctlsort = fp"obj/ioctlsort{personality}"
    fs.write(fp"src/ioctlent{personality}.h", run.text $ioctlsort ?)?
  }

  for personality in personalities {
    if personality != "0" {
      write_ioctl_redefs(personality)?
    }
  }

  let cflags = ["-O2", "-DIN_STRACE=1"]

  let library = make.compile_c_tasks(cc, triple, cflags, [], cppflags, p".", library_sources, p"obj/libstrace")
  let libstrace = make.link_archive_task(cc, library.objects, p"obj/libstrace.a", library.deps)
  let main = make.compile_c_tasks(cc, triple, cflags, [], cppflags, p".", [p"src/strace.c"], p"obj/strace")
  let link = make.link_executable_task(cc, triple, main.objects, [p"obj/libstrace.a"], [], p"obj/strace/strace", [@main.deps, libstrace.name])
  make.run_tasks([@library.tasks, libstrace, @main.tasks, link], make.jobs()?)?
  fs.install(link.outputs[0], fp"{dest}/usr/bin/strace", 0o755, parents: true, overwrite: true)?
}
