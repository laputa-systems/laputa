##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

# The program parses capability text into a capability set, prints it back in
# libcap's canonical form, reads one flag, maps names to and from numbers
# through the generated name table, and rejects an unknown name.
#
# <sys/capability.h> includes the kernel's <linux/capability.h>, which a
# consumer's build gets from linux-headers; libcap does not depend on it at
# runtime, so the proof root lacks it. The program declares the subset of the
# libcap ABI it calls instead, with the header's types and the kernel's
# capability numbers.
const program = r"""#include <stdio.h>
#include <sys/types.h>

typedef struct _cap_struct *cap_t;
typedef int cap_value_t;
typedef enum { CAP_EFFECTIVE = 0, CAP_PERMITTED = 1, CAP_INHERITABLE = 2 } cap_flag_t;
typedef enum { CAP_CLEAR = 0, CAP_SET = 1 } cap_flag_value_t;
#define CAP_NET_RAW 13
#define CAP_SETFCAP 31

cap_t cap_from_text(const char *);
char *cap_to_text(cap_t, ssize_t *);
int cap_get_flag(cap_t, cap_value_t, cap_flag_t, cap_flag_value_t *);
int cap_from_name(const char *, cap_value_t *);
char *cap_to_name(cap_value_t);
int cap_free(void *);

int main(void) {
  cap_t caps = cap_from_text("cap_net_raw,cap_net_bind_service+ep cap_chown+i");
  cap_value_t value;
  char *text, *name;
  cap_flag_value_t raw_effective;

  if (caps == NULL || (text = cap_to_text(caps, NULL)) == NULL) {
    return 1;
  }
  puts(text);
  if (cap_get_flag(caps, CAP_NET_RAW, CAP_EFFECTIVE, &raw_effective) != 0 || raw_effective != CAP_SET) {
    return 2;
  }
  if (cap_from_name("cap_checkpoint_restore", &value) != 0) {
    return 3;
  }
  name = cap_to_name(CAP_SETFCAP);
  printf("%d %s\n", value, name);
  if (cap_from_text("cap_no_such_thing+ep") != NULL) {
    return 4;
  }
  cap_free(name);
  cap_free(text);
  cap_free(caps);
  return 0;
}
"""

pure current_caps(print_out: Str) -> Str {
  for line in print_out.lines() {
    return line.replace("Current: ", "") when line.starts_with("Current: ")
  }

  ""
}

# Docker's default capability set for root includes CAP_SETPCAP (needed to
# drop from the bounding set) and CAP_SETFCAP (needed to write file
# capabilities). The checks that change capability state run when the proof
# holds them and otherwise must fail with the kernel's refusal, so a
# restricted container still proves the programs reach the kernel.
proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libcap")
  proof.target_elf(root, p"usr/lib/libcap.so.2.78", "libcap")

  for program_name in ["capsh", "getcap", "getpcaps", "setcap"] {
    proof.target_elf(root, fp"usr/bin/{program_name}", "libcap")
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"libcap ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let os = system.uname()?
  let loader = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let libdir = fp"{root}/usr/lib".display()
  let bin = fp"{root}/usr/bin"
  let tmp = fp"{root}/var/tmp/proof-libcap"
  tmp.remove(missing_ok: true)
  tmp.mkdir()
  defer tmp.remove(missing_ok: true)?

  let cc = process.which("cc")?
  fp"{tmp}/proof-libcap.c".write(program)
  let binary = fp"{tmp}/proof-libcap"
  run $cc fp"{tmp}/proof-libcap.c" f"-I{root}/usr/include" f"-L{root}/usr/lib" "-lcap" "-o" $binary ?
  var checks = ["text round-trip"]

  env ({LD_LIBRARY_PATH: libdir}) {
    let text = run.text $binary ?
    proof.ensure(text == "cap_chown=i cap_net_bind_service,cap_net_raw+ep\n40 cap_setfcap\n", "libcap-text", f"unexpected capability text:\n{text}")

    # The executable library reads its argv from /proc/self/cmdline, so when
    # started through the loader it sees the library path as an unknown
    # option: it prints its banner, then usage, and exits 1.
    let banner = run.text --accept=[1] $loader fp"{root}/usr/lib/libcap.so.2.78" ?
    proof.ensure("is the shared library version: libcap-2.78." in banner, "libcap-execable", f"unexpected library banner:\n{banner}")

    let decoded = run.text $loader fp"{bin}/capsh" "--decode=0x3000" ?
    proof.ensure(decoded.trim() == "0x0000000000003000=cap_net_admin,cap_net_raw", "libcap-decode", f"unexpected capsh --decode: {decoded.trim()}")

    let printed = run.text $loader fp"{bin}/capsh" "--print" ?
    let current = current_caps(printed)
    proof.ensure(current != "" and "Bounding set =" in printed, "libcap-capsh", f"unexpected capsh --print:\n{printed}")

    # capsh and getpcaps run as children of this proof with its capabilities.
    let pid = process.current_pid()?
    let pcaps = run.text $loader fp"{bin}/getpcaps" f"{pid}" ?
    proof.ensure(pcaps.trim() == f"{pid}: {current}", "libcap-getpcaps", f"getpcaps disagrees with capsh: {pcaps.trim()} vs {current}")
    checks += ["capsh --print/--decode", "getpcaps"]

    # `--drop` removes cap_net_raw from the bounding set, then capsh runs
    # its shell (/bin/xshi) with `-c`, which prints the bounding set again.
    let inner = f"{loader} {bin}/capsh --print"
    let dropped = run.capture --text $loader fp"{bin}/capsh" "--drop=cap_net_raw" "--" "-c" $inner ?

    if "cap_setpcap" in current and "cap_net_raw" in current {
      proof.ensure(dropped.status.ok, "libcap-drop", f"capsh --drop failed: {dropped.stderr.trim()}")
      let bounding = [line for line in dropped.stdout.lines() if line.starts_with("Bounding set =")]
      proof.ensure(bounding.len() == 1 and ! ("cap_net_raw" in bounding[0]), "libcap-drop", f"cap_net_raw still bounded:\n{dropped.stdout}")
      checks += ["capsh --drop through xshi"]
    } else {
      proof.ensure(! dropped.status.ok, "libcap-drop", "capsh --drop succeeded without CAP_SETPCAP")
    }

    let target = fp"{tmp}/capable"
    fs.install(fp"{bin}/getcap", target, 0o755, overwrite: true)
    let setcap_run = run.capture --text $loader fp"{bin}/setcap" "cap_net_raw,cap_net_bind_service+ep" $target ?

    if "cap_setfcap" in current {
      proof.ensure(setcap_run.status.ok, "libcap-setcap", f"setcap failed: {setcap_run.stderr.trim()}")
      let got = run.text $loader fp"{bin}/getcap" $target ?
      proof.ensure(got.trim() == f"{target} cap_net_bind_service,cap_net_raw=ep", "libcap-getcap", f"unexpected getcap: {got.trim()}")
      checks += ["setcap/getcap file capabilities"]
    } else {
      proof.ensure(! setcap_run.status.ok, "libcap-setcap", "setcap succeeded without CAP_SETFCAP")
    }
  }

  print f"libcap ok: {checks.join(", ")}"
}

main(@args)
