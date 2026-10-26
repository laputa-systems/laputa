self_hosting_lock() {
  local lock_path=$1
  local variable=$2
  local inherited=${!variable-}
  if test -n "$inherited" && python3 - "$lock_path" "$inherited" <<'PY'
import os, sys
try:
    held = os.fstat(int(sys.argv[2]))
    expected = os.stat(sys.argv[1])
except (ValueError, OSError):
    raise SystemExit(1)
raise SystemExit(0 if (held.st_dev, held.st_ino) == (expected.st_dev, expected.st_ino) else 1)
PY
  then
    flock -n "$inherited" || { printf 'self-hosting path is already in use: %s\n' "$lock_path" >&2; return 1; }
    return
  fi
  local acquired
  exec {acquired}>"$lock_path"
  flock -n "$acquired" || { printf 'self-hosting path is already in use: %s\n' "$lock_path" >&2; return 1; }
  printf -v "$variable" '%s' "$acquired"
  export "$variable"
}

self_hosting_disk_lock() {
  local repository=$1
  local output_root=$2
  local backing_disk
  backing_disk=$(python3 - "$output_root/output.ext4" <<'PY'
import os, sys
path = os.path.realpath(sys.argv[1])
if os.path.exists(path) and os.stat(path).st_nlink != 1:
    raise SystemExit('self-hosting output disk must have exactly one hard link')
print(path)
PY
  )
  case "$backing_disk" in "$repository"/.work/*) ;; *) printf 'self-hosting output disk must be under .work: %s\n' "$backing_disk" >&2; return 1 ;; esac
  self_hosting_lock "$backing_disk.lock" LAPUTA_SELF_HOSTING_DISK_LOCK_FD
}
