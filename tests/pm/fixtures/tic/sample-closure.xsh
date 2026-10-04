#!/bin/xsh
# Print the entries of a terminfo source that the named entries need: the
# entries themselves and, transitively, every entry their use= clauses name,
# in source order.  Comment lines are dropped; entry text is kept verbatim.
#
#   xsh sample-closure.xsh -- terminfo.src NAME... > ncurses-sample.src

error ClosureError = Missing(name: Str)

type SourceEntry = {names: List[Str], text: Str, uses: List[Str]}

proc entries_of(source: Path) [fs, error] -> Result[List[SourceEntry]] {
  var entries: List[SourceEntry] = []
  var lines: List[Str] = []
  for line in source.read_text()?.split("\n") {
    if line.starts_with("#") or line.trim() == "" {
      continue
    }

    if line.starts_with(" ") or line.starts_with("\t") {
      lines += [line]
      continue
    }

    if lines.len() > 0 {
      entries += [entry_of(lines)]
    }

    lines = [line]
  }

  if lines.len() > 0 {
    entries += [entry_of(lines)]
  }

  entries
}

# The targets of the `use=` clauses in an entry's text.
pure uses_of(text: Str) -> List[Str] {
  var uses: List[Str] = []
  var at = text.find("use=")
  while at != null {
    let start = at + 4
    var end = start
    while end < text.byte_len() and text.byte_slice(end, 1) != "," and text.byte_slice(end, 1).trim() != "" {
      end += 1
    }

    uses += [text.byte_slice(start, end - start)]
    at = text.find("use=", end)
  }

  uses
}

pure entry_of(lines: List[Str]) -> SourceEntry {
  let text = lines.join("\n")
  SourceEntry(names: lines[0].split(",")[0].split("|"), text:, uses: uses_of(text))
}

cli main(source: Path, ...names: List[Str]) {
  let entries = entries_of(source)?
  var wanted: Map[Str, Bool] = {}
  var pending = names
  while pending.len() > 0 {
    let name = pending[0]
    pending = pending[1..]
    if name in wanted {
      continue
    }

    wanted[name] = true
    let owners = [entry for entry in entries if name in entry.names]
    guard owners.len() > 0 else {
      return Err(ClosureError.Missing(name:))
    }

    for owner in owners {
      pending = pending + owner.uses
    }
  }

  let kept = [entry.text for entry in entries if [name for name in entry.names if name in wanted].len() > 0]
  print (kept.join("\n\n"))
}
