##! Parses restricted CMake Ninja actions.
error NinjaParseError = Invalid(message: Str)

## Parses literal arguments and the supported command sequencing operator.
export proc ninja_actions_parse(text: Str) [process, error] -> Result[List[List[Str]], Error] {
  let chars = text.split("")
  var quote = ""
  var escaped = false
  var current = ""
  var parts: List[Str] = []
  var i = 0
  while i < chars.len() {
    let c = chars[i]
    if escaped {
      current += c
      escaped = false
    } else if c == "\\" and quote != "'" {
      current += c
      escaped = true
    } else if quote == "'" {
      current += c
      if c == "'" { quote = "" }
    } else if quote == "\"" {
      if c == "$" or c == "`" { return Err(NinjaParseError.Invalid(message: f"unsupported expansion: {text}")) }
      current += c
      if c == "\"" { quote = "" }
    } else if c == "'" or c == "\"" {
      quote = c
      current += c
    } else if c == "&" and i + 1 < chars.len() and chars[i + 1] == "&" {
      parts = parts.push(current)
      current = ""
      i += 1
    } else if c in ["&", "|", ";", "<", ">", "$", "`", "(", ")", "*", "?", "[", "]", "~", "#", "{", "}", "\n"] {
      return Err(NinjaParseError.Invalid(message: f"unsupported shell syntax: {text}"))
    } else {
      current += c
    }
    i += 1
  }
  if quote != "" or escaped { return Err(NinjaParseError.Invalid(message: f"unterminated argument: {text}")) }
  parts = parts.push(current)
  var commands: List[List[Str]] = []
  for part in parts {
    let argv = process.argv_words(part.trim())?
    if argv.is_empty() { return Err(NinjaParseError.Invalid(message: f"empty action: {text}")) }
    commands = commands.push(argv)
  }
  commands
}

