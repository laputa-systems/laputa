##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "expat")
  proof.target_elf(root, p"usr/lib/libexpat.so.1", "expat")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "expat ok: cross-built"
    return
  }

  let cc = process.which("cc")?
  let tmp = fp"{root}/var/tmp/proof-expat"
  tmp.remove(missing_ok: true)
  tmp.mkdir(true)
  defer tmp.remove(missing_ok: true)?

  # wayland-scanner and fontconfig parse their XML through expat: the proof
  # parses a well-formed document with namespaces and rejects a malformed one.
  fp"{tmp}/proof-expat.c".write(
    """#include <string.h>
#include <expat.h>

static int elements;
static int saw_attr;

static void XMLCALL on_start(void *data, const XML_Char *name, const XML_Char **attrs) {
  (void)data;
  elements++;
  if (strcmp(name, "urn:laputa interface") == 0 && attrs[0] != NULL && strcmp(attrs[1], "wl_seat") == 0) saw_attr = 1;
}

static void XMLCALL on_end(void *data, const XML_Char *name) {
  (void)data; (void)name;
}

int main(void) {
  const char *good = "<protocol xmlns='urn:laputa'><interface name='wl_seat'/><interface name='wl_output'/></protocol>";
  XML_Parser p = XML_ParserCreateNS(NULL, ' ');
  if (p == NULL) return 1;
  XML_SetElementHandler(p, on_start, on_end);
  if (XML_Parse(p, good, (int)strlen(good), 1) != XML_STATUS_OK) return 2;
  XML_ParserFree(p);
  if (elements != 3 || !saw_attr) return 3;

  const char *bad = "<protocol><interface></protocol>";
  p = XML_ParserCreate(NULL);
  if (XML_Parse(p, bad, (int)strlen(bad), 1) != XML_STATUS_ERROR) return 4;
  if (XML_GetErrorCode(p) != XML_ERROR_TAG_MISMATCH) return 5;
  XML_ParserFree(p);

  XML_Expat_Version v = XML_ExpatVersionInfo();
  return v.major == 2 ? 0 : 6;
}
""",
  )

  let binary = fp"{tmp}/proof-expat"
  run $cc fp"{tmp}/proof-expat.c" f"-I{root}/usr/include" f"-L{root}/usr/lib" "-lexpat" "-o" $binary ?

  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib".display(),
  }) {
    run $binary ?
  }

  print "expat ok: namespaced parse, tag mismatch rejected"
}

main(@args)
