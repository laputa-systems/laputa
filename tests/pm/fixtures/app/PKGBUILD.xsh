export let name = "app"

export let ver = "1.0.0"

export let rel = "1"

export let deps = ["dep"]

export let mkdeps_host = ["llvm-toolchain"]

export let upstream_sources = []

export let filetree = [{path: p"usr/share/app.txt", kind: "file"}]

export proc build(dest: Path) [fs, error] -> Result[Unit, Error] {
  let target = fp"{dest}/usr/share/app.txt"
  target.parent.mkdir()?

  target.write(
    """app
""",
  )?
}
