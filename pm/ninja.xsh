##! Generated Ninja manifest operations.

## Replace one command argument on every generated command line. Fails when none of `olds` appears, so a stale path cannot leave the original tool in place.
export proc ninja_rewrite_command_arguments(text: Str, olds: List[Str], replacement: Str) -> Result[Str, Error] {
  if replacement == "" or olds.is_empty() or "" in olds {
    return Err(error.failure("Ninja command arguments must not be empty"))?
  }
  var replaced = 0
  let lines = collect {
    for line in text.split("\n") {
      if line.starts_with("  COMMAND = ") {
        let words = line.byte_slice(12).split(" ")
        replaced += [word for word in words if word in olds].len()
        yield "  COMMAND = " + [if word in olds { replacement } else { word } for word in words].join(" ")
      } else {
        yield line
      }
    }
  }
  if replaced == 0 {
    return Err(error.failure(f"no generated command uses {olds.join(" or ")}"))?
  }
  lines.join("\n")
}
