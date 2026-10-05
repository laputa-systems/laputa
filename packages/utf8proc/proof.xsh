use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "utf8proc")
  proof.target_elf(root, p"usr/lib/libutf8proc.so.3", "utf8proc")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "utf8proc ok: cross-built"
    return
  }

  let cc = process.which("cc")?
  let tmp = fp"{root}/var/tmp/proof-utf8proc"
  tmp.remove()
  tmp.mkdir(true)
  defer tmp.remove()

  # tmux asks utf8proc for display widths, so the proof checks a wide CJK
  # character and a combining mark alongside NFC composition.
  fp"{tmp}/proof-utf8proc.c".write(
    """#include <stdlib.h>
#include <string.h>
#include <utf8proc.h>

int main(void) {
  utf8proc_uint8_t *nfc = utf8proc_NFC((const utf8proc_uint8_t *)"e\\xcc\\x81");
  if (nfc == NULL || strcmp((const char *)nfc, "\\xc3\\xa9") != 0) {
    return 1;
  }
  free(nfc);
  if (utf8proc_charwidth(0x4e00) != 2 || utf8proc_charwidth(0x0301) != 0 || utf8proc_charwidth('a') != 1) {
    return 2;
  }
  return strncmp(utf8proc_version(), "2.", 2) == 0 ? 0 : 3;
}
""",
  )

  let binary = fp"{tmp}/proof-utf8proc"
  run $cc fp"{tmp}/proof-utf8proc.c" f"-I{root}/usr/include" f"-L{root}/usr/lib" "-lutf8proc" "-o" $binary

  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib".display(),
  }) {
    run $binary
  }

  print "utf8proc ok: NFC, character widths"
}
