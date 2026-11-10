##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

const jit_source = """#include <llvm-c/Analysis.h>
#include <llvm-c/Core.h>
#include <llvm-c/ExecutionEngine.h>
#include <llvm-c/Target.h>
#include <stdio.h>

int run_jit(void) {
  LLVMLinkInMCJIT();
  if (LLVMInitializeNativeTarget() || LLVMInitializeNativeAsmPrinter()) {
    return 1;
  }
  LLVMModuleRef module = LLVMModuleCreateWithName("proof");
  LLVMTypeRef i32 = LLVMInt32Type();
  LLVMTypeRef params[] = {i32, i32};
  LLVMValueRef add = LLVMAddFunction(module, "add", LLVMFunctionType(i32, params, 2, 0));
  LLVMBuilderRef builder = LLVMCreateBuilder();
  LLVMPositionBuilderAtEnd(builder, LLVMAppendBasicBlock(add, "entry"));
  LLVMBuildRet(builder, LLVMBuildAdd(builder, LLVMGetParam(add, 0), LLVMGetParam(add, 1), "sum"));
  char *error = NULL;
  if (LLVMVerifyModule(module, LLVMReturnStatusAction, &error)) {
    fprintf(stderr, "verify: %s\\n", error);
    return 2;
  }
  LLVMExecutionEngineRef engine;
  if (LLVMCreateMCJITCompilerForModule(&engine, module, NULL, 0, &error)) {
    fprintf(stderr, "mcjit: %s\\n", error);
    return 3;
  }
  int (*fn)(int, int) = (int (*)(int, int))LLVMGetFunctionAddress(engine, "add");
  printf("%d\\n", fn(40, 2));
  return 0;
}
"""

const main_source = """int run_jit(void);

int main(void) {
  return run_jit();
}
"""

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "llvm-static")
  let version = proof.package_version(root, "llvm-static")?.split("-")[0]
  proof.ensure(fp"{root}/usr/lib/llvm-static/lib/libLLVMMCJIT.a".exists()?, "llvm-static-mcjit", "libLLVMMCJIT.a is missing")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "llvm-static ok: cross-built"
    return
  }

  let llvm_config = fp"{root}/usr/lib/llvm-static/bin/llvm-config"
  let reported = env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display()}) {
    run.text $llvm_config "--version"
  }?
  proof.ensure(reported.trim() == version, "llvm-static-config", f"llvm-config reports {reported.trim()}, package {version}")

  let libs = env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display()}) {
    run.text $llvm_config "--ldflags" "--link-static" "--libs" "--system-libs" "mcjit" "native"
  }?.words()
  let cxx = process.which("c++")?
  tempdir tmp at fp"{root}/var/tmp/proof-llvm-static" {
    let source = fp"{tmp}/jit.c"
    let object = fp"{tmp}/jit.o"
    let library = fp"{tmp}/libjit.so"
    let main = fp"{tmp}/main.c"
    let binary = fp"{tmp}/jit"
    source.write(jit_source)
    main.write(main_source)
    let cc = process.which("cc")?
    run $cc "-c" "-fPIC" f"-I{root}/usr/lib/llvm-static/include" $source "-o" $object
    run $cxx "-shared" $object @libs "-o" $library
    for needed in elf.inspect(library)?.needed {
      proof.ensure(! needed.starts_with("libLLVM") and ! needed.starts_with("libc++"), "llvm-static-link", f"the JIT library links {needed}")
    }
    run $cc $main f"-L{tmp}" "-ljit" "-o" $binary
    let out = env ({LD_LIBRARY_PATH: f"{tmp}:{root}/usr/lib"}) {
      run.text $binary
    }?
    proof.ensure(out == "42\n", "llvm-static-jit", f"unexpected JIT result: {out.trim()}")
  }
  print f"llvm-static ok: LLVM {version} MCJIT compiles and runs native code from static archives linked into a shared library"
}
