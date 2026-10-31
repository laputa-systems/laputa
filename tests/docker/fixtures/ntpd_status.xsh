type ClockService = module {
  export proc status() [fs, process, env, error] -> Result[Str, Error]
}
proc main() [fs, process, env, error] {
  let service = module.load(p"/service.xsh")?.require(ClockService)?
  let result = service.status()
  if let Ok(value) = result {
    fail f"unexpected status: {value}"
  }
  print "malformed status rejected"
}
