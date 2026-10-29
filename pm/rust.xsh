##! Rust package build mechanics.

## Stages the Rust standard library while preserving checkout executable modes and symlink targets.
export proc rust_stage_standard_library(source: Path, dest: Path) [fs, error] {
  dest.remove()
  dest.mkdir()

  for entry in fs.walk(source, gitignore: false)? |> sort-by .path {
    continue when entry.path == source
    let relative = entry.path.relative_to(source)
    let out = fp"{dest}/{relative}"

    if entry.kind == "dir" {
      out.mkdir()
    } else if entry.kind == "file" {
      let mode = if entry.path.executable() { 0o755 } else { 0o644 }
      fs.install(entry.path, out, mode, parents: true, overwrite: true)
    } else if entry.kind == "symlink" {
      out.parent.mkdir()
      out.remove()
      out.symlink(to: entry.path.readlink()?)
    }
  }
}
