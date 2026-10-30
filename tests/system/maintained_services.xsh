##! Maintained-profile service ownership: supervised logger and DHCPv4 client.
use packages.dropbear.service as dropbear_service
use packages.laputa-net.dhcp-eth0 as dhcp_service
use packages.laputa-net.service as net_service
use packages.laputa-syslog.service as logger_service

test test_dhcp_service_is_a_boot_longrun_without_a_lease_gate [error] {
  let service = dhcp_service.service
  assert service.name == "dhcp-eth0"
  assert service.kind == "longrun"
  assert service.targets == ["boot"]
  assert ! ("readiness" in service.keys())
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

test test_dropbear_does_not_wait_on_the_lease [error] {
  let need = dropbear_service.service.dependencies.need
  assert "firewall" in need
  assert "dropbear-keygen" in need
  assert "net" in need
  assert ! ("dhcp-eth0" in need)
  assert ! ("logger" in need)
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
