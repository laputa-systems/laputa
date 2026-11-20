defined_symbols() {
  local kind symbols
  kind=$(file -b "$1") || return 1
  case "$kind" in
    *Mach-O*) symbols=$(nm -P -gU "$1") || return 1 ;;
    *ELF*|*'current ar archive'*) symbols=$(nm -P -g --defined-only "$1") || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$symbols" | awk '$2 ~ /^[[:alpha:]?]$/ && $3 ~ /^[[:xdigit:]]+$/ {print $1}' | LC_ALL=C sort
}
