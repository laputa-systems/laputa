#!/bin/xsh
if fs.exists(/etc/laputa-installer/ci)? {
  if fs.exists(/etc/laputa-installer/ci.started)? {
    return
  }

  fs.write(/etc/laputa-installer/ci.started, "1\n")?

  match process.run(process.command_argv(/usr/bin/setup-laputa, ["setup-laputa", "--ci"], timeout: 120s)) {
    Ok(status) => {
      if status.ok {
        print "LAPUTA_INSTALLER_CI_OK"
        match fs.write(/dev/ttyAMA0, "LAPUTA_INSTALLER_CI_OK\n") {
          Ok(_) => {}
          Err(_) => {}
        }
      } else {
        print "LAPUTA_INSTALLER_CI_FAILED"
        match fs.write(/dev/ttyAMA0, "LAPUTA_INSTALLER_CI_FAILED\n") {
          Ok(_) => {}
          Err(_) => {}
        }
      }
    }
    Err(err) => {
      print ${err.message}
      print "LAPUTA_INSTALLER_CI_FAILED"
      match fs.write(/dev/ttyAMA0, "LAPUTA_INSTALLER_CI_FAILED\n") {
        Ok(_) => {}
        Err(_) => {}
      }
    }
  }
}
