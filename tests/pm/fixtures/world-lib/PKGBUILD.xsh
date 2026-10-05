export let name = "world-lib"

export let ver = "1.0.0"

export let rel = "1"

export let deps = []

export let mkdeps_host = []

export let upstream_sources = []

export let filetree = [{path: p"usr/share/world-lib.txt", kind: "file"}]

export proc build(dest: Path) [fs, error] -> Result[Unit, Error] {
  let target = fp"{dest}/usr/share/world-lib.txt"
  target.parent.mkdir()?

  target.write(
    """world-lib
""",
  )?
}
