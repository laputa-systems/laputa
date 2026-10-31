#!/bin/xsh
proc main() [fs, process, env, error] {
  let status = json.read(p"/run/xinit/mdevd.json")?
  guard json.get(status, ["ready"], false).require(Bool)? else { fail "mdevd did not signal readiness" }
  let result = process.run(process.command_argv(/usr/bin/mdevd-coldplug, ["mdevd-coldplug", "-O", "4"]))?
  guard result.ok else { fail "mdevd coldplug failed" }
}
main()
