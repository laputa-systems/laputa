##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(rootfs, "less")
  proof.target_elf(rootfs, p"usr/bin/less", "less")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "less ok: cross-built"
    return
  }

  let os = system.uname()?
  let dynlinker = fp"{rootfs}/usr/lib/ld-musl-{os.machine}.so.1"
  let less = fp"{rootfs}/usr/bin/less"
  let tmp = fp"{rootfs}/var/tmp/proof-less"
  fs.remove(tmp, missing_ok: true)
  fs.mkdir(tmp, true)
  defer fs.remove(tmp, missing_ok: true)?
  let ver = proof.package_version(rootfs, "less")?
  let version = run.text $dynlinker $less "--version" ?
  proof.ensure(version.starts_with(f"less {ver} "), "proof-less", f"less --version reported {version.lines()[0]}")

  let text = fp"{tmp}/lines.txt"
  fs.write(text, [f"line {i}" for i in range(1, 101)].join("\n") + "\n")

  # Without a tty less copies its input, like cat.
  let copied = run.text $dynlinker $less $text ?
  proof.ensure(copied == text.read_text()?, "proof-less", "less did not copy its input to a non-terminal")

  # On a 10-row terminal less pages lines 1-9, then the down-arrow key (sent
  # in its application-mode form, as less enables keypad mode) scrolls to
  # line 10, and q quits. less has no terminfo here, so each TERM a Laputa
  # user meets must work from the built-in capabilities.
  let driver = proof.pty_driver(tmp)?

  for term in ["xterm-256color", "foot", "tmux-256color", "linux"] {
    let out = fp"{tmp}/screen-{term}.out"

    env ({
      TERM: term,
    }) {
      let status = run.status --timeout=30s $driver "10" "80" "20000" "line 9" "\x1bOB" "line 10" "q" "--" $dynlinker $less $text > $out
      proof.ensure(status.ok, "proof-less", f"less under TERM={term} did not page, scroll, and quit: {out.read_text()?}")
    }?

    let screen = out.read_text()?

    proof.ensure("\x1b[?1049h" in screen, "proof-less", f"less did not switch to the alternate screen under TERM={term}")
    proof.ensure("\x1b[?1h\x1b=" in screen, "proof-less", f"less did not enable keypad mode under TERM={term}")
    proof.ensure(screen.ends_with("\x1b[?1049l"), "proof-less", f"less did not restore the screen on quit under TERM={term}")
  }

  print f"less ok: {ver} copies to a pipe; pages, scrolls by arrow key, and quits on a pty for xterm-256color, foot, tmux-256color, linux"
}

main(@args)
