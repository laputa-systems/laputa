##! Semantic comparison of checked-in Linux configurations with Kconfig output.
pure linux_config_symbols(text: Str) -> Map[Str] {
  var symbols: Map[Str] = {}

  for raw in text.split("\n") {
    let line = raw.trim()

    if line.starts_with("CONFIG_") and "=" in line {
      let split_at = line.find("=") ?? 0
      symbols[line.byte_slice(0, split_at)] = line.byte_slice(split_at + 1)
    } else if line.starts_with("# CONFIG_") and line.ends_with(" is not set") {
      let name = line.byte_slice(2, line.byte_len() - 2 - " is not set".byte_len())
      symbols[name] = "n"
    }
  }

  symbols
}

## Returns sorted symbol changes, preserving absence, disabled symbols, and literal values.
export pure linux_config_changes(before: Str, after: Str) -> List[Str] {
  let original = linux_config_symbols(before)
  let normalized = linux_config_symbols(after)
  var names = original.keys()

  for name in normalized.keys() {
    if name not in names {
      names += [name]
    }
  }

  var changes: List[Str] = []

  for name in names |> sort-by . {
    let old_value = original.get(name) ?? "<absent>"
    let new_value = normalized.get(name) ?? "<absent>"

    if old_value != new_value {
      changes += [f"{name}: {old_value} -> {new_value}"]
    }
  }

  changes
}
