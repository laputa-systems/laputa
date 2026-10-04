##! Parser generator CLI and definition lookup coverage without Linux build modules.
proc generator_runner() [process, env, error] -> Result[Path] {
  let configured = env.get("XSH_HOST") ?? ""
  return fp"{configured}" when configured != ""
  process.which("xsh")?
}

test test_bison_parses_linux_kconfig_argv_and_rejects_missing_grammar [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-bison-kconfig")?
  let grammar = fp"{root}/scripts/kconfig/parser.y"
  let output = fp"{root}/scripts/kconfig/parser.tab.c"
  let header = fp"{root}/scripts/kconfig/parser.tab.h"
  let stderr = fp"{root}/bison.err"
  let modules = path.absolute(p".")?
  let xsh = generator_runner()?
  let bison = fp"{modules}/packages/bison/files/bison.xsh"
  fs.mkdir(grammar.parent)?
  fs.write(
    grammar,
    "%token WORD\n%start input\n%%\ninput: WORD ;\n%%\n",
  )?

  let success = process.run(
    process.command_argv(
      xsh,
      [
        xsh.display(),
        bison.display(),
        "--",
        "-o",
        "scripts/kconfig/parser.tab.c",
        "--defines=scripts/kconfig/parser.tab.h",
        "-t",
        "-l",
        "scripts/kconfig/parser.y",
      ],
      cwd: root,
      env: {XSH_BISON_NO_UPSTREAM: "1"},
      stderr:,
    ),
  )?
  if ! success.ok {
    test.fail(stderr.read_text()?)?
  }

  assert success.ok
  assert output.exists()?
  assert header.exists()?
  assert "#define WORD 258" in header.read_text()?

  let missing = process.run(
    process.command_argv(
      xsh,
      [
        xsh.display(),
        bison.display(),
        "--",
        "-o",
        "scripts/kconfig/parser.tab.c",
        "--defines=scripts/kconfig/parser.tab.h",
        "-t",
        "-l",
        "scripts/kconfig/missing.y",
      ],
      cwd: root,
      env: {XSH_BISON_NO_UPSTREAM: "1"},
      stderr:,
    ),
  )?
  assert missing.ok == false
  assert "No such file or directory" in stderr.read_text()?
}

test test_flex_parses_linux_kconfig_argv_and_rejects_missing_input [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-flex-kconfig")?
  let lexer = fp"{root}/scripts/kconfig/lexer.l"
  let output = fp"{root}/scripts/kconfig/lexer.lex.c"
  let stderr = fp"{root}/flex.err"
  let modules = path.absolute(p".")?
  let xsh = generator_runner()?
  let flex = fp"{modules}/packages/flex/files/flex.xsh"
  fs.mkdir(lexer.parent)?
  fs.write(lexer, "WORD [a-z]+\n%%\n{WORD} return 1;\n%%\n")?

  let success = process.run(
    process.command_argv(
      xsh,
      [
        xsh.display(),
        flex.display(),
        "--",
        "-oscripts/kconfig/lexer.lex.c",
        "-L",
        "scripts/kconfig/lexer.l",
      ],
      cwd: root,
      env: {XSH_FLEX_NO_UPSTREAM: "1"},
      stderr:,
    ),
  )?
  if ! success.ok {
    test.fail(stderr.read_text()?)?
  }

  assert output.exists()?
  assert "([a-z]+)" in output.read_text()?

  let missing = process.run(
    process.command_argv(
      xsh,
      [
        xsh.display(),
        flex.display(),
        "--",
        "-oscripts/kconfig/lexer.lex.c",
        "-L",
        "scripts/kconfig/missing.l",
      ],
      cwd: root,
      env: {XSH_FLEX_NO_UPSTREAM: "1"},
      stderr:,
    ),
  )?
  assert missing.ok == false
  assert "No such file or directory" in stderr.read_text()?
}
