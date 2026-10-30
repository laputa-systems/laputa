use system.qmp

proc main(...args: List[Str]) [process, net, time, error] {
  let kind = if args[1] == "mutation" { qmp.QmpMutation } else { qmp.QmpReadOnly }
  let steps = if args[1] == "multi" {
    [qmp.QmpExecute("query-status", "{}", kind), qmp.QmpDelay(1), qmp.QmpExecute("query-name", "{}", kind)]
  } else {
    [qmp.QmpExecute("query-status", "{}", kind)]
  }
  let timeout = if args[1] == "flood" { 200 } else { 2000 }
  qmp.qmp_linux_run(Path(args[0]), steps, timeout)?
  print "ok"
}
