#!/bin/xsh
# The QEMU harness reads the serial console: the PL011 UART on aarch64 virt,
# the 16550 UART on x86_64 pc. The kernel's /dev/console may be tty0 instead.
proc report(marker: Str) [fs] {
  print $marker

  for serial in [/dev/ttyAMA0, /dev/ttyS0] {
    match fs.exists(serial) {
      Ok(true) => {
        match fs.write(serial, f"""{marker}
""") {
          Ok(_) | Err(_) => {}
        }

        return
      }
      Ok(false) | Err(_) => {}
    }
  }
}

proc main() [fs, process, error] {
  return unless fs.exists(/etc/laputa-installer/ci)?
  return when fs.exists(/etc/laputa-installer/ci.started)?

  fs.write(/etc/laputa-installer/ci.started, "1\n")?

  match process.run(process.command_argv(/usr/bin/setup-laputa, ["setup-laputa", "--ci"], timeout: 120s)) {
    Ok(status) => report(if status.ok { "LAPUTA_INSTALLER_CI_OK" } else { "LAPUTA_INSTALLER_CI_FAILED" })
    Err(err) => {
      print ${err.message}
      report("LAPUTA_INSTALLER_CI_FAILED")
    }
  }
}

main()?
