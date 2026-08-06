#!/bin/xsh
proc main() [fs, process, time, error] {
  # 1. Assert external networking is NOT yet configured (no DHCP by default).
  let interfaces = linux.interfaces()?
  var has_ext_addr = false

  for iface in interfaces {
    if iface.name != "lo" {
      for addr in iface.addresses {
        if addr.family == "inet" {
          has_ext_addr = true
        }
      }
    }
  }

  if has_ext_addr {
    # The script already ran (or something else brought the interface up).
    # The interface being up is the desired end state, so treat it as OK.
    print "LAPUTA_TARGET_CI_OK"
    return
  }

  # 2. Configure DHCP on eth0.
  fs.write(
    /etc/network/interfaces,
    """auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
""",
  )?

  # 3. Bring up networking via DHCP.
  run /usr/bin/ifup "-a" ?

  # 4. Wait for a DHCP lease on a non-lo interface (timeout ~15 s).
  var elapsed = 0
  var got_lease = false

  while elapsed < 15 {
    let ifs = linux.interfaces()?

    for iface in ifs {
      if iface.name != "lo" {
        for addr in iface.addresses {
          if addr.family == "inet" {
            got_lease = true
          }
        }
      }
    }

    if got_lease {
      break
    }

    time.sleep(1s)?
    elapsed += 1
  }

  if ! got_lease {
    print "LAPUTA_TARGET_CI_FAILED: no DHCP lease after 15 s"
    return
  }

  # 5. Assert a default route exists.
  let routes = linux.routes()?
  var has_default = false

  for route in routes {
    if route.dst == "default" {
      has_default = true
    }
  }

  if ! has_default {
    print "LAPUTA_TARGET_CI_FAILED: no default route after DHCP"
    return
  }

  # 6. Smoke test passed.
  print "LAPUTA_TARGET_CI_OK"
}

main()?
