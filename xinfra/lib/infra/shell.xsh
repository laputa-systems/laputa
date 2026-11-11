##! The only place a request value becomes remote shell source.

const single_quote = "'"
const nul = "\0"

## Quote one value as a single POSIX shell word. A value with a NUL byte has no
## shell representation and is refused instead of truncated.
export pure quote(value: Str) -> Result[Str, Error] {
  if value.find(nul) != null {
    fail "a remote shell word cannot contain a NUL byte"
  }

  Ok(f"'{value.replace(single_quote, with: "'\\''")}'")
}

pure quote_all(values: List[Str]) -> Result[List[Str], Error] {
  var quoted: List[Str] = []
  for value in values {
    quoted += [quote(value)?]
  }

  Ok(quoted)
}

## Render the command string handed to the remote login shell: the script is a
## constant single-quoted word run by `/bin/sh -c`, and every request value
## follows it as a positional argument.
export pure command(script: Str, args: List[Str]) -> Result[Str, Error] {
  let words = ["/bin/sh", "-c", quote(script)?, "xinfra"] + quote_all(args)?
  Ok(words.join(" "))
}

## Render the command string for a script that runs through `doas -n`.
export pure escalated_command(script: Str, args: List[Str]) -> Result[Str, Error] {
  Ok(f"doas -n {command(script, args)?}")
}
