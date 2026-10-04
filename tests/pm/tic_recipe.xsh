##! Golden tests for the XSH terminfo compiler (packages/tic/files/tic.xsh):
##! its compiled entries must be byte-identical to ncurses 6.6 `tic -x`.
#
# The fixtures under tests/pm/fixtures/tic were made on the host from
# ncurses-6.6.tar.gz (sha256 355b4cbb...9ff11) and foot-1.27.0.tar.gz, with
# ncurses' own tic built from that tarball (`./configure && make`, progs/tic):
#
#   sed '/^xterm+kbs|fragment for backspace key/,/^#/s/kbs=^H,/kbs=^?,/' \
#     ncurses-6.6/misc/terminfo.src > terminfo.src
#   xsh tests/pm/fixtures/tic/sample-closure.xsh -- terminfo.src $SAMPLE \
#     > tests/pm/fixtures/tic/ncurses-sample.src
#   sed 's/@default_terminfo@/foot/g' foot/foot.info > tests/pm/fixtures/tic/foot.info
#   TERMINFO=/nonexistent tic -x -o expected-ncurses -e "${SAMPLE// /,}" ncurses-sample.src
#   TERMINFO=/nonexistent tic -x -o expected-foot -e foot,foot-direct foot.info
#
# with SAMPLE="xterm-256color tmux-256color screen linux vt100 xterm-direct
# dumb foot konsole-256color terminology-1.8.1 screen.xterm-xfree86".  The
# last three exercise use= chains with cancelled standard and extended
# capabilities; xterm-direct and foot-direct use the 32-bit number format.

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

proc runner() [fs, process, env, error] -> Result[Path] {
  let configured = (env.get("XSH_HOST") ?? "").trim()

  if configured != "" {
    let selected = fp"{configured}"

    return selected when selected.exists()?
  }

  process.which("xsh")?
}

proc compile(out: Path, names: List[Str], source: Path) [fs, process, env, error] -> Result[Status] {
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

# Every compiled name under a database root, as `<leaf>/<name>`.
proc compiled_paths(root: Path) [fs, error] -> Result[List[Str]] {
  fs.walk(root)?
    |> where .kind == "file"
    |> map { |entry| f"{entry.path.parent().name()}/{entry.path.name()}" }
    |> sort
}

proc assert_same_tree(expected: Path, actual: Path) [fs, error] {
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
  assert_same_tree(p"tests/pm/fixtures/tic/expected-ncurses", out)?
}

test test_foot_entries_match_ncurses_tic [fs, process, env, error] { |ctx|
  let out = fp"{test.temp_dir(ctx, name: "tic-foot")?}/terminfo"
  let status = compile(out, ["foot", "foot-direct"], p"tests/pm/fixtures/tic/foot.info")?
  assert status.ok
  assert_same_tree(p"tests/pm/fixtures/tic/expected-foot", out)?
}

# tic would look an unknown use= target up in whatever database the host has;
# this compiler fails instead, so a build never depends on the build machine.
test test_unresolved_use_fails [fs, process, env, error] { |ctx|
  let dir = test.temp_dir(ctx, name: "tic-unresolved")?
  let source = fp"{dir}/missing.src"
  source.write("needs-base|entry with a missing use target,\n\tam, use=no-such-entry,\n")?
  let status = compile(fp"{dir}/terminfo", ["needs-base"], source)?
  assert ! status.ok
  assert ! fp"{dir}/terminfo/n/needs-base".exists()?
}
