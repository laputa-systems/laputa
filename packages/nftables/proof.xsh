##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

# `nft --check` evaluates the whole ruleset and sends it to the kernel as a
# batch that is aborted instead of committed, so it needs CAP_NET_ADMIN over
# the network namespace. Proof containers run with Docker's default
# capabilities (no CAP_NET_ADMIN) and seccomp profile (no unshare), so the
# kernel refuses every nf_tables message there with EPERM. Leading the ruleset
# with `flush ruleset` makes nft skip its kernel cache dump, so parsing,
# evaluation, and netlink linearization of every command run in userspace and
# the only remaining failure is the kernel refusing the batch at its first
# command. With CAP_NET_ADMIN the check must succeed outright.
const ruleset = """flush ruleset

table inet laputa_proof {
	set blocked {
		type ipv4_addr
		elements = { 192.0.2.1, 198.51.100.7 }
	}

	chain input {
		type filter hook input priority filter; policy accept;
		ct state established,related accept
		ip saddr @blocked drop
		tcp dport 22 accept
	}
}
"""

# The same ruleset with an IPv6 set matched against an IPv4 address must fail
# in nft's own evaluator, which shows the check above was not vacuous.
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

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "nftables")
  proof.target_elf(root, p"usr/bin/nft", "nftables")
  proof.target_elf(root, p"usr/lib/libnftables.so.1.1.0", "nftables")
  proof.ensure(fp"{root}/usr/include/nftables/libnftables.h".exists()?, "nftables", "missing libnftables.h")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"nftables ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let os = system.uname()?
  let loader = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let nft = fp"{root}/usr/bin/nft"
  let libdir = fp"{root}/usr/lib".display()
  let tmp = fp"{root}/var/tmp/proof-nftables"
  tmp.remove(missing_ok: true)
  tmp.mkdir()
  defer tmp.remove(missing_ok: true)?

  let version = run.text LD_LIBRARY_PATH=$libdir $loader $nft "--version" ?
  proof.ensure(version.trim() == "nftables v1.1.7 (Commodore Bullmoose #8)", "nftables-version", f"unexpected version: {version.trim()}")

  let rules = fp"{tmp}/laputa.nft"
  rules.write(ruleset)
  let checked = run.capture --text LD_LIBRARY_PATH=$libdir $loader $nft "--check" "-f" $rules ?

  let kernel = if checked.status.ok {
    "accepted by the kernel"
  } else {
    let refused = f"{rules}:1:1-14: Error: Could not process rule: Operation not permitted"

    proof.ensure(
      refused in checked.stderr and checked.stderr.split(": Error: ").len() == 2,
      "nftables-check",
      f"nft --check failed before the kernel boundary: {checked.stderr.trim()}",
    )

    "kernel refused the batch without CAP_NET_ADMIN"
  }

  let mismatched = fp"{tmp}/mismatched.nft"
  mismatched.write(mismatched_ruleset)
  let rejected = run.capture --text LD_LIBRARY_PATH=$libdir $loader $nft "--check" "-f" $mismatched ?
  proof.ensure(! rejected.status.ok, "nftables-evaluate", "nft accepted an IPv4 match against an IPv6 set")

  proof.ensure(
    "datatype mismatch, expected IPv4 address, expression has type IPv6 address" in rejected.stderr,
    "nftables-evaluate",
    f"unexpected evaluation error: {rejected.stderr.trim()}",
  )

  print f"nftables ok: --version, ruleset evaluated ({kernel}), type mismatch rejected"
}

main(@args)
