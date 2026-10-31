##! Remote baseline probes over one native SSH session.

use xinfra.transport as transport

## One doctor probe result.
export type Check = {name: Str, ok: Bool, detail: Str}

## Probe the remote POSIX and Alpine baseline on one session.
export proc doctor(session: transport.Session) -> Result[List[Check], Str] {
  let script = r"""
set -u
printf 'sh=%s\n' "$([ -x /bin/sh ] && echo yes || echo no)"
printf 'lc_all=%s\n' "${LC_ALL:-missing}"
printf 'path=%s\n' "$PATH"
printf 'stat=%s\n' "$([ -n "$(stat -c '%a' / 2>/dev/null)" ] && echo yes || echo no)"
printf 'sha256sum=%s\n' "$(command -v sha256sum >/dev/null 2>&1 && echo yes || echo no)"
printf 'mktemp=%s\n' "$(command -v mktemp >/dev/null 2>&1 && echo yes || echo no)"
scratch="$(mktemp -d 2>/dev/null || true)"
mv_t=no
if [ -n "$scratch" ]; then
  : > "$scratch/a"
  : > "$scratch/b"
  mv -T "$scratch/a" "$scratch/b" 2>/dev/null && mv_t=yes
  rm -rf "$scratch"
fi
printf 'mv_t=%s\n' "$mv_t"
printf 'apk=%s\n' "$(command -v apk >/dev/null 2>&1 && echo yes || echo no)"
printf 'rc_service=%s\n' "$(command -v rc-service >/dev/null 2>&1 && echo yes || echo no)"
printf 'sudo=%s\n' "$(sudo -n true 2>/dev/null && echo yes || echo no)"
printf 'doas=%s\n' "$(doas -n true 2>/dev/null && echo yes || echo no)"
"""
  let result = transport.run_script(session, script, 30000)?
  if result.exit_code != 0 {
    return Err(f"doctor probe failed: {result.stderr.utf8() ?? ""}")
  }

  let values = parse_values(result.stdout.utf8() ?? "")
  Ok([
    check("sh", map_value(values, "sh"), "yes"),
    check("LC_ALL", map_value(values, "lc_all"), "C"),
    check("PATH", map_value(values, "path"), transport.REMOTE_PATH),
    check("stat -c", map_value(values, "stat"), "yes"),
    check("sha256sum", map_value(values, "sha256sum"), "yes"),
    check("mktemp", map_value(values, "mktemp"), "yes"),
    check("mv -T", map_value(values, "mv_t"), "yes"),
    check("apk", map_value(values, "apk"), "yes"),
    check("rc-service", map_value(values, "rc_service"), "yes"),
    check("sudo", map_value(values, "sudo"), "yes"),
    check("doas", map_value(values, "doas"), "yes"),
  ])
}

pure parse_values(text: Str) -> Map[Str, Str] {
  var values: Map[Str, Str] = {}
  for line in text.lines() {
    let parts = line.split("=", maxsplit: 1)
    if parts.len() == 2 {
      values[parts[0]] = parts[1]
    }
  }
  values
}

pure map_value(values: Map[Str, Str], key: Str) -> Str {
  match values.get(key) {
    Ok(value) => value,
    Err(_) => "",
  }
}

pure check(name: Str, actual: Str, expected: Str) -> Check {
  {name: name, ok: actual == expected, detail: actual}
}
