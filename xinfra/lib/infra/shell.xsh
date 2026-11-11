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

const hex_digits = "0123456789abcdef"

pure xsh_hex_byte(byte: Int) -> Str {
  f"\\x{hex_digits.byte_slice(byte / 16, 1)}{hex_digits.byte_slice(byte % 16, 1)}"
}

## Quote one value as an XSH double-quoted string literal. Bytes outside
## printable ASCII become `\xNN`, so the literal decodes to the same UTF-8 text
## whatever the value contains; a value with a NUL byte has no representation
## on an SSH command line and is refused instead of truncated.
export pure xsh_quote(value: Str) -> Result[Str, Error] {
  if value.find(nul) != null {
    fail "a remote command string cannot contain a NUL byte"
  }

  var text = "\""
  var index = 0
  while index < value.byte_len() {
    let byte = value.byte_at(index) ?? 0
    if byte == 34 {
      text = text + "\\\""
    } else if byte == 36 {
      text = text + "\\$"
    } else if byte == 92 {
      text = text + "\\\\"
    } else if byte == 9 {
      text = text + "\\t"
    } else if byte == 10 {
      text = text + "\\n"
    } else if byte == 13 {
      text = text + "\\r"
    } else if byte >= 32 and byte < 127 {
      text = text + value.byte_slice(index, 1)
    } else {
      text = text + xsh_hex_byte(byte)
    }
    index += 1
  }

  Ok(text + "\"")
}

## Render one XSH program for the remote `xsh-login -c`. The catalogue source
## is a constant that reads its operands from `xinfra_args`; the values are
## emitted as escaped XSH string literals, so an operand cannot change the
## program.
export pure xsh_command(script: Str, args: List[Str]) -> Result[Str, Error] {
  var quoted: List[Str] = []
  for value in args {
    quoted += [xsh_quote(value)?]
  }

  Ok(f"let xinfra_args: List[Str] = [{quoted.join(", ")}]\n{script}\n")
}
