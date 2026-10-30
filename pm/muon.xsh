##! Muon structured command argument operations.

## Encode one argument for Muon's structured Ninja metadata.
export pure muon_encoded_argument(value: Str) -> Str {
  let hex = "0123456789abcdef"
  let parts = collect {
    for byte in bytes.from_text(value) {
      yield hex.byte_slice(byte / 16, 1) + hex.byte_slice(byte % 16, 1)
    }
  }
  "x" + parts.join("")
}

## Rewrite a command argument and its structured metadata together.
export proc muon_rewrite_ninja_argument(text: Str, old: Str, replacement: Str) -> Result[Str, Error] {
  if old == "" or replacement == "" {
    return Err(error.failure("Muon command arguments must not be empty"))?
  }
  return text when old == replacement
  let encoded_old = muon_encoded_argument(old)
  let encoded_replacement = muon_encoded_argument(replacement)
  var commands = 0
  var arguments = 0
  for line in text.split("\n") {
    if line.starts_with(" COMMAND = ") {
      commands += line.split(old).len() - 1
    }
    if line.starts_with(" ARGV_COMMAND = ") {
      for token in line.split(" ") {
        arguments += 1 when token == encoded_old
      }
    }
  }
  if commands != arguments {
    return Err(error.failure(f"Muon command and structured argument counts differ for {old}"))?
  }
  let lines = collect {
    for line in text.split("\n") {
      var rewritten = line
      if line.starts_with(" COMMAND = ") {
        rewritten = line.replace(old, with: replacement)
      }
      if line.starts_with(" ARGV_COMMAND = ") {
        rewritten = [
          if token == encoded_old { encoded_replacement } else { token }
          for token in line.split(" ")
        ].join(" ")
      }
      yield rewritten
    }
  }
  lines.join("\n")
}
