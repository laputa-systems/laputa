##! Shared payload archive encoding and its process-scoped fingerprint.

## Writes a payload archive with PM's payload encoding.
export proc create(tarball: Path, dest: Path, archive_paths: List[Path]) [fs, error] {
  archive.create(tarball, dest, archive_paths, .Tar, compression: .Gzip, collision: .Replace)
}

proc compute_encoding_fingerprint() [fs, error] -> Result[Str, Error] {
  let handle = fs.tempdir()?
  let root = handle.host_path()?
  defer root.remove()
  let tree = fp"{root}/tree"
  let directory = fp"{tree}/directory"
  let file = fp"{tree}/file"
  let link = fp"{tree}/link"
  tree.mkdir()
  directory.mkdir()
  directory.chmod(0o755)
  file.write("laputa payload encoding fingerprint\n")
  file.chmod(0o644)
  link.symlink(to: p"file")
  fs.set_times(file, mtime_sec: 1700000000)
  fs.set_times(directory, mtime_sec: 1700000000)
  fs.set_times(link, mtime_sec: 1700000000, follow_symlinks: false)
  let tarball = fp"{root}/payload.tar.gz"
  create(tarball, tree, [p"directory", p"file", p"link"])
  hash.sha256(tarball)?.hex()
}

## Returns the payload encoder's fingerprint, computed once per process.
export proc encoding_fingerprint() [fs, error] -> Result[Str, Error] {
  let result = utils.cache(compute_encoding_fingerprint).require(Result[Str, Error])?
  result?
}
