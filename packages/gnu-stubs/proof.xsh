##! XSH module `proof` package and build operations.
use pm.util as pm_util

const popcount_probe = """#include <dlfcn.h>

int main(void) {
  void *library = dlopen("libgcc_s.so.1", RTLD_NOW);
  if (library == 0) {
    return 1;
  }
  long long (*popcount)(long long) = (long long (*)(long long))dlsym(library, "__popcountdi2");
  if (popcount == 0) {
    return 2;
  }
  return popcount(0xf0f0f0f0f0LL) == 20 ? 0 : 3;
}
"""

error ProofError = Failed(kind: Str, message: Str)

proc main(rootfs = p"/rootfs") [fs, process, env, error] {
  for path_value in [
    fp"{rootfs}/usr/lib/crtbeginS.o",
    fp"{rootfs}/usr/lib/crtendS.o",
    fp"{rootfs}/usr/lib/libgcc_s.so",
    fp"{rootfs}/usr/lib/libgcc_s.so.1",
  ] {
    guard path_value.exists() else {
      return Err(
        ProofError.Failed(kind: "proof-gnu-stubs", message: f"missing {path_value.strip_prefix(rootfs)?.display()}"),
      )
    }
  }

  let link = fp"{rootfs}/usr/lib/libgcc_s.so.1".readlink()?

  if link != "libgcc_s.so" {
    return Err(ProofError.Failed(kind: "proof-gnu-stubs", message: f"libgcc_s.so.1 symlink points to {link}"))
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "gnu-stubs ok: cross-built"
    return
  }

  let cc = process.which("cc")?
  tempdir tmp at fp"{rootfs}/var/tmp/proof-gnu-stubs" {
    let source = fp"{tmp}/popcount.c"
    let probe = fp"{tmp}/popcount"
    source.write(popcount_probe)
    run $cc $source "-o" $probe
    env ({LD_LIBRARY_PATH: fp"{rootfs}/usr/lib".display()}) {
      run $probe
    }?
  }
  print "gnu-stubs ok: libgcc_s exports a working __popcountdi2"
}
