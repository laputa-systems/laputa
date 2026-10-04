##! XSH module `proof` package and build operations.
use pm.proof as proof
use pm.util as pm_util

type RuleCase = {command: Str, table: Str, args: List[Str]}

# Rules of the kind tailscaled installs through go-iptables: conntrack state,
# comments, mark matching and setting, NAT masquerade, and an ICMPv6 match.
# iptables parses every match and target option through the statically linked
# extensions before it opens the kernel table, so failing only at the table
# (iptc_init) proves the extensions registered and accepted their options.
const rule_cases: List[RuleCase] = [
  {
    command: "iptables",
    table: "filter",
    args: ["-A", "INPUT", "-p", "tcp", "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-m", "comment", "--comment", "laputa-proof", "-j", "ACCEPT"],
  },
  {
    command: "iptables",
    table: "mangle",
    args: ["-A", "PREROUTING", "-m", "mark", "--mark", "0x40000/0xff0000", "-j", "MARK", "--set-xmark", "0x0/0xff0000"],
  },
  {
    command: "iptables",
    table: "nat",
    args: ["-A", "POSTROUTING", "-o", "eth0", "-j", "MASQUERADE"],
  },
  {
    command: "ip6tables",
    table: "filter",
    args: ["-A", "INPUT", "-p", "ipv6-icmp", "--icmpv6-type", "echo-request", "-j", "ACCEPT"],
  },
]

# Before using an extension, iptables asks the kernel over a raw socket which
# revision it supports; the answer depends on the host kernel (a kernel
# without the legacy tables answers ENOPROTOOPT, and iptables then falls back
# to revision 0, where MARK has no --set-xmark), and with the tables present
# but no CAP_NET_ADMIN the probe aborts. Without CAP_NET_RAW the socket fails
# with EPERM and iptables assumes every revision, which makes the proof the
# same on every host. This helper drops CAP_NET_ADMIN and CAP_NET_RAW from the
# bounding set, so the exec'd command (still root, empty inheritable and
# ambient sets) holds neither. Capability numbers are from linux/capability.h.
const unprivileged_program = r"""#include <stdio.h>
#include <sys/prctl.h>
#include <unistd.h>

#define CAP_NET_ADMIN 12
#define CAP_NET_RAW 13

int main(int argc, char **argv) {
  if (argc < 2) {
    fputs("usage: without-net-caps PROGRAM [ARG...]\n", stderr);
    return 125;
  }
  if (prctl(PR_CAPBSET_DROP, CAP_NET_ADMIN, 0, 0, 0) != 0 || prctl(PR_CAPBSET_DROP, CAP_NET_RAW, 0, 0, 0) != 0) {
    perror("without-net-caps: PR_CAPBSET_DROP");
    return 125;
  }
  execv(argv[1], argv + 1);
  perror("without-net-caps: execv");
  return 126;
}
"""

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(rootfs, "iptables")?
  proof.target_elf(rootfs, p"usr/bin/xtables-legacy-multi", "iptables")?

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"iptables ok: cross-built {pm_util.target_arch()?}"
    return
  }

  # The musl loader runs each command link with its own path as argv[0], so
  # xtables-legacy-multi dispatches on the installed link name.
  let os = system.uname()?
  let loader = fp"{rootfs}/usr/lib/ld-musl-{os.machine}.so.1"
  let tmp = fp"{rootfs}/var/tmp/proof-iptables"
  fs.remove(tmp, missing_ok: true)?
  fs.mkdir(tmp)?
  defer fs.remove(tmp, missing_ok: true)?
  let lock = fp"{tmp}/xtables.lock"

  for command in ["iptables", "ip6tables", "iptables-save", "ip6tables-save", "iptables-restore", "ip6tables-restore"] {
    let version = run.text $loader fp"{rootfs}/usr/bin/{command}" "-V" ?
    proof.ensure(version.trim() == f"{command} v1.8.13 (legacy)", "iptables-version", f"unexpected {command} -V: {version.trim()}")?
  }

  let cc = process.which("cc")?
  let unprivileged = fp"{tmp}/without-net-caps"
  fs.write(fp"{tmp}/without-net-caps.c", unprivileged_program)?
  run $cc fp"{tmp}/without-net-caps.c" "-o" $unprivileged ?

  for case in rule_cases {
    let program = fp"{rootfs}/usr/bin/{case.command}"
    let table = case.table
    let args = case.args
    let result = run.capture --text XTABLES_LOCKFILE=$lock $unprivileged $loader $program "-t" $table @args ?
    proof.ensure(! result.status.ok, "iptables-rule", f"{case.command} -t {table} succeeded without CAP_NET_ADMIN")?
    let boundary = f"can't initialize {case.command} table `{table}': "

    proof.ensure(
      boundary in result.stderr,
      "iptables-rule",
      f"{case.command} -t {table} failed before the kernel table: {result.stderr.trim()}",
    )?
  }

  let rejected = run.capture --text XTABLES_LOCKFILE=$lock $unprivileged $loader fp"{rootfs}/usr/bin/iptables" "-A" "INPUT" "-m" "conntrack" "--ctstate" "BOGUS" "-j" "ACCEPT" ?
  proof.ensure(! rejected.status.ok, "iptables-parse", "iptables accepted a bogus conntrack state")?
  proof.ensure("Bad ctstate \"BOGUS\"" in rejected.stderr, "iptables-parse", f"unexpected parse error: {rejected.stderr.trim()}")?
  print "iptables ok: legacy -V for every command, extension rules parsed up to the kernel table, bad option rejected"
}

main(@args)?
