##! CMake action parsing preserves literal arguments and rejects shell semantics.
use packages.mold.ninja_parser

test quoted_arguments_and_sequence [process, error] {
  let actions = ninja_parser.ninja_actions_parse("cd '/tmp/a && b' && /usr/bin/cc -DNAME=\"a b\" -c 'file;name.c' -o out.o")?
  assert actions == [["cd", "/tmp/a && b"], ["/usr/bin/cc", "-DNAME=a b", "-c", "file;name.c", "-o", "out.o"]]
  assert ninja_parser.ninja_actions_parse(": && /usr/bin/cmake -E rm -f out && /usr/bin/llvm-ar qc out a.o")? == [[":"], ["/usr/bin/cmake", "-E", "rm", "-f", "out"], ["/usr/bin/llvm-ar", "qc", "out", "a.o"]]
  assert ninja_parser.ninja_actions_parse("cc '$HOME' -c x.c -o x.o")?[0][1] == "$HOME"
  assert ninja_parser.ninja_actions_parse("cc '*?[x]~#{a}'")?[0][1] == "*?[x]~#{a}"
}

test reject_shell_semantics [process, error] {
  for text in ["cc x; touch p", "cc x | cat", "cc > out", "cc $HOME", "cc \"$HOME\"", "cc $(id)", "cc `id`", "cc x &", "cc 'unfinished", "cc x &&", "cc *.c", "cc x?", "cc [ab]", "cc ~", "cc x # comment", "cc {a,b}"] {
    match ninja_parser.ninja_actions_parse(text) {
      Ok(_) => test.fail(f"accepted shell syntax: {text}")
      Err(_) => {}
    }
  }
}

test cmake_probe_arguments_and_failure_marker [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "mold actions")?
  let xsh = process.which("xsh")?
  let samu = fp"{root}/samu"
  samu.write(f"""#!{xsh}
proc main(...args: List[Str]) [env] {{
  print ${{e"ACTION_COMMAND" ?? ""}}
}}
""", mode: 0o755)
  let cc = fp"{root}/cc"
  cc.write(f"""#!{xsh}
proc main(...args: List[Str]) [fs, env, error] {{
  fp"{{e"ACTION_OUTPUT" ?? ""}}".write(json.encode(args)?)
}}
""", mode: 0o755)
  let marker = fp"{root}/failure"
  let output = fp"{root}/output"
  let script = fp"{e"XSH_MODULE_PATH" ?? ""}/packages/mold/ninja_actions.xsh"
  let runner = [xsh.display(), script.display(), "cmTC_probe"]
  env ({PATH: f"{root}:{e"PATH" ?? ""}", MOLD_NINJA_FAILURE: marker.display(), ACTION_OUTPUT: output.display(), ACTION_COMMAND: f"'{cc}' -DNAME=\"a b\" -c 'input file.c' -o out.o"}) {
    let status = process.run(process.command_argv(xsh, runner, cwd: root))?
    assert status.ok
    assert json.read(output)?.require(List[Str])? == ["-DNAME=a b", "-c", "input file.c", "-o", "out.o"]
    assert ! marker.exists()?
  }
  env ({PATH: f"{root}:{e"PATH" ?? ""}", MOLD_NINJA_FAILURE: marker.display(), ACTION_COMMAND: "cc x.c; touch escaped"}) {
    let status = process.run(process.command_argv(xsh, runner, cwd: root))?
    assert ! status.ok
    assert marker.exists()?
  }
  marker.remove()
  env ({PATH: f"{root}:{e"PATH" ?? ""}", MOLD_NINJA_FAILURE: marker.display(), ACTION_COMMAND: "cc -c x.c -o generated.h"}) {
    let status = process.run(process.command_argv(xsh, runner, cwd: root))?
    assert ! status.ok
    assert marker.exists()?
  }
  marker.remove()
  env ({PATH: f"{root}:{e"PATH" ?? ""}", MOLD_NINJA_FAILURE: marker.display(), ACTION_COMMAND: "cd '' && cc -c x.c -o x.o"}) {
    let status = process.run(process.command_argv(xsh, runner, cwd: root))?
    assert ! status.ok
    assert marker.exists()?
  }
}
