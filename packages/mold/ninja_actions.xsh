#!/bin/xsh
use pm.make
use packages.mold.ninja_parser

error NinjaActionsError = Invalid(message: Str)


proc execute(commands: List[List[Str]], cwd: Path) [fs, process, env, error] {
  var directory = cwd
  var first = true
  for argv in commands {
    if argv == [":"] {
      first = false
      continue
    }
    if argv[0] == "cd" {
      guard first and argv.len() == 2 and argv[1] != "" else { return Err(NinjaActionsError.Invalid(message: "invalid cd action")) }
      directory = fp"{argv[1]}"
    } else {
      let name = fp"{argv[0]}".name
      guard name in ["cmake", "cc", "c++", "llvm-ar", "llvm-ranlib"] else {
        return Err(NinjaActionsError.Invalid(message: f"unsupported action: {argv[0]}"))
      }
      let status = process.run(process.command_argv(argv[0], argv, cwd: directory))?
      guard status.ok else { return Err(NinjaActionsError.Invalid(message: f"command failed: {argv[0]}")) }
    }
    first = false
  }
}

proc parse_or_mark(text: Str, failure: Path) [fs, process, env, error] -> Result[List[List[Str]], Error] {
  match ninja_parser.ninja_actions_parse(text) {
    Ok(commands) => {
      var first = true
      for argv in commands {
        let name = fp"{argv[0]}".name
        if (argv[0] == "cd" and (! first or argv.len() != 2 or argv[1] == "")) or (argv[0] != "cd" and argv != [":"] and !(name in ["cmake", "cc", "c++", "llvm-ar", "llvm-ranlib"])) {
          failure.write(f"unsupported action: {text}")
          return Err(NinjaActionsError.Invalid(message: f"unsupported action: {text}"))
        }
        first = false
      }
      commands
    }
    Err(problem) => {
      failure.write(problem.message)
      Err(problem)?
    }
  }
}

pure compile_has_one_object(argv: List[Str]) -> Bool {
  var count = 0
  var output = ""
  var index = 0
  while index < argv.len() {
    if argv[index] == "-o" {
      count += 1
      if index + 1 >= argv.len() { return false }
      output = argv[index + 1]
    }
    index += 1
  }
  count == 1 and output.ends_with(".o")
}

proc main(...args: List[Str]) [fs, process, env, error] {
  let failure_value = (e"MOLD_NINJA_FAILURE" ?? "").trim()
  guard failure_value != "" else { return Err(NinjaActionsError.Invalid(message: "MOLD_NINJA_FAILURE is required")) }
  let failure = fp"{failure_value}"
  let samu = process.which("samu")?
  if args == ["--version"] {
    run $samu "--version"
    return
  }
  var targets: List[Str] = []
  for arg in args {
    continue when arg == "-v" or arg.starts_with("-j")
    if arg.starts_with("-") {
      failure.write(f"unsupported ninja argument: {arg}")
      return Err(NinjaActionsError.Invalid(message: f"unsupported ninja argument: {arg}"))
    }
    targets = targets.push(arg)
  }
  let commands = run.text $samu "-t" "commands" @targets
  let cwd = fs.cwd()?
  var tasks: List[make.MakeTask] = []
  var count = 0
  for line in commands.split("\n") {
    let text = line.trim()
    continue when text == ""
    let actions = parse_or_mark(text, failure)?
    let argv = actions[0]
    if actions.len() == 1 and "-c" in argv and fp"{argv[0]}".name in ["cc", "c++"] {
      if ! compile_has_one_object(argv) {
        failure.write(f"unsupported compile output: {text}")
        return Err(NinjaActionsError.Invalid(message: f"unsupported compile output: {text}"))
      }
      var task_argv: List[Any] = []
      for arg in argv { task_argv = task_argv.push(arg) }
      tasks = tasks.push({name: f"compile-{count}", outputs: [], inputs: [], deps: [], argv: task_argv, cwd, env: {}, depfile: p"", stamp: p""})
      count += 1
    } else {
      make.run_tasks(tasks, make.jobs()?)
      tasks = []
      execute(actions, cwd)
    }
  }
  make.run_tasks(tasks, make.jobs()?)
}
