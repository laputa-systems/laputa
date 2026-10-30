use system.qmp
use system.qemu

proc main(...args: List[Str]) [process, net, time, error] {
  if args[1] == "stop" or args[1] == "cont" {
    let control = if args[1] == "stop" { qemu.QemuStop } else { qemu.QemuContinue }
    qemu.qemu_control(Path(args[0]), control)?
    print "ok"
    return
  }
  let kind = if args[1] == "mutation" { qmp.QmpMutation } else { qmp.QmpReadOnly }
  let steps = if args[1] == "multi" or args[1] == "slow-multi" {
    [qmp.QmpExecute("query-status", "{}", kind), qmp.QmpDelay(1), qmp.QmpExecute("query-name", "{}", kind)]
  } else {
    [qmp.QmpExecute("query-status", "{}", kind)]
  }
  let timeout = if args[1] == "flood" or args[1] == "slow-multi" { 200 } else { 2000 }
  qmp.qmp_run_until(Path(args[0]), steps, time.monotonic()? + timeout * 1000000)?
  print "ok"
}
