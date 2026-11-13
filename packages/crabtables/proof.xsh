##! XSH module `crabtables` package proof.
use pm.proof
use pm.util as pm_util

# `nfcrt -c` compiles the whole ruleset in userspace and sends it to the kernel
# as a batch that is aborted instead of committed, so it needs CAP_NET_ADMIN
# over the network namespace. Proof containers run with Docker's default
# capabilities (no CAP_NET_ADMIN) and seccomp profile (no unshare), so the
# kernel refuses every nf_tables message there with EPERM. Leading the ruleset
# with `flush ruleset` makes nfcrt skip its kernel cache dump, so parsing,
# evaluation, and compilation of every command run in userspace and the only
# remaining failure is the kernel refusing the batch at its first command. With
# CAP_NET_ADMIN the check must succeed outright.
const mismatched_ruleset = """flush ruleset

table inet laputa_proof {
	set blocked {
		type ipv6_addr
		elements = { 2001:db8::1 }
	}

	chain input {
		type filter hook input priority filter; policy accept;
		ip saddr @blocked drop
	}
}
"""

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "crabtables")
  proof.target_elf(root, p"usr/bin/nfcrt", "crabtables")
  proof.ensure(fp"{root}/usr/lib/xinit/services/firewall.xsh".exists()?, "proof-crabtables", "missing firewall service module")
  proof.ensure(fp"{root}/etc/nftables.conf".exists()?, "proof-crabtables", "missing /etc/nftables.conf")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"crabtables ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let nfcrt = fp"{root}/usr/bin/nfcrt"
  let ruleset = fp"{root}/etc/nftables.conf"
  tempdir tmp at fp"{root}/var/tmp/proof-crabtables" {

    env ({LD_LIBRARY_PATH: fp"{root}/usr/lib"}) {
      let version = run.text $nfcrt "--version"
      proof.ensure(
        version.trim() == f"nfcrt v{proof.package_version(root, "crabtables")?} (nftables compatible)",
        "crabtables-version",
        f"unexpected version: {version.trim()}",
      )

      let checked = run.capture --text $nfcrt "-c" "-f" $ruleset

      let kernel = if checked.status.ok {
        "accepted by the kernel"
      } else {
        let refused = f"{ruleset}:1:1-14: Error: Could not process rule: Operation not permitted"

        proof.ensure(
          refused in checked.stderr and checked.stderr.split(": Error: ").len() == 2,
          "crabtables-check",
          f"nfcrt -c failed before the kernel boundary: {checked.stderr.trim()}",
        )

        "kernel refused the batch without CAP_NET_ADMIN"
      }

      let mismatched = fp"{tmp}/mismatched.nft"
      mismatched.write(mismatched_ruleset)
      let rejected = run.capture --text $nfcrt "-c" "-f" $mismatched
      proof.ensure(! rejected.status.ok, "crabtables-evaluate", "nfcrt accepted an IPv4 match against an IPv6 set")

      proof.ensure(
        "datatype mismatch, expected IPv4 address, expression has type IPv6 address" in rejected.stderr,
        "crabtables-evaluate",
        f"unexpected evaluation error: {rejected.stderr.trim()}",
      )

      print f"crabtables ok: --version, shipped ruleset compiled ({kernel}), type mismatch rejected"
    }
  }
}
