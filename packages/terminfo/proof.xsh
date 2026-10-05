##! XSH module `proof` package and build operations.
use pm.proof

# A compiled entry read back from ncurses' binary format, independently of the
# compiler: header, names, booleans, numbers (16-bit for magic 0432, 32-bit
# for 01036), string offsets, the string table, and the extended section.
type Compiled = {
  magic: Int,
  names: Str,
  bools: List[Int],
  nums: List[Int],
  strs: List[Bytes?],
  ext_bools: Map[Str, Int],
  ext_nums: Map[Str, Int],
  ext_strs: Map[Str, Bytes?],
}

error ReadError = Malformed(file: Path, message: Str)

# Standard capability indexes, fixed by the SVr4-compatible order of
# ncurses' include/Caps.
const AUTO_RIGHT_MARGIN = 1
const COLUMNS = 0
const MAX_COLORS = 13
const CURSOR_ADDRESS = 10
const KEY_BACKSPACE = 55
const KEY_UP = 87
const KEYPAD_XMIT = 89

pure u16(data: Bytes, at: Int) -> Int {
  (data.byte_at(at) ?? 0) + (data.byte_at(at + 1) ?? 0) * 256
}

pure s16(data: Bytes, at: Int) -> Int {
  let value = u16(data, at)
  if value >= 32768 { value - 65536 } else { value }
}

pure s32(data: Bytes, at: Int) -> Int {
  let value = u16(data, at) + u16(data, at + 2) * 65536
  if value >= 2147483648 { value - 4294967296 } else { value }
}

# The NUL-terminated string at `at`.
pure c_string(data: Bytes, at: Int) -> Bytes {
  var end = at
  while (data.byte_at(end) ?? 0) != 0 {
    end += 1
  }

  data[at..end]
}

pure table_string(data: Bytes, base: Int, offset: Int) -> Bytes? {
  if offset < 0 {
    return null
  }

  c_string(data, base + offset)
}

proc read_compiled(file: Path) [fs, error] -> Result[Compiled] {
  let data = file.read_bytes()?
  let magic = u16(data, 0)
  guard magic == 0o432 or magic == 0o1036 else {
    return Err(ReadError.Malformed(file:, message: f"bad magic {magic}"))
  }

  let width = if magic == 0o1036 { 4 } else { 2 }
  let name_size = u16(data, 2)
  let bool_count = u16(data, 4)
  let num_count = u16(data, 6)
  let str_count = u16(data, 8)
  let table_size = u16(data, 10)
  let names = c_string(data, 12).utf8()?
  let bool_at = 12 + name_size
  let bools = [data.byte_at(bool_at + k) ?? 0 for k in range(bool_count)]
  let num_at = bool_at + bool_count + (name_size + bool_count) % 2
  let nums = [if width == 4 { s32(data, num_at + 4 * k) } else { s16(data, num_at + 2 * k) } for k in range(num_count)]
  let offset_at = num_at + width * num_count
  let table_at = offset_at + 2 * str_count
  let strs = [table_string(data, table_at, s16(data, offset_at + 2 * k)) for k in range(str_count)]

  var ext_bools: Map[Str, Int] = {}
  var ext_nums: Map[Str, Int] = {}
  var ext_strs: Map[Str, Bytes?] = {}
  let ext_at = table_at + table_size + table_size % 2
  if ext_at < data.len() {
    let eb = u16(data, ext_at)
    let en = u16(data, ext_at + 2)
    let es = u16(data, ext_at + 4)
    let ext_bool_at = ext_at + 10
    let ext_num_at = ext_bool_at + eb + eb % 2
    let ext_offset_at = ext_num_at + width * en
    let total = eb + en + es
    let ext_table_at = ext_offset_at + 2 * (es + total)
    let values = [s16(data, ext_offset_at + 2 * k) for k in range(es)]
    let value_strings = [table_string(data, ext_table_at, offset) for offset in values]
    # Names follow the string values; their offsets restart at zero.
    var names_at = ext_table_at
    for k in range(es) {
      let text = value_strings[k]
      if text != null and ext_table_at + values[k] + text.len() + 1 > names_at {
        names_at = ext_table_at + values[k] + text.len() + 1
      }
    }

    let ext_names = [c_string(data, names_at + s16(data, ext_offset_at + 2 * (es + k))).utf8()? for k in range(total)]
    ext_bools = {[ext_names[k]]: data.byte_at(ext_bool_at + k) ?? 0 for k in range(eb)}
    ext_nums = {
      [ext_names[eb + k]]: if width == 4 { s32(data, ext_num_at + 4 * k) } else { s16(data, ext_num_at + 2 * k) }
      for k in range(en)
    }
    ext_strs = {[ext_names[eb + en + k]]: value_strings[k] for k in range(es)}
  }

  Compiled(magic:, names:, bools:, nums:, strs:, ext_bools:, ext_nums:, ext_strs:)
}

pure number(entry: Compiled, index: Int) -> Int {
  if index < entry.nums.len() { entry.nums[index] } else { -1 }
}

pure flag(entry: Compiled, index: Int) -> Bool {
  index < entry.bools.len() and entry.bools[index] == 1
}

pure string(entry: Compiled, index: Int) -> Bytes? {
  if index < entry.strs.len() { entry.strs[index] } else { null }
}

proc expect_string(entry: Compiled, index: Int, want: Bytes, what: Str) [error] {
  proof.ensure(string(entry, index) == want, "proof-terminfo", f"{entry.names}: unexpected {what}")?
}

proc main(root: Path = /rootfs) [fs, error] {
  proof.package_metadata(root, "terminfo")?
  let database = fp"{root}/usr/share/terminfo"
  let paths = fs.walk(database)? |> where .kind == "file"
  proof.ensure(paths.len() > 2800, "proof-terminfo", f"only {paths.len()} compiled names in {database}")?

  let xterm = read_compiled(fp"{database}/x/xterm-256color")?
  proof.ensure(xterm.names.starts_with("xterm-256color|"), "proof-terminfo", "xterm-256color has the wrong names")?
  proof.ensure(number(xterm, MAX_COLORS) == 256, "proof-terminfo", "xterm-256color does not have 256 colors")?
  proof.ensure(flag(xterm, AUTO_RIGHT_MARGIN), "proof-terminfo", "xterm-256color lost am")?
  expect_string(xterm, CURSOR_ADDRESS, b"\x1b[%i%p1%d;%p2%dH", "cup")?
  expect_string(xterm, KEY_UP, b"\x1bOA", "kcuu1")?
  expect_string(xterm, KEYPAD_XMIT, b"\x1b[?1h\x1b=", "smkx")?
  # The Linux edit of the xterm+kbs fragment: backspace sends DEL.
  expect_string(xterm, KEY_BACKSPACE, b"\x7f", "kbs")?

  # foot's own description, not ncurses' copy: it declares Tc and Su.
  let foot = read_compiled(fp"{database}/f/foot")?
  proof.ensure(number(foot, MAX_COLORS) == 256, "proof-terminfo", "foot does not have 256 colors")?
  expect_string(foot, CURSOR_ADDRESS, b"\x1b[%i%p1%d;%p2%dH", "cup")?
  expect_string(foot, KEY_UP, b"\x1bOA", "kcuu1")?
  expect_string(foot, KEYPAD_XMIT, b"\x1b[?1h\x1b=", "smkx")?
  proof.ensure((foot.ext_bools.get("Tc") ?? 0) == 1, "proof-terminfo", "foot is not foot's own entry (no Tc)")?
  proof.ensure("Smulx" in foot.ext_strs and foot.ext_strs["Smulx"] == b"\x1b[4:%p1%dm", "proof-terminfo", "foot lost Smulx")?

  # Direct color needs the 32-bit number format.
  let foot_direct = read_compiled(fp"{database}/f/foot-direct")?
  proof.ensure(foot_direct.magic == 0o1036, "proof-terminfo", "foot-direct is not in the 32-bit number format")?
  proof.ensure(number(foot_direct, MAX_COLORS) == 16777216, "proof-terminfo", "foot-direct does not have 2^24 colors")?
  proof.ensure((foot_direct.ext_bools.get("RGB") ?? 0) == 1, "proof-terminfo", "foot-direct lost RGB")?

  let console = read_compiled(fp"{database}/l/linux")?
  proof.ensure(number(console, MAX_COLORS) == 8, "proof-terminfo", "linux does not have 8 colors")?
  expect_string(console, CURSOR_ADDRESS, b"\x1b[%i%p1%d;%p2%dH", "cup")?
  expect_string(console, KEY_UP, b"\x1b[A", "kcuu1")?
  proof.ensure(string(console, KEYPAD_XMIT) == null, "proof-terminfo", "linux has an unexpected smkx")?

  let dumb = read_compiled(fp"{database}/d/dumb")?
  proof.ensure(number(dumb, COLUMNS) == 80, "proof-terminfo", "dumb does not have 80 columns")?
  proof.ensure(string(dumb, CURSOR_ADDRESS) == null, "proof-terminfo", "dumb has cursor addressing")?

  # Aliases name the same compiled entry.
  let alias = fp"{database}/v/vt100-am".read_bytes()?
  proof.ensure(alias == fp"{database}/v/vt100".read_bytes()?, "proof-terminfo", "vt100-am differs from vt100")?

  print f"terminfo ok: {paths.len()} names; xterm-256color, foot, foot-direct, linux, dumb read back"
}

main(@args)?
