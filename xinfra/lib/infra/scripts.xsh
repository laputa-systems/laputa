##! The constant POSIX shell scripts that run on a target. Each receives its
##! values as positional arguments and prints a small `key value` protocol in
##! which free-form text is hex encoded. The utility baseline is a POSIX
##! `sh` with `stat -c`, `sha256sum`, `od`, `tr`, `mktemp`, `mv`, `readlink`,
##! `chmod`, `chown`, `ln`, `rm` and `awk`, as BusyBox and GNU coreutils provide.
##!
##! The same operations also have XSH sources for a target whose login shell is
##! `xsh-login`, which executes its `-c` argument as XSH. One constant exists
##! per (operation, dialect); `source` is the only selector, and it refuses an
##! operation the dialect has no source for instead of reusing the other one.

use infra.model

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

## Print whether an xinit service file exists under the scanned directory and
## what `xinit status` reports for its running state and readiness. Arguments:
## name.
export const xinit_service_state = r"""
LC_ALL=C
export LC_ALL
hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
service_dir=${XINIT_SERVICE_DIR:-/usr/lib/xinit/services}
if ! command -v xinit >/dev/null 2>&1; then
  printf 'state unavailable\n'
  exit 0
fi
if [ ! -f "$service_dir/$1.xsh" ]; then
  printf 'state missing\n'
  exit 0
fi
if ! out=$(xinit status "$1" 2>&1); then
  case $out in
    *'Permission denied'*) printf 'state denied\ndetail %s\n' "$(hex "$out")" ;;
    *) printf 'state error\ndetail %s\n' "$(hex "$out")" ;;
  esac
  exit 0
fi
printf 'state found\n'
printf '%s\n' "$out" | head -n 1 | awk '{
  running = ""
  ready = ""
  for (i = 1; i <= NF; i++) {
    if (i == 2) running = $i
    if ($i ~ /^ready=/) ready = substr($i, 7)
  }
  if (running == "" || ready == "") {
    print "state malformed"
  } else {
    printf "running %s\nready %s\n", running, ready
  }
}'
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
for tool in apk rc-service rc-update xinit adduser addgroup deluser delgroup usermod doas; do
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

## Start, stop, restart or reload an xinit service through its control plane.
## Arguments: name, action.
export const xinit_control_service = r"""
case $2 in
  start|stop|restart|reload) ;;
  *) echo "xinit has no such service action: $2" >&2; exit 64 ;;
esac
exec xinit "$2" "$1"
"""

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

## The closed set of operations a resource needs from a target. One source
## exists per operation and dialect; `source` selects it.
export enum Operation: Str {
  PathState = "path-state",
  PackageState = "package-state",
  AccountsState = "accounts-state",
  ServiceState = "service-state",
  XinitServiceState = "xinit-service-state",
  Capabilities = "capabilities",
  EchoArguments = "echo-arguments",
  RunArgv = "run-argv",
  RunShell = "run-shell",
  MakeDirectory = "make-directory",
  ChangeOwner = "change-owner",
  ChangeMode = "change-mode",
  RemoveDirectory = "remove-directory",
  RemoveFile = "remove-file",
  MakeLink = "make-link",
  ReplaceLink = "replace-link",
  RemoveLink = "remove-link",
  CreateStage = "create-stage",
  WriteStage = "write-stage",
  InspectStage = "inspect-stage",
  FinishStage = "finish-stage",
  PromoteStage = "promote-stage",
  DiscardStage = "discard-stage",
  ApkAdd = "apk-add",
  ApkDel = "apk-del",
  ApkUpdate = "apk-update",
  AddGroup = "add-group",
  DeleteGroup = "delete-group",
  AddUser = "add-user",
  ModifyUser = "modify-user",
  JoinGroup = "join-group",
  DeleteUser = "delete-user",
  EnableService = "enable-service",
  DisableService = "disable-service",
  ControlService = "control-service",
  XinitControlService = "xinit-control-service",
  AcquireLock = "acquire-lock",
  ReleaseLock = "release-lock",
  InspectLock = "inspect-lock",
}

## Why a dialect could not provide an operation.
export error ScriptError = Missing(dialect: model.Dialect, operation: Operation, message: Str)

const xsh_prelude = r"""
pure xinfra_hex(data: Bytes) -> Str {
  let digits = "0123456789abcdef"
  var out = ""
  for byte in data {
    out = out + digits.byte_slice(byte / 16, 1) + digits.byte_slice(byte % 16, 1)
  }
  out
}

pure xinfra_octal(mode: Int) -> Str {
  let digits = "01234567"
  if mode == 0 { return "0" }
  var rest = mode
  var text = ""
  while rest > 0 {
    text = digits.byte_slice(rest % 8, 1) + text
    rest = rest / 8
  }
  text
}

proc xinfra_uid(name: Str) [fs, error] -> Result[Int, Error] {
  if let Ok(number) = name.parse_int() {
    return Ok(number)
  }
  Ok(user.lookup(name)?.uid)
}

proc xinfra_gid(name: Str) [fs, error] -> Result[Int, Error] {
  if let Ok(number) = name.parse_int() {
    return Ok(number)
  }
  Ok(group.lookup(name)?.gid)
}

proc xinfra_owner(target: Path, spec: Str) [fs, error] -> Result[Unit, Error] {
  if spec.starts_with(":") {
    return fs.set_owner(target, gid: xinfra_gid(spec.byte_slice(1))?)
  }
  let parts = spec.split(":", 2)
  if parts.len() == 2 {
    return fs.set_owner(target, uid: xinfra_uid(parts[0])?, gid: xinfra_gid(parts[1])?)
  }
  fs.set_owner(target, uid: xinfra_uid(spec)?)
}
"""

const xsh_path_state = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, process, env, error] {
  let target = fp"{xinfra_args[0]}"
  match fs.stat(target, follow_symlinks: false) {
    Err(error) => {
      let code = error.errno ?? 0
      if code == 2 {
        print "state missing"
      } else if code == 20 {
        print f"state blocked\ndetail {xinfra_hex(bytes.from_text(error.message))}"
      } else if code == 13 {
        print f"state denied\ndetail {xinfra_hex(bytes.from_text(error.message))}"
      } else {
        print f"state error\ndetail {xinfra_hex(bytes.from_text(error.message))}"
      }
    }
    Ok(info) => {
      let kind = match info.kind {
        "dir" => "dir"
        "file" => "file"
        "symlink" => "link"
        else => "other"
      }
      print "state found"
      print f"kind {kind}"
      print f"mode {xinfra_octal(info.mode.bit_and(0o7777))}"
      print f"uid {info.uid}"
      print f"gid {info.gid}"
      print f"size {info.size}"
      print f"mtime {info.mtime_ns / 1000000000}"
      let owner = match user.by_uid(info.uid) {
        Ok(found) => xinfra_hex(bytes.from_text(found.name))
        Err(_) => ""
      }
      print f"owner {owner}"
      let group_name = match group.by_gid(info.gid) {
        Ok(found) => xinfra_hex(bytes.from_text(found.name))
        Err(_) => ""
      }
      print f"group {group_name}"
      if kind == "file" {
        let digest = match hash.sha256(target) {
          Ok(found) => found.hex()
          Err(_) => "unreadable"
        }
        print f"digest {digest}"
      } else if kind == "link" {
        let link_target = match target.readlink() {
          Ok(found) => xinfra_hex(found.bytes())
          Err(_) => ""
        }
        print f"target {link_target}"
      }
    }
  }
}
xinfra_main(xinfra_args)
"""

const xsh_xinit_service_state = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, process, env, error] {
  let name = xinfra_args[0]
  let configured = env.get("XINIT_SERVICE_DIR")
  let service_dir = match configured {
    Ok(found) => found
    Err(_) => "/usr/lib/xinit/services"
  }
  match process.which("xinit") {
    Err(_) => {
      print "state unavailable"
      return
    }
    Ok(_) => {}
  }
  let service_file = fp"{service_dir}/{name}.xsh"
  if ! (service_file.is_file() ?? false) {
    print "state missing"
    return
  }
  let result = run.capture --text xinit status $name
  if ! result.status.ok {
    if "Permission denied" in result.stderr {
      print f"state denied\ndetail {xinfra_hex(bytes.from_text(result.stderr))}"
    } else {
      print f"state error\ndetail {xinfra_hex(bytes.from_text(result.stderr))}"
    }
    return
  }
  let lines = result.stdout.lines()
  let first = if lines.is_empty() { "" } else { lines[0] }
  var running = ""
  var ready = ""
  var index = 0
  for field in first.words() {
    if index == 1 { running = field }
    if field.starts_with("ready=") { ready = field.byte_slice(6) }
    index = index + 1
  }
  if running == "" or ready == "" {
    print "state malformed"
  } else {
    print "state found"
    print f"running {running}"
    print f"ready {ready}"
  }
}
xinfra_main(xinfra_args)
"""

const xsh_capabilities = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, process, error] {
  print "shell ok"
  for tool in ["stat", "sha256sum", "od", "tr", "mktemp", "mv", "readlink", "chmod", "chown", "ln", "rm", "mkdir", "rmdir", "cat", "awk", "id", "sed", "wc", "head"] {
    match process.which(tool) {
      Ok(_) => print f"have {tool}"
      Err(_) => print f"lack {tool}"
    }
  }
  for tool in ["apk", "rc-service", "rc-update", "xinit", "adduser", "addgroup", "deluser", "delgroup", "usermod", "doas"] {
    match process.which(tool) {
      Ok(_) => print f"have {tool}"
      Err(_) => print f"lack {tool}"
    }
  }
  let who = user.current()?
  print f"uid {who.uid}"
}
xinfra_main(xinfra_args)
"""

const xsh_echo_arguments = r"""
proc xinfra_main(xinfra_args: List[Str]) [io, error] {
  for word in xinfra_args {
    io.write_stdout_bytes(bytes.from_text(word + "\0"))?
  }
}
xinfra_main(xinfra_args)
"""

const xsh_run_argv = r"""
proc xinfra_main(xinfra_args: List[Str]) [process, io, error] {
  guard ! xinfra_args.is_empty() else {
    fail "run argv needs a command"
  }
  let plan = process.command_argv(xinfra_args[0], xinfra_args)
  match process.run(plan) {
    Err(error) => {
      eprint f"xinfra: {error.message}"
      exit 127
    }
    Ok(status) => {
      if status.signaled() {
        exit 125
      }
      match status.exit_code() {
        Ok(code) => exit code
        Err(_) => exit 127
      }
    }
  }
}
xinfra_main(xinfra_args)
"""

const xsh_make_directory = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, error] {
  let target = fp"{xinfra_args[0]}"
  let parents = xinfra_args[1] == "1"
  let mode = if xinfra_args[2] == "" { 0o777 } else { f"0o{xinfra_args[2]}".parse_int()? }
  if parents {
    let root = fs.open_root(p"/")?
    root.mkdir(target.strip_prefix(p"/")?, mode: mode, parents: true)?
  } else {
    let root = fs.open_root(target.parent())?
    root.mkdir(target.strip_prefix(target.parent())?, mode: mode)?
  }
}
xinfra_main(xinfra_args)
"""

const xsh_change_owner = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, error] {
  xinfra_owner(fp"{xinfra_args[1]}", xinfra_args[0])?
}
xinfra_main(xinfra_args)
"""

const xsh_change_mode = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, error] {
  let mode = f"0o{xinfra_args[0]}".parse_int()?
  fp"{xinfra_args[1]}".chmod(mode)?
}
xinfra_main(xinfra_args)
"""

const xsh_remove_directory = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, error] {
  fp"{xinfra_args[0]}".remove_dir()?
}
xinfra_main(xinfra_args)
"""

const xsh_remove_file = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, process, error] {
  let target = fp"{xinfra_args[0]}"
  if target.is_dir() ?? false {
    eprint "refusing to remove a directory"
    exit 66
  }
  match target.unlink() {
    Ok(_) => {}
    Err(error) => {
      if (error.errno ?? 0) != 2 {
        return Err(error)
      }
    }
  }
}
xinfra_main(xinfra_args)
"""

const xsh_make_link = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, error] {
  fs.symlink(fp"{xinfra_args[0]}", fp"{xinfra_args[1]}")?
}
xinfra_main(xinfra_args)
"""

const xsh_replace_link = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, process, error] {
  let target = fp"{xinfra_args[1]}"
  if ! (target.is_symlink() ?? false) {
    eprint "refusing to replace something that is not a symlink"
    exit 66
  }
  target.unlink()?
  fs.symlink(fp"{xinfra_args[0]}", target)?
}
xinfra_main(xinfra_args)
"""

const xsh_remove_link = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, process, error] {
  let target = fp"{xinfra_args[0]}"
  if ! (target.is_symlink() ?? false) {
    eprint "refusing to remove something that is not a symlink"
    exit 66
  }
  target.unlink()?
}
xinfra_main(xinfra_args)
"""

const xsh_create_stage = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, io, error] {
  let stage = fs.temp_sibling(fp"{xinfra_args[0]}/xinfra")?
  fs.mknod(stage, "file", 0o600)?
  io.write_stdout(xinfra_hex(stage.bytes()))?
}
xinfra_main(xinfra_args)
"""

const xsh_write_stage = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, io, error] {
  let data = io.stdin_bytes()?
  fp"{xinfra_args[0]}".write(data)?
}
xinfra_main(xinfra_args)
"""

const xsh_inspect_stage = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, error] {
  let target = fp"{xinfra_args[0]}"
  let digest = hash.sha256(target)?
  let info = fs.stat(target)?
  print f"digest {digest.hex()}"
  print f"size {info.size}"
}
xinfra_main(xinfra_args)
"""

const xsh_finish_stage = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, error] {
  let target = fp"{xinfra_args[0]}"
  if xinfra_args[1] != "" {
    xinfra_owner(target, xinfra_args[1])?
  }
  let mode = f"0o{xinfra_args[2]}".parse_int()?
  target.chmod(mode)?
}
xinfra_main(xinfra_args)
"""

const xsh_promote_stage = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, process, error] {
  let destination = fp"{xinfra_args[1]}"
  let existing = match fs.stat(destination, follow_symlinks: true) {
    Ok(found) => found
    Err(_) => null
  }
  if existing != null and existing.kind == "dir" {
    eprint "refusing to replace a directory"
    exit 66
  }
  fp"{xinfra_args[0]}".rename(to: destination, overwrite: true)?
}
xinfra_main(xinfra_args)
"""

const xsh_discard_stage = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, error] {
  match fp"{xinfra_args[0]}".unlink() {
    Ok(_) => {}
    Err(error) => {
      if (error.errno ?? 0) != 2 {
        return Err(error)
      }
    }
  }
}
xinfra_main(xinfra_args)
"""

const xsh_xinit_control_service = r"""
proc xinfra_main(xinfra_args: List[Str]) [process, io, error] {
  if xinfra_args[1] not in ["start", "stop", "restart", "reload"] {
    eprint f"xinit has no such service action: {xinfra_args[1]}"
    exit 64
  }
  let plan = process.command_argv("xinit", ["xinit", xinfra_args[1], xinfra_args[0]])
  match process.run(plan) {
    Err(error) => {
      eprint f"xinfra: {error.message}"
      exit 127
    }
    Ok(status) => {
      if status.signaled() {
        exit 125
      }
      match status.exit_code() {
        Ok(code) => exit code
        Err(_) => exit 127
      }
    }
  }
}
xinfra_main(xinfra_args)
"""

const xsh_acquire_lock = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, process, error] {
  let target = if xinfra_args[0].starts_with("/") { fp"{xinfra_args[0]}" } else { fp"{fs.cwd()?}/{xinfra_args[0]}" }
  var created = false
  match fs.open_root(target.parent()) {
    Ok(root) => {
      match root.mkdir(target.strip_prefix(target.parent())?, mode: 0o700) {
        Ok(_) => { created = true }
        Err(_) => {}
      }
    }
    Err(_) => {}
  }
  if created {
    let source = p"/proc/sys/kernel/random/uuid".read_text()?
    let token = source.trim().replace("-", with: "")
    fp"{xinfra_args[0]}/owner".write(f"{token}\n{xinfra_args[1]}\n", mode: 0o600)?
    print f"acquired {token}"
  } else {
    let raw = fp"{xinfra_args[0]}/owner".read_text() ?? ""
    let holder = raw.replace("\n", with: " ")
    print f"held {xinfra_hex(bytes.from_text(holder))}"
    exit 75
  }
}
xinfra_main(xinfra_args)
"""

const xsh_release_lock = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, process, error] {
  let target = if xinfra_args[0].starts_with("/") { xinfra_args[0] } else { f"{fs.cwd()?}/{xinfra_args[0]}" }
  let raw = fp"{target}/owner".read_text() ?? ""
  let lines = raw.lines()
  let owner = if lines.is_empty() { "" } else { lines[0] }
  if owner != "" and owner == xinfra_args[1] {
    match fp"{target}/owner".unlink() {
      Ok(_) => {}
      Err(_) => {}
    }
    fp"{target}".remove_dir()?
  } else {
    eprint "the lock is not held with this token"
    exit 76
  }
}
xinfra_main(xinfra_args)
"""

const xsh_inspect_lock = r"""
proc xinfra_main(xinfra_args: List[Str]) [fs, error] {
  let target = if xinfra_args[0].starts_with("/") { fp"{xinfra_args[0]}" } else { fp"{fs.cwd()?}/{xinfra_args[0]}" }
  if ! (target.is_dir() ?? false) {
    print "state free"
    return
  }
  let raw = fp"{target}/owner".read_text() ?? ""
  let holder = raw.replace("\n", with: " ")
  print "state held"
  print f"holder {xinfra_hex(bytes.from_text(holder))}"
}
xinfra_main(xinfra_args)
"""

pure posix_source(operation: Operation) -> Str {
  match operation {
    PathState => path_state
    PackageState => package_state
    AccountsState => accounts_state
    ServiceState => service_state
    XinitServiceState => xinit_service_state
    Capabilities => capabilities
    EchoArguments => echo_arguments
    RunArgv => run_argv
    RunShell => run_shell
    MakeDirectory => make_directory
    ChangeOwner => change_owner
    ChangeMode => change_mode
    RemoveDirectory => remove_directory
    RemoveFile => remove_file
    MakeLink => make_link
    ReplaceLink => replace_link
    RemoveLink => remove_link
    CreateStage => create_stage
    WriteStage => write_stage
    InspectStage => inspect_stage
    FinishStage => finish_stage
    PromoteStage => promote_stage
    DiscardStage => discard_stage
    ApkAdd => apk_add
    ApkDel => apk_del
    ApkUpdate => apk_update
    AddGroup => add_group
    DeleteGroup => delete_group
    AddUser => add_user
    ModifyUser => modify_user
    JoinGroup => join_group
    DeleteUser => delete_user
    EnableService => enable_service
    DisableService => disable_service
    ControlService => control_service
    XinitControlService => xinit_control_service
    AcquireLock => acquire_lock
    ReleaseLock => release_lock
    InspectLock => inspect_lock
  }
}

pure xsh_source(operation: Operation) -> Result[Str, ScriptError] {
  let body = match operation {
    PathState => xsh_path_state
    XinitServiceState => xsh_xinit_service_state
    Capabilities => xsh_capabilities
    EchoArguments => xsh_echo_arguments
    RunArgv => xsh_run_argv
    MakeDirectory => xsh_make_directory
    ChangeOwner => xsh_change_owner
    ChangeMode => xsh_change_mode
    RemoveDirectory => xsh_remove_directory
    RemoveFile => xsh_remove_file
    MakeLink => xsh_make_link
    ReplaceLink => xsh_replace_link
    RemoveLink => xsh_remove_link
    CreateStage => xsh_create_stage
    WriteStage => xsh_write_stage
    InspectStage => xsh_inspect_stage
    FinishStage => xsh_finish_stage
    PromoteStage => xsh_promote_stage
    DiscardStage => xsh_discard_stage
    XinitControlService => xsh_xinit_control_service
    AcquireLock => xsh_acquire_lock
    ReleaseLock => xsh_release_lock
    InspectLock => xsh_inspect_lock
    else => {
      return Err(ScriptError.Missing(dialect: .Xsh, operation:, message: f"the xsh dialect has no script for {operation}"))
    }
  }
  Ok(f"{xsh_prelude}\n{body}")
}

## The source of one operation in one dialect, or the typed reason the dialect
## does not provide it.
export pure source(dialect: model.Dialect, operation: Operation) -> Result[Str, ScriptError] {
  match dialect {
    model.Posix => Ok(posix_source(operation))
    model.Xsh => xsh_source(operation)
  }
}

## Whether a dialect provides an operation.
export pure supports(dialect: model.Dialect, operation: Operation) -> Bool {
  match dialect {
    model.Posix => true
    model.Xsh => match operation {
      PathState => true
      XinitServiceState => true
      Capabilities => true
      EchoArguments => true
      RunArgv => true
      MakeDirectory => true
      ChangeOwner => true
      ChangeMode => true
      RemoveDirectory => true
      RemoveFile => true
      MakeLink => true
      ReplaceLink => true
      RemoveLink => true
      CreateStage => true
      WriteStage => true
      InspectStage => true
      FinishStage => true
      PromoteStage => true
      DiscardStage => true
      XinitControlService => true
      AcquireLock => true
      ReleaseLock => true
      InspectLock => true
      else => false
    }
  }
}

## The operations one resource kind needs, including every mutation path the
## kind can take. `workload.prepare` checks them against each host's dialect.
export pure operations(spec: model.Spec) -> List[Operation] {
  match spec {
    model.Directory(_) => [.PathState, .MakeDirectory, .ChangeOwner, .ChangeMode, .RemoveDirectory]
    model.File(_) => [.PathState, .CreateStage, .WriteStage, .InspectStage, .FinishStage, .PromoteStage, .DiscardStage, .RemoveFile, .ChangeOwner, .ChangeMode, .RunArgv]
    model.Link(_) => [.PathState, .MakeLink, .ReplaceLink, .RemoveLink]
    model.Package(_) => [.PackageState, .ApkAdd, .ApkDel]
    model.PackageIndex(_) => [.ApkUpdate]
    model.GroupAccount(_) => [.AccountsState, .AddGroup, .DeleteGroup]
    model.UserAccount(_) => [.AccountsState, .AddUser, .ModifyUser, .JoinGroup, .DeleteUser]
    model.Exec(command) => {
      var found: List[Operation] = []
      match command.invocation {
        model.Argv(_) => { found += [.RunArgv] }
        model.Shell(_) => { found += [.RunShell] }
      }
      match command.guard {
        model.Creates(_) => { found += [.PathState] }
        model.SkipIf(invocation) => {
          match invocation {
            model.Argv(_) => { found += [.RunArgv] }
            model.Shell(_) => { found += [.RunShell] }
          }
        }
        model.OnlyIf(invocation) => {
          match invocation {
            model.Argv(_) => { found += [.RunArgv] }
            model.Shell(_) => { found += [.RunShell] }
          }
        }
        else => {}
      }
      found
    }
    model.Service(service) => {
      match service.adapter {
        model.OpenRc => [.ServiceState, .EnableService, .DisableService, .ControlService]
        model.Xinit => [.XinitServiceState, .XinitControlService]
      }
    }
  }
}
