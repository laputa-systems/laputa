##! Kbuild's scripts/headers_install.sh in XSH: turn a kernel uapi header into the header userspace includes.
# The script runs two passes over each header: sed rewrites that drop kernel
# annotations and the `_UAPI` guard prefix, then `unifdef -U__KERNEL__
# -D__EXPORTED_HEADERS__`, which removes kernel-only conditional blocks. A raw
# uapi header is not usable as is: asm/swab.h, for one, includes
# <linux/compiler.h>, which only the kernel tree has.

## A header the rewrite cannot process: an unbalanced conditional or a malformed expression.
export error UapiError = Failed(kind: Str, message: Str)

## Apply headers_install.sh's sed rewrites to one header line.
export pure rewrite_line(line: Str) -> Str {
  var out = rx"([[:space:](])(__user|__force|__iomem)[[:space:]]".replace(line, "$1")
  out = rx"__attribute_const__([[:space:]]|$)".replace(out, "$1")
  out = rx"^#include <linux/compiler.h>".replace(out, "")
  out = rx"(^|[^a-zA-Z0-9])__packed([^a-zA-Z0-9_]|$)".replace(out, r"${1}__attribute__((packed))${2}")
  out = rx"(^|[[:space:](])(inline|asm|volatile)([[:space:](]|$)".replace(out, r"${1}__${2}__${3}")
  rx"#(ifndef|define|endif[[:space:]]*/[*])[[:space:]]*_UAPI".replace(out, "#$1 ")
}

# A preprocessor condition after substituting the two symbols unifdef knows:
# a constant, or `known: false` when other macros decide it.
type Cond = {known: Bool, value: Bool}

type Parsed = {cond: Cond, next: Int}

pure constant(value: Bool) -> Cond {
  {known: true, value}
}

const unknown: Cond = {known: false, value: false}

pure negate(cond: Cond) -> Cond {
  return constant(! cond.value) when cond.known

  unknown
}

# `&&` (absorbing false) or `||` (absorbing true): an absorbing constant
# decides the result whatever the unknown parts are.
pure combine(parts: List[Cond], op: Str) -> Cond {
  let absorbing = op == "||"
  var decided = true

  for part in parts {
    if part.known {
      return constant(absorbing) when part.value == absorbing
    } else {
      decided = false
    }
  }

  return constant(! absorbing) when decided

  unknown
}

pure defined_cond(name: Str) -> Cond {
  return constant(false) when name == "__KERNEL__"

  return constant(true) when name == "__EXPORTED_HEADERS__"

  unknown
}

pure tokenize(expr: Str) -> List[Str] {
  [found.text for found in rx"&&|\|\||==|!=|<=|>=|<<|>>|[A-Za-z_][A-Za-z0-9_]*|[0-9][A-Za-z0-9_]*|\S".find(expr)]
}

pure token(tokens: List[Str], index: Int) -> Str {
  return tokens[index] when index < tokens.len()

  ""
}

proc parse_or(tokens: List[Str], start: Int) [error] -> Result[Parsed] {
  let first = parse_and(tokens, start)?
  var parts = [first.cond]
  var at = first.next

  while token(tokens, at) == "||" {
    let next = parse_and(tokens, at + 1)?
    parts += [next.cond]
    at = next.next
  }

  {cond: combine(parts, "||"), next: at}
}

proc parse_and(tokens: List[Str], start: Int) [error] -> Result[Parsed] {
  let first = parse_unary(tokens, start)?
  var parts = [first.cond]
  var at = first.next

  while token(tokens, at) == "&&" {
    let next = parse_unary(tokens, at + 1)?
    parts += [next.cond]
    at = next.next
  }

  {cond: combine(parts, "&&"), next: at}
}

proc parse_unary(tokens: List[Str], start: Int) [error] -> Result[Parsed] {
  if token(tokens, start) == "!" {
    let inner = parse_unary(tokens, start + 1)?
    return {cond: negate(inner.cond), next: inner.next}
  }

  parse_primary(tokens, start)?
}

proc parse_primary(tokens: List[Str], start: Int) [error] -> Result[Parsed] {
  let first = token(tokens, start)

  if first == "(" {
    let inner = parse_or(tokens, start + 1)?

    if token(tokens, inner.next) != ")" {
      return Err(UapiError.Failed(kind: "uapi-expression", message: f"unbalanced parentheses in `{tokens.join(" ")}`"))
    }

    return {cond: inner.cond, next: inner.next + 1}
  }

  if first == "defined" {
    if token(tokens, start + 1) == "(" and token(tokens, start + 3) == ")" {
      return {cond: defined_cond(token(tokens, start + 2)), next: start + 4}
    }

    if token(tokens, start + 1) != "" {
      return {cond: defined_cond(token(tokens, start + 1)), next: start + 2}
    }
  }

  # Anything else up to the next top-level `&&`, `||`, or closing `)` is an
  # opaque term such as `__BITS_PER_LONG == 32`.
  var at = start
  var depth = 0
  var words: List[Str] = []

  while at < tokens.len() {
    let word = tokens[at]
    break when depth == 0 and (word == "&&" or word == "||" or word == ")")
    depth += if word == "(" { 1 } else if word == ")" { -1 } else { 0 }
    words += [word]
    at += 1
  }

  if words.len() == 0 {
    return Err(UapiError.Failed(kind: "uapi-expression", message: f"empty term in `{tokens.join(" ")}`"))
  }

  {cond: unknown, next: at}
}

## Evaluate an `#if` expression with __KERNEL__ undefined and __EXPORTED_HEADERS__ defined.
export proc eval_condition(expr: Str) [error] -> Result[Cond, Error] {
  let tokens = tokenize(expr)
  let parsed = parse_or(tokens, 0)?

  if parsed.next != tokens.len() {
    return Err(UapiError.Failed(kind: "uapi-expression", message: f"trailing tokens in `{expr}`"))
  }

  parsed.cond
}

type Directive = {kind: Str, expr: Str}

pure directive(line: Str) -> Directive? {
  let parts = rx"^[[:space:]]*#[[:space:]]*(ifdef|ifndef|if|elif|else|endif)([^A-Za-z0-9_].*)?$".captures(line)

  return null when parts.len() < 2

  # Comments in the condition are not part of the expression.
  let tail = if parts.len() > 2 { parts[2] } else { "" }
  let expr = rx"//.*$".replace(rx"/\*.*?\*/".replace(tail, " "), "").trim()
  {kind: parts[1], expr}
}

pure touches(expr: Str) -> Bool {
  for word in tokenize(expr) {
    return true when word == "__KERNEL__" or word == "__EXPORTED_HEADERS__"
  }

  false
}

proc directive_cond(found: Directive) [error] -> Result[Cond] {
  return defined_cond(found.expr) when found.kind == "ifdef"

  return negate(defined_cond(found.expr)) when found.kind == "ifndef"

  eval_condition(found.expr)?
}

# A conditional block as unifdef rewrites it. `kept` blocks stay in the output
# with their directives; `resolved` blocks lose their directives and keep at
# most the one branch that is true; `closed` is a kept block whose remaining
# branches follow a branch that became `#else`; `dropped` sits inside a branch
# that is gone.
type Frame = {mode: Str, taking: Bool, done: Bool}

pure all_taking(frames: List[Frame]) -> Bool {
  for frame in frames {
    return false unless frame.taking
  }

  true
}

pure set_top(frames: List[Frame], frame: Frame) -> List[Frame] {
  frames[..frames.len() - 1].push(frame)
}

# Like unifdef, only a condition that resolves to a constant changes the
# output; any other directive, mixed ones included, passes through byte for
# byte.
## Remove kernel-only conditional blocks as `unifdef -U__KERNEL__ -D__EXPORTED_HEADERS__` does.
export proc unifdef(lines: List[Str]) [error] -> Result[List[Str], Error] {
  var out: List[Str] = []
  var frames: List[Frame] = []
  var index = 0

  while index < lines.len() {
    # A directive continued with backslashes is one logical line.
    var physical = [lines[index]]

    while physical[physical.len() - 1].ends_with("\\") and index + 1 < lines.len() {
      index += 1
      physical += [lines[index]]
    }

    index += 1
    let logical = [rx"\\$".replace(line, "") for line in physical].join(" ")
    let found = directive(logical)

    if found == null {
      if all_taking(frames) {
        out += physical
      }

      continue
    }

    let current: Directive = found
    let touched = touches(current.expr)

    if current.kind in ["if", "ifdef", "ifndef"] {
      if ! all_taking(frames) {
        frames += [{mode: "dropped", taking: false, done: true}]
      } else if ! touched {
        frames += [{mode: "kept", taking: true, done: false}]
        out += physical
      } else {
        let cond = directive_cond(current)?

        if cond.known {
          frames += [{mode: "resolved", taking: cond.value, done: cond.value}]
        } else {
          frames += [{mode: "kept", taking: true, done: false}]
          out += physical
        }
      }

      continue
    }

    if frames.len() == 0 {
      return Err(UapiError.Failed(kind: "uapi-conditional", message: f"#{current.kind} without #if"))
    }

    let top = frames[frames.len() - 1]

    if current.kind == "endif" {
      frames = frames[..frames.len() - 1]
      if top.mode == "kept" or top.mode == "closed" {
        out += physical
      }

      continue
    }

    match top.mode {
      "dropped" => {}
      "closed" => frames = set_top(frames, {...top, taking: false})
      "resolved" => {
        if current.kind == "else" {
          frames = set_top(frames, {...top, taking: ! top.done, done: true})
        } else if top.done {
          frames = set_top(frames, {...top, taking: false})
        } else {
          let cond = if touched { eval_condition(current.expr)? } else { unknown }

          if cond.known {
            frames = set_top(frames, {...top, taking: cond.value, done: cond.value})
          } else {
            # The first surviving branch opens the block: unifdef overwrites
            # `elif` with `if  ` in place and keeps the rest of the line.
            frames = set_top(frames, {mode: "kept", taking: true, done: false})
            out += [rx"^([[:space:]]*#[[:space:]]*)elif".replace(physical[0], r"${1}if  ")].extend(physical[1..])
          }
        }
      }
      _ => {
        if current.kind == "else" or ! touched {
          frames = set_top(frames, {...top, taking: true})
          out += physical
        } else {
          let cond = eval_condition(current.expr)?

          if cond.known and cond.value {
            frames = set_top(frames, {mode: "closed", taking: true, done: true})
            out += ["#else"]
          } else if cond.known {
            frames = set_top(frames, {...top, taking: false})
          } else {
            frames = set_top(frames, {...top, taking: true})
            out += physical
          }
        }
      }
    }
  }

  if frames.len() > 0 {
    return Err(UapiError.Failed(kind: "uapi-conditional", message: "#if without #endif"))
  }

  out
}

## The installed form of one uapi header's text.
export proc install_text(text: Str) [error] -> Result[Str, Error] {
  let lines = [rewrite_line(line) for line in text.lines()]
  let kept = unifdef(lines)?

  return "" when kept.len() == 0

  kept.join("\n") + "\n"
}

## Install every header below `source` to the same relative path below `target`, rewritten for userspace.
export proc install_tree(source: Path, target: Path) [fs, error] {
  let source_root = path.absolute(source)?

  for entry in fs.files(source)? |> where .ext == "h" {
    let out = fp"{target}/{entry.path.relative_to(source_root)}"
    fs.mkdir(out.parent)?
    fs.write(out, install_text(entry.path.read_text()?)?)?
    fs.chmod(out, 0o644)?
  }
}
