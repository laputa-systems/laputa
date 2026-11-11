##! The constant POSIX shell scripts that run on a target. Each receives its
##! values as positional arguments and prints a small `key value` protocol in
##! which free-form text is hex encoded. The utility baseline is a POSIX
##! `sh` with `stat -c`, `sha256sum`, `od`, `tr`, `mktemp`, `mv`, `readlink`,
##! `chmod`, `chown`, `ln`, `rm` and `awk`, as BusyBox and GNU coreutils provide.

## Print the state of one path: type, mode, ids, size, content digest for a
## regular file, and the target of a symlink. Arguments: path.
export const path_state = r"""
LC_ALL=C
export LC_ALL
hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
if ! out=$(stat -c '%f %a %u %g %s %Y' -- "$1" 2>&1); then
  case $out in
    *'No such file or directory'*) printf 'state missing\n' ;;
    *'Not a directory'*) printf 'state blocked\ndetail %s\n' "$(hex "$out")" ;;
    *'Permission denied'*) printf 'state denied\ndetail %s\n' "$(hex "$out")" ;;
    *) printf 'state error\ndetail %s\n' "$(hex "$out")" ;;
  esac
  exit 0
fi
set -- "$1" $out
type=$(( 0x$2 & 61440 ))
case $type in
  16384) kind=dir ;;
  32768) kind=file ;;
  40960) kind=link ;;
  *) kind=other ;;
esac
printf 'state found\nkind %s\nmode %s\nuid %s\ngid %s\nsize %s\nmtime %s\n' "$kind" "$3" "$4" "$5" "$6" "$7"
printf 'owner %s\n' "$(hex "$(stat -c %U -- "$1" 2>/dev/null)")"
printf 'group %s\n' "$(hex "$(stat -c %G -- "$1" 2>/dev/null)")"
case $kind in
  file)
    if d=$({ sha256sum < "$1"; } 2>/dev/null); then
      printf 'digest %s\n' "${d%% *}"
    else
      printf 'digest unreadable\n'
    fi
    ;;
  link)
    t=$(readlink -- "$1"; echo x)
    t=${t%x}
    t=${t%?}
    printf 'target %s\n' "$(hex "$t")"
    ;;
esac
"""

## Print whether a package is installed and, when a wanted version is given, how
## the installed version orders against it. Arguments: name, wanted version or
## the empty string.
export const package_state = r"""
LC_ALL=C
export LC_ALL
db=/lib/apk/db/installed
if ! command -v apk >/dev/null 2>&1 || [ ! -r "$db" ]; then
  printf 'state unavailable\n'
  exit 0
fi
v=$(awk -v n="$1" 'BEGIN { p = "P:" n } $0 == p { f = 1; next } f && /^V:/ { print substr($0, 3); exit } /^$/ { f = 0 }' "$db")
if [ -z "$v" ]; then
  printf 'state absent\n'
  exit 0
fi
printf 'state installed\nversion %s\n' "$v"
if [ -n "$2" ]; then
  case $(apk version -t "$v" "$2" 2>/dev/null) in
    '<') printf 'ordering lt\n' ;;
    '=') printf 'ordering eq\n' ;;
    '>') printf 'ordering gt\n' ;;
    *) printf 'ordering unknown\n' ;;
  esac
fi
"""

## Print the account database: passwd, then group, each after a marker line.
export const accounts_state = r"""
LC_ALL=C
export LC_ALL
for f in /etc/passwd /etc/group; do
  if [ ! -r "$f" ]; then
    printf 'state denied\n'
    exit 0
  fi
done
printf 'state ok\n@@passwd@@\n'
cat /etc/passwd
printf '@@group@@\n'
cat /etc/group
"""

## Print whether an OpenRC service exists, is enabled in a runlevel, and its
## status code. Arguments: name, runlevel.
export const service_state = r"""
LC_ALL=C
export LC_ALL
if ! command -v rc-service >/dev/null 2>&1; then
  printf 'state unavailable\n'
  exit 0
fi
if [ ! -x "/etc/init.d/$1" ]; then
  printf 'state missing\n'
  exit 0
fi
printf 'state found\n'
if [ -L "/etc/runlevels/$2/$1" ]; then
  printf 'enabled yes\n'
else
  printf 'enabled no\n'
fi
rc-service "$1" status >/dev/null 2>&1
printf 'status %s\n' "$?"
"""

## Print which utilities the baseline needs are present. Arguments: none.
export const capabilities = r"""
LC_ALL=C
export LC_ALL
printf 'shell ok\n'
for tool in stat sha256sum od tr mktemp mv readlink chmod chown ln rm mkdir rmdir cat awk id sed wc head; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf 'have %s\n' "$tool"
  else
    printf 'lack %s\n' "$tool"
  fi
done
for tool in apk rc-service rc-update adduser addgroup deluser delgroup usermod doas; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf 'have %s\n' "$tool"
  else
    printf 'lack %s\n' "$tool"
  fi
done
printf 'uid %s\n' "$(id -u)"
"""

## Echo every argument back NUL terminated, for the quoting round-trip check.
## Arguments: any.
export const echo_arguments = r"""printf '%s\0' "$@" """

## Run an argv. Arguments: the command and its arguments.
export const run_argv = r"""exec "$@" """

## Run a shell string. Arguments: the string.
export const run_shell = r"""exec /bin/sh -c "$1" """

## Create a directory with a private initial mode when one is declared, so it
## is never visible with looser permissions. Arguments: path, `1` to create
## parents, initial mode or the empty string.
export const make_directory = r"""
set -e
if [ "$2" = 1 ]; then
  if [ -n "$3" ]; then mkdir -p -m "$3" -- "$1"; else mkdir -p -- "$1"; fi
else
  if [ -n "$3" ]; then mkdir -m "$3" -- "$1"; else mkdir -- "$1"; fi
fi
"""

## Change owner and group. Arguments: owner spec (`user`, `user:group` or
## `:group`), path.
export const change_owner = r"""chown -- "$1" "$2" """

## Change the mode. Arguments: mode, path.
export const change_mode = r"""chmod -- "$1" "$2" """

## Remove an empty directory. Arguments: path.
export const remove_directory = r"""rmdir -- "$1" """

## Remove a regular file, never a directory. Arguments: path.
export const remove_file = r"""
if [ -d "$1" ] && [ ! -L "$1" ]; then
  echo 'refusing to remove a directory' >&2
  exit 66
fi
rm -f -- "$1"
"""

## Create a symlink. Arguments: target, path.
export const make_link = r"""ln -s -- "$1" "$2" """

## Replace an existing symlink, never anything else. Arguments: target, path.
export const replace_link = r"""
if [ ! -L "$2" ]; then
  echo 'refusing to replace something that is not a symlink' >&2
  exit 66
fi
rm -f -- "$2"
ln -s -- "$1" "$2"
"""

## Remove a symlink, never anything else. Arguments: path.
export const remove_link = r"""
if [ ! -L "$1" ]; then
  echo 'refusing to remove something that is not a symlink' >&2
  exit 66
fi
rm -f -- "$1"
"""

## Create a private, unpredictable staging file inside a directory and print
## its path hex encoded. Arguments: directory.
export const create_stage = r"""
umask 077
t=$(mktemp "$1/.xinfra.XXXXXX") || exit 70
printf '%s' "$t" | od -An -v -tx1 | tr -d ' \n'
"""

## Write standard input into a staging file. Arguments: staging path.
export const write_stage = r"""cat > "$1" """

## Print the digest and size of a staging file. Arguments: staging path.
export const inspect_stage = r"""
set -e
d=$(sha256sum < "$1")
printf 'digest %s\n' "${d%% *}"
printf 'size %s\n' "$(wc -c < "$1" | tr -d ' ')"
"""

## Set ownership and mode on a staging file before it is promoted. Arguments:
## staging path, owner spec or the empty string, mode.
export const finish_stage = r"""
set -e
if [ -n "$2" ]; then chown -- "$2" "$1"; fi
chmod -- "$3" "$1"
"""

## Replace the destination with the staging file by a same-directory rename,
## refusing a destination that is a directory or a link to one. Arguments:
## staging path, destination.
export const promote_stage = r"""
if [ -d "$2" ]; then
  echo 'refusing to replace a directory' >&2
  exit 66
fi
mv -f -- "$1" "$2"
"""

## Remove a staging file. Arguments: staging path.
export const discard_stage = r"""rm -f -- "$1" """

## Install packages. Arguments: apk package specifications.
export const apk_add = r"""apk add --no-progress -- "$@" """

## Remove packages. Arguments: package names.
export const apk_del = r"""apk del --no-progress -- "$@" """

## Refresh the package index. Arguments: none.
export const apk_update = r"""apk update --no-progress"""

## Add a group. Arguments: name, gid or the empty string.
export const add_group = r"""
if [ -n "$2" ]; then addgroup -g "$2" "$1"; else addgroup "$1"; fi
"""

## Remove a group. Arguments: name.
export const delete_group = r"""delgroup "$1" """

## Add a user without a password and without touching other accounts.
## Arguments: name, uid, primary group, home, shell, `1` for a system user;
## empty strings mean unset.
export const add_user = r"""
name=$1
uid=$2
primary=$3
home=$4
shell=$5
system=$6
set -- -D
if [ -n "$uid" ]; then set -- "$@" -u "$uid"; fi
if [ -n "$primary" ]; then set -- "$@" -G "$primary"; fi
if [ -n "$home" ]; then set -- "$@" -h "$home"; fi
if [ -n "$shell" ]; then set -- "$@" -s "$shell"; fi
if [ "$system" = 1 ]; then set -- "$@" -S; fi
exec adduser "$@" "$name"
"""

## Change the primary group, home or shell of a user with `usermod`, which the
## `shadow` package provides. The home is not moved. Arguments: name, primary
## group, home, shell; empty strings mean unchanged.
export const modify_user = r"""
if ! command -v usermod >/dev/null 2>&1; then
  echo 'usermod is required to change an existing user; install the shadow package' >&2
  exit 127
fi
name=$1
if [ -n "$2" ]; then usermod -g "$2" "$name" || exit; fi
if [ -n "$3" ]; then usermod -d "$3" "$name" || exit; fi
if [ -n "$4" ]; then usermod -s "$4" "$name" || exit; fi
"""

## Add an existing user to an existing group. Arguments: user, group.
export const join_group = r"""adduser "$1" "$2" """

## Remove a user account and nothing else: the home directory and the user's
## files stay. Arguments: name.
export const delete_user = r"""deluser "$1" """

## Enable a service in a runlevel. Arguments: name, runlevel.
export const enable_service = r"""rc-update add "$1" "$2" """

## Disable a service in a runlevel. Arguments: name, runlevel.
export const disable_service = r"""rc-update del "$1" "$2" """

## Start, stop, restart or reload a service. Arguments: name, action.
export const control_service = r"""rc-service "$1" "$2" """

## Take the host lock with a mkdir. Prints `acquired TOKEN` or `held` and the
## holder text hex encoded. Arguments: lock directory, holder text.
export const acquire_lock = r"""
umask 077
if mkdir -- "$1" 2>/dev/null; then
  token=$(head -c 16 /dev/urandom | od -An -v -tx1 | tr -d ' \n')
  printf '%s\n%s\n' "$token" "$2" > "$1/owner"
  printf 'acquired %s\n' "$token"
else
  holder=$(cat "$1/owner" 2>/dev/null | tr '\n' ' ')
  printf 'held %s\n' "$(printf '%s' "$holder" | od -An -v -tx1 | tr -d ' \n')"
  exit 75
fi
"""

## Release the lock only if the token matches. Arguments: lock directory, token.
export const release_lock = r"""
owner=$(sed -n 1p "$1/owner" 2>/dev/null)
if [ -n "$owner" ] && [ "$owner" = "$2" ]; then
  rm -f -- "$1/owner"
  rmdir -- "$1"
else
  echo 'the lock is not held with this token' >&2
  exit 76
fi
"""

## Print the holder of the lock, hex encoded. Arguments: lock directory.
export const inspect_lock = r"""
if [ ! -d "$1" ]; then
  printf 'state free\n'
  exit 0
fi
printf 'state held\nholder %s\n' "$(cat "$1/owner" 2>/dev/null | tr '\n' ' ' | od -An -v -tx1 | tr -d ' \n')"
"""
