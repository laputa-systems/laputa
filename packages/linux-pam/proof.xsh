use pm.proof
use pm.util as pm_util

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  let arch = pm_util.target_arch()?

  for rel in [
    p"usr/lib/libpam.so.0",
    p"usr/lib/security/pam_unix.so",
    p"usr/lib/security/pam_rootok.so",
    p"usr/lib/security/pam_permit.so",
    p"usr/lib/security/pam_deny.so",
    p"etc/pam.d/sudo",
    p"etc/pam.d/su",
    p"etc/pam.d/su-l",
  ] {
    proof.ensure(fs.exists(fp"{rootfs}/{rel}")?, "proof-linux-pam", f"missing {rel}")
  }

  proof.target_elf(rootfs, p"usr/lib/libpam.so.0", "linux-pam")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"linux-pam ok: cross-built {arch}"
    return
  }

  let cc = process.which("cc")?
  let tmp = fp"{rootfs}/var/tmp/proof-linux-pam"
  fs.remove(tmp, missing_ok: true)
  fs.mkdir(fp"{tmp}/pam.d", true)
  defer fs.remove(tmp, missing_ok: true)?

  # Two services in a private config directory: libpam must parse each stack,
  # dlopen the named module from the payload, and return that module's verdict.
  fs.write(fp"{tmp}/pam.d/proof-permit", f"auth required {rootfs}/usr/lib/security/pam_permit.so\n")
  fs.write(fp"{tmp}/pam.d/proof-deny", f"auth required {rootfs}/usr/lib/security/pam_deny.so\n")

  fs.write(
    fp"{tmp}/proof-pam.c",
    """#include <stdio.h>
#include <security/pam_appl.h>

static int conv(int n, const struct pam_message **msg, struct pam_response **resp, void *data) {
  (void)n; (void)msg; (void)resp; (void)data;
  return PAM_CONV_ERR;
}

static int authenticate(const char *service, const char *confdir) {
  struct pam_conv c = {conv, NULL};
  pam_handle_t *pamh = NULL;
  int rc = pam_start_confdir(service, "root", &c, confdir, &pamh);
  if (rc != PAM_SUCCESS) return -1;
  rc = pam_authenticate(pamh, 0);
  pam_end(pamh, rc);
  return rc;
}

int main(int argc, char **argv) {
  if (argc != 2) return 1;
  if (authenticate("proof-permit", argv[1]) != PAM_SUCCESS) return 2;
  if (authenticate("proof-deny", argv[1]) != PAM_AUTH_ERR) return 3;
  return 0;
}
""",
  )

  let binary = fp"{tmp}/proof-pam"
  run $cc fp"{tmp}/proof-pam.c" f"-I{rootfs}/usr/include" f"-L{rootfs}/usr/lib" "-lpam" "-o" $binary ?

  env ({
    LD_LIBRARY_PATH: fp"{rootfs}/usr/lib".display(),
  }) {
    run $binary fp"{tmp}/pam.d" ?
  }

  print f"linux-pam ok: {arch} permit and deny stacks"
}

main(@args)
