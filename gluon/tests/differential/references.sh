reference_tool() {
  local program=$1 candidate=$2 expected=$3 resolved version
  resolved=$(type -P "$program") || {
    printf 'error: reference %s is missing from PATH\n' "$program" >&2
    return 1
  }
  case "$resolved" in
    /*) ;;
    *) resolved="$PWD/$resolved" ;;
  esac
  if [ "$resolved" -ef "$candidate" ] || cmp -s "$resolved" "$candidate"; then
    printf 'error: reference %s resolves to the gluon candidate: %s\n' "$program" "$resolved" >&2
    return 1
  fi
  if ! version=$("$resolved" --version); then
    printf 'error: could not read reference %s version: %s\n' "$program" "$resolved" >&2
    return 1
  fi
  if [ -z "$expected" ] || [ "$version" != "$expected" ]; then
    printf 'error: expected reference %s %s, found %s at %s\n' "$program" "$expected" "$version" "$resolved" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}
