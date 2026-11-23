use pm.target as pm_target
use pm.types

error ScriptError = Failed(kind: Str, message: Str)

proc ensure(condition: Bool, kind: Str, message: Str) {
  if ! condition {
    Err(ScriptError.Failed(kind:, message:))?
  }
}

pure elf_machine_name(target: types.Target) -> Result[Str, Error] {
  match target {
    types.Aarch64LinuxMusl => "AArch64"
    types.X86_64LinuxMusl => "X86-64"
    types.TargetReserved => Err(types.PmError.PackageContract("unsupported ELF target"))
  }
}

proc build_root_path() -> Result[Path] {
  let build_root_value = (e"XSH_PM_BUILD_ROOT" ?? "").trim()
  ensure(build_root_value != "", "proof-musl", "XSH_PM_BUILD_ROOT is required for native-cross proof")
  fp"{build_root_value}"
}

proc cross_cc(default_cc: Path, build_arch: Str, target_arch: Str) -> Result[Path] {
  return default_cc when build_arch == target_arch

  let build_root = build_root_path()?
  fp"{build_root}/usr/lib/llvm23/bin/clang-23"
}

proc compile_program(
  cc: Path,
  rootfs: Path,
  source: Path,
  program: Path,
  triple: Str,
  dynlinker: Path,
  build_arch: Str,
  target_arch: Str,
) {
  let include_dir = fp"{rootfs}/usr/include"
  let lib_dir = fp"{rootfs}/usr/lib"

  if build_arch == target_arch {
    run $cc f"--target={triple}" f"--sysroot={rootfs}" "-dynamic" f"-I{include_dir}" f"-L{lib_dir}" \
      f"-Wl,-rpath,{lib_dir}" f"-Wl,-dynamic-linker,{dynlinker}" $source "-o" $program
    return
  }

  let build_root = build_root_path()?

  env ({
    LD_LIBRARY_PATH: f"{build_root}/usr/lib:{build_root}/usr/lib/llvm23/lib",
    PATH: f"{build_root}/usr/lib/llvm-toolchain/bin:{build_root}/usr/bin:{e"PATH" ?? ""}",
  }) {
    run $cc f"--target={triple}" f"--sysroot={rootfs}" "-fuse-ld=lld" "-nostdlib" fp"{lib_dir}/Scrt1.o" \
      fp"{lib_dir}/crti.o" $source f"-L{lib_dir}" "-lc" fp"{lib_dir}/crtn.o" f"-Wl,-rpath,{lib_dir}" \
      f"-Wl,-dynamic-linker,{dynlinker}" "-o" $program
  }
}

proc run_regression(dynlinker: Path, program: Path, kind: Str) {
  let result = run.capture --text $dynlinker $program
  ensure(result.status.ok, kind, f"{kind} regression failed:\n{result.stdout.trim()}\n{result.stderr.trim()}")
  print result.stdout.trim()
}

proc main(rootfs = p"/rootfs") [fs, process, env, error] -> Result[Unit, Error] {
  let target = pm_target.recipe_target()?
  let arch = types.pm_target_arch(target)
  let build_arch = types.pm_target_arch(pm_target.build_target()?)
  let triple = f"{arch}-linux-musl"
  let ldso = f"ld-musl-{arch}.so.1"
  let default_cc = process.which("cc")?
  let cc = cross_cc(default_cc, build_arch, arch)?
  let readelf = process.which("readelf")?
  tempdir tmp at fp"{rootfs}/var/tmp/proof-musl" {
    let hello_src = fp"{tmp}/hello.c"

    hello_src.write(
      """#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
/* Linking takes clone's address, so a libc that lost the public clone()
   wrapper (src/linux/clone.c) to an arch file of the same name fails here. */
int (*volatile clone_entry)(int (*)(void *), void *, int, void *, ...) = clone;
int main(void) { puts(clone_entry ? "hello musl" : "no clone"); return 0; }
""",
    )

    let regcomp_src = fp"{tmp}/regcomp.c"

    regcomp_src.write(
      """#include <regex.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/wait.h>

enum { INPUT_LIMIT = 1024000, CASES = 6 };

static const char *names[CASES] = {
  "ordinary patterns compile and match",
  "pattern at the 1024000-byte input limit is refused",
  "pattern past the input limit is refused",
  "nested {255} repetitions are refused",
  "nested {255,} alternation repetitions are refused",
  "three nested {255} repetitions are refused",
};

static void say(const char *msg) {
  puts(msg);
  fflush(stdout);
}

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int ordinary(void) {
  regex_t re;
  if (regcomp(&re, "^(ab|cd)+x{2,3}[[:digit:]]*$", REG_EXTENDED | REG_NOSUB)) return 1;
  int hit = regexec(&re, "abcdxx12", 0, 0, 0);
  int miss = regexec(&re, "abcdx12", 0, 0, 0);
  regfree(&re);
  if (hit != 0 || miss != REG_NOMATCH) return 2;

  regmatch_t m[2];
  if (regcomp(&re, "^((a{2}){3}){4}$", REG_EXTENDED)) return 3;
  char text[25];
  memset(text, 'a', 24);
  text[24] = 0;
  int full = regexec(&re, text, 2, m, 0);
  text[23] = 'b';
  int broken = regexec(&re, text, 0, 0, 0);
  regfree(&re);
  if (full != 0 || m[0].rm_so != 0 || m[0].rm_eo != 24 || m[1].rm_eo != 24) return 4;
  return broken == REG_NOMATCH ? 0 : 5;
}

static int oversize(size_t n) {
  char *pattern = malloc(n + 1);
  if (!pattern) return 1;
  memset(pattern, 'a', n);
  pattern[n] = 0;
  regex_t re;
  double start = now();
  int rc = regcomp(&re, pattern, REG_EXTENDED | REG_NOSUB);
  double took = now() - start;
  if (rc == 0) regfree(&re);
  if (rc != REG_ESPACE) return 2;
  return took < 5.0 ? 0 : 3;
}

static int nested(const char *pattern) {
  struct rlimit cap = { 1UL << 30, 1UL << 30 };
  if (setrlimit(RLIMIT_AS, &cap)) return 1;
  regex_t re;
  int rc = regcomp(&re, pattern, REG_EXTENDED);
  if (rc == 0) {
    regfree(&re);
    return 2;
  }
  return rc == REG_ESPACE ? 0 : 3;
}

static int run_case(int id) {
  switch (id) {
  case 0: return ordinary();
  case 1: return oversize(INPUT_LIMIT);
  case 2: return oversize(2 * INPUT_LIMIT);
  case 3: return nested("(((a{255}){255}){255}){255}");
  case 4: return nested("((a|b*){255,}){255,}");
  case 5: return nested("((a{255}){255}){255}");
  }
  return 99;
}

int main(void) {
  int failed = 0;
  for (int id = 0; id < CASES; id++) {
    pid_t pid = fork();
    if (pid < 0) return 2;
    if (pid == 0) {
      alarm(60);
      _exit(run_case(id));
    }
    int st = 0;
    if (waitpid(pid, &st, 0) != pid) return 2;
    char line[200];
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0) {
      snprintf(line, sizeof line, "ok: %s", names[id]);
    } else if (WIFSIGNALED(st)) {
      snprintf(line, sizeof line, "FAIL: %s: killed by signal %d", names[id], WTERMSIG(st));
      failed++;
    } else {
      snprintf(line, sizeof line, "FAIL: %s: exit %d", names[id], WEXITSTATUS(st));
      failed++;
    }
    say(line);
  }
  return failed ? 1 : 0;
}
""",
    )

    let iconv_src = fp"{tmp}/gb18030.c"

    iconv_src.write(
      """#include <errno.h>
#include <iconv.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

enum { CASES = 5, FLOOD_CHARS = 1000000, BMP_FOUR_BYTE = 39420 };

static const char *names[CASES] = {
  "four-byte sequences at the range edges decode to the right characters",
  "every four-byte BMP sequence decodes in order without surrogates",
  "supplementary-plane sequences decode linearly and stop at U+10FFFF",
  "malformed and truncated sequences are refused",
  "1000000 worst-case four-byte characters decode within the time bound",
};

static void say(const char *msg) {
  puts(msg);
  fflush(stdout);
}

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static iconv_t gb18030(void) {
  iconv_t cd = iconv_open("UTF-32LE", "GB18030");
  if (cd == (iconv_t)-1) _exit(90);
  return cd;
}

static long decode(iconv_t cd, const unsigned char *bytes, size_t len) {
  unsigned char out[8];
  char *ip = (char *)bytes;
  char *op = (char *)out;
  size_t il = len;
  size_t ol = sizeof out;
  iconv(cd, 0, 0, 0, 0);
  if (iconv(cd, &ip, &il, &op, &ol) == (size_t)-1) return errno == EINVAL ? -2 : -1;
  if (il != 0 || ol != sizeof out - 4) return -3;
  return (long)out[0] | (long)out[1] << 8 | (long)out[2] << 16 | (long)out[3] << 24;
}

static long four(iconv_t cd, int a, int b, int c, int d) {
  unsigned char bytes[4] = { a, b, c, d };
  return decode(cd, bytes, 4);
}

static int edges(void) {
  iconv_t cd = gb18030();
  if (four(cd, 0x81, 0x30, 0x81, 0x30) != 0x80) return 1;
  if (four(cd, 0x83, 0x36, 0xc7, 0x38) != 0xd7ff) return 2;
  if (four(cd, 0x84, 0x31, 0xa4, 0x39) != 0xffff) return 3;
  if (four(cd, 0x90, 0x30, 0x81, 0x30) != 0x10000) return 4;
  if (four(cd, 0x90, 0x30, 0x81, 0x31) != 0x10001) return 5;
  if (four(cd, 0xe3, 0x32, 0x9a, 0x35) != 0x10ffff) return 6;
  return 0;
}

static int bmp(void) {
  iconv_t cd = gb18030();
  long prev = -1;
  int count = 0;
  for (int a = 0x81; a <= 0x84; a++)
    for (int b = 0x30; b <= 0x39; b++)
      for (int c = 0x81; c <= 0xfe; c++)
        for (int d = 0x30; d <= 0x39; d++) {
          if (a == 0x84 && (b > 0x31 || (b == 0x31 && (c > 0xa4 || (c == 0xa4 && d > 0x39))))) goto done;
          long cp = four(cd, a, b, c, d);
          if (cp < 0x80 || cp > 0xffff) return 1;
          if (cp >= 0xd800 && cp <= 0xdfff) return 2;
          if (cp <= prev) return 3;
          prev = cp;
          count++;
        }
done:
  if (prev != 0xffff) return 4;
  return count == BMP_FOUR_BYTE ? 0 : 5;
}

static int supplementary(void) {
  iconv_t cd = gb18030();
  for (long i = 0; i < 0x100000; i += i < 64 ? 1 : 4097) {
    long pair = i / 1260;
    long rest = i % 1260;
    int a = 0x90 + pair / 10;
    int b = 0x30 + pair % 10;
    int c = 0x81 + rest / 10;
    int d = 0x30 + rest % 10;
    if (four(cd, a, b, c, d) != 0x10000 + i) return 1;
  }
  if (four(cd, 0xe3, 0x32, 0x9a, 0x36) != -1) return 2;
  if (four(cd, 0x84, 0x31, 0xa5, 0x30) != -1) return 3;
  return 0;
}

static int malformed(void) {
  iconv_t cd = gb18030();
  unsigned char shortseq[3] = { 0x84, 0x31, 0xa4 };
  if (decode(cd, shortseq, 3) != -2) return 1;
  if (four(cd, 0x84, 0x31, 0xa4, 0x3a) != -1) return 2;
  if (four(cd, 0x84, 0x31, 0x7f, 0x30) != -1) return 3;
  if (four(cd, 0xff, 0x30, 0x81, 0x30) != -1) return 4;
  return 0;
}

static int flood(void) {
  iconv_t cd = gb18030();
  size_t n = FLOOD_CHARS;
  unsigned char *in = malloc(4 * n);
  unsigned char *out = malloc(4 * n);
  if (!in || !out) return 1;
  for (size_t i = 0; i < n; i++) {
    in[4 * i] = 0x84;
    in[4 * i + 1] = 0x31;
    in[4 * i + 2] = 0xa4;
    in[4 * i + 3] = 0x39;
  }
  char *ip = (char *)in;
  char *op = (char *)out;
  size_t il = 4 * n;
  size_t ol = 4 * n;
  double start = now();
  size_t rc = iconv(cd, &ip, &il, &op, &ol);
  double took = now() - start;
  if (took >= 2.0) return 2;
  if (rc == (size_t)-1 || il != 0 || ol != 0) return 3;
  for (size_t i = 0; i < n; i++)
    if (out[4 * i] != 0xff || out[4 * i + 1] != 0xff || out[4 * i + 2] != 0 || out[4 * i + 3] != 0) return 4;
  return 0;
}

static int run_case(int id) {
  switch (id) {
  case 0: return edges();
  case 1: return bmp();
  case 2: return supplementary();
  case 3: return malformed();
  case 4: return flood();
  }
  return 99;
}

int main(void) {
  int failed = 0;
  for (int id = 0; id < CASES; id++) {
    pid_t pid = fork();
    if (pid < 0) return 2;
    if (pid == 0) {
      alarm(60);
      _exit(run_case(id));
    }
    int st = 0;
    if (waitpid(pid, &st, 0) != pid) return 2;
    char line[200];
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0) {
      snprintf(line, sizeof line, "ok: %s", names[id]);
    } else if (WIFSIGNALED(st)) {
      snprintf(line, sizeof line, "FAIL: %s: killed by signal %d", names[id], WTERMSIG(st));
      failed++;
    } else {
      snprintf(line, sizeof line, "FAIL: %s: exit %d", names[id], WEXITSTATUS(st));
      failed++;
    }
    say(line);
  }
  return failed ? 1 : 0;
}
""",
    )

    let syscalls = fp"{rootfs}/usr/include/bits/syscall.h".read_text()?
    ensure("#define __NR_openat" in syscalls and "#define SYS_openat" in syscalls, "proof-musl", "bits/syscall.h lacks __NR_* or SYS_* names")

    let hello = fp"{tmp}/hello"
    let dynlinker = fp"{rootfs}/usr/lib/{ldso}"
    compile_program(cc, rootfs, hello_src, hello, triple, dynlinker, build_arch, arch)
    let header = run.text $readelf "-h" $hello
    ensure(elf_machine_name(target)? in header, "proof-musl", f"hello binary is not {arch}")

    let regcomp_prog = fp"{tmp}/regcomp"
    compile_program(cc, rootfs, regcomp_src, regcomp_prog, triple, dynlinker, build_arch, arch)
    let iconv_prog = fp"{tmp}/gb18030"
    compile_program(cc, rootfs, iconv_src, iconv_prog, triple, dynlinker, build_arch, arch)

    if build_arch == arch {
      let out = run.text $dynlinker $hello
      let trimmed = out.trim()

      if trimmed != "hello musl" {
        return Err(ScriptError.Failed(kind: "proof-musl", message: f"unexpected output: {trimmed}"))?
      }

      print "musl ok: "${trimmed}
      run_regression(dynlinker, regcomp_prog, "proof-musl-regcomp")
      run_regression(dynlinker, iconv_prog, "proof-musl-gb18030")
    } else {
      print "musl ok: cross-built "${arch}
    }
  }
}
