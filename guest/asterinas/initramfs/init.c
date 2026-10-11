// The initramfs handoff must exec from its only thread because Asterinas waits
// for sibling threads to exit during execve, while the XSH CLI keeps its main
// thread waiting for a separate script-preparation thread.

typedef long SysResult;

static SysResult syscall2(long number, long first, long second) {
  register long arg1 __asm__("rdi") = first;
  register long arg2 __asm__("rsi") = second;
  register long result __asm__("rax") = number;
  __asm__ volatile("syscall"
                   : "+a"(result)
                   : "D"(arg1), "S"(arg2)
                   : "rcx", "r11", "memory");
  return result;
}

static SysResult syscall3(long number, long first, long second, long third) {
  register long arg1 __asm__("rdi") = first;
  register long arg2 __asm__("rsi") = second;
  register long arg3 __asm__("rdx") = third;
  register long result __asm__("rax") = number;
  __asm__ volatile("syscall"
                   : "+a"(result)
                   : "D"(arg1), "S"(arg2), "d"(arg3)
                   : "rcx", "r11", "memory");
  return result;
}

static SysResult syscall5(long number, long first, long second, long third,
                          long fourth, long fifth) {
  register long arg1 __asm__("rdi") = first;
  register long arg2 __asm__("rsi") = second;
  register long arg3 __asm__("rdx") = third;
  register long arg4 __asm__("r10") = fourth;
  register long arg5 __asm__("r8") = fifth;
  register long result __asm__("rax") = number;
  __asm__ volatile("syscall"
                   : "+a"(result)
                   : "D"(arg1), "S"(arg2), "d"(arg3), "r"(arg4), "r"(arg5)
                   : "rcx", "r11", "memory");
  return result;
}

static long text_length(const char *text) {
  long length = 0;
  while (text[length] != '\0') {
    length++;
  }
  return length;
}

static void write_text(const char *text) {
  const char *cursor = text;
  long remaining = text_length(text);
  while (remaining > 0) {
    SysResult written = syscall3(1, 2, (long)cursor, remaining);
    if (written <= 0) {
      return;
    }
    cursor += written;
    remaining -= written;
  }
}

static void write_number(long number) {
  char digits[24];
  long index = 0;
  unsigned long magnitude;

  if (number < 0) {
    write_text("-");
    magnitude = (unsigned long)(-number);
  } else {
    magnitude = (unsigned long)number;
  }

  do {
    digits[index++] = (char)('0' + (magnitude % 10));
    magnitude /= 10;
  } while (magnitude > 0);

  while (index > 0) {
    char digit[1] = {digits[--index]};
    syscall3(1, 2, (long)digit, 1);
  }
}

__attribute__((noreturn)) static void fail(const char *phase, SysResult result) {
  write_text("LAPUTA_ASTERINAS_TEST_FAILED init ");
  write_text(phase);
  write_text(" errno=");
  write_number(result);
  write_text("\n");
  syscall2(60, 1, 0);
  __builtin_unreachable();
}

static void require_success(const char *phase, SysResult result) {
  if (result < 0) {
    fail(phase, result);
  }
}

static void require_path(const char *phase, const char *path) {
  SysResult result = syscall3(21, (long)path, 0, 0);
  if (result < 0) {
    fail(phase, result);
  }
}

void _start(void) {
  char *const argv[] = {"/init", 0};
  char *const envp[] = {"PATH=/usr/bin:/bin",
                       "XSH_MODULE_PATH=/usr/lib/xsh/core", 0};

  write_text("LAPUTA_ASTERINAS_INITRAMFS_START\n");
  require_success("mount-dev", syscall5(165, (long)"devtmpfs", (long)"/dev",
                                       (long)"devtmpfs", 0, 0));
  require_success("mount-proc", syscall5(165, (long)"proc", (long)"/proc",
                                        (long)"proc", 0, 0));
  require_success("mount-sys", syscall5(165, (long)"sysfs", (long)"/sys",
                                       (long)"sysfs", 0, 0));
  write_text("LAPUTA_ASTERINAS_SYSFS_MOUNT_OK\n");
  require_success("mount-ext2", syscall5(165, (long)"/dev/vda", (long)"/newroot",
                                         (long)"ext2", 0, 0));
  write_text("LAPUTA_ASTERINAS_EXT2_MOUNT_OK\n");

  require_path("missing-laputa-init", "/newroot/init");
  require_path("missing-laputa-xsh", "/newroot/usr/bin/xsh");
  require_path("missing-os-release", "/newroot/etc/os-release");
  write_text("LAPUTA_ASTERINAS_NEWROOT_LAYOUT_OK\n");
  write_text("LAPUTA_ASTERINAS_SWITCH_ROOT_START\n");

  require_success("move-proc", syscall5(165, (long)"/proc",
                                       (long)"/newroot/proc", 0, 8192, 0));
  require_success("move-sys", syscall5(165, (long)"/sys",
                                       (long)"/newroot/sys", 0, 8192, 0));
  require_success("move-dev", syscall5(165, (long)"/dev",
                                      (long)"/newroot/dev", 0, 8192, 0));
  write_text("LAPUTA_ASTERINAS_PSEUDO_MOUNTS_MOVED_OK\n");
  require_success("chdir-newroot", syscall2(80, (long)"/newroot", 0));
  write_text("LAPUTA_ASTERINAS_NEWROOT_CHDIR_OK\n");
  require_success("chroot-newroot", syscall2(161, (long)".", 0));
  write_text("LAPUTA_ASTERINAS_CHROOT_OK\n");
  require_success("chdir-root", syscall2(80, (long)"/", 0));
  require_path("missing-root-init", "/init");
  write_text("LAPUTA_ASTERINAS_ROOT_INIT_SCRIPT_START\n");
  write_text("LAPUTA_ASTERINAS_INIT_EXEC_START\n");
  require_success("exec-root-init",
                  syscall3(59, (long)"/init", (long)argv, (long)envp));
  fail("exec-returned", -1);
}
