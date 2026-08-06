proc main(out: Path = /tmp/pm-out-build-env, repo: Path = /repo) [fs, error] {
  fs.mkdir(repo)?
  fs.copy(fp"${out}/remote-index.json", fp"${repo}/index.json", overwrite: true)?
  let cache = fp"${out}/remote-cache"

  if ! fs.exists(cache)? {
    return
  }

  for entry in fs.files(cache) {
    let rel = entry.path.strip_prefix(cache)?
    fs.install(entry.path, fp"${repo}/${rel}", 0o644, parents: true, overwrite: true)?
  }
}

main(@args)?
