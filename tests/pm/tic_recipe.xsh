##! Golden tests for the XSH terminfo compiler (packages/tic/files/tic.xsh):
##! its compiled entries must be byte-identical to ncurses 6.6 `tic -x`.

const ncurses_sample = [
  "xterm-256color",
  "tmux-256color",
  "screen",
  "linux",
  "vt100",
  "xterm-direct",
  "dumb",
  "foot",
  "konsole-256color",
  "terminology-1.8.1",
  "screen.xterm-xfree86",
]

proc runner() -> Result[Path] {
  let configured = (e"XSH_HOST" ?? "").trim()

  if configured != "" {
    let selected = fp"{configured}"

    return selected when selected.exists()
  }

  process.which("xsh")?
}

proc compile(out: Path, names: List[Str], source: Path) -> Result[Status] {
  let xsh = runner()?
  let argv = [
    xsh.display(),
    "packages/tic/files/tic.xsh",
    "--",
    "-x",
    "-o",
    out.display(),
    "-e",
    names.join(","),
    source.display(),
  ]
  process.run(process.command_argv(xsh, argv))?
}

proc compiled_paths(root: Path) -> Result[List[Str]] {
  fs.walk(root)?
    |> where .kind == "file"
    |> map f"{.path.parent().name()}/{.path.name()}"
    |> sort
}

proc assert_same_tree(expected: Path, actual: Path) {
  let want = compiled_paths(expected)?
  let have = compiled_paths(actual)?
  assert have == want

  for rel in want {
    let reference = fp"{expected}/{rel}".read_bytes()?
    let compiled = fp"{actual}/{rel}".read_bytes()?
    assert compiled == reference, f"{rel} differs from ncurses tic's output"
  }
}

test test_ncurses_sample_matches_ncurses_tic [fs, process, env, error] { |ctx|
  let out = fp"{test.temp_dir(ctx, name: "tic-ncurses")?}/terminfo"
  let status = compile(out, ncurses_sample, p"tests/pm/fixtures/tic/ncurses-sample.src")?
  assert status.ok
  assert_same_tree(p"tests/pm/fixtures/tic/expected-ncurses", out)
}

test test_foot_entries_match_ncurses_tic [fs, process, env, error] { |ctx|
  let out = fp"{test.temp_dir(ctx, name: "tic-foot")?}/terminfo"
  let status = compile(out, ["foot", "foot-direct"], p"tests/pm/fixtures/tic/foot.info")?
  assert status.ok
  assert_same_tree(p"tests/pm/fixtures/tic/expected-foot", out)
}

test test_unresolved_use_fails [fs, process, env, error] { |ctx|
  let dir = test.temp_dir(ctx, name: "tic-unresolved")?
  let source = fp"{dir}/missing.src"
  source.write("needs-base|entry with a missing use target,\n\tam, use=no-such-entry,\n")
  let status = compile(fp"{dir}/terminfo", ["needs-base"], source)?
  assert ! status.ok
  assert ! fp"{dir}/terminfo/n/needs-base".exists()?
}
