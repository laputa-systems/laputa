use system.qmp

proc main(...args: List[Str]) [process, net, time, error] {
  let kind = if args[1] == "mutation" { qmp.QmpMutation } else { qmp.QmpReadOnly }
  let steps = if args[1] == "multi" {
    [qmp.QmpExecute("query-status", "{}", kind), qmp.QmpDelay(1), qmp.QmpExecute("query-name", "{}", kind)]
  } else {
    [qmp.QmpExecute("query-status", "{}", kind)]
  }
  qmp.qmp_linux_run(Path(args[0]), steps, 2000)?
  print "ok"
}
