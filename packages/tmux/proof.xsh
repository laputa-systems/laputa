use pm.proof
use pm.util as pm_util

error ScriptError = Failed(kind: Str, message: Str)

proc check(condition: Bool, kind: Str, message: Str) {
  if ! condition {
    Err(ScriptError.Failed(kind:, message:))?
  }
}

proc main(rootfs: Path = /rootfs) [fs, process, env, time, error] {
  let os = system.uname()?
  let dynlinker = fp"{rootfs}/usr/lib/ld-musl-{os.machine}.so.1"
  let tmux = fp"{rootfs}/usr/bin/tmux"
  proof.target_elf(rootfs, p"usr/bin/tmux", "tmux")
  let build_arch = pm_util.build_arch()?
  let target_arch = pm_util.target_arch()?

  if build_arch != target_arch {
    print f"tmux ok: cross-built {target_arch}"
    return
  }

  match e"XSH_PM_IN_CHROOT" {
    Ok(_) => {
      print "tmux ok: windowed proof skipped in chroot (no pty under QEMU)"
      return
    }
    Err(_) => {}
  }

  # The session shell is the runner's static xshi. tmux's runtime closure
  # holds no shell (xsh, which owns /usr/bin/sh, is runtime-only and stays out
  # of proof roots), and the proof is about tmux, not the shell it hosts.
  let shell = process.which("xshi")?
  let tmp = /tmp/tmux-proof
  tmp.mkdir()
  let label = "laputa-proof"
  let config = fp"{tmp}/tmux.conf"
  fp"{tmp}/home".mkdir()
  check(dynlinker.exists()?, "tmux-proof", f"missing rootfs musl loader: {dynlinker}")
  check(tmux.exists()?, "tmux-proof", f"missing rootfs tmux binary: {tmux}")

  config.write(
    """set -g default-terminal "tmux-256color"
set -ga terminal-features "tmux-256color:Sync"
set -as terminal-features ",screen*:256:clipboard:ccolour:cstyle:focus:title"
set -g set-clipboard external
set -sg escape-time 0
set -g focus-events on
""",
  )

  env ({
    HOME: fp"{tmp}/home",
    LD_LIBRARY_PATH: fp"{rootfs}/usr/lib",
    PS1: "laputa$ ",
    SHELL: shell,
    TERM: "tmux-256color",
    TMUX_TMPDIR: tmp,
  }) {
    run $dynlinker $tmux "-L" $label "-f" $config "new-session" "-d" "-s" "proof" "-x" "80" "-y" "24" $shell \
      "--no-config"
    time.sleep(500ms)
    let sessions = run.text $dynlinker $tmux "-L" $label "list-sessions"
    check("proof:" in sessions, "tmux-session", f"tmux did not report proof session: {sessions.trim()}")
    let default_terminal = run.text $dynlinker $tmux "-L" $label "show-options" "-gqv" "default-terminal"
    check(default_terminal.trim() == "tmux-256color", "tmux-config", f"default-terminal was {default_terminal.trim()}")
    let terminal_features = run.text $dynlinker $tmux "-L" $label "show-options" "-gqv" "terminal-features"

    check(
      "tmux-256color:Sync" in terminal_features,
      "tmux-config",
      f"missing Sync terminal feature: {terminal_features.trim()}",
    )

    check(
      "screen*:256:clipboard:ccolour:cstyle:focus:title" in terminal_features,
      "tmux-config",
      f"missing screen terminal features: {terminal_features.trim()}",
    )

    let set_clipboard = run.text $dynlinker $tmux "-L" $label "show-options" "-gqv" "set-clipboard"
    check(set_clipboard.trim() == "external", "tmux-config", f"set-clipboard was {set_clipboard.trim()}")
    let escape_time = run.text $dynlinker $tmux "-L" $label "show-options" "-sgqv" "escape-time"
    check(escape_time.trim() == "0", "tmux-config", f"escape-time was {escape_time.trim()}")
    let focus_events = run.text $dynlinker $tmux "-L" $label "show-options" "-gqv" "focus-events"
    check(focus_events.trim() == "on", "tmux-config", f"focus-events was {focus_events.trim()}")
    run $dynlinker $tmux "-L" $label "send-keys" "-t" "proof:0.0" "print \"tmux-proof-alpha\"" "C-m"
    run $dynlinker $tmux "-L" $label "send-keys" "-t" "proof:0.0" "print \"tmux-proof-edit:ba" "BSpace" "BSpace" \
      "ok\"" "C-m"
    time.sleep(1000ms)
    let pane = run.text $dynlinker $tmux "-L" $label "capture-pane" "-pt" "proof:0.0"
    check("tmux-proof-alpha" in pane, "tmux-pane", f"tmux pane did not capture alpha output: {pane.trim()}")
    check("tmux-proof-edit:ok" in pane, "tmux-pane", f"tmux pane did not capture edited command output: {pane.trim()}")
    run $dynlinker $tmux "-L" $label "new-window" "-d" "-n" "check" $shell "--no-config"
    let windows = run.text $dynlinker $tmux "-L" $label "list-windows"
    check("check" in windows, "tmux-window", f"tmux did not report created window: {windows.trim()}")
    run $dynlinker $tmux "-L" $label "kill-server"
    let dead = run.status $dynlinker $tmux "-L" $label "has-session" "-t" "proof" 2> /dev/null
    check(! dead.ok, "tmux-stop", "tmux server still reported the proof session after kill-server")
  }

  outer_terminals(rootfs, dynlinker, tmux, shell, tmp, config)
  print "tmux ok: config, pty capture, window creation, clean stop, attach under xterm-256color, foot, linux, tmux-256color"
}

# A client attached from foot (TERM=foot or xterm-256color), the Linux
# console, a serial line, or a nested tmux must find its outer terminal's
# capabilities without a terminfo database: tmux carries built-in entries
# compiled from ncurses' terminfo.src. Each attach runs one pane command on a
# real pty, and the client must draw it with that terminal's own sequences.
proc outer_terminals(rootfs: Path, dynlinker: Path, tmux: Path, shell: Path, tmp: Path, config: Path) {
  let driver = proof.pty_driver(tmp)?
  # The marker is assembled at run time so that only the pane's output, never
  # the command text, can match it.
  let pane = "let state = \"ok\"\nprint f\"tmux-attached-{state}\"\ntime.sleep(1s)?"

  for term in ["xterm-256color", "foot", "linux", "tmux-256color"] {
    let label = f"laputa-proof-{term}"
    let out = fp"{tmp}/attach-{term}.out"

    env ({
      HOME: fp"{tmp}/home",
      LD_LIBRARY_PATH: fp"{rootfs}/usr/lib",
      TERM: term,
      TMUX_TMPDIR: tmp,
    }) {
      let status = run.status --timeout=60s $driver "24" "80" "30000" "tmux-attached-ok" "" "--" $dynlinker $tmux "-L" \
        $label "-f" $config "new-session" $shell "--no-config" "-c" $pane > $out
      check(
        status.ok,
        "tmux-attach",
        f"client under TERM={term} did not draw its pane and exit cleanly: {out.read_text()?}",
      )
    }

    let screen = out.read_text()?

    check("[exited]" in screen, "tmux-attach", f"client under TERM={term} did not report its session exiting: {screen}")

    # linux has no alternate screen and resets the cursor with its own
    # cnorm; the others switch to the alternate screen.
    if term == "linux" {
      check("\u{1b}[?1049h" not in screen, "tmux-attach", "client used an alternate screen the linux console lacks")
      check("\u{1b}[?25h\u{1b}[?0c" in screen, "tmux-attach", "client did not use the linux console's cnorm")
    } else {
      check("\u{1b}[?1049h" in screen, "tmux-attach", f"client under TERM={term} did not enter the alternate screen")
    }
  }

  # As with ncurses, a terminal tmux knows nothing about is refused.
  env ({
    HOME: fp"{tmp}/home",
    LD_LIBRARY_PATH: fp"{rootfs}/usr/lib",
    TERM: "laputa-unknown-terminal",
    TMUX_TMPDIR: tmp,
  }) {
    let status = run.status $driver "24" "80" "10000" "--" $dynlinker $tmux "-L" "laputa-proof-unknown" "-f" $config \
      "new-session" $shell "--no-config" "-c" "time.sleep(1s)?" > fp"{tmp}/unknown.out"
    check(! status.ok, "tmux-attach", "tmux attached to an unknown terminal")
  }

  let refused = fp"{tmp}/unknown.out".read_text()?
  check(
    "missing or unsuitable terminal: laputa-unknown-terminal" in refused,
    "tmux-attach",
    f"unknown terminal not reported: {refused}",
  )
}
