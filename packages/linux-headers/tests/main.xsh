##! Behavior of the headers_install port that turns kernel uapi headers into installed ones.
use packages.linux-headers.uapi

test test_rewrite_drops_kernel_annotations_and_uapi_guards [error] {
  test.eq(uapi.rewrite_line("long f(void __user *p, int __force x);"), "long f(void *p, int x);")?
  test.eq(uapi.rewrite_line("#include <linux/compiler.h>"), "")?
  test.eq(uapi.rewrite_line("#ifndef _UAPI_ASM_X86_SWAB_H"), "#ifndef _ASM_X86_SWAB_H")?
  test.eq(uapi.rewrite_line("#endif /* _UAPI_ASM_X86_SWAB_H */"), "#endif /* _ASM_X86_SWAB_H */")?
  test.eq(uapi.rewrite_line("static inline __u32 f(void)"), "static __inline__ __u32 f(void)")?
  test.eq(uapi.rewrite_line("} __packed;"), "} __attribute__((packed));")?
}

test test_unifdef_resolves_kernel_only_blocks [error] {
  let text = """#ifdef __KERNEL__
kernel
#else
user
#endif
#ifndef __KERNEL__
also user
#endif
#if defined(__KERNEL__) && !defined(__aarch64__)
kernel again
#endif
#ifdef __EXPORTED_HEADERS__
exported
#endif
"""
  test.eq(uapi.install_text(text)?, "user\nalso user\nexported\n")?
}

test test_unifdef_keeps_unresolved_conditions_verbatim [error] {
  let text = """#if defined(__GNUC__) && !defined(__STRICT_ANSI__) || defined(__KERNEL__)
gnu
#elif defined(__KERNEL__)
kernel
#else
other
#endif
"""
  test.eq(
    uapi.install_text(text)?,
    "#if defined(__GNUC__) && !defined(__STRICT_ANSI__) || defined(__KERNEL__)\ngnu\n#else\nother\n#endif\n",
  )?
}

test test_unifdef_opens_the_block_at_the_first_surviving_elif [error] {
  let text = """#if defined(__KERNEL__)
kernel
#elif defined(__linux__)
linux
#else
other
#endif
"""
  test.eq(uapi.install_text(text)?, "#if   defined(__linux__)\nlinux\n#else\nother\n#endif\n")?
}

test test_unifdef_passes_unrelated_directives_through_and_drops_nested_kernel_code [error] {
  let text = """#ifdef __x86_64__  /* 64-bit */
#ifdef __KERNEL__
#if FOO
dropped
#endif
#endif
#define X(a) \\
  ((a) + 1)
#endif
"""
  test.eq(uapi.install_text(text)?, "#ifdef __x86_64__  /* 64-bit */\n#define X(a) \\\n  ((a) + 1)\n#endif\n")?
}

test test_unifdef_rejects_unbalanced_conditionals [error] {
  match uapi.install_text("#ifdef __KERNEL__\nkernel\n") {
    Ok(_) => test.fail("an unterminated #ifdef was accepted")?
    Err(problem) => assert "#if without #endif" in problem.message
  }
}
