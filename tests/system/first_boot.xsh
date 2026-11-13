##! Behavior coverage for first-boot identity, the OxiSH accounts file, and the firewall plan.
use packages.crabtables.service as firewall_service
use packages.oxish.hostkey as oxish_hostkey
use packages.oxish.service as oxish_service
use pm.repo_snapshot
use system.first_boot

const ed25519 = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
const other_ed25519 = "AAAAC3NzaC1lZDI1NTE5AAAAIP5dX9+bfK4gA/ycbra29S+WJPifGPkYzWvgR4ZNU783"

proc snapshot(root: Path) -> Result[List[Str]] {
  let lines = collect {
    for entry in fs.walk(root, hidden: true) {
      if entry.path != root {
        let rel = entry.path.strip_prefix(root)?.display()
        let mode = entry.mode % 4096

        if entry.kind == "file" {
          yield f"f {rel} {mode} {entry.path.read_bytes()?.base64()}"
        } else if entry.kind == "dir" {
          yield f"d {rel} {mode}"
        }
      }
    }
  }

  lines |> sort |> collect
}

proc prepare(ctx: TestContext, name: Str) -> Result[Path] {
  let root = test.temp_dir(ctx, name:)?
  fp"{root}/sentinel".write("keep\n")
  root
}

proc reject(ctx: TestContext, name: Str, document: Str) {
  let root = prepare(ctx, name:)?
  let before = snapshot(root)?

  match first_boot.apply(root, document) {
    Ok(_) => assert false
    Err(_) => {}
  }

  assert snapshot(root)? == before
}

pure base(identity: Str) -> Str {
  f"""
hostname laputa-host
operator pazu
authorized-key ssh-ed25519 {ed25519} pazu@laputa
authorized-key ssh-ed25519 {other_ed25519} other
network dhcp
tailscale no
identity {identity}
"""
}

test test_dhcp_apply_is_idempotent [fs, error] { |ctx|
  let root = prepare(ctx, name: "dhcp")?
  fp"{root}/etc".mkdir()
  fp"{root}/etc/passwd".write("root:x:0:0:root:/root:/bin/xshi\n")
  first_boot.apply(root, base("new"))
  let passwd = fp"{root}/etc/passwd".read_text()?
  let users = passwd.lines() |> where .starts_with("pazu:") |> collect
  assert users.len() == 1
  assert users[0] == "pazu:x:1000:1000::/home/pazu:/usr/bin/xsh-login"
  assert passwd.starts_with("root:x:0:0:root:/root:/bin/xshi\n")
  let accounts = fp"{root}/etc/oxish/accounts".read_text()?
  assert accounts == f"# account  key\npazu ssh-ed25519 {ed25519} pazu@laputa\npazu ssh-ed25519 {other_ed25519} other\n"
  assert fp"{root}/etc/oxish/accounts".metadata()?.mode % 4096 == 0o644
  assert fp"{root}/etc/oxish".metadata()?.mode % 4096 == 0o755
  assert ! fp"{root}/home/pazu/.ssh".exists()?
  assert fp"{root}/etc/hostname".read_text()? == "laputa-host\n"
  assert fp"{root}/etc/laputa/first-boot/network".read_text()? == "dhcp\n"
  assert fp"{root}/etc/laputa/first-boot/tailscale".read_text()? == "no\n"
  assert ! fp"{root}/etc/laputa/trust-update-key".exists()?
  let applied = fp"{root}/etc/laputa/first-boot/applied".read_text()?
  assert "hostname laputa-host" in applied
  assert "identity new" in applied
  let after = snapshot(root)?
  first_boot.apply(root, base("new"))
  assert snapshot(root)? == after
  assert (fp"{root}/etc/passwd".read_lines()? |> where .starts_with("pazu:") |> collect).len() == 1
}

test test_static_network_requires_address_and_gateway [fs, error] { |ctx|
  let missing = """
hostname laputa-host
operator pazu
authorized-key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl pazu
network static
tailscale no
identity new
"""
  reject(ctx, "static-missing", missing)
  let address_only = """
hostname laputa-host
operator pazu
authorized-key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl pazu
network static
address 192.0.2.10/24
tailscale no
identity new
"""
  reject(ctx, "static-address", address_only)
  let root = prepare(ctx, name: "static-ok")?
  let document = """
hostname laputa-host
operator pazu
authorized-key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl pazu
network static
address 192.0.2.10/24
gateway 192.0.2.1
tailscale no
identity new
"""
  first_boot.apply(root, document)
  assert fp"{root}/etc/laputa/first-boot/network".read_text()? == "address 192.0.2.10/24\ngateway 192.0.2.1\n"
}

test test_invalid_documents_leave_the_tree_unchanged [fs, error] { |ctx|
  reject(ctx, "bad-hostname", """
hostname -bad
operator pazu
authorized-key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl pazu
network dhcp
tailscale no
identity new
""")
  reject(ctx, "missing-key", """
hostname laputa-host
operator pazu
network dhcp
tailscale no
identity new
""")
  reject(ctx, "ssh-rsa", """
hostname laputa-host
operator pazu
authorized-key ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 pazu
network dhcp
tailscale no
identity new
""")
  reject(ctx, "unknown-field", """
hostname laputa-host
operator pazu
authorized-key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl pazu
network dhcp
console ttyS0
tailscale no
identity new
""")
  let root = prepare(ctx, name: "invalid-after-apply")?
  first_boot.apply(root, base("new"))
  let after = snapshot(root)?
  match first_boot.apply(root, "hostname\nnot-a-field\n") {
    Ok(_) => assert false
    Err(_) => {}
  }
  assert snapshot(root)? == after
}

proc host_key(root: Path) -> Path {
  fp"{root}/etc/oxish/host_ed25519_key"
}

test test_restore_requires_an_unchanged_host_key [fs, error] { |ctx|
  reject(ctx, "restore-missing", base("restore"))
  let root = prepare(ctx, name: "restore-ok")?
  let key = host_key(root)
  key.parent.mkdir()
  let body = b"existing-host-key"
  key.write(body)
  let before = key.read_bytes()?
  first_boot.apply(root, base("restore"))
  assert key.read_bytes()? == before
  assert fp"{root}/etc/hostname".exists()?
}

test test_clone_refuses_an_existing_host_key [fs, error] { |ctx|
  let root = prepare(ctx, name: "clone-present")?
  let key = host_key(root)
  key.parent.mkdir()
  key.write(b"cloned-host-key")
  let before = snapshot(root)?
  match first_boot.apply(root, base("clone")) {
    Ok(_) => assert false
    Err(_) => {}
  }
  assert snapshot(root)? == before
  assert key.read_bytes()? == b"cloned-host-key"
  let fresh = prepare(ctx, name: "clone-absent")?
  first_boot.apply(fresh, base("clone"))
  assert ! host_key(fresh).exists()?
  assert fp"{fresh}/etc/hostname".read_text()? == "laputa-host\n"
}

test test_trust_key_must_be_32_bytes_and_is_not_private [fs, error] { |ctx|
  let short = b"0123456789abcdef0123456789abcde"
  reject(ctx, "trust-short", f"""
hostname laputa-host
operator pazu
authorized-key ssh-ed25519 {ed25519} pazu
network dhcp
trust-key {short.base64()}
tailscale no
identity new
""")
  let raw = b"0123456789abcdef0123456789abcdef"
  let root = prepare(ctx, name: "trust-ok")?
  first_boot.apply(root, f"""
hostname laputa-host
operator pazu
authorized-key ssh-ed25519 {ed25519} pazu
network dhcp
trust-key {raw.base64()}
tailscale no
identity new
""")
  let installed = fp"{root}/etc/laputa/trust-update-key"
  assert installed.read_bytes()? == raw
  assert installed.metadata()?.mode % 4096 == 0o444
  let applied = fp"{root}/etc/laputa/first-boot/applied".read_text()?
  assert raw.base64() in applied
  assert ! ("0123456789abcdef0123456789abcdef" in applied)
}

pure snapshot_fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/repo-snapshot/{name}"
}

proc snapshot_key(name: Str) -> Result[Bytes] {
  snapshot_fixture(f"keys/{name}.public.base64").read_text()?.trim().base64_decode()?
}

pure repo_key_document(keys: List[Bytes]) -> Str {
  let lines = [f"repo-key {key.base64()}" for key in keys]
  base("new") + "\n" + lines.join("\n") + "\n"
}

proc snapshot_input(which: Str, keys: List[Bytes]) -> Result[repo_snapshot.SnapshotVerifyInput] {
  {
    metadata: snapshot_fixture(f"{which}/metadata").read_bytes()?,
    signature: snapshot_fixture(f"{which}/metadata.sig").read_bytes()?,
    keys,
    index_bytes: snapshot_fixture("index.json").read_bytes()?,
    accepted: null,
    now_epoch_seconds: 1995000000,
  }
}

proc snapshot_accepted(which: Str, keys: List[Bytes]) -> Result[Bool] {
  match repo_snapshot.snapshot_verify(snapshot_input(which, keys)?) {
    Ok(_) => true
    Err(_) => false
  }
}

test test_repo_keys_provision_the_snapshot_key_set_and_rotate_by_reapplication [fs, error] { |ctx|
  let current = snapshot_key("signing-key")?
  let next = snapshot_key("next-key")?
  let root = prepare(ctx, name: "repo-keys")?
  first_boot.apply(root, repo_key_document([current]))
  let installed = fp"{root}/etc/laputa/repo-snapshot-keys"
  assert installed.read_bytes()? == current
  assert installed.metadata()?.mode % 4096 == 0o444
  assert snapshot_accepted("snapshot-gen1", repo_snapshot.snapshot_load_keys(installed)?)?
  assert ! snapshot_accepted("snapshot-gen2", repo_snapshot.snapshot_load_keys(installed)?)?

  first_boot.apply(root, repo_key_document([current, next]))
  let window = repo_snapshot.snapshot_load_keys(installed)?
  assert window == [current, next]
  assert snapshot_accepted("snapshot-gen1", window)?
  assert snapshot_accepted("snapshot-gen2", window)?

  first_boot.apply(root, repo_key_document([next]))
  let revoked = repo_snapshot.snapshot_load_keys(installed)?
  assert revoked == [next]
  assert ! snapshot_accepted("snapshot-gen1", revoked)?
  assert snapshot_accepted("snapshot-gen2", revoked)?

  let applied = fp"{root}/etc/laputa/first-boot/applied".read_text()?
  assert f"repo-key {next.base64()}" in applied
  assert ! (f"repo-key {current.base64()}" in applied)
  let after = snapshot(root)?
  first_boot.apply(root, repo_key_document([next]))
  assert snapshot(root)? == after
}

test test_repo_keys_are_exact_distinct_and_bounded [fs, error] { |ctx|
  let short = b"0123456789abcdef0123456789abcde"
  reject(ctx, "repo-short", repo_key_document([short]))
  let key = snapshot_key("signing-key")?
  reject(ctx, "repo-duplicate", repo_key_document([key, key]))
  let keys = [snapshot_key("signing-key")?, snapshot_key("next-key")?, snapshot_key("wrong-key")?, snapshot_key("legacy-key")?]
  let root = prepare(ctx, name: "repo-limit")?
  first_boot.apply(root, repo_key_document(keys))
  assert fp"{root}/etc/laputa/repo-snapshot-keys".read_bytes()?.len() == 128
  reject(ctx, "repo-excess", repo_key_document(keys.extend([b"0123456789abcdef0123456789abcdef"])))
}

test test_a_document_without_repo_keys_leaves_no_snapshot_key_set [fs, error] { |ctx|
  let root = prepare(ctx, name: "repo-absent")?
  first_boot.apply(root, base("new"))
  assert ! fp"{root}/etc/laputa/repo-snapshot-keys".exists()?
}

test test_tailscale_yes_writes_no_auth_key [fs, error] { |ctx|
  let root = prepare(ctx, name: "tailscale")?
  first_boot.apply(root, """
hostname laputa-host
operator pazu
authorized-key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl pazu
network dhcp
tailscale yes
identity new
""")
  assert fp"{root}/etc/laputa/first-boot/tailscale".read_text()? == "yes\n"
  for entry in fs.walk(root, hidden: true) {
    if entry.kind == "file" {
      let text = entry.path.read_text()?
      assert ! ("tskey" in text)
      assert ! ("authkey" in text)
      assert ! ("auth-key" in text)
    }
  }
}

test test_first_boot_and_the_oxish_service_agree_on_the_state_disk_paths [error] {
  assert fp"/{first_boot.host_key_path}" == oxish_service.host_key_path
  assert fp"/{first_boot.host_key_path}" == oxish_hostkey.host_key_path
  assert fp"/{first_boot.accounts_path}" == oxish_service.accounts_path
  assert "--host-key-file" in oxish_service.oxish_argv()
  assert f"{oxish_service.host_key_path}" in oxish_service.oxish_argv()
  assert f"{oxish_service.accounts_path}" in oxish_service.oxish_argv()
}

test test_accounts_follow_the_applied_document_on_reapplication [fs, error] { |ctx|
  let root = prepare(ctx, name: "accounts-rotate")?
  first_boot.apply(root, base("new"))?
  let rotated = base("new").replace(f"authorized-key ssh-ed25519 {other_ed25519} other\n", with: "")
  first_boot.apply(root, rotated)?
  assert fp"{root}/etc/oxish/accounts".read_text()? == f"# account  key\npazu ssh-ed25519 {ed25519} pazu@laputa\n"
}

test test_documents_oxish_would_refuse_never_reach_the_state_tree [fs, error] { |ctx|
  reject(ctx, "duplicate-key", base("new").replace(other_ed25519, with: ed25519))
  reject(ctx, "short-blob", base("new").replace(other_ed25519, with: "AAAAC3NzaC1lZDI1NTE5AAAAIOMq"))
  reject(ctx, "wrong-blob-type", base("new").replace(other_ed25519, with: "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7"))
}

test test_new_operator_skips_used_account_ids [fs, error] { |ctx|
  let root = prepare(ctx, name: "ids")?
  fp"{root}/etc".mkdir()
  fp"{root}/etc/passwd".write("root:x:0:0:root:/root:/bin/xshi\nlaputa:x:1000:1000:Laputa User:/home/laputa:/bin/xshi\n")
  fp"{root}/etc/group".write("root:x:0:\nlaputa:x:1000:\nxinit-admin:x:124:\n")
  fp"{root}/etc/shadow".write("root:*:0:0:99999:7:::\nlaputa:*:0:0:99999:7:::\n")
  fp"{root}/etc/shells".write("/bin/xshi\n")
  first_boot.apply(root, base("new"))
  let passwd = fp"{root}/etc/passwd".read_text()?
  assert "pazu:x:1001:1001::/home/pazu:/usr/bin/xsh-login" in passwd.lines()
  assert "laputa:x:1000:1000:Laputa User:/home/laputa:/bin/xshi" in passwd.lines()
  assert "pazu:x:1001:" in fp"{root}/etc/group".read_lines()?
  assert "xinit-admin:x:124:pazu" in fp"{root}/etc/group".read_lines()?
  assert "pazu:*:0:0:99999:7:::" in fp"{root}/etc/shadow".read_lines()?
  assert "/usr/bin/xsh-login" in fp"{root}/etc/shells".read_lines()?
  let after = snapshot(root)?
  first_boot.apply(root, base("new"))
  assert snapshot(root)? == after
}

test test_first_boot_makes_shadow_root_only_and_keeps_public_identity_files_readable [fs, error] { |ctx|
  let root = prepare(ctx, name: "shadow-mode")?
  fp"{root}/etc".mkdir()
  fp"{root}/etc/passwd".write("root:x:0:0:root:/root:/bin/xshi\n")
  fp"{root}/etc/group".write("root:x:0:\nxinit-admin:x:124:\n")
  fp"{root}/etc/shadow".write("root:*:0:0:99999:7:::\n")
  fp"{root}/etc/shadow".chmod(0o644)
  fp"{root}/etc/shells".write("/bin/xshi\n")
  first_boot.apply(root, base("new"))
  assert "pazu:*:0:0:99999:7:::" in fp"{root}/etc/shadow".read_lines()?
  assert fp"{root}/etc/shadow".metadata()?.mode % 4096 == 0o600
  assert fp"{root}/etc/passwd".metadata()?.mode % 4096 == 0o644
  assert fp"{root}/etc/group".metadata()?.mode % 4096 == 0o644
  assert fp"{root}/etc/shells".metadata()?.mode % 4096 == 0o644
}

test test_first_boot_tightens_an_existing_shadow_mode_without_appending [fs, error] { |ctx|
  let root = prepare(ctx, name: "shadow-existing-mode")?
  fp"{root}/etc".mkdir()
  fp"{root}/etc/passwd".write("root:x:0:0:root:/root:/bin/xshi\npazu:x:1000:1000::/home/pazu:/usr/bin/xsh-login\n")
  fp"{root}/etc/group".write("root:x:0:\npazu:x:1000:\nxinit-admin:x:124:\n")
  fp"{root}/etc/shadow".write("root:*:0:0:99999:7:::\npazu:*:0:0:99999:7:::\n")
  fp"{root}/etc/shadow".chmod(0o644)
  fp"{root}/etc/shells".write("/bin/xshi\n")
  first_boot.apply(root, base("new"))
  assert fp"{root}/etc/shadow".read_text()? == "root:*:0:0:99999:7:::\npazu:*:0:0:99999:7:::\n"
  assert fp"{root}/etc/shadow".metadata()?.mode % 4096 == 0o600
}

test test_firewall_fails_closed_without_a_ruleset [fs, error] {
  match firewall_service.firewall_plan(false) {
    Ok(_) => assert false
    Err(_) => {}
  }

  let plan = firewall_service.firewall_plan(true)?
  assert plan == ["/usr/bin/nfcrt", "-f", "/etc/nftables.conf"]
  firewall_service.firewall_result(0)
  match firewall_service.firewall_result(1) {
    Ok(_) => assert false
    Err(_) => {}
  }

  let ruleset = p"packages/crabtables/nftables.conf".read_text()?
  let recipe = p"packages/crabtables/PKGBUILD.xsh".read_text()?
  assert "flush ruleset" in ruleset
  assert "policy drop;" in ruleset
  assert "tcp dport 22 accept" in ruleset
  assert "meta l4proto icmp accept" in ruleset
  assert "meta l4proto icmpv6 accept" in ruleset
  assert "iif lo accept" in ruleset
  assert "ct state established,related accept" in ruleset
  assert ! ("dport 23" in ruleset)
  assert "meta skuid 123 tcp dport 4460 accept" in ruleset
  assert "meta skuid 123 udp dport 123 accept" in ruleset
  assert "\ttcp dport 4460 drop" in ruleset
  assert "\tudp dport 123 drop" in ruleset
  assert "etc/nftables.conf" in recipe
}

test test_killed_writer_before_publish_leaves_no_partial_tree [fs, error] { |ctx|
  let root = prepare(ctx, name: "killed-writer")?
  fp"{root}/etc".mkdir()
  fp"{root}/etc/passwd".write("root:x:0:0:root:/root:/bin/xshi\n")
  let before = snapshot(root)?
  match first_boot.apply(root, base("new"), "stage") {
    Ok(_) => assert false
    Err(_) => {}
  }
  assert snapshot(root)? == before
  assert ! fp"{root}/etc/laputa/first-boot/applied".exists()?
  first_boot.apply(root, base("new"))
  assert fp"{root}/etc/hostname".read_text()? == "laputa-host\n"
  assert fp"{root}/etc/laputa/first-boot/applied".read_text()? != ""
  assert fp"{root}/sentinel".read_text()? == "keep\n"
  let after = snapshot(root)?
  first_boot.apply(root, base("new"))
  assert snapshot(root)? == after
}

test test_state_image_ownership_uses_allocated_operator_identity [fs, error] { |ctx|
  let root = prepare(ctx, name: "state-owner")?
  fp"{root}/etc".mkdir()?
  fp"{root}/etc/passwd".write("root:x:0:0:root:/root:/bin/xshi\noccupied:x:1000:1000::/home/occupied:/bin/false\n")?
  first_boot.apply(root, base("new"))?
  fp"{root}/format".write("laputa-maintained-state-1\n")?
  let owners = first_boot.state_ownership(root)?
  assert owners == [{path: "home/pazu", uid: 1001, gid: 1001}]
  fp"{root}/etc/oxish/accounts".remove()?
  fp"{root}/etc/oxish/accounts".symlink(to: p"/etc/passwd")?
  assert first_boot.state_ownership(root) is Err(_)
}

test test_state_image_uses_existing_account_primary_group [fs, error] { |ctx|
  let root = prepare(ctx, name: "state-existing-account")?
  fp"{root}/etc".mkdir()?
  fp"{root}/etc/passwd".write("pazu:x:1001:100::/home/pazu:/bin/false\n")?
  first_boot.apply(root, base("new"))?
  fp"{root}/format".write("laputa-maintained-state-1\n")?
  let owners = first_boot.state_ownership(root)?
  assert owners |> all { |owner| owner.uid == 1001 and owner.gid == 100 }
  fp"{root}/etc/passwd".write("pazu:x:1001:100::/home/pazu:/bin/false\npazu:x:1002:100::/home/pazu:/bin/false\n")?
  assert first_boot.state_ownership(root) is Err(_)
}

test test_state_image_publication_preserves_old_output_on_invalid_state [fs, process, env, error] { |ctx|
  let root = prepare(ctx, name: "state-publish")?
  let source = fp"{root}/state"
  let image = fp"{root}/state.ext4"
  first_boot.apply(source, base("new"))?
  fp"{source}/format".write("laputa-maintained-state-1\n")?
  let xsh = Path(e"XSH_HOST" ?? "xsh")
  let argv = [xsh.display(), "system/maintained_state_image.xsh", "--", source.display(), image.display(), "8388608", "packages/laputa-fs/files/mkfs.ext4.xsh", xsh.display()]
  assert process.run(process.command_argv(xsh, argv))?.ok
  assert image.metadata()?.mode.bit_and(0o777) == 0o600
  assert image.metadata()?.size == 8MiB
  image.write("previous")?
  fp"{source}/format".write("wrong\n")?
  assert !process.run(process.command_argv(xsh, argv))?.ok
  assert image.read_text()? == "previous"
}

test test_apply_tightens_preexisting_operator_paths_and_replaces_a_stale_accounts_file [fs, error] { |ctx|
  let root = prepare(ctx, name: "oxish-modes")?
  fp"{root}/etc/oxish".mkdir(parents: true)?
  fp"{root}/home/pazu".mkdir(parents: true)?
  fp"{root}/home/pazu".chmod(0o777)?
  fp"{root}/etc/oxish/accounts".write("stale\n")?
  fp"{root}/etc/oxish/accounts".chmod(0o666)?
  first_boot.apply(root, base("new"))?
  assert fp"{root}/home/pazu".metadata()?.mode % 4096 == 0o755
  assert fp"{root}/etc/oxish/accounts".metadata()?.mode % 4096 == 0o644
  assert "stale" not in fp"{root}/etc/oxish/accounts".read_text()?
}

test test_state_image_ownership_accepts_a_key_file_name_as_operator [fs, error] { |ctx|
  let root = prepare(ctx, name: "state-operator-authorized-keys")?
  let document = base("new").replace("operator pazu", with: "operator authorized_keys")
  first_boot.apply(root, document)?
  fp"{root}/format".write("laputa-maintained-state-1\n")?
  let owners = first_boot.state_ownership(root)?
  assert owners == [{path: "home/authorized_keys", uid: 1000, gid: 1000}]
  assert "\nauthorized_keys ssh-ed25519 " in fp"{root}/etc/oxish/accounts".read_text()?
}
