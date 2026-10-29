#!/bin/xsh

type ChildEvent = {pid: Int, status: Status}

proc qualification_payload(marker: Str) [fs, process, error] {
  let identity = unix.id()?
  assert identity.uid == 0 and identity.euid == 0
  assert identity.gid == 0 and identity.egid == 0
  assert identity.supplementary == [0]
  fp"/run/doas-qualification/{marker}".write("executed\n")?
}

proc qualification_laputa(terminal: Bool) [fs, process, error] {
  let identity = unix.id()?
  assert identity.uid == 1000 and identity.euid == 1000
  assert identity.gid == 1000 and identity.egid == 1000
  assert 4 in identity.supplementary
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
  if terminal and (! p"/proc/sys/dev/tty/legacy_tiocsti".exists() or p"/proc/sys/dev/tty/legacy_tiocsti".read_text()?.trim() != "0") {
    assert ! status.ok
  } else {
    assert status.ok
  }
  let check = process.run(process.command_argv(
    /usr/bin/doas,
    ["doas", "-C", "/run/doas-qualification/private.conf"],
    stdout: /dev/null,
    stderr: /dev/null,
  ))?
  assert ! check.ok
}

proc qualification_nobody() [process, error] {
  let identity = unix.id()?
  assert identity.uid == 99 and identity.euid == 99
  assert identity.gid == 99 and identity.egid == 99
  assert ! (4 in identity.supplementary)
  let status = process.run(process.command_argv(
    /usr/bin/doas,
    ["doas", "/usr/bin/xsh", "/usr/lib/laputa/doas-qualification.xsh", "payload", "unauthorized"],
    stdout: /dev/null,
    stderr: /dev/null,
  ))?
  assert ! status.ok
}

proc qualification_run() [fs, process, time, error] {
  let root = p"/run/doas-qualification"
  root.mkdir()?
  root.chmod(0o755)?
  p"/run/doas-qualification/private.conf".write("permit nopass root\n")?
  p"/run/doas-qualification/private.conf".chmod(0o600)?
  let detached = process.run(process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/doas-qualification.xsh", "detached"],
    stdin: /dev/null, stdout: /dev/null, stderr: /dev/null, new_session: true,
  ))?
  assert detached.ok
  assert p"/run/doas-qualification/detached".read_text()? == "executed\n"
  let denied = process.run(process.command_argv(
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
    tries += 1
  }
  if events.is_empty() {
    process.kill(child.pid, signal: "KILL")?
    fail "terminal qualification timed out"
  }
  assert events.len() == 1 and events[0].pid == child.pid and events[0].status.ok
  unix.close_fd(pty.replica)?
  unix.close_fd(pty.master)?
  if p"/proc/sys/dev/tty/legacy_tiocsti".exists() and p"/proc/sys/dev/tty/legacy_tiocsti".read_text()?.trim() == "0" {
    assert p"/run/doas-qualification/terminal".read_text()? == "executed\n"
  } else {
    assert ! p"/run/doas-qualification/terminal".exists()?
  }
  print "LAPUTA_DOAS_QUALIFICATION_OK"
}

proc main(...argv: List[Str]) [fs, process, time, error] {
  if argv.is_empty() {
    qualification_run()?
  } else if argv == ["detached"] {
    qualification_laputa(false)?
  } else if argv == ["terminal"] {
    qualification_laputa(true)?
  } else if argv == ["nobody"] {
    qualification_nobody()?
  } else if argv.len() == 2 and argv[0] == "payload" {
    qualification_payload(argv[1])?
  } else {
    fail "invalid qualification arguments"
  }
}

main(@args)?
