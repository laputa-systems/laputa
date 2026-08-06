proc ensure_tmp(path_value: Path) [fs, error] {
  if ! fs.exists(path_value)? {
    fs.mkdir(path_value)?
  }

  fs.chmod(path_value, 0o1777)?
}

proc main() [fs, error] {
  for path_value in [/tmp, /var/tmp, /build-env/tmp, /build-env/var/tmp, /rootfs/tmp, /rootfs/var/tmp] {
    ensure_tmp(path_value)?
  }
}

main()?
