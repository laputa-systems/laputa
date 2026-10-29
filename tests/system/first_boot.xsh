##! Behavior coverage for first-boot identity, Dropbear argv, and the firewall plan.
use packages.dropbear.service as dropbear_service
use packages.nftables.service as firewall_service
use system.first_boot

const ed25519 = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

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
authorized-key ssh-ed25519 {ed25519} other
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
  assert users[0] == "pazu:x:1000:1000::/home/pazu:/usr/bin/xsh"
  assert passwd.starts_with("root:x:0:0:root:/root:/bin/xshi\n")
  let keys = fp"{root}/home/pazu/.ssh/authorized_keys".read_text()?
  assert keys.lines().len() == 2
  assert fp"{root}/etc/hostname".read_text()? == "laputa-host\n"
  assert fp"{root}/etc/laputa/first-boot/network".read_text()? == "dhcp\n"
  assert fp"{root}/etc/laputa/first-boot/tailscale".read_text()? == "no\n"
  assert ! fp"{root}/etc/laputa/trust-update-key".exists()?
  assert fp"{root}/home/pazu/.ssh".metadata()?.mode % 4096 == 0o700
  assert fp"{root}/home/pazu/.ssh/authorized_keys".metadata()?.mode % 4096 == 0o600
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
  fp"{root}/etc/dropbear/dropbear_ed25519_host_key"
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

test test_dropbear_argv_uses_the_persistent_host_key [error] {
  let persistent = "/etc/dropbear/dropbear_ed25519_host_key"
  let argv = dropbear_service.dropbear_argv()
  assert "-r" in argv
  assert persistent in argv
  assert ! ("-R" in argv)
  let ephemeral = dropbear_service.dropbear_argv("0.0.0.0", 22, p"/etc/dropbear/dropbear_ed25519_host_key", true)
  assert "-R" in ephemeral
  assert ! ("-r" in ephemeral)
  assert ! (persistent in ephemeral)
}

test test_firewall_plan_runs_nft_once_when_the_config_exists [error] {
  assert firewall_service.firewall_plan(false).is_empty()
  let plans = firewall_service.firewall_plan(true)
  assert plans.len() == 1
  assert plans[0] == ["/usr/bin/nft", "-f", "/etc/nftables.conf"]
  firewall_service.firewall_result(0)
  match firewall_service.firewall_result(1) {
    Ok(_) => assert false
    Err(_) => {}
  }
}
