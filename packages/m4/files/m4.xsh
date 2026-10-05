#!/bin/xsh
error ScriptError = Failed(kind: Str, message: Str)

# m4 — macro processor in pure XSH, following GNU M4 1.4.x.
#
# Bison runs its skeletons (m4sugar, c-skel.m4, yacc.c, glr.c, lalr1.cc) and
# flex runs its scanner skeleton through this program, so it implements the
# GNU m4 language rather than a subset: an input stack that rescans every
# expansion, arguments collected while expanding the macros inside them,
# nested quotes, comments, `$@`/`$*`/`$#`/`$N` substitution, builtin tokens
# (`defn` of a builtin), pushdef stacks, numbered diversions, LIFO `m4wrap`,
# 32-bit `eval`, GNU regular expressions, and `-P` prefixed builtins.
#
# The expander keeps all mutable state in locals of `expand_inputs`. XSH
# values are copied when a mutated collection is shared, so the macro table,
# the input stack, and the pending-call stack never cross a call boundary;
# helpers receive only strings and small argument lists.
#
# Differences from GNU m4 that bison and flex do not reach:
# - text is UTF-8 and string builtins count bytes like GNU m4, so `substr`
#   and `format` precision fail loudly rather than split a multi-byte
#   character, `translit` maps characters, and `%c` of a byte above 127
#   gives the Latin-1 character (m4sugar's unused `m4_cr_all` table);
# - regular expressions run on the Rust engine: alternation is leftmost-first
#   rather than POSIX leftmost-longest, and back-references in a pattern fail
#   loudly;
# - multi-byte quote and comment delimiters must lie inside one input block;
# - `syscmd` runs `cat` here-documents (bison's `b4_cat`) natively and needs
#   `/bin/sh` for any other command, as does `esyscmd`;
# - `traceon`, `traceoff`, `debugmode`, and `debugfile` accept their
#   arguments and trace nothing; floating-point `format` conversions fail.

# A macro call whose arguments are still being collected. `at_*` locate the
# macro name for diagnostics when it was read from a file (`at_pos` is -1
# otherwise).
type PendingCall = {
  name: Str,
  defn: Str,
  args: List[Str],
  funcs: List[Str],
  parts: List[Str],
  func: Str,
  depth: Int,
  skip: Bool,
  at_text: Str,
  at_pos: Int,
  at_name: Str,
}

type QuoteScan = {end: Int, depth: Int}

type BuiltinOutput = {text: Str, notes: List[Str]}

type NumArg = {ok: Bool, value: Int, note: Str}

type EvalValue = {v: Int, err: Str}

type RegexTranslation = {pattern: Str, error: Str, groups: Int}

type Heredoc = {target: Str, body: Str}

type InputSpec = {name: Str, stdin: Bool}

type Options = {
  prefix: Bool,
  include_paths: List[Str],
  defines: List[List[Str]],
  inputs: List[InputSpec],
}

const default_lquote = "`"

const default_rquote = "'"

const int32_span = 4294967296

const nesting_limit = 1024

# Every ASCII character at its own byte offset, for `translit` ranges and `%c`.
const ascii_table = "\u{0}\u{1}\u{2}\u{3}\u{4}\u{5}\u{6}\u{7}\u{8}\t\n\u{b}\u{c}\r\u{e}\u{f}\u{10}\u{11}\u{12}\u{13}\u{14}\u{15}\u{16}\u{17}\u{18}\u{19}\u{1a}\u{1b}\u{1c}\u{1d}\u{1e}\u{1f} !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\u{7f}"

# U+0080..U+00FF, two bytes each: `%c` of a byte above 127 yields the Latin-1
# character, since text here is UTF-8 and cannot hold the raw byte.
const latin1_table = "\u{80}\u{81}\u{82}\u{83}\u{84}\u{85}\u{86}\u{87}\u{88}\u{89}\u{8a}\u{8b}\u{8c}\u{8d}\u{8e}\u{8f}\u{90}\u{91}\u{92}\u{93}\u{94}\u{95}\u{96}\u{97}\u{98}\u{99}\u{9a}\u{9b}\u{9c}\u{9d}\u{9e}\u{9f}\u{a0}\u{a1}\u{a2}\u{a3}\u{a4}\u{a5}\u{a6}\u{a7}\u{a8}\u{a9}\u{aa}\u{ab}\u{ac}\u{ad}\u{ae}\u{af}\u{b0}\u{b1}\u{b2}\u{b3}\u{b4}\u{b5}\u{b6}\u{b7}\u{b8}\u{b9}\u{ba}\u{bb}\u{bc}\u{bd}\u{be}\u{bf}\u{c0}\u{c1}\u{c2}\u{c3}\u{c4}\u{c5}\u{c6}\u{c7}\u{c8}\u{c9}\u{ca}\u{cb}\u{cc}\u{cd}\u{ce}\u{cf}\u{d0}\u{d1}\u{d2}\u{d3}\u{d4}\u{d5}\u{d6}\u{d7}\u{d8}\u{d9}\u{da}\u{db}\u{dc}\u{dd}\u{de}\u{df}\u{e0}\u{e1}\u{e2}\u{e3}\u{e4}\u{e5}\u{e6}\u{e7}\u{e8}\u{e9}\u{ea}\u{eb}\u{ec}\u{ed}\u{ee}\u{ef}\u{f0}\u{f1}\u{f2}\u{f3}\u{f4}\u{f5}\u{f6}\u{f7}\u{f8}\u{f9}\u{fa}\u{fb}\u{fc}\u{fd}\u{fe}\u{ff}"

proc read_input_file(filepath: Str) -> Result[Str] {
  # `fp"${...}"` is a literal-path form in the pinned published runner: it
  # resolves a dynamic operand as the current directory. Convert CLI text
  # explicitly so m4 reads the requested file, never its cwd.
  let input = fp"{filepath}"

  if ! input.exists() {
    return Err(ScriptError.Failed(kind: "m4-input", message: f"cannot open `{filepath}': No such file or directory"))
  }

  let metadata = input.metadata()?

  if metadata.kind != "file" {
    return Err(ScriptError.Failed(kind: "m4-input", message: f"cannot read non-file input: {filepath}"))
  }

  input.read_text()
}

# ── byte classes and scanning ────────────────────────────────────────────────
pure is_word_char(b: Int) -> Bool {
  (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or b == 95 or (b >= 48 and b <= 57)
}

pure is_space(b: Int) -> Bool {
  b == 32 or (b >= 9 and b <= 13)
}

pure space_end(text: Str, pos: Int, len: Int) -> Int {
  var i = pos

  while i < len {
    let b = text.byte_at(i) ?? 0

    if b != 32 and (b < 9 or b > 13) {
      return i
    }

    i += 1
  }

  i
}

pure word_end(text: Str, pos: Int, len: Int) -> Int {
  var i = pos

  while i < len {
    let b = text.byte_at(i) ?? 0

    if (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or b == 95 or (b >= 48 and b <= 57) {
      i += 1
    } else {
      return i
    }
  }

  i
}

# End of a run of ordinary text starting at `pos`. The byte at `pos` is
# always taken, so a lone first byte of a longer delimiter still advances.
pure plain_end(text: Str, pos: Int, len: Int, lq0: Int, bc0: Int, in_args: Bool) -> Int {
  var i = pos + 1

  while i < len {
    let b = text.byte_at(i) ?? 0

    if (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or b == 95 or b == lq0 or b == bc0 {
      return i
    }

    if in_args and (b == 40 or b == 41 or b == 44) {
      return i
    }

    i += 1
  }

  i
}

pure match_at(text: Str, pos: Int, needle: Str) -> Bool {
  let n = needle.byte_len()
  var i = 0

  while i < n {
    if text.byte_at(pos + i) != needle.byte_at(i) {
      return false
    }

    i += 1
  }

  true
}

# Scan quoted text from `pos`, already inside `depth` quote levels. The close
# quote is tested before the open quote, as GNU m4 does, so equal delimiters
# never nest. An unterminated scan ends at `len` with the remaining depth.
pure scan_quoted(text: Str, pos: Int, len: Int, lq: Str, rq: Str, depth: Int) -> QuoteScan {
  let lql = lq.byte_len()
  let rql = rq.byte_len()
  var p = pos
  var d = depth
  var next_l = text.find(lq, p) ?? -1

  while true {
    let next_r = text.find(rq, p) ?? -1

    if next_r < 0 {
      while next_l >= 0 {
        d += 1
        next_l = text.find(lq, next_l + lql) ?? -1
      }

      return {end: len, depth: d}
    }

    if next_l >= 0 and next_l < next_r {
      d += 1
      p = next_l + lql
      next_l = text.find(lq, p) ?? -1
    } else {
      d -= 1
      p = next_r + rql

      if d == 0 {
        return {end: p, depth: 0}
      }

      if next_l >= 0 and next_l < p {
        next_l = text.find(lq, p) ?? -1
      }
    }
  }

  {end: len, depth: d}
}

# The input line at byte `pos`. Like GNU m4, a newline only starts the next
# line once a character after it has been read, so a newline at `pos - 1`
# still belongs to the line it ends.
pure count_lines(text: Str, pos: Int) -> Int {
  var line = 1
  var p = 0

  while true {
    let nl = text.find("\n", p) ?? -1

    if nl < 0 or nl >= pos - 1 {
      return line
    }

    line += 1
    p = nl + 1
  }

  line
}

# ── numbers ──────────────────────────────────────────────────────────────────
pure wrap32(v: Int) -> Int {
  var r = v % int32_span

  if r < 0 {
    r += int32_span
  }

  if r >= 2147483648 { r - int32_span } else { r }
}

pure to_u32(v: Int) -> Int {
  if v < 0 { v + int32_span } else { v }
}

# strtol over the whole argument, as GNU m4's numeric arguments are read.
pure parse_c_long(text: Str) -> NumArg {
  let n = text.byte_len()
  var i = 0

  while i < n and is_space(text.byte_at(i) ?? 0) {
    i += 1
  }

  let leading = i > 0
  var negative = false
  let sign = text.byte_at(i) ?? 0

  if sign == 45 or sign == 43 {
    negative = sign == 45
    i += 1
  }

  let digits_start = i
  var value = 0

  while i < n {
    let b = text.byte_at(i) ?? 0

    if b < 48 or b > 57 {
      return {ok: false, value: 0, note: ""}
    }

    if value < 1000000000000000 {
      value = value * 10 + (b - 48)
    }

    i += 1
  }

  if i == digits_start {
    return {ok: false, value: 0, note: ""}
  }

  {ok: true, value: if negative { -value } else { value }, note: if leading { "leading" } else { "" }}
}

# A numeric builtin argument: empty is 0 with a warning, trailing junk fails.
pure numeric_arg(text: Str, builtin_name: Str) -> NumArg {
  if text == "" {
    return {ok: true, value: 0, note: f"empty string treated as 0 in builtin `{builtin_name}'"}
  }

  let parsed = parse_c_long(text)

  if ! parsed.ok {
    return {ok: false, value: 0, note: f"non-numeric argument to builtin `{builtin_name}'"}
  }

  if parsed.note == "leading" {
    return {ok: true, value: parsed.value, note: f"leading whitespace ignored in builtin `{builtin_name}'"}
  }

  {ok: true, value: parsed.value, note: ""}
}

pure digit_char(d: Int) -> Str {
  "0123456789abcdefghijklmnopqrstuvwxyz".byte_slice(d, 1)
}

pure repeat_text(unit: Str, count: Int) -> Str {
  var parts: List[Str] = []
  var i = 0

  while i < count {
    parts += [unit]
    i += 1
  }

  parts.join("")
}

pure format_radix(value: Int, radix: Int, width: Int) -> Str {
  let negative = value < 0
  var magnitude = if negative { -value } else { value }
  var digits = ""

  if radix == 1 {
    digits = repeat_text("1", magnitude)
  } else if magnitude == 0 {
    digits = "0"
  } else {
    var rev: List[Str] = []

    while magnitude > 0 {
      rev += [digit_char(magnitude % radix)]
      magnitude = magnitude / radix
    }

    var i = rev.len() - 1

    while i >= 0 {
      digits = f"{digits}{rev[i]}"
      i -= 1
    }
  }

  let pad = width - digits.byte_len()
  let padded = if pad > 0 { f"{repeat_text("0", pad)}{digits}" } else { digits }

  if negative { f"-{padded}" } else { padded }
}

# ── eval ─────────────────────────────────────────────────────────────────────
# Tokens are operator spellings or "#" followed by a decimal value; an
# unknown character ends the list with "!bad". Lexing
# follows GNU m4 1.4: 0x/0b/0r prefixes, octal after a leading zero, and a
# number ends at the first character that is not a digit of its base.
pure eval_tokens(expr: Str) -> List[Str] {
  var tokens: List[Str] = []
  let n = expr.byte_len()
  var i = 0

  while i < n {
    let b = expr.byte_at(i) ?? 0

    if is_space(b) {
      i += 1
      continue
    }

    if b >= 48 and b <= 57 {
      var base = 10

      if b == 48 {
        i += 1
        let c = expr.byte_at(i) ?? 0

        if c == 120 or c == 88 {
          base = 16
          i += 1
        } else if c == 98 or c == 66 {
          base = 2
          i += 1
        } else if c == 114 or c == 82 {
          i += 1
          base = 0

          while i < n and (expr.byte_at(i) ?? 0) >= 48 and (expr.byte_at(i) ?? 0) <= 57 and base <= 36 {
            base = base * 10 + ((expr.byte_at(i) ?? 0) - 48)
            i += 1
          }

          if base == 0 or base > 36 or (expr.byte_at(i) ?? 0) != 58 {
            tokens += ["!bad"]
            return tokens
          }

          i += 1
        } else {
          base = 8
        }
      }

      var value = 0

      while i < n {
        let c = expr.byte_at(i) ?? 0
        var digit = -1

        if c >= 48 and c <= 57 {
          digit = c - 48
        } else if c >= 97 and c <= 122 {
          digit = c - 97 + 10
        } else if c >= 65 and c <= 90 {
          digit = c - 65 + 10
        } else {
          break
        }

        if base == 1 {
          if digit == 1 {
            value = wrap32(value + 1)
          } else if digit == 0 and value == 0 {
            i += 1
            continue
          } else {
            break
          }
        } else if digit >= base {
          break
        } else {
          value = wrap32(value * base + digit)
        }

        i += 1
      }

      tokens += [f"#{value}"]
      continue
    }

    let two = if i + 1 < n { expr.byte_slice(i, 2) } else { "" }

    if two == "**" or two == "<<" or two == ">>" or two == "<=" or two == ">=" or two == "==" or two == "!=" or two == "&&" or two == "||" {
      tokens += [two]
      i += 2
      continue
    }

    let one = expr.byte_slice(i, 1)

    if one == "+" or one == "-" or one == "*" or one == "/" or one == "%" or one == "<" or one == ">" or one == "=" or one == "!" or one == "~" or one == "&" or one == "|" or one == "^" or one == "(" or one == ")" {
      tokens += [one]
      i += 1
      continue
    }

    tokens += ["!bad"]
    return tokens
  }

  tokens
}

pure eval_power(base: Int, exponent: Int) -> Int {
  var result = 1
  var b = base
  var e = exponent

  while e > 0 {
    if e % 2 == 1 {
      result = wrap32(result * b)
    }

    b = wrap32(b * b)
    e = e / 2
  }

  result
}

pure shift_value(value: Int, count: Int, left: Bool) -> Int {
  let k = to_u32(count).bit_and(31)
  var factor = 1
  var j = 0

  while j < k {
    factor = factor * 2
    j += 1
  }

  if left {
    return wrap32(to_u32(value) * factor)
  }

  if value >= 0 { value / factor } else { -((-value - 1) / factor) - 1 }
}

# Binding strength of a binary operator, loosest first; unary operators bind
# tighter than all of them (GNU m4 reads `-2**2` as 4).
pure eval_prec(op: Str) -> Int {
  match op {
    "||" => 1
    "&&" => 2
    "|" => 3
    "^" => 4
    "&" => 5
    "==" | "!=" | "=" => 6
    "<" | "<=" | ">" | ">=" => 7
    "<<" | ">>" => 8
    "+" | "-" => 9
    "*" | "/" | "%" => 10
    "**" => 11
    "u+" | "u-" | "u~" | "u!" => 12
    else => 0
  }
}

# One operator on 32-bit values. `err` marks a value whose evaluation failed;
# it propagates except through the side of `&&`/`||` that is not evaluated,
# which is how GNU m4 lets `0 && 1/0` be 0.
pure eval_apply(op: Str, a: EvalValue, b: EvalValue) -> EvalValue {
  if op == "&&" {
    return a when a.err != ""

    return {v: 0, err: ""} when a.v == 0

    return b when b.err != ""

    return {v: if b.v != 0 { 1 } else { 0 }, err: ""}
  }

  if op == "||" {
    return a when a.err != ""

    return {v: 1, err: ""} when a.v != 0

    return b when b.err != ""

    return {v: if b.v != 0 { 1 } else { 0 }, err: ""}
  }

  return a when a.err != ""

  return b when b.err != ""

  let x = a.v
  let y = b.v

  let v = match op {
    "u+" => y
    "u-" => wrap32(-y)
    "u~" => wrap32(4294967295.clear_bits(to_u32(y)))
    "u!" => if y == 0 { 1 } else { 0 }
    "|" => wrap32(to_u32(x).bit_or(to_u32(y)))
    "^" => wrap32(to_u32(x).bit_or(to_u32(y)).clear_bits(to_u32(x).bit_and(to_u32(y))))
    "&" => wrap32(to_u32(x).bit_and(to_u32(y)))
    "==" | "=" => if x == y { 1 } else { 0 }
    "!=" => if x != y { 1 } else { 0 }
    "<" => if x < y { 1 } else { 0 }
    "<=" => if x <= y { 1 } else { 0 }
    ">" => if x > y { 1 } else { 0 }
    ">=" => if x >= y { 1 } else { 0 }
    "<<" => shift_value(x, y, true)
    ">>" => shift_value(x, y, false)
    "+" => wrap32(x + y)
    "-" => wrap32(x - y)
    "*" => wrap32(x * y)
    else => 0
  }

  if op == "/" or op == "%" {
    if y == 0 {
      return {v: 0, err: if op == "/" { "divide by zero" } else { "modulo by zero" }}
    }

    if y == -1 {
      return {v: if op == "/" { wrap32(-x) } else { 0 }, err: ""}
    }

    return {v: if op == "/" { x / y } else { x % y }, err: ""}
  }

  if op == "**" {
    return {v: 0, err: "negative exponent"} when y < 0

    return {v: 0, err: "divide by zero"} when x == 0 and y == 0

    return {v: eval_power(x, y), err: ""}
  }

  {v, err: ""}
}

# Operator-precedence evaluation of GNU m4's eval grammar. `err` is a syntax
# reason ("bad expression", "bad input", "excess input", "missing right
# parenthesis") or an arithmetic failure.
pure eval_tokens_value(tokens: List[Str]) -> EvalValue {
  var values: List[EvalValue] = []
  var ops: List[Str] = []
  var expect_operand = true
  var i = 0

  while i < tokens.len() {
    let t = tokens[i]
    i += 1

    if expect_operand {
      if t.starts_with("#") {
        values += [{v: t.byte_slice(1, t.byte_len() - 1).parse_int() ?? 0, err: ""}]
        expect_operand = false
      } else if t == "+" or t == "-" or t == "~" or t == "!" {
        ops += [f"u{t}"]
      } else if t == "(" {
        ops += ["("]
      } else {
        return {v: 0, err: if t == "!bad" { "bad input" } else { "bad expression" }}
      }

      continue
    }

    if t == ")" {
      while ops.len() > 0 and ops[ops.len() - 1] != "(" {
        let op = ops[ops.len() - 1]
        ops = ops[0..ops.len() - 1]

        if op.starts_with("u") {
          let y = values[values.len() - 1]
          values = values[0..values.len() - 1] + [eval_apply(op, {v: 0, err: ""}, y)]
        } else {
          let y = values[values.len() - 1]
          let x = values[values.len() - 2]
          values = values[0..values.len() - 2] + [eval_apply(op, x, y)]
        }
      }

      return {v: 0, err: "excess input"} when ops.len() == 0

      ops = ops[0..ops.len() - 1]
      continue
    }

    let p = eval_prec(t)

    if p == 0 or t == "!" or t == "~" {
      return {v: 0, err: "excess input"}
    }

    while ops.len() > 0 {
      let top = ops[ops.len() - 1]

      if top == "(" {
        break
      }

      let tp = eval_prec(top)

      if tp < p or (tp == p and t == "**") {
        break
      }

      ops = ops[0..ops.len() - 1]

      if top.starts_with("u") {
        let y = values[values.len() - 1]
        values = values[0..values.len() - 1] + [eval_apply(top, {v: 0, err: ""}, y)]
      } else {
        let y = values[values.len() - 1]
        let x = values[values.len() - 2]
        values = values[0..values.len() - 2] + [eval_apply(top, x, y)]
      }
    }

    ops += [t]
    expect_operand = true
  }

  return {v: 0, err: "bad expression"} when expect_operand

  while ops.len() > 0 {
    let op = ops[ops.len() - 1]
    ops = ops[0..ops.len() - 1]

    return {v: 0, err: "missing right parenthesis"} when op == "("

    if op.starts_with("u") {
      let y = values[values.len() - 1]
      values = values[0..values.len() - 1] + [eval_apply(op, {v: 0, err: ""}, y)]
    } else {
      let y = values[values.len() - 1]
      let x = values[values.len() - 2]
      values = values[0..values.len() - 2] + [eval_apply(op, x, y)]
    }
  }

  values[0]
}

pure eval_text(expr: Str, radix: Int, width: Int) -> BuiltinOutput {
  var notes: List[Str] = []

  if expr == "" {
    notes += ["empty string treated as 0 in builtin `eval'"]
    return {text: format_radix(0, radix, width), notes}
  }

  let tokens = eval_tokens(expr)

  if "=" in tokens {
    notes += ["Warning: recommend ==, not =, for equality operator"]
  }

  let result = eval_tokens_value(tokens)

  if result.err == "bad expression" {
    return {text: "", notes: notes.push(f"bad expression in eval: {expr}")}
  }

  if result.err == "bad input" or result.err == "excess input" or result.err == "missing right parenthesis" {
    return {text: "", notes: notes.push(f"bad expression in eval ({result.err}): {expr}")}
  }

  if result.err != "" {
    return {text: "", notes: notes.push(f"{result.err} in eval: {expr}")}
  }

  {text: format_radix(result.v, radix, width), notes}
}

# ── translit, format, and regular expressions ────────────────────────────────
pure text_chars(text: Str) -> List[Str] {
  [c for c in text]
}

# GNU m4's expand_ranges: `a-z` expands inclusively in either direction; a
# leading or trailing dash is literal.
pure expand_ranges(spec: Str) -> List[Str] {
  let chars = text_chars(spec)
  var out: List[Str] = []
  var i = 0
  var prev = ""

  while i < chars.len() {
    let c = chars[i]

    if c == "-" and prev != "" {
      if i + 1 >= chars.len() {
        out += ["-"]
        return out
      }

      let to = chars[i + 1]
      let from_code = prev.byte_at(0) ?? 0
      let to_code = to.byte_at(0) ?? 0

      if prev.byte_len() == 1 and to.byte_len() == 1 {

        if from_code <= to_code {
          var k = from_code + 1

          while k <= to_code {
            out += [ascii_table.byte_slice(k, 1)]
            k += 1
          }
        } else {
          var k = from_code - 1

          while k >= to_code {
            out += [ascii_table.byte_slice(k, 1)]
            k -= 1
          }
        }
      } else {
        out += ["-", to]
      }

      prev = to
      i += 2
      continue
    }

    out += [c]
    prev = c
    i += 1
  }

  out
}

pure translit_text(text: Str, from_spec: Str, to_spec: Str) -> Str {
  let from = if "-" in from_spec { expand_ranges(from_spec) } else { text_chars(from_spec) }
  let to = if "-" in to_spec { expand_ranges(to_spec) } else { text_chars(to_spec) }
  var mapping: Map[Str] = {}
  var j = 0

  for c in from {
    if ! (c in mapping) {
      mapping[c] = if j < to.len() { to[j] } else { "" }
    }

    if j < to.len() {
      j += 1
    }
  }

  var out: List[Str] = []

  for c in text {
    out += [mapping.get(c) ?? c]
  }

  out.join("")
}

pure pad_field(body: Str, width: Int, left: Bool, zero: Bool) -> Str {
  let missing = width - body.byte_len()

  return body when missing <= 0

  if left {
    return f"{body}{repeat_text(" ", missing)}"
  }

  if zero {
    let first = body.byte_at(0) ?? 0

    if first == 45 or first == 43 or first == 32 {
      return f"{body.byte_slice(0, 1)}{repeat_text("0", missing)}{body.byte_slice(1, body.byte_len() - 1)}"
    }

    if body.starts_with("0x") or body.starts_with("0X") {
      return f"{body.byte_slice(0, 2)}{repeat_text("0", missing)}{body.byte_slice(2, body.byte_len() - 2)}"
    }

    return f"{repeat_text("0", missing)}{body}"
  }

  f"{repeat_text(" ", missing)}{body}"
}

pure format_arg(args: List[Str], i: Int) -> Str {
  if i < args.len() { args[i] } else { "" }
}

pure format_int_arg(text: Str) -> NumArg {
  return {ok: true, value: 0, note: ""} when text == ""

  let parsed = parse_c_long(text)

  if ! parsed.ok {
    return {ok: false, value: 0, note: f"non-numeric argument {text}"}
  }

  {ok: true, value: wrap32(parsed.value), note: ""}
}

# GNU m4's format: printf directives with flags, `*` widths and precisions,
# integer, character, and string conversions.
pure format_text(args: List[Str]) -> Result[BuiltinOutput] {
  let fmt = format_arg(args, 0)
  let n = fmt.byte_len()
  var out: List[Str] = []
  var notes: List[Str] = []
  var ai = 1
  var p = 0

  while p < n {
    let pct = fmt.find("%", p) ?? -1

    if pct < 0 {
      out += [fmt.byte_slice(p, n - p)]
      break
    }

    if pct > p {
      out += [fmt.byte_slice(p, pct - p)]
    }

    var i = pct + 1

    if (fmt.byte_at(i) ?? 0) == 37 {
      out += ["%"]
      p = i + 1
      continue
    }

    var left = false
    var plus = false
    var space = false
    var alt = false
    var zero = false

    while i < n {
      let f = fmt.byte_at(i) ?? 0

      if f == 45 {
        left = true
      } else if f == 43 {
        plus = true
      } else if f == 32 {
        space = true
      } else if f == 35 {
        alt = true
      } else if f == 48 {
        zero = true
      } else if f == 39 {
        let _ = f
      } else {
        break
      }

      i += 1
    }

    var width = 0

    if (fmt.byte_at(i) ?? 0) == 42 {
      let w = format_int_arg(format_arg(args, ai))
      notes = if w.note != "" { notes.push(w.note) } else { notes }
      ai += 1
      width = w.value

      if width < 0 {
        left = true
        width = -width
      }

      i += 1
    } else {
      while (fmt.byte_at(i) ?? 0) >= 48 and (fmt.byte_at(i) ?? 0) <= 57 {
        width = width * 10 + ((fmt.byte_at(i) ?? 0) - 48)
        i += 1
      }
    }

    var precision = -1

    if (fmt.byte_at(i) ?? 0) == 46 {
      i += 1
      precision = 0

      if (fmt.byte_at(i) ?? 0) == 42 {
        let pr = format_int_arg(format_arg(args, ai))
        notes = if pr.note != "" { notes.push(pr.note) } else { notes }
        ai += 1
        precision = pr.value
        i += 1
      } else {
        while (fmt.byte_at(i) ?? 0) >= 48 and (fmt.byte_at(i) ?? 0) <= 57 {
          precision = precision * 10 + ((fmt.byte_at(i) ?? 0) - 48)
          i += 1
        }
      }
    }

    while (fmt.byte_at(i) ?? 0) == 108 or (fmt.byte_at(i) ?? 0) == 104 {
      i += 1
    }

    let conv = fmt.byte_at(i) ?? 0
    let spec = fmt.byte_slice(pct, if i < n { i + 1 - pct } else { n - pct })
    p = i + 1

    if conv == 115 {
      var s = format_arg(args, ai)
      ai += 1

      if precision >= 0 and precision < s.byte_len() {
        s = s.byte_slice(0, precision)
      }

      out += [pad_field(s, width, left, false)]
    } else if conv == 99 {
      let c = format_int_arg(format_arg(args, ai))
      notes = if c.note != "" { notes.push(c.note) } else { notes }
      ai += 1
      let code = to_u32(c.value).bit_and(255)

      let glyph = if code >= 128 { latin1_table.byte_slice((code - 128) * 2, 2) } else { ascii_table.byte_slice(code, 1) }
      out += [pad_field(glyph, width, left, false)]
    } else if conv == 100 or conv == 105 or conv == 117 or conv == 111 or conv == 120 or conv == 88 {
      let a = format_int_arg(format_arg(args, ai))
      notes = if a.note != "" { notes.push(a.note) } else { notes }
      ai += 1
      let signed = conv == 100 or conv == 105
      let value = if signed { a.value } else { to_u32(a.value) }
      let radix = if conv == 111 { 8 } else if conv == 120 or conv == 88 { 16 } else { 10 }
      var digits = format_radix(if value < 0 { -value } else { value }, radix, if precision >= 0 { precision } else { 1 })

      if precision == 0 and value == 0 {
        digits = ""
      }

      if conv == 88 {
        digits = digits.upper()
      }

      if alt and conv == 111 and ! digits.starts_with("0") {
        digits = f"0{digits}"
      }

      if alt and (conv == 120 or conv == 88) and value != 0 {
        digits = if conv == 120 { f"0x{digits}" } else { f"0X{digits}" }
      }

      let sign = if value < 0 { "-" } else if signed and plus { "+" } else if signed and space { " " } else { "" }
      out += [pad_field(f"{sign}{digits}", width, left, zero and precision < 0)]
    } else if conv == 101 or conv == 69 or conv == 102 or conv == 70 or conv == 103 or conv == 71 or conv == 97 or conv == 65 {
      return Err(ScriptError.Failed(kind: "m4-format", message: f"format: floating-point conversion `{spec}' is not supported"))
    } else {
      notes += [f"Warning: unrecognized specifier in `{fmt}'"]
      return {text: out.join(""), notes}
    }
  }

  {text: out.join(""), notes}
}

pure regex_literal(c: Str) -> Str {
  let b = c.byte_at(0) ?? 0

  if c.byte_len() > 1 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) {
    return c
  }

  let hex = "0123456789abcdef"
  f"\\x{{{hex.byte_slice(b / 16, 1)}{hex.byte_slice(b % 16, 1)}}}"
}

pure utf8_width(b: Int) -> Int {
  if b >= 240 { 4 } else if b >= 224 { 3 } else if b >= 192 { 2 } else { 1 }
}

# Translate a GNU m4 (Emacs-syntax GNU regex) pattern: `\(`, `\)`, `\|` are
# operators and their plain forms literal; `*`, `+`, `?` are literal at the
# start of a pattern or group; `^`/`$` anchor only at pattern or group edges
# and match at line breaks; backslash is literal inside brackets; there are
# no intervals and no character classes. `error` is a GNU compile error
# (reported as a warning); unsupported constructs fail as `unsupported: ...`.
pure gnu_regex_to_rust(pat: Str) -> RegexTranslation {
  var out: List[Str] = ["(?m)"]
  let n = pat.byte_len()
  var i = 0
  var at_start = true
  var last_atom = -1
  var last_was_repeat = false
  var group_starts: List[Int] = []
  var groups = 0

  while i < n {
    let c = pat.byte_at(i) ?? 0

    if c == 92 {
      if i + 1 >= n {
        return {pattern: "", error: "Trailing backslash", groups}
      }

      let d = pat.byte_at(i + 1) ?? 0
      i += 2

      if d == 40 {
        group_starts += [out.len()]
        out += ["("]
        groups += 1
        at_start = true
        last_atom = -1
        last_was_repeat = false
        continue
      }

      if d == 41 {
        if group_starts.len() == 0 {
          return {pattern: "", error: "Unmatched ) or \\)", groups}
        }

        last_atom = group_starts[group_starts.len() - 1]
        group_starts = group_starts[0..group_starts.len() - 1]
        out += [")"]
        at_start = false
        last_was_repeat = false
        continue
      }

      if d == 124 {
        out += ["|"]
        at_start = true
        last_atom = -1
        last_was_repeat = false
        continue
      }

      if d >= 49 and d <= 57 {
        return {pattern: "", error: f"unsupported: back-reference \\{pat.byte_slice(i - 1, 1)} is not supported in regular expression `{pat}'", groups}
      }

      let piece = match d {
        119 => "[0-9A-Za-z_]"
        87 => "[^0-9A-Za-z_]"
        115 => "[ \\t\\n\\r\\x{0b}\\x{0c}]"
        83 => "[^ \\t\\n\\r\\x{0b}\\x{0c}]"
        98 => "(?-u:\\b)"
        66 => "(?-u:\\B)"
        60 => r"(?-u:\b{start})"
        62 => r"(?-u:\b{end})"
        96 => "\\A"
        39 => "\\z"
        else => ""
      }

      if piece != "" {
        last_atom = out.len()
        out += [piece]
      } else {
        let w = utf8_width(d)
        last_atom = out.len()
        out += [regex_literal(pat.byte_slice(i - 1, w))]
        i += w - 1
      }

      at_start = false
      last_was_repeat = false
      continue
    }

    if c == 91 {
      var j = i + 1
      var negate = false

      if (pat.byte_at(j) ?? 0) == 94 {
        negate = true
        j += 1
      }

      var items: List[Str] = []
      var first = true
      var closed = false

      while j < n {
        let b = pat.byte_at(j) ?? 0

        if b == 93 and ! first {
          closed = true
          j += 1
          break
        }

        let w = utf8_width(b)
        let item = pat.byte_slice(j, w)
        j += w
        first = false

        if (pat.byte_at(j) ?? 0) == 45 and j + 1 < n and (pat.byte_at(j + 1) ?? 0) != 93 {
          let w2 = utf8_width(pat.byte_at(j + 1) ?? 0)
          let upper = pat.byte_slice(j + 1, w2)
          j += 1 + w2
          items += [f"{regex_literal(item)}-{regex_literal(upper)}"]
        } else {
          items += [regex_literal(item)]
        }
      }

      if ! closed {
        return {pattern: "", error: "Unmatched [, [^, [:, [., or [=", groups}
      }

      last_atom = out.len()
      out += [f"[{if negate { "^" } else { "" }}{items.join("")}]"]
      i = j
      at_start = false
      last_was_repeat = false
      continue
    }

    if c == 94 {
      if at_start {
        out += ["^"]
        last_atom = -1
      } else {
        last_atom = out.len()
        out += ["\\^"]
        at_start = false
      }

      i += 1
      last_was_repeat = false
      continue
    }

    if c == 36 {
      let at_end = i + 1 == n or match_at(pat, i + 1, "\\)") or match_at(pat, i + 1, "\\|")

      if at_end {
        out += ["$"]
        last_atom = -1
      } else {
        last_atom = out.len()
        out += ["\\$"]
      }

      i += 1
      at_start = false
      last_was_repeat = false
      continue
    }

    if c == 42 or c == 43 or c == 63 {
      if at_start or last_atom < 0 {
        last_atom = out.len()
        out += [regex_literal(pat.byte_slice(i, 1))]
        at_start = false
        last_was_repeat = false
        i += 1
        continue
      }

      # GNU applies a second repetition to the repeated atom (`a*?` is
      # `(a*)?`); Rust would read it as a lazy modifier.
      if last_was_repeat {
        out = out[0..last_atom] + ["(?:"] + out[last_atom..] + [")"]
      }

      out += [pat.byte_slice(i, 1)]
      last_was_repeat = true
      i += 1
      continue
    }

    let w = utf8_width(c)
    last_atom = out.len()
    out += [if c == 46 { "." } else { regex_literal(pat.byte_slice(i, w)) }]
    i += w
    at_start = false
    last_was_repeat = false
  }

  if group_starts.len() > 0 {
    return {pattern: "", error: "Unmatched ( or \\(", groups}
  }

  {pattern: out.join(""), error: "", groups}
}

pure substitute_captures(repl: Str, captures: List[Str]) -> BuiltinOutput {
  var out: List[Str] = []
  var notes: List[Str] = []
  let n = repl.byte_len()
  var p = 0

  while p < n {
    let bs = repl.find("\\", p) ?? -1
    let stop = if bs < 0 { n } else { bs }

    if stop > p {
      out += [repl.byte_slice(p, stop - p)]
    }

    if bs < 0 {
      break
    }

    if bs + 1 >= n {
      notes += ["Warning: trailing \\ ignored in replacement"]
      break
    }

    let d = repl.byte_at(bs + 1) ?? 0

    if d == 38 or d == 48 {
      if d == 48 {
        notes += ["Warning: \\0 will disappear, use \\& instead in replacements"]
      }

      out += [captures[0]]
      p = bs + 2
    } else if d >= 49 and d <= 57 {
      let g = d - 48

      if g < captures.len() {
        out += [captures[g]]
      } else {
        notes += [f"Warning: sub-expression {g} not present"]
      }

      p = bs + 2
    } else {
      let w = utf8_width(d)
      out += [repl.byte_slice(bs + 1, w)]
      p = bs + 1 + w
    }
  }

  {text: out.join(""), notes}
}

pure compile_gnu_regex(pat: Str) -> Result[RegexTranslation] {
  let tr = gnu_regex_to_rust(pat)

  if tr.error.starts_with("unsupported: ") {
    return Err(ScriptError.Failed(kind: "m4-regex", message: tr.error.byte_slice(13, tr.error.byte_len() - 13)))
  }

  tr
}

# Width of the UTF-8 character that ends at byte offset `e`.
pure char_width_before(text: Str, e: Int) -> Int {
  var w = 1

  while e - w > 0 and (text.byte_at(e - w) ?? 0) >= 128 and (text.byte_at(e - w) ?? 0) < 192 {
    w += 1
  }

  w
}

# Captures of the match the pattern makes at byte `s`, ending at or before
# `e`, seen with one character of context on each side: `at_start` is the
# pattern anchored at the text start, `at_offset` the pattern behind one
# consumed character, so anchors and word boundaries see their real
# neighbours. The first capture is the match itself.
pure captures_at(text: Str, s: Int, e: Int, at_start: Regex, at_offset: Regex) -> List[Str] {
  let n = text.byte_len()
  let tail = if e < n { utf8_width(text.byte_at(e) ?? 0) } else { 0 }

  if s == 0 {
    return at_start.captures(text.byte_slice(0, e + tail))
  }

  let pw = char_width_before(text, s)
  let caps = at_offset.captures(text.byte_slice(s - pw, e + tail - s + pw))

  return [] when caps.len() == 0

  [caps[0].byte_slice(pw, caps[0].byte_len() - pw)] + caps[1..]
}

# GNU m4's patsubst loop: search from the end of each match, and after an
# empty match copy one character and search on. The Rust iterator finds the
# same matches except that it skips an empty match right where a non-empty
# one ended, so those positions are probed and added back.
pure patsubst_text(text: Str, pat: Str, repl: Str) -> Result[BuiltinOutput] {
  let tr = compile_gnu_regex(pat)?

  if tr.error != "" {
    return {text: "", notes: [f"bad regular expression: `{pat}': {tr.error}"]}
  }

  let re = regex.compile(tr.pattern)?
  let found = re.find(text)

  return {text, notes: []} when found.len() == 0

  let body = tr.pattern.byte_slice(4, tr.pattern.byte_len() - 4)
  let at_start = regex.compile(f"(?m)\\A(?:{body})")?
  let at_offset = regex.compile(f"(?m)\\A(?s:.)(?:{body})")?
  let literal = repl.find("\\") == null
  let n = text.byte_len()
  var spans: List[Int] = []

  for i, m in found {
    spans += [m.start, m.end]

    if m.end > m.start and (i + 1 == found.len() or found[i + 1].start != m.end) {
      let probe = captures_at(text, m.end, m.end, at_start, at_offset)

      if probe.len() > 0 and probe[0] == "" {
        spans += [m.end, m.end]
      }
    }
  }

  var out: List[Str] = []
  var notes: List[Str] = []
  var offset = 0
  var k = 0

  while k < spans.len() {
    let s = spans[k]
    let e = spans[k + 1]

    if s > offset {
      out += [text.byte_slice(offset, s - offset)]
    }

    if literal {
      out += [repl]
    } else {
      let caps = captures_at(text, s, e, at_start, at_offset)
      let sub = substitute_captures(repl, if caps.len() > 0 { caps } else { [text.byte_slice(s, e - s)] })
      out += [sub.text]
      notes += sub.notes
    }

    offset = e

    if s == e and offset < n {
      let w = utf8_width(text.byte_at(offset) ?? 0)
      out += [text.byte_slice(offset, w)]
      offset += w
    }

    k += 2
  }

  if offset < n {
    out += [text.byte_slice(offset, n - offset)]
  }

  {text: out.join(""), notes}
}

pure regexp_text(text: Str, pat: Str, repl: Str, has_repl: Bool) -> Result[BuiltinOutput] {
  let tr = compile_gnu_regex(pat)?

  if tr.error != "" {
    return {text: "", notes: [f"bad regular expression: `{pat}': {tr.error}"]}
  }

  let re = regex.compile(tr.pattern)?

  if ! has_repl {
    let found = re.find(text)
    return {text: if found.len() == 0 { "-1" } else { f"{found[0].start}" }, notes: []}
  }

  let caps = re.captures(text)

  return {text: "", notes: []} when caps.len() == 0

  substitute_captures(repl, caps)
}

# ── macro bodies and builtins ────────────────────────────────────────────────
pure quote_args(args: List[Str], from: Int, lq: Str, rq: Str, quoted: Bool) -> Str {
  var out: List[Str] = []
  var i = from

  while i < args.len() {
    out += [if quoted { f"{lq}{args[i]}{rq}" } else { args[i] }]
    i += 1
  }

  out.join(",")
}

# Substitute `$0`..`$N` (multi-digit), `$#`, `$*`, and `$@` in a user macro.
pure expand_user_body(body: Str, name: Str, args: List[Str], lq: Str, rq: Str) -> Str {
  var out: List[Str] = []
  let n = body.byte_len()
  var p = 0

  while p < n {
    let d = body.find("$", p) ?? -1

    if d < 0 {
      out += [body.byte_slice(p, n - p)]
      break
    }

    if d > p {
      out += [body.byte_slice(p, d - p)]
    }

    let c = body.byte_at(d + 1) ?? -1

    if c >= 48 and c <= 57 {
      var q = d + 1
      var index = 0

      while q < n and (body.byte_at(q) ?? 0) >= 48 and (body.byte_at(q) ?? 0) <= 57 {
        if index < 100000000 {
          index = index * 10 + ((body.byte_at(q) ?? 0) - 48)
        }

        q += 1
      }

      if index == 0 {
        out += [name]
      } else if index <= args.len() {
        out += [args[index - 1]]
      }

      p = q
    } else if c == 35 {
      out += [f"{args.len()}"]
      p = d + 2
    } else if c == 42 or c == 64 {
      out += [quote_args(args, 0, lq, rq, c == 64)]
      p = d + 2
    } else {
      out += ["$"]
      p = d + 1
    }
  }

  out.join("")
}

pure builtin_names() -> List[Str] {
  [
    "__file__",
    "__line__",
    "__program__",
    "builtin",
    "changecom",
    "changequote",
    "debugfile",
    "debugmode",
    "decr",
    "define",
    "defn",
    "divert",
    "divnum",
    "dnl",
    "dumpdef",
    "errprint",
    "esyscmd",
    "eval",
    "format",
    "ifdef",
    "ifelse",
    "include",
    "incr",
    "index",
    "indir",
    "len",
    "m4exit",
    "m4wrap",
    "maketemp",
    "mkstemp",
    "patsubst",
    "popdef",
    "pushdef",
    "regexp",
    "shift",
    "sinclude",
    "substr",
    "syscmd",
    "sysval",
    "traceoff",
    "traceon",
    "translit",
    "undefine",
    "undivert",
  ]
}

# Builtins that are recognized only when called with parentheses.
pure builtin_blind(name: Str) -> Bool {
  match name {
    "builtin" | "decr" | "define" | "defn" | "errprint" | "esyscmd" | "eval" | "format" | "ifdef" | "ifelse" | "include" | "incr" | "index" | "indir" | "len" | "m4wrap" | "maketemp" | "mkstemp" | "patsubst" | "popdef" | "pushdef" | "regexp" | "shift" | "sinclude" | "substr" | "syscmd" | "translit" | "undefine" => true
    else => false
  }
}

pure argc_notes(name: Str, argc: Int, min: Int, max: Int) -> List[Str] {
  if argc < min {
    return [f"Warning: too few arguments to builtin `{name}'"]
  }

  if max >= 0 and argc > max {
    return [f"Warning: excess arguments to builtin `{name}' ignored"]
  }

  []
}

pure arg_at(args: List[Str], i: Int) -> Str {
  if i < args.len() { args[i] } else { "" }
}

# Builtins whose result depends only on their arguments and the quotes. The
# result is pushed back as input and rescanned, as GNU m4 does.
pure call_builtin(name: Str, args: List[Str], lq: Str, rq: Str) -> Result[BuiltinOutput] {
  let argc = args.len() + 1

  if name == "ifelse" {
    return {text: "", notes: []} when argc == 2

    if argc < 4 {
      return {text: "", notes: argc_notes(name, argc, 4, -1)}
    }

    let notes = if (argc + 2) % 3 > 1 { [f"Warning: excess arguments to builtin `{name}' ignored"] } else { [] }
    var i = 0

    while true {
      return {text: args[i + 2], notes} when args[i] == args[i + 1]

      let left = args.len() - i

      return {text: "", notes} when left == 3

      return {text: args[i + 3], notes} when left == 4 or left == 5

      i += 3
    }
  }

  if name == "shift" {
    return {text: quote_args(args, 1, lq, rq, true), notes: argc_notes(name, argc, 2, -1)}
  }

  if name == "len" {
    return {text: f"{arg_at(args, 0).byte_len()}", notes: argc_notes(name, argc, 2, 2)}
  }

  if name == "index" {
    if argc < 3 {
      return {text: if argc == 2 { "0" } else { "" }, notes: argc_notes(name, argc, 3, 3)}
    }

    let found = args[0].find(args[1]) ?? -1
    return {text: f"{found}", notes: argc_notes(name, argc, 3, 3)}
  }

  if name == "substr" {
    if argc < 3 {
      return {text: arg_at(args, 0), notes: argc_notes(name, argc, 3, 4)}
    }

    let text = args[0]
    let avail = text.byte_len()
    let start = numeric_arg(args[1], name)

    if ! start.ok {
      return {text: "", notes: [start.note]}
    }

    var length = avail - start.value
    var notes = if start.note != "" { [start.note] } else { [] }

    if argc >= 4 {
      let given = numeric_arg(args[2], name)

      if ! given.ok {
        return {text: "", notes: notes.push(given.note)}
      }

      notes = if given.note != "" { notes.push(given.note) } else { notes }
      length = given.value
    }

    if start.value < 0 or length <= 0 or start.value >= avail {
      return {text: "", notes}
    }

    if length > avail - start.value {
      length = avail - start.value
    }

    return {text: text.byte_slice(start.value, length), notes: notes.extend(argc_notes(name, argc, 3, 4))}
  }

  if name == "translit" {
    if argc < 3 {
      return {text: arg_at(args, 0), notes: argc_notes(name, argc, 3, 4)}
    }

    return {text: translit_text(args[0], args[1], arg_at(args, 2)), notes: argc_notes(name, argc, 3, 4)}
  }

  if name == "patsubst" {
    if argc < 3 {
      return {text: arg_at(args, 0), notes: argc_notes(name, argc, 3, 4)}
    }

    let r = patsubst_text(args[0], args[1], arg_at(args, 2))?
    return {text: r.text, notes: r.notes.extend(argc_notes(name, argc, 3, 4))}
  }

  if name == "regexp" {
    if argc < 3 {
      return {text: if argc == 2 { "0" } else { "" }, notes: argc_notes(name, argc, 3, 4)}
    }

    let r = regexp_text(args[0], args[1], arg_at(args, 2), argc >= 4)?
    return {text: r.text, notes: r.notes.extend(argc_notes(name, argc, 3, 4))}
  }

  if name == "format" {
    return {text: "", notes: argc_notes(name, argc, 2, -1)} when argc < 2

    return format_text(args)
  }

  if name == "eval" {
    return {text: "", notes: argc_notes(name, argc, 2, 4)} when argc < 2

    var radix = 10
    var width = 1

    if argc >= 3 and args[1] != "" {
      let r = numeric_arg(args[1], name)

      if ! r.ok {
        return {text: "", notes: [r.note]}
      }

      radix = r.value
    }

    if radix < 1 or radix > 36 {
      return {text: "", notes: [f"radix {radix} in builtin `eval' out of range"]}
    }

    if argc >= 4 and args[2] != "" {
      let w = numeric_arg(args[2], name)

      if ! w.ok {
        return {text: "", notes: [w.note]}
      }

      width = w.value
    }

    if width < 0 {
      return {text: "", notes: ["negative width to builtin `eval'"]}
    }

    let r = eval_text(args[0], radix, width)
    return {text: r.text, notes: r.notes.extend(argc_notes(name, argc, 2, 4))}
  }

  if name == "incr" or name == "decr" {
    return {text: "", notes: argc_notes(name, argc, 2, 2)} when argc < 2

    let v = numeric_arg(args[0], name)

    if ! v.ok {
      return {text: "", notes: [v.note]}
    }

    let result = wrap32(if name == "incr" { v.value + 1 } else { v.value - 1 })
    let notes = if v.note != "" { [v.note] } else { [] }
    return {text: f"{result}", notes: notes.extend(argc_notes(name, argc, 2, 2))}
  }

  Err(ScriptError.Failed(kind: "m4-internal", message: f"no argument-only builtin named {name}"))
}

pure is_argument_builtin(name: Str) -> Bool {
  match name {
    "ifelse" | "shift" | "len" | "index" | "substr" | "translit" | "patsubst" | "regexp" | "format" | "eval" | "incr" | "decr" => true
    else => false
  }
}

# `cat` here-documents are what bison's `b4_cat` passes to `syscmd`; run
# them without a shell. Returns null for any other command.
pure cat_heredoc(cmd: Str) -> Heredoc? {
  let caps = rx"(?s)^cat(?: >>([^ \t\n<>|&;$`'\x22\\]+))? <<('?)([A-Za-z_][A-Za-z0-9_]*)'?\n(.*)\n([A-Za-z_][A-Za-z0-9_]*)\n?$".captures(cmd)

  return null when caps.len() < 6

  return null when caps[3] != caps[5]

  if caps[2] == "" and ("$" in caps[4] or "`" in caps[4] or "\\" in caps[4]) {
    return null
  }

  {target: caps[1], body: f"{caps[4]}\n"}
}

pure parse_define_arg(def: Str) -> List[Str] {
  let eq = def.find("=") ?? -1

  return [def, ""] when eq < 0

  [def.byte_slice(0, eq), def.byte_slice(eq + 1, def.byte_len() - eq - 1)]
}

pure new_call(name: Str, defn: Str, at_text: Str, at_pos: Int, at_name: Str) -> PendingCall {
  {name, defn, args: [], funcs: [], parts: [], func: "", depth: 0, skip: true, at_text, at_pos, at_name}
}

pure numeric_key_order(keys: List[Str]) -> List[Int] {
  var numbers: List[Int] = []

  for k in keys {
    numbers += [k.parse_int() ?? 0]
  }

  numbers |> sort
}

# ── core expander ────────────────────────────────────────────────────────────
proc include_candidate(name: Str, include_paths: List[Str]) -> Result[Str] {
  let direct = fp"{name}"

  if direct.exists() and direct.is_file() {
    return name
  }

  if ! name.starts_with("/") {
    for dir in include_paths {
      let candidate = fp"{dir}/{name}"

      if candidate.exists() and candidate.is_file() {
        return f"{dir}/{name}"
      }
    }
  }

  ""
}

proc expand_inputs(opts: Options) [fs, process, env, error, io] -> Result[Int] {
  # Macro table: name -> top definition, "t" + text or "b" + builtin name;
  # `stacks` holds the older pushdef'd definitions, bottom first.
  var defs: Map[Str] = {}
  var stacks: Map[List[Str]] = {}

  for b in builtin_names() {
    defs[if opts.prefix { f"m4_{b}" } else { b }] = f"b{b}"
  }

  defs["__gnu__"] = "t"
  defs["__unix__"] = "t"

  for pair in opts.defines {
    if pair.len() == 1 {
      defs = defs.remove(pair[0])
      stacks = stacks.remove(pair[0])
    } else {
      defs[pair[0]] = f"t{pair[1]}"
    }
  }

  var lq = default_lquote
  var rq = default_rquote
  var bc = "#"
  var ec = "\n"

  # Input stack. The current block lives in locals; suspended blocks are in
  # the f_* lists. Kinds: 0 expansion text, 1 file, 2 builtin token (name in
  # `iname`), 3 m4wrap text (file and line where it was registered).
  var text = ""
  var pos = 0
  var tlen = 0
  var kind = 0
  var iname = ""
  var iline = 0
  var f_text: List[Str] = []
  var f_pos: List[Int] = []
  var f_kind: List[Int] = []
  var f_name: List[Str] = []
  var f_line: List[Int] = []
  var nf = 0

  # Pending calls: `cur` is the innermost, `calls[0..nc - 1]` the outer ones.
  let blank = new_call("", "", "", -1, "")
  var calls: List[PendingCall] = []
  var cur = blank
  var nc = 0

  # Output: `sink` collects the current diversion (stdout for 0, discarded
  # when negative); other diversions accumulate in `diversions`.
  var div = 0
  var sink: List[Str] = []
  var diversions: Map[Str] = {}
  var wraps: List[Str] = []
  var wrap_names: List[Str] = []
  var wrap_lines: List[Int] = []
  var sysval = 0
  var status = 0
  var next_input = 0
  var temp_counter = 0

  # First bytes and lengths of the delimiters (-1 and 0 when disabled), kept
  # beside the delimiters for the scanner's per-token tests.
  var lq0 = lq.byte_at(0) ?? -1
  var lql = lq.byte_len()
  var rql = rq.byte_len()
  var bc0 = bc.byte_at(0) ?? -1
  var bcl = bc.byte_len()
  var call_name = ""
  var call_def = ""
  var call_args: List[Str] = []
  var call_funcs: List[Str] = []
  var call_at_text = ""
  var call_at_pos = -1
  var call_at_name = ""
  var eval_memo: Map[Str] = {}
  var warned_backslash_zero = false

  while true {
    # Pull the next block when the current one is exhausted.
    if pos >= tlen {
      if nf > 0 {
        nf -= 1
        text = f_text[nf]
        pos = f_pos[nf]
        kind = f_kind[nf]
        iname = f_name[nf]
        iline = f_line[nf]
        tlen = text.byte_len()
        f_text[nf] = ""
        continue
      }

      if nc > 0 {
        let where = if kind == 1 { f"{iname}:{count_lines(text, pos)}" } else { f"{iname}:{iline}" }
        eprint f"m4:{where}: ERROR: end of file in argument list"

        if div == 0 {
          io.write_stdout(sink.join(""))
        }

        return 1
      }

      if next_input < opts.inputs.len() {
        let spec = opts.inputs[next_input]
        next_input += 1
        text = if spec.stdin { io.stdin_text()? } else { read_input_file(spec.name)? }
        pos = 0
        tlen = text.byte_len()
        kind = 1
        iname = if spec.stdin { "stdin" } else { spec.name }
        iline = 0
        continue
      }

      if wraps.len() > 0 {
        # Wrapped text is read last-registered first, each as its own block.
        var k = 0

        while k < wraps.len() - 1 {
          if nf < f_text.len() {
            f_text[nf] = wraps[k]
            f_pos[nf] = 0
            f_kind[nf] = 3
            f_name[nf] = wrap_names[k]
            f_line[nf] = wrap_lines[k]
          } else {
            f_text += [wraps[k]]
            f_pos += [0]
            f_kind += [3]
            f_name += [wrap_names[k]]
            f_line += [wrap_lines[k]]
          }

          nf += 1
          k += 1
        }

        text = wraps[wraps.len() - 1]
        pos = 0
        tlen = text.byte_len()
        kind = 3
        iname = wrap_names[wraps.len() - 1]
        iline = wrap_lines[wraps.len() - 1]
        wraps = []
        wrap_names = []
        wrap_lines = []
        continue
      }

      break
    }

    # Each token either is emitted (to the innermost pending argument or the
    # current diversion) and loops, or leaves a call in `call_*` to run below.
    if kind == 2 {
      # A builtin token from `defn`: it becomes an argument's definition when
      # it starts that argument, and is dropped anywhere else.
      if nc > 0 {
        if cur.parts.len() == 0 and cur.func == "" {
          cur.func = iname
        }

        cur.skip = false
      }

      pos = tlen
      continue
    }

    let b = text.byte_at(pos) ?? 0

    if b == bc0 and (bcl == 1 or match_at(text, pos, bc)) {
      var pieces: List[Str] = []
      var start = pos
      var p = pos + bcl

      while true {
        let close = text.find(ec, p) ?? -1

        if close >= 0 {
          pieces += [text.byte_slice(start, close + ec.byte_len() - start)]
          pos = close + ec.byte_len()
          break
        }

        pieces += [text.byte_slice(start, tlen - start)]
        pos = tlen

        if nf == 0 {
          eprint f"m4:{iname}: ERROR: end of file in comment"
          return 1
        }

        while pos >= tlen and nf > 0 {
          nf -= 1
          text = f_text[nf]
          pos = f_pos[nf]
          kind = f_kind[nf]
          iname = f_name[nf]
          iline = f_line[nf]
          tlen = text.byte_len()
          f_text[nf] = ""
        }

        start = pos
        p = pos
      }

      let comment = pieces.join("")

      if nc > 0 {
        cur.parts += [comment]
        cur.skip = false
      } else if div >= 0 {
        sink += [comment]

        if div == 0 and sink.len() >= 4096 {
          io.write_stdout(sink.join(""))
          sink = []
        }
      }

      continue
    }

    if (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or b == 95 {
      var end = word_end(text, pos, tlen)
      var word = text.byte_slice(pos, end - pos)
      pos = end

      # A name continues into the following input block, as GNU m4 reads
      # it through the input stack.
      while pos >= tlen and nf > 0 {
        var i = nf - 1
        var next_byte = -1

        while i >= 0 {
          if f_pos[i] < f_text[i].byte_len() {
            next_byte = if f_kind[i] == 2 { -1 } else { f_text[i].byte_at(f_pos[i]) ?? -1 }
            break
          }

          i -= 1
        }

        if ! is_word_char(next_byte) {
          break
        }

        while pos >= tlen and nf > 0 {
          nf -= 1
          text = f_text[nf]
          pos = f_pos[nf]
          kind = f_kind[nf]
          iname = f_name[nf]
          iline = f_line[nf]
          tlen = text.byte_len()
          f_text[nf] = ""
        }

        end = word_end(text, pos, tlen)
        word = f"{word}{text.byte_slice(pos, end - pos)}"
        pos = end
      }

      let d = defs.get(word) ?? ""

      if d == "" {
        if nc > 0 {
          cur.parts += [word]
          cur.skip = false
        } else if div >= 0 {
          sink += [word]

          if div == 0 and sink.len() >= 4096 {
            io.write_stdout(sink.join(""))
            sink = []
          }
        }

        continue
      }

      var peek = -1

      if pos < tlen {
        peek = text.byte_at(pos) ?? -1
      } else {
        var i = nf - 1

        while i >= 0 {
          if f_pos[i] < f_text[i].byte_len() {
            peek = if f_kind[i] == 2 { -1 } else { f_text[i].byte_at(f_pos[i]) ?? -1 }
            break
          }

          i -= 1
        }
      }

      if peek == 40 {
        while pos >= tlen and nf > 0 {
          nf -= 1
          text = f_text[nf]
          pos = f_pos[nf]
          kind = f_kind[nf]
          iname = f_name[nf]
          iline = f_line[nf]
          tlen = text.byte_len()
          f_text[nf] = ""
        }

        pos += 1

        if nc >= nesting_limit {
          eprint f"m4:{iname}: recursion limit of {nesting_limit} exceeded"
          return 1
        }

        if nc > 0 {
          cur.skip = false

          if nc - 1 < calls.len() {
            calls[nc - 1] = cur
          } else {
            calls += [cur]
          }
        }

        cur = if kind == 1 { new_call(word, d, text, pos, iname) } else { new_call(word, d, "", -1, iname) }
        nc += 1
        continue
      }

      if d.byte_at(0) == 98 and builtin_blind(d.byte_slice(1, d.byte_len() - 1)) {
        if nc > 0 {
          cur.parts += [word]
          cur.skip = false
        } else if div >= 0 {
          sink += [word]

          if div == 0 and sink.len() >= 4096 {
            io.write_stdout(sink.join(""))
            sink = []
          }
        }

        continue
      }

      call_name = word
      call_def = d
      call_args = []
      call_funcs = []
      call_at_pos = -1

      if nc > 0 {
        cur.skip = false
      }
    } else if b == lq0 and (lql == 1 or match_at(text, pos, lq)) {
      var pieces: List[Str] = []
      var start = pos + lql
      var depth = 1

      while true {
        let scan = scan_quoted(text, start, tlen, lq, rq, depth)

        if scan.depth == 0 {
          pieces += [text.byte_slice(start, scan.end - rql - start)]
          pos = scan.end
          break
        }

        pieces += [text.byte_slice(start, tlen - start)]
        depth = scan.depth
        pos = tlen

        if nf == 0 {
          eprint f"m4:{iname}: ERROR: end of file in string"
          return 1
        }

        while pos >= tlen and nf > 0 {
          nf -= 1
          text = f_text[nf]
          pos = f_pos[nf]
          kind = f_kind[nf]
          iname = f_name[nf]
          iline = f_line[nf]
          tlen = text.byte_len()
          f_text[nf] = ""
        }

        if kind == 2 {
          pos = tlen
        }

        start = pos
      }

      let quoted = if pieces.len() == 1 { pieces[0] } else { pieces.join("") }

      if nc > 0 {
        cur.parts += [quoted]
        cur.skip = false
      } else if div >= 0 {
        sink += [quoted]

        if div == 0 and sink.len() >= 4096 {
          io.write_stdout(sink.join(""))
          sink = []
        }
      }

      continue
    } else if nc > 0 {
      if cur.skip and (b == 32 or (b >= 9 and b <= 13)) {
        pos = space_end(text, pos + 1, tlen)
        continue
      }

      cur.skip = false

      if b == 40 {
        cur.depth += 1
        cur.parts += ["("]
        pos += 1
        continue
      }

      if b != 41 and b != 44 {
        let end = plain_end(text, pos, tlen, lq0, bc0, true)
        cur.parts += [text.byte_slice(pos, end - pos)]
        pos = end
        continue
      }

      pos += 1

      if cur.depth > 0 {
        cur.parts += [if b == 41 { ")" } else { "," }]

        if b == 41 {
          cur.depth -= 1
        }

        continue
      }

      cur.args += [if cur.func != "" { "" } else if cur.parts.len() == 1 { cur.parts[0] } else { cur.parts.join("") }]
      cur.funcs += [cur.func]
      cur.parts = []
      cur.func = ""

      if b == 44 {
        cur.skip = true
        continue
      }

      call_name = cur.name
      call_def = cur.defn
      call_args = cur.args
      call_funcs = cur.funcs
      call_at_text = cur.at_text
      call_at_pos = cur.at_pos
      call_at_name = cur.at_name
      nc -= 1

      if nc > 0 {
        cur = calls[nc - 1]
        calls[nc - 1] = blank
      } else {
        cur = blank
      }
    } else {
      let end = plain_end(text, pos, tlen, lq0, bc0, false)

      if div >= 0 {
        sink += [text.byte_slice(pos, end - pos)]

        if div == 0 and sink.len() >= 4096 {
          io.write_stdout(sink.join(""))
          sink = []
        }
      }

      pos = end
      continue
    }

    # Run the call. `indir` and `builtin` retarget it and loop.
    var push_text = ""
    var push_macdef = ""
    var notes: List[Str] = []
    var name = call_name
    var defn = call_def
    var args = call_args
    var funcs = call_funcs

    while true {
      if defn.starts_with("t") {
        push_text = expand_user_body(defn.byte_slice(1, defn.byte_len() - 1), name, args, lq, rq)
        break
      }

      let bi = defn.byte_slice(1, defn.byte_len() - 1)
      let argc = args.len() + 1

      if is_argument_builtin(bi) {
        # m4sugar's loops evaluate the same few expressions thousands of
        # times; eval results without diagnostics are remembered.
        let memo_key = if bi == "eval" { args.join("\u{1}") } else { "" }
        let memo = if memo_key != "" { eval_memo.get(memo_key) ?? "\u{0}" } else { "\u{0}" }

        if memo != "\u{0}" {
          push_text = memo
          break
        }

        match call_builtin(bi, args, lq, rq) {
          Ok(r) => {
            push_text = r.text
            notes += r.notes

            if memo_key != "" and r.notes.len() == 0 {
              eval_memo[memo_key] = r.text
            }
          }
          Err(failure) => {
            let where = if kind == 1 { f"{iname}:{count_lines(text, pos)}" } else { f"{iname}:{iline}" }
            eprint f"m4:{where}: {failure.message}"

            if div == 0 {
              io.write_stdout(sink.join(""))
            }

            return 1
          }
        }

        break
      }

      if bi == "indir" or bi == "builtin" {
        if argc < 2 {
          notes += argc_notes(bi, argc, 2, -1)
          break
        }

        let target = args[0]
        let target_def = if bi == "indir" {
          defs.get(target) ?? ""
        } else if target in builtin_names() {
          f"b{target}"
        } else {
          ""
        }

        if target_def == "" {
          notes += [if bi == "indir" { f"undefined macro `{target}'" } else { f"undefined builtin `{target}'" }]
          break
        }

        name = target
        defn = target_def
        args = args[1..]
        funcs = funcs[1..]
        continue
      }

      match bi {
        "define" | "pushdef" => {
          if argc < 2 {
            notes += argc_notes(bi, argc, 2, 3)
          } else {
            let target = args[0]
            let value = if funcs.len() >= 2 and funcs[1] != "" { f"b{funcs[1]}" } else { f"t{arg_at(args, 1)}" }

            if bi == "pushdef" and target in defs {
              stacks[target] = (stacks.get(target) ?? []).push(defs[target])
            }

            defs[target] = value
            notes += argc_notes(bi, argc, 2, 3)
          }
        }
        "undefine" => {
          for target in args {
            defs = defs.remove(target)
            stacks = stacks.remove(target)
          }

          notes += argc_notes(bi, argc, 2, -1)
        }
        "popdef" => {
          for target in args {
            let older = stacks.get(target) ?? []

            if older.len() > 0 {
              defs[target] = older[older.len() - 1]

              if older.len() == 1 {
                stacks = stacks.remove(target)
              } else {
                stacks[target] = older[0..older.len() - 1]
              }
            } else {
              defs = defs.remove(target)
            }
          }

          notes += argc_notes(bi, argc, 2, -1)
        }
        "defn" => {
          var pieces: List[Str] = []

          for target in args {
            let found = defs.get(target) ?? ""

            if found.starts_with("t") {
              pieces += [f"{lq}{found.byte_slice(1, found.byte_len() - 1)}{rq}"]
            } else if found.starts_with("b") {
              if args.len() == 1 {
                push_macdef = found.byte_slice(1, found.byte_len() - 1)
              } else {
                notes += [f"Warning: cannot concatenate builtin `{target}'"]
              }
            }
          }

          push_text = pieces.join("")
          notes += argc_notes(bi, argc, 2, -1)
        }
        "ifdef" => {
          if argc < 3 {
            notes += argc_notes(bi, argc, 3, 4)
          } else {
            push_text = if args[0] in defs { args[1] } else { arg_at(args, 2) }
            notes += argc_notes(bi, argc, 3, 4)
          }
        }
        "dnl" => {
          var done = false

          while ! done {
            if kind != 2 and pos < tlen {
              let nl = text.find("\n", pos) ?? -1

              if nl >= 0 {
                pos = nl + 1
                done = true
                continue
              }
            }

            pos = tlen

            if nf == 0 {
              done = true
            } else {
              nf -= 1
              text = f_text[nf]
              pos = f_pos[nf]
              kind = f_kind[nf]
              iname = f_name[nf]
              iline = f_line[nf]
              tlen = text.byte_len()
              f_text[nf] = ""
            }
          }

          notes += argc_notes(bi, argc, 1, 1)
        }
        "divert" => {
          var target = 0

          if argc >= 2 {
            let n = numeric_arg(args[0], bi)

            if n.note != "" {
              notes += [n.note]
            }

            target = if n.ok { n.value } else { div }
          }

          if target != div {
            if div == 0 {
              io.write_stdout(sink.join(""))
            } else if div > 0 and sink.len() > 0 {
              diversions[f"{div}"] = f"{diversions.get(f"{div}") ?? ""}{sink.join("")}"
            }

            sink = []
            div = target
          }

          notes += argc_notes(bi, argc, 1, 2)
        }
        "undivert" => {
          var targets: List[Str] = []

          if argc == 1 {
            for k in numeric_key_order(diversions.keys()) {
              targets += [f"{k}"]
            }
          } else {
            targets = args
          }

          for t in targets {
            let n = parse_c_long(t)

            if n.ok {
              let key = f"{n.value}"

              if n.value != div and key in diversions {
                if div >= 0 {
                  sink += [diversions[key]]
                }

                diversions = diversions.remove(key)
              }
            } else {
              let found = include_candidate(t, opts.include_paths)?

              if found == "" {
                notes += [f"cannot undivert `{t}': No such file or directory"]
                status = 1
              } else if div >= 0 {
                sink += [read_input_file(found)?]
              }
            }
          }
        }
        "divnum" => {
          push_text = f"{div}"
          notes += argc_notes(bi, argc, 1, 1)
        }
        "changequote" => {
          let open = if argc >= 2 { args[0] } else { default_lquote }
          let close = if argc >= 3 { args[1] } else { default_rquote }

          if open == "" {
            lq = ""
            rq = ""
          } else {
            lq = open
            rq = if close == "" { default_rquote } else { close }
          }

          lq0 = lq.byte_at(0) ?? -1
          lql = lq.byte_len()
          rql = rq.byte_len()

          notes += argc_notes(bi, argc, 1, 3)
        }
        "changecom" => {
          if argc == 1 or args[0] == "" {
            bc = ""
            ec = ""
          } else {
            bc = args[0]
            ec = if argc >= 3 and args[1] != "" { args[1] } else { "\n" }
          }

          bc0 = bc.byte_at(0) ?? -1
          bcl = bc.byte_len()

          notes += argc_notes(bi, argc, 1, 3)
        }
        "include" | "sinclude" => {
          if argc < 2 {
            notes += argc_notes(bi, argc, 2, 2)
          } else {
            let found = include_candidate(args[0], opts.include_paths)?

            if found == "" {
              if bi == "include" {
                notes += [f"cannot open `{args[0]}': No such file or directory"]
                status = 1
              }
            } else {
              let body = read_input_file(found)?

              if pos < tlen or kind == 1 or kind == 3 {
                if nf < f_text.len() {
                  f_text[nf] = text
                  f_pos[nf] = pos
                  f_kind[nf] = kind
                  f_name[nf] = iname
                  f_line[nf] = iline
                } else {
                  f_text += [text]
                  f_pos += [pos]
                  f_kind += [kind]
                  f_name += [iname]
                  f_line += [iline]
                }

                nf += 1
              }

              text = body
              pos = 0
              tlen = body.byte_len()
              kind = 1
              iname = found
              iline = 0
            }

            notes += argc_notes(bi, argc, 2, 2)
          }
        }
        "m4wrap" => {
          if argc < 2 {
            notes += argc_notes(bi, argc, 2, -1)
          } else {
            wraps += [args.join(" ")]
            wrap_names += [iname]
            wrap_lines += [if kind == 1 { count_lines(text, pos) } else { iline }]
          }
        }
        "m4exit" => {
          var code = 0

          if argc >= 2 {
            let n = numeric_arg(args[0], bi)

            if n.note != "" {
              notes += [n.note]
            }

            code = if n.ok { n.value } else { 1 }
          }

          for note in notes {
            let where = if kind == 1 { f"{iname}:{count_lines(text, pos)}" } else { f"{iname}:{iline}" }
            eprint f"m4:{where}: {note}"
          }

          if div == 0 {
            io.write_stdout(sink.join(""))
          }

          return code
        }
        "errprint" => {
          if argc < 2 {
            notes += argc_notes(bi, argc, 2, -1)
          } else {
            let message = args.join(" ")
            eprint (if message.ends_with("\n") { message.byte_slice(0, message.byte_len() - 1) } else { message })
          }
        }
        "dumpdef" => {
          let names = if argc == 1 { defs.keys() } else { args }

          for target in names {
            let found = defs.get(target) ?? ""

            if found.starts_with("t") {
              eprint f"{target}:\t{found.byte_slice(1, found.byte_len() - 1)}"
            } else if found.starts_with("b") {
              eprint f"{target}:\t<{found.byte_slice(1, found.byte_len() - 1)}>"
            } else {
              notes += [f"undefined macro `{target}'"]
            }
          }
        }
        "syscmd" | "esyscmd" => {
          if argc < 2 {
            notes += argc_notes(bi, argc, 2, 2)
          } else {
            let cmd = args[0]
            let heredoc = cat_heredoc(cmd)

            if div == 0 {
              io.write_stdout(sink.join(""))
              sink = []
            }

            if heredoc != null and bi == "syscmd" {
              if heredoc.target == "" {
                io.write_stdout(heredoc.body)
              } else {
                let target = fp"{heredoc.target}"
                let before = if target.exists() { target.read_text()? } else { "" }
                target.write(f"{before}{heredoc.body}")
              }

              sysval = 0
            } else {
              if ! (process.which("sh") is Ok(_)) {
                let where = if kind == 1 { f"{iname}:{count_lines(text, pos)}" } else { f"{iname}:{iline}" }
                eprint f"m4:{where}: {bi}: no /bin/sh to run `{cmd}'"
                return 1
              }

              if bi == "syscmd" {
                let ran = run.status sh -c $cmd
                sysval = ran.exit_code() ?? 127
              } else {
                let ran = run.capture --text sh -c $cmd ?
                push_text = ran.stdout
                sysval = ran.status.exit_code() ?? 127

                if ran.stderr != "" {
                  eprint (if ran.stderr.ends_with("\n") { ran.stderr.byte_slice(0, ran.stderr.byte_len() - 1) } else { ran.stderr })
                }
              }
            }

            notes += argc_notes(bi, argc, 2, 2)
          }
        }
        "sysval" => {
          push_text = f"{sysval}"
        }
        "mkstemp" | "maketemp" => {
          if argc < 2 {
            notes += argc_notes(bi, argc, 2, 2)
          } else {
            var pattern_name = args[0]
            var xs = 0

            while xs < pattern_name.byte_len() and (pattern_name.byte_at(pattern_name.byte_len() - 1 - xs) ?? 0) == 88 {
              xs += 1
            }

            if xs < 6 {
              pattern_name = f"{pattern_name}{repeat_text("X", 6 - xs)}"
              xs = 6
            }

            let stem = pattern_name.byte_slice(0, pattern_name.byte_len() - xs)
            var made = ""

            while made == "" {
              temp_counter += 1
              let suffix = format_radix(process.current_pid()? * 1000 + temp_counter, 36, xs)
              let candidate = f"{stem}{suffix.byte_slice(suffix.byte_len() - xs, xs)}"

              if ! fp"{candidate}".exists() {
                fp"{candidate}".write("")
                made = candidate
              }
            }

            push_text = f"{lq}{made}{rq}"
          }
        }
        "__file__" => {
          var file = iname

          if kind != 1 and kind != 3 {
            var i = nf - 1

            while i >= 0 {
              if f_kind[i] == 1 or f_kind[i] == 3 {
                file = f_name[i]
                break
              }

              i -= 1
            }
          }

          push_text = f"{lq}{file}{rq}"
        }
        "__line__" => {
          var line = 0

          if kind == 1 {
            line = count_lines(text, pos)
          } else if kind == 3 {
            line = iline
          } else {
            var i = nf - 1

            while i >= 0 {
              if f_kind[i] == 1 {
                line = count_lines(f_text[i], f_pos[i])
                break
              }

              if f_kind[i] == 3 {
                line = f_line[i]
                break
              }

              i -= 1
            }
          }

          push_text = f"{line}"
        }
        "__program__" => {
          push_text = f"{lq}m4{rq}"
        }
        "traceon" | "traceoff" | "debugmode" | "debugfile" => {
          let _ = bi
        }
        else => {
          return Err(ScriptError.Failed(kind: "m4-internal", message: f"unhandled builtin {bi}"))
        }
      }

      break
    }

    if notes.len() > 0 {
      # Diagnostics name the line of the macro name when it was read from a
      # file, else the current position in the innermost file.
      var where = ""

      if call_at_pos >= 0 {
        where = f"{call_at_name}:{count_lines(call_at_text, call_at_pos)}"
      } else if kind == 1 {
        where = f"{iname}:{count_lines(text, pos)}"
      } else if kind == 3 {
        where = f"{iname}:{iline}"
      } else {
        var i = nf - 1
        where = "NONE:0"

        while i >= 0 {
          if f_kind[i] == 1 {
            where = f"{f_name[i]}:{count_lines(f_text[i], f_pos[i])}"
            break
          }

          if f_kind[i] == 3 {
            where = f"{f_name[i]}:{f_line[i]}"
            break
          }

          i -= 1
        }
      }

      for note in notes {
        # GNU m4 gives the `\0` deprecation once per run.
        if note.starts_with("Warning: \\0 will disappear") {
          if warned_backslash_zero {
            continue
          }

          warned_backslash_zero = true
        }

        eprint f"m4:{where}: {note}"
      }
    }

    if push_text != "" or push_macdef != "" {
      # Exhausted expansion blocks are dropped rather than suspended, so tail
      # calls do not grow the input stack; file blocks stay for locations.
      if pos < tlen or kind == 1 or kind == 3 {
        if nf < f_text.len() {
          f_text[nf] = text
          f_pos[nf] = pos
          f_kind[nf] = kind
          f_name[nf] = iname
          f_line[nf] = iline
        } else {
          f_text += [text]
          f_pos += [pos]
          f_kind += [kind]
          f_name += [iname]
          f_line += [iline]
        }

        nf += 1
      }

      if push_macdef != "" {
        text = push_macdef
        kind = 2
        iname = push_macdef
      } else {
        text = push_text
        kind = 0
      }

      pos = 0
      tlen = text.byte_len()
    }
  }

  # End of input: diversions are emitted in numeric order.
  if div == 0 {
    io.write_stdout(sink.join(""))
  } else if div > 0 and sink.len() > 0 {
    diversions[f"{div}"] = f"{diversions.get(f"{div}") ?? ""}{sink.join("")}"
  }

  for k in numeric_key_order(diversions.keys()) {
    if k > 0 {
      io.write_stdout(diversions[f"{k}"])
    }
  }

  status
}

# ── command line ─────────────────────────────────────────────────────────────
proc parse_options(argv: List[Str]) -> Result[Options?] {
  var prefix = false
  var include_paths: List[Str] = []
  var defines: List[List[Str]] = []
  var inputs: List[InputSpec] = []
  var i = 0
  var options_done = false

  while i < argv.len() {
    let a = argv[i]
    i += 1

    if options_done or a == "-" or ! a.starts_with("-") {
      inputs += [{name: a, stdin: a == "-"}]
      continue
    }

    if a == "--" {
      options_done = true
      continue
    }

    if a == "--version" {
      io.write_stdout("m4 (GNU M4 compatible, XSH) 1.4.20\n")
      return null
    }

    if a == "--help" or a == "-h" {
      io.write_stdout("usage: m4 [-P] [-I DIR] [-D NAME[=VALUE]] [-U NAME] [FILE]...\n")
      return null
    }

    if a == "-g" or a == "--gnu" or a == "-Q" or a == "--quiet" or a == "--silent" or a.starts_with("-d") or a.starts_with("--debug") {
      continue
    }

    if a == "-P" or a == "--prefix-builtins" {
      prefix = true
      continue
    }

    var flag = ""
    var value = ""
    var has_value = false

    if a.starts_with("--include=") or a.starts_with("--define=") or a.starts_with("--undefine=") {
      let eq = a.find("=") ?? 0
      flag = match a.byte_slice(0, eq) {
        "--include" => "I"
        "--define" => "D"
        else => "U"
      }
      value = a.byte_slice(eq + 1, a.byte_len() - eq - 1)
      has_value = true
    } else if a == "--include" or a == "--define" or a == "--undefine" {
      flag = match a {
        "--include" => "I"
        "--define" => "D"
        else => "U"
      }
    } else if a.byte_len() >= 2 and (a.starts_with("-I") or a.starts_with("-D") or a.starts_with("-U")) {
      flag = a.byte_slice(1, 1)

      if a.byte_len() > 2 {
        value = a.byte_slice(2, a.byte_len() - 2)
        has_value = true
      }
    } else {
      return Err(ScriptError.Failed(kind: "m4-usage", message: f"unrecognized option '{a}'"))
    }

    if ! has_value {
      if i >= argv.len() {
        return Err(ScriptError.Failed(kind: "m4-usage", message: f"option '{a}' requires an argument"))
      }

      value = argv[i]
      i += 1
    }

    match flag {
      "I" => include_paths += [value]
      "D" => defines += [parse_define_arg(value)]
      else => defines += [[value]]
    }
  }

  if inputs.len() == 0 {
    inputs = [{name: "-", stdin: true}]
  }

  {prefix, include_paths, defines, inputs}
}

proc main(margs: List[Str] = []) [fs, process, env, error, io] {
  var parsed: Options? = null

  match parse_options(margs) {
    Ok(o) => parsed = o
    Err(failure) => {
      eprint f"m4: {failure.message}"
      exit 1
    }
  }

  let opts = parsed

  return when opts == null

  let status = match expand_inputs(opts) {
    Ok(code) => code
    Err(failure) => {
      eprint f"m4: {failure.message}"
      1
    }
  }

  if status != 0 {
    exit status
  }
}

main(args)
