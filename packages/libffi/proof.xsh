##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libffi")?
  proof.target_elf(root, p"usr/lib/libffi.so.8", "libffi")?

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "libffi ok: cross-built"
    return
  }

  let ver = proof.package_version(root, "libffi")?
  let cc = process.which("cc")?
  let tmp = fp"{root}/var/tmp/proof-libffi"
  fs.remove(tmp, missing_ok: true)?
  fs.mkdir(tmp, true)?
  defer fs.remove(tmp, missing_ok: true)?

  # wayland marshals every request through ffi_call and dispatches events
  # through closures, which use the static trampolines on Linux; the proof
  # makes one call of each kind, including a struct return by value.
  fs.write(
    fp"{tmp}/proof-libffi.c",
    """#include <string.h>
#include <ffi.h>

struct pair { long a; double b; };

static struct pair make_pair(long a, double b) { struct pair p = {a, b}; return p; }
static long add3(long a, long b, long c) { return a + b + c; }

static void closure_body(ffi_cif *cif, void *ret, void **args, void *data) {
  (void)cif;
  *(ffi_arg *)ret = *(int *)args[0] * *(int *)data;
}

int main(int argc, char **argv) {
  if (argc != 2 || strcmp(ffi_get_version(), argv[1]) != 0) return 1;

  ffi_cif cif;
  ffi_type *longs[3] = {&ffi_type_slong, &ffi_type_slong, &ffi_type_slong};
  long x = 40, y = 1, z = 1, sum = 0;
  void *values[3] = {&x, &y, &z};
  if (ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 3, &ffi_type_slong, longs) != FFI_OK) return 2;
  ffi_call(&cif, FFI_FN(add3), &sum, values);
  if (sum != 42) return 3;

  ffi_type *pair_fields[3] = {&ffi_type_slong, &ffi_type_double, NULL};
  ffi_type pair_type = {0, 0, FFI_TYPE_STRUCT, pair_fields};
  ffi_type *pair_args[2] = {&ffi_type_slong, &ffi_type_double};
  long pa = 7;
  double pb = 2.5;
  void *pair_values[2] = {&pa, &pb};
  struct pair got;
  if (ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 2, &pair_type, pair_args) != FFI_OK) return 4;
  ffi_call(&cif, FFI_FN(make_pair), &got, pair_values);
  if (got.a != 7 || got.b != 2.5) return 5;

  void *code;
  ffi_closure *closure = ffi_closure_alloc(sizeof(ffi_closure), &code);
  if (closure == NULL) return 6;
  ffi_type *ints[1] = {&ffi_type_sint};
  int factor = 3;
  if (ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 1, &ffi_type_sint, ints) != FFI_OK) return 7;
  if (ffi_prep_closure_loc(closure, &cif, closure_body, &factor, code) != FFI_OK) return 8;
  int result = ((int (*)(int))code)(14);
  ffi_closure_free(closure);
  return result == 42 ? 0 : 9;
}
""",
  )?

  let binary = fp"{tmp}/proof-libffi"
  run $cc fp"{tmp}/proof-libffi.c" f"-I{root}/usr/include" f"-L{root}/usr/lib" "-lffi" "-o" $binary ?

  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib".display(),
  }) {
    run $binary $ver ?
  }?

  # The version script must export the symbol nodes consumers bind to.
  let readelf = proof.readelf_tool()?
  let symbols = run.text $readelf "--dyn-syms" "-W" fp"{root}/usr/lib/libffi.so.8" ?

  for symbol in ["ffi_call@@LIBFFI_BASE_8.0", "ffi_closure_alloc@@LIBFFI_CLOSURE_8.0", "ffi_get_version@@LIBFFI_BASE_8.1", "ffi_type_sint128@@LIBFFI_INT128_8.3"] {
    proof.ensure(symbol in symbols, "proof-libffi", f"libffi does not export {symbol}")?
  }

  print f"libffi ok: {ver} call, struct return, closure, versioned exports"
}

main(@args)?
