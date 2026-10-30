use system.qmp

proc main(...args: List[Str]) [process, net, time, error] {
  let kind = if args[1] == "mutation" { qmp.QmpMutation } else { qmp.QmpReadOnly }
  let _ = qmp.qmp_linux_execute(Path(args[0]), "query-status", {}, kind, 2000)?
  print "ok"
}
