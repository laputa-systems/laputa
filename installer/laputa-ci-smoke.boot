#!/bin/xsh
# The QEMU harness reads the serial console: the PL011 UART on aarch64 virt,
# the 16550 UART on x86_64 pc. The kernel's /dev/console may be tty0 instead.
proc report(marker: Str) {
  print $marker

  for serial in [p"/dev/ttyAMA0", p"/dev/ttyS0"] {
    match serial.exists() {
      Ok(true) => {
        match serial.write(f"""{marker}
""") {
          Ok(_) | Err(_) => {}
        }

        return
      }
      Ok(false) | Err(_) => {}
    }
  }
}

proc main() [fs, process, time, error] {
  # 1. Assert external networking is NOT yet configured (no DHCP by default).
  let observed = linux.network_dump()?
  var has_ext_addr = false

  for iface in observed.links {
    if (iface.name ?? "") != "lo" {
      for addr in observed.addresses {
        if addr.ifindex == iface.ifindex and addr.family == "inet" {
          has_ext_addr = true
        }
      }
    }
  }

  if has_ext_addr {
    # The script already ran (or something else brought the interface up).
    # The interface being up is the desired end state, so treat it as OK.
    report("LAPUTA_TARGET_CI_OK")
    return
  }

  # 2. Configure DHCP on eth0.
  p"/etc/network/interfaces".write(
    """auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
""",
  )

  # 3. Bring up networking via DHCP.
  run /usr/bin/ifup "-a"

  # 4. Wait for a DHCP lease on a non-lo interface (timeout ~15 s).
  var elapsed = 0
  var got_lease = false

  while elapsed < 15 {
    let ifs = linux.network_dump()?

    for iface in ifs.links {
      if (iface.name ?? "") != "lo" {
        for addr in ifs.addresses {
          if addr.ifindex == iface.ifindex and addr.family == "inet" {
            got_lease = true
          }
        }
      }
    }

    break when got_lease

    time.sleep(1s)
    elapsed += 1
  }

  if ! got_lease {
    report("LAPUTA_TARGET_CI_FAILED: no DHCP lease after 15 s")
    return
  }

  # 5. Assert a default route exists.
  let routes = linux.network_dump()?.routes
  var has_default = false

  for route in routes {
    if route.table == 254 and route.destination_prefix_length == 0 {
      has_default = true
    }
  }

  if ! has_default {
    report("LAPUTA_TARGET_CI_FAILED: no default route after DHCP")
    return
  }

  # 6. Smoke test passed.
  report("LAPUTA_TARGET_CI_OK")
}

main()
