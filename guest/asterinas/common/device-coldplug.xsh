#!/bin/xsh --
proc main() [process, env, error] {
  let mdevd = unix.spawn_process_group(
    process.command_argv(/usr/bin/xsh, ["xsh", "/usr/lib/asterinas/mdevd-launch.xsh"]),
    notify: true,
  )?
  let readiness = unix.poll_fd(mdevd.notify_fd, ["readable"], 30000)?
  guard "readable" in readiness else { fail "mdevd did not signal readiness" }
  let coldplug = process.run(process.command_argv(/usr/bin/mdevd-coldplug, ["mdevd-coldplug", "-O", "4"]))?
  guard coldplug.ok else { fail "mdevd coldplug failed" }
}

main()
