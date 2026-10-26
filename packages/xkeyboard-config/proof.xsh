use pm.proof

proc main(root = /rootfs) [fs, error] {
  proof.package_metadata(root, "xkeyboard-config")
  let xkb = fp"{root}/usr/share/X11/xkb"

  for ruleset in ["base", "evdev"] {
    let lines = fp"{xkb}/rules/{ruleset}".read_text()?.split("\n")
    let headers = [line.words().join(" ") for line in lines if line.starts_with("! ")]

    for header in ["! model = keycodes", "! layout = keycodes", "! model layout = symbols", "! option = symbols"] {
      proof.ensure(header in headers, "proof-xkeyboard-config", f"{ruleset} rules lack the `{header}` section")
    }
  }

  for component in [p"keycodes/evdev", p"symbols/us", p"symbols/pc", p"types/complete", p"compat/complete"] {
    proof.ensure(fp"{xkb}/{component}".exists()?, "proof-xkeyboard-config", f"missing XKB component {component}")
  }

  print "xkeyboard-config ok"
}
