##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

type Compiled = {
  magic: Int,
  names: Str,
}

pure u16(data: Bytes, at: Int) -> Int {
  (data.byte_at(at) ?? 0) + (data.byte_at(at + 1) ?? 0) * 256
}

pure c_string(data: Bytes, at: Int) -> Bytes {
  var end = at
  while (data.byte_at(end) ?? 0) != 0 {
    end += 1
  }

  data[at..end]
}

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "ghostty-custom")
  let bin = fp"{root}/usr/bin/ghostty-custom"
  proof.target_elf(root, p"usr/bin/ghostty-custom", "ghostty-custom")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" $bin
  proof.ensure("[libEGL.so.1]" in dynamic, "proof-ghostty-custom", "ghostty-custom does not link libEGL")
  proof.ensure("[libwayland-client.so.0]" in dynamic, "proof-ghostty-custom", "ghostty-custom does not link libwayland-client")
  proof.ensure("[libxkbcommon.so.0]" in dynamic, "proof-ghostty-custom", "ghostty-custom does not link libxkbcommon")
  proof.ensure("[libgtk" not in dynamic, "proof-ghostty-custom", "ghostty-custom links GTK")
  proof.ensure("[libadwaita" not in dynamic, "proof-ghostty-custom", "ghostty-custom links libadwaita")
  proof.ensure("libdbus" not in dynamic, "proof-ghostty-custom", "ghostty-custom links D-Bus")
  proof.ensure("libsystemd" not in dynamic, "proof-ghostty-custom", "ghostty-custom links systemd")
  proof.ensure("libX11" not in dynamic, "proof-ghostty-custom", "ghostty-custom links X11")
  proof.ensure("libc.so.6" not in dynamic, "proof-ghostty-custom", "ghostty-custom links glibc")

  let strings = bin.read_bytes()?.strings()
  proof.ensure("wayland" in strings or "Wayland" in strings, "proof-ghostty-custom", "ghostty-custom lacks wayland runtime marker")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"ghostty-custom ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let os = system.uname()?
  let dynlinker = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  env ({LD_LIBRARY_PATH: fp"{root}/usr/lib"}) {
    let version = run.text $dynlinker $bin "--version"
    proof.ensure("Ghostty" in version and ("wayland" in version or "Wayland" in version), "proof-ghostty-custom", f"unexpected version: {version.trim()}")
    let config = run.text $dynlinker $bin "+show-config"
    proof.ensure("=" in config, "proof-ghostty-custom", "ghostty +show-config produced no key=value output")
  }

  let entry = fp"{root}/usr/share/terminfo/x/xterm-ghostty"
  proof.ensure(entry.exists()?, "proof-ghostty-custom", "xterm-ghostty terminfo missing")
  let data = entry.read_bytes()?
  let magic = u16(data, 0)
  proof.ensure(magic == 0o432 or magic == 0o1036, "proof-ghostty-custom", f"xterm-ghostty has bad magic {magic}")
  let names = c_string(data, 12) as Str
  proof.ensure(names.starts_with("xterm-ghostty|"), "proof-ghostty-custom", f"xterm-ghostty has wrong names: {names}")

  print "ghostty-custom ok"
}
