##! Maintained-profile service ownership: supervised logger and DHCPv4 client.
use packages.laputa-net.dhcp-eth0 as dhcp_service
use packages.laputa-net.service as net_service
use packages.laputa-syslog.service as logger_service
use packages.ntpd-rs.service as ntp_service
use packages.oxish.hostkey as oxish_hostkey
use packages.oxish.service as oxish_service
use profiles.qemu-maintained as maintained

test test_dhcp_service_is_a_boot_longrun_with_notify [error] {
  let service = dhcp_service.service
  assert service.name == "dhcp-eth0"
  assert service.kind == "longrun"
  assert service.targets == ["boot"]
  assert service.readiness == "notify"
  assert service.restart.mode == "always"
  assert ! ("dependencies" in service.keys())
}

test test_dhcp_argv_names_the_single_resolver_owner [error] {
  let argv = dhcp_service.dhcp_argv()
  assert argv == ["dhcpc", "--lease-dir", "/var/lib/dhcpc", "--run-dir", "/run/dhcpc", "--resolv-dir", "/etc", "--static-file", "/etc/dhcpc/resolv.static", "eth0"]
  for marker in ["v6", "slaac", "dhcpv6"] {
    assert ! (marker in argv)
  }
}

test test_logger_service_is_a_boot_longrun_with_notify [error] {
  let service = logger_service.service
  assert service.name == "logger"
  assert service.kind == "longrun"
  assert service.targets == ["boot"]
  assert service.readiness == "notify"
  assert service.restart.mode == "always"
  assert ! ("dependencies" in service.keys())
  assert logger_service.syslogd_argv() == ["syslogd", "--state", "/run", "--socket", "/dev/log"]
}

test test_oxish_does_not_wait_on_the_lease [error] {
  let service = oxish_service.service
  let need = service.dependencies.need
  assert service.name == "oxish"
  assert service.kind == "longrun"
  assert service.targets == ["boot"]
  assert service.restart.mode == "always"
  assert "firewall" in need
  assert "oxish-hostkey" in need
  assert "net" in need
  assert ! ("dhcp-eth0" in need)
  assert ! ("logger" in need)
}

test test_oxish_hostkey_is_a_boot_oneshot_before_the_server [error] {
  let service = oxish_hostkey.service
  assert service.name == "oxish-hostkey"
  assert service.kind == "oneshot"
  assert service.targets == ["boot"]
  assert service.name in oxish_service.service.dependencies.need
}

test test_oxish_host_key_and_accounts_live_beside_each_other_on_the_state_disk [error] {
  assert oxish_service.host_key_path == oxish_hostkey.host_key_path
  assert oxish_service.host_key_path.parent == oxish_service.accounts_path.parent
}

test test_oxish_argv_serves_login_mode_with_persistent_key_and_accounts [error] {
  let argv = oxish_service.oxish_argv()
  assert argv[0] == "oxish-server"
  assert argv[1..3] == ["--mode", "login"]
  assert ["--host-key-file", "/etc/oxish/host_ed25519_key"] |> all { |word| word in argv }
  assert ["--accounts", "/etc/oxish/accounts", "--passwd-file", "/etc/passwd", "--group-file", "/etc/group"] |> all { |word| word in argv }
  assert ["--bind", "0.0.0.0", "--port", "22"] |> all { |word| word in argv }
  assert ! ("--allow-root-login" in argv)
  assert ! ("--generate-host-key" in argv)
  let loopback = oxish_service.oxish_argv("127.0.0.1", 2222, p"/tmp/key", p"/tmp/accounts")
  assert "127.0.0.1" in loopback and "2222" in loopback and "/tmp/key" in loopback and "/tmp/accounts" in loopback
}

test test_oxish_keygen_never_forces_a_replacement [error] {
  let argv = oxish_hostkey.keygen_argv()
  assert argv[0] == "/usr/bin/oxish-keygen"
  assert argv[1..3] == ["-f", "/etc/oxish/host_ed25519_key"]
  assert ! ("-y" in argv) and ! ("-l" in argv)
}

test test_loopback_config_claims_no_other_writer [fs, error] {
  let interfaces = p"packages/laputa-net/interfaces".read_text()?
  assert "eth0" not in interfaces
  assert "inet6" not in interfaces
  assert "resolv" not in interfaces
  let oneshot = net_service.service
  assert oneshot.name == "net"
  assert oneshot.kind == "oneshot"
  assert oneshot.targets == ["boot"]
}

test test_maintained_clock_is_authenticated_majority_of_three_operators [fs, error] {
  assert "ntpd-rs" in maintained.profile.package_roots
  assert "ca-certificates" in maintained.profile.package_roots
  assert ntp_service.service.name == "ntpd-rs"
  assert ntp_service.service.targets == ["boot"]
  assert ntp_service.service.readiness == "notify"
  let config = p"packages/ntpd-rs/ntp.toml".read_text()?
  let modes = config.lines() |> where .starts_with("mode = ") |> collect
  assert modes == ["mode = \"nts\"", "mode = \"nts\"", "mode = \"nts\""]
  for operator in ["time.cloudflare.com", "nts.netnod.se", "nts.time.nl"] {
    assert f"address = \"{operator}\"" in config
  }
  assert "minimum-agreeing-sources = 2" in config
  assert "pool" not in config
  assert "frequency-calibration-path = \"/var/lib/ntpd-rs/frequency.json\"" in config
}
