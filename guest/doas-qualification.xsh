#!/bin/xsh

type ChildEvent = {pid: Int, status: Status}

proc qualification_detached(command: Command) [process, time, error] -> Result[Status, Error] {
  let child = spawn command?
  let event = process.wait_timeout([child], 30s)?
  if event != null {
    return event.status
  }
  process.kill(child.pid, signal: "KILL")?
  let _ = process.wait_any([child])?
  fail "detached privilege qualification timed out"
}

proc qualification_payload(marker: Str) [fs, process, error] {
  let identity = unix.id()?
  let root = user.lookup("root")?
  let groups = user.groups("root", primary_gid: root.gid)?
  assert identity.uid == root.uid and identity.euid == root.uid
  assert identity.gid == root.gid and identity.egid == root.gid
  assert identity.supplementary.len() == groups.len()
  for gid in groups { assert gid in identity.supplementary }
  fp"/run/doas-qualification/{marker}".write("executed\n")?
}

proc qualification_laputa(terminal: Bool) [fs, process, error] {
  let identity = unix.id()?
  let laputa = user.lookup("laputa")?
  let groups = user.groups("laputa", primary_gid: laputa.gid)?
  assert identity.uid == laputa.uid and identity.euid == laputa.uid
  assert identity.gid == laputa.gid and identity.egid == laputa.gid
  assert identity.supplementary.len() == groups.len()
  for gid in groups { assert gid in identity.supplementary }
  assert process.session_id()? == process.parent_pid()?
  if terminal {
    assert unix.isatty(0) and unix.isatty(1) and unix.isatty(2)
    let _ = unix.controlling_tty()?
  } else {
    assert ! unix.isatty(0) and ! unix.isatty(1) and ! unix.isatty(2)
    match unix.controlling_tty() {
      Ok(_) => fail "unexpected controlling terminal"
      Err(_) => {}
    }
  }
  let marker = if terminal { "terminal" } else { "detached" }
  let status = process.run(process.command_argv(
    /usr/bin/doas,
    ["doas", "/usr/bin/xsh", "/usr/lib/laputa/doas-qualification.xsh", "payload", marker],
  ))?
  assert status.ok
  let check = process.run(process.command_argv(
    /usr/bin/doas,
    ["doas", "-C", "/run/doas-qualification/private.conf"],
    stdout: /dev/null,
    stderr: /dev/null,
  ))?
  assert ! check.ok
}

proc qualification_nobody() [fs, process, error] {
  let identity = unix.id()?
  let nobody = user.lookup("nobody")?
  let groups = user.groups("nobody", primary_gid: nobody.gid)?
  assert identity.uid == nobody.uid and identity.euid == nobody.uid
  assert identity.gid == nobody.gid and identity.egid == nobody.gid
  assert identity.supplementary.len() == groups.len()
  for gid in groups { assert gid in identity.supplementary }
  let status = process.run(process.command_argv(
    /usr/bin/doas,
    ["doas", "/usr/bin/xsh", "/usr/lib/laputa/doas-qualification.xsh", "payload", "unauthorized"],
    stdout: /dev/null,
    stderr: /dev/null,
  ))?
  assert ! status.ok
}

proc qualification_denied_command() [fs, process, error] {
  let identity = unix.id()?
  let laputa = user.lookup("laputa")?
  assert identity.uid == laputa.uid and identity.euid == laputa.uid
  assert identity.gid == laputa.gid and identity.egid == laputa.gid
  let status = process.run(process.command_argv(
    /usr/bin/doas,
    ["doas", "/usr/bin/xsh", "/usr/lib/laputa/doas-qualification.xsh", "payload", "unauthorized-command"],
    stdout: /dev/null, stderr: /dev/null,
  ))?
  assert ! status.ok
}

proc qualification_restricted_policy() [fs, process, time, error] {
  let config = p"/etc/doas.conf"
  let original = config.read_text()?
  defer config.write(original)?
  config.write(f"{original}\ndeny laputa cmd /usr/bin/xsh args /usr/lib/laputa/doas-qualification.xsh payload unauthorized-command\n")?
  let status = qualification_detached(process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/doas-qualification.xsh", "denied-command"],
    stdin: /dev/null, stdout: /dev/null, stderr: /dev/null, new_session: true,
  ))?
  assert status.ok
  assert ! p"/run/doas-qualification/unauthorized-command".exists()?
}

proc qualification_run() [fs, process, time, net, error] {
  let executable = p"/usr/bin/doas".metadata()?
  let root_user = user.lookup("root")?
  assert executable.kind == "file" and executable.uid == root_user.uid and executable.setuid
  assert ! executable.world_writable
  var mount = ""
  var mount_options = ""
  for line in p"/proc/self/mountinfo".read_text()?.split("\n") {
    let fields = line.split(" ")
    if fields.len() >= 6 {
      let point = fields[4]
      if (point == "/" or point == "/usr/bin/doas" or "/usr/bin/doas".starts_with(f"{point}/")) and point.byte_len() > mount.byte_len() {
        mount = point
        mount_options = fields[5]
      }
    }
  }
  assert mount != ""
  assert ! ("nosuid" in mount_options.split(",")) and ! ("noexec" in mount_options.split(","))
  assert p"/proc/sys/dev/tty/legacy_tiocsti".read_text()?.trim() == "0"
  let root = p"/run/doas-qualification"
  root.mkdir()?
  root.chmod(0o755)?
  p"/run/doas-qualification/private.conf".write("permit nopass root\n")?
  p"/run/doas-qualification/private.conf".chmod(0o600)?
  let detached = qualification_detached(process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/doas-qualification.xsh", "detached"],
    stdin: /dev/null, stdout: /run/doas-qualification/detached.log, stderr: /run/doas-qualification/detached.log, new_session: true,
  ))?
  if ! detached.ok {
    p"/dev/console".write(p"/run/doas-qualification/detached.log".read_text()?)?
  }
  assert detached.ok
  assert p"/run/doas-qualification/detached".read_text()? == "executed\n"
  let denied = qualification_detached(process.command_argv(
    /usr/bin/su,
    ["su", "nobody", "-s", "/usr/bin/xsh", "/usr/lib/laputa/doas-qualification.xsh", "nobody"],
    stdin: /dev/null, stdout: /dev/null, stderr: /dev/null, new_session: true,
  ))?
  assert denied.ok
  assert ! p"/run/doas-qualification/unauthorized".exists()?
  let pty = unix.open_pty()?
  let child = unix.spawn_with_tty(process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/doas-qualification.xsh", "terminal"],
  ), tty: pty.name)?
  var events: List[ChildEvent] = []
  var tries = 0
  while events.is_empty() and tries < 300 {
    time.sleep(100ms)?
    events = unix.reap_child_events()?.collect()
    for chunk in range(0, 16) {
      let _ = chunk
      if ! ("readable" in unix.poll_fd(pty.master, ["readable"], timeout_ms: 0)?) { break }
      p"/dev/console".write(unix.read_fd(pty.master, 4096)?)?
    }
    tries += 1
  }
  if events.is_empty() {
    process.kill(child.pid, signal: "KILL")?
    fail "terminal qualification timed out"
  }
  assert events.len() == 1 and events[0].pid == child.pid and events[0].status.ok
  unix.close_fd(pty.replica)?
  unix.close_fd(pty.master)?
  assert p"/run/doas-qualification/terminal".read_text()? == "executed\n"
  qualification_restricted_policy()?
  print "LAPUTA_DOAS_QUALIFICATION_OK"
}

proc main(...argv: List[Str]) [fs, process, time, net, error] {
  if argv.is_empty() {
    qualification_run()?
  } else if argv == ["detached"] {
    qualification_laputa(false)?
  } else if argv == ["terminal"] {
    qualification_laputa(true)?
  } else if argv == ["denied-command"] {
    qualification_denied_command()?
  } else if argv == ["nobody"] {
    qualification_nobody()?
  } else if argv.len() == 2 and argv[0] == "payload" {
    qualification_payload(argv[1])?
  } else {
    fail "invalid qualification arguments"
  }
}

main(@args)?
