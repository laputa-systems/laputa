##! Checks applet links installed from the verified local XSH seed.
use packages.xsh.PKGBUILD as xsh_recipe

test xsh_seed_installs_declared_applet_links_and_keeps_libraries_private [fs, env, error] { |ctx|
  let workspace = test.temp_dir(ctx, name: "xsh recipe")?
  let seed = fp"{workspace}/seed"
  let core_tree = fp"{workspace}/archive/core"
  fp"{core_tree}/lib".mkdir()

  for command_name in ["arch", "id", "su"] {
    fp"{core_tree}/{command_name}".write("#!/bin/xsh\n", mode: 0o755)
  }
  fp"{core_tree}/lib/identity.xsh".write("const fixture = true\n")
  seed.mkdir()
  archive.tar_create(fp"{seed}/core.tar.xz", fp"{workspace}/archive", [p"core"], compression: "xz")

  for binary in ["xsh", "xshi", "xsht"] {
    fp"{seed}/{binary}".write(f"fixture {binary}\n", mode: 0o755)
  }
  let files = {product: hash.sha256(fp"{seed}/{product}")?.hex() for product in ["xsh", "xshi", "xsht", "core.tar.xz"]}
  json.write(fp"{seed}/manifest.json", {files})
  let dest = fp"{workspace}/dest"

  cd $workspace {
    xsh_recipe.build(dest)
  }

  let applet_paths = [entry.path for entry in xsh_recipe.filetree if entry.kind == "symlink"]
  for command_name in ["arch", "id"] {
    let relative = fp"usr/bin/{command_name}"
    assert relative in applet_paths, f"installed applet {command_name} is missing from the payload contract"
    assert fp"{dest}/{relative}".readlink()? == fp"../lib/xsh/core/{command_name}"
  }
  assert ! fp"{dest}/usr/bin/su".exists()?
  assert ! fp"{dest}/usr/bin/identity.xsh".exists()?
  assert fp"{dest}/usr/lib/xsh/core/lib/identity.xsh".exists()?
  assert fp"{dest}/usr/bin/sh".readlink()? == p"xshi"
}
