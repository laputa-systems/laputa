##! XSH module `PKGBUILD` package and build operations.
use pm.env as pm_env

## Exported declaration `name`.
export const name = "libevdev"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1.13.7"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "linux-headers", "muon", "samurai", "pkgconf"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://gitlab.freedesktop.org/libevdev/libevdev/-/archive/libevdev-VERSION/libevdev-libevdev-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "9294aaaff6829ab1581e6684f4c3ddc449fee563229e863353a4893f1a673f4b",
      },
    ],
  },
]

type EventDef = {attr: Str, value: Int, name: Str}

type EventDefinitions = {defs: List[EventDef], max_codes: Map[Int]}

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/include/libevdev-1.0/libevdev/libevdev-uinput.h",
    kind: "file",
  },
  {
    path: p"usr/include/libevdev-1.0/libevdev/libevdev.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libevdev.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libevdev.so.2",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libevdev.so.2.3.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/libevdev.pc",
    kind: "file",
  },
]

# The definitions from here through `write_event_names` port
# libevdev/make-event-names.py, which writes event-names.h from the kernel's
# input headers. The port follows the script's data model: each event class
# maps a code value to the last name defined for it, the per-class maps are
# printed by value, and every name lookup table is sorted by name, because
# libevdev binary-searches those tables.
pure event_prefixes() -> List[Str] {
  [
    "EV_",
    "REL_",
    "ABS_",
    "KEY_",
    "BTN_",
    "LED_",
    "SND_",
    "MSC_",
    "SW_",
    "FF_",
    "SYN_",
    "REP_",
    "INPUT_PROP_",
    "MT_TOOL_",
  ]
}

# The script's code_prefixes, in the sorted order it prints them.
pure code_prefixes() -> List[Str] {
  [
    "ABS_",
    "BTN_",
    "FF_",
    "KEY_",
    "LED_",
    "MSC_",
    "REL_",
    "REP_",
    "SND_",
    "SW_",
    "SYN_",
  ]
}

pure duplicate_defines() -> List[Str] {
  [
    "EV_VERSION",
    "BTN_MISC",
    "BTN_MOUSE",
    "BTN_JOYSTICK",
    "BTN_GAMEPAD",
    "BTN_DIGI",
    "BTN_WHEEL",
    "BTN_TRIGGER_HAPPY",
    "SW_MAX",
    "REP_MAX",
  ]
}

pure ignored_prefixes() -> List[Str] {
  ["SND_PROFILE_"]
}

# `prefix[:-1].lower()`: "INPUT_PROP_" names the `input_prop` class.
pure attr_name(prefix: Str) -> Str {
  if let [_, stem] = rx"^(.*)_$".captures(prefix) {
    return stem.lower()
  }

  prefix.lower()
}

# Python's `int(text, 0)`: decimal, or 0x/0o/0b prefixed. A decimal with a
# leading zero is rejected, so such a define names no code.
pure define_value(text: Str) -> Int {
  return -1 when rx"^0[0-9]*[1-9][0-9]*$".captures(text) != []

  return -1 when rx"^(0[xXoObB][0-9a-fA-F]+|[0-9]+)$".captures(text) == []

  text.parse_int() ?? -1
}

pure class_defs(defs: List[EventDef], attr: Str) -> List[EventDef] {
  [item for item in defs |> where .attr == attr |> sort-by .value]
}

pure has_class(defs: List[EventDef], attr: Str) -> Bool {
  class_defs(defs, attr) != []
}

pure c_lines_for_bits(defs: List[EventDef], attr: Str) -> List[Str] {
  return [] unless has_class(defs, attr)

  var lines = [f"static const char * const {attr}_map[{attr.upper()}_MAX + 1] = {{"]

  for item in class_defs(defs, attr) {
    lines += [f"    [{item.name}] = \"{item.name}\","]
  }

  if attr == "key" {
    for item in class_defs(defs, "btn") {
      lines += [f"    [{item.name}] = \"{item.name}\","]
    }
  }

  lines.push("};").push("")
}

pure c_lookup_lines(defs: List[EventDef], attr: Str, max_codes: Map[Int]) -> List[Str] {
  return [] unless has_class(defs, attr)

  var names = class_defs(defs, attr)

  if attr == "btn" {
    for name in ["BTN_A", "BTN_B", "BTN_X", "BTN_Y"] {
      names += [{attr, value: 0, name}]
    }
  }

  let max_name = f"{attr.upper()}_MAX"

  if max_name in duplicate_defines() {
    names += [{attr, value: max_codes.get(max_name) ?? 0, name: max_name}]
  }

  [f"    {{ .name = \"{item.name}\", .value = {item.name} }}," for item in names |> sort-by .name]
}

pure collect_event_defs(headers: List[Str]) -> EventDefinitions {
  var defs: List[EventDef] = []
  var max_codes: Map[Int] = {}

  for header in headers {
    for line in header.split("\n") {
      if let [_, event_name, value_text] = rx"^#define\s+(\w+)\s+(\w+)".captures(line) {
        let value = define_value(value_text)

        if value >= 0 {
          var done = false

          for prefix in event_prefixes() {
            let ignored = [p for p in ignored_prefixes() if event_name.starts_with(p)] != []

            if ! done and event_name.starts_with(prefix) and ! ignored {
              if event_name.ends_with("_MAX") {
                max_codes[event_name] = value
              }

              if event_name in duplicate_defines() {
                done = true
              } else {
                let attr = attr_name(prefix)
                defs = [item for item in defs if ! (item.attr == attr and item.value == value)]
                defs += [{attr, value, name: event_name}]
              }
            }
          }
        }
      }
    }
  }

  {defs, max_codes}
}

## event-names.h for the given input header texts, in the order
## make-event-names.py reads them.
export pure event_names_header(headers: List[Str]) -> Str {
  let collected = collect_event_defs(headers)
  let defs: List[EventDef] = collected.defs
  let max_codes: Map[Int] = collected.max_codes
  var lines = ["/* THIS FILE IS GENERATED, DO NOT EDIT */", "", "#ifndef EVENT_NAMES_H", "#define EVENT_NAMES_H", ""]

  for prefix in event_prefixes() {
    if prefix != "BTN_" {
      lines += c_lines_for_bits(defs, attr_name(prefix))
    }
  }

  lines += ["static const char * const * const event_type_map[EV_MAX + 1] = {"]

  for prefix in event_prefixes() {
    if prefix not in ["BTN_", "EV_", "INPUT_PROP_", "MT_TOOL_"] {
      let attr = attr_name(prefix)
      lines += [f"    [EV_{attr.upper()}] = {attr}_map,"]
    }
  }

  lines += ["};", ""]
  lines += ["#if __clang__"]
  lines += ["#pragma clang diagnostic push"]
  lines += ["#pragma clang diagnostic ignored \"-Winitializer-overrides\""]
  lines += ["#elif __GNUC__"]
  lines += ["#pragma GCC diagnostic push"]
  lines += ["#pragma GCC diagnostic ignored \"-Woverride-init\""]
  lines += ["#endif"]
  lines += ["static const int ev_max[EV_MAX + 1] = {"]
  let ev_defs = class_defs(defs, "ev")
  var index = 0

  while index <= (max_codes.get("EV_MAX") ?? -1) {
    var line = "    -1,"

    for item in ev_defs |> where .value == index {
      if let [_, class] = rx"^EV_(.*)$".captures(item.name) {
        if f"{class}_" in event_prefixes() {
          line = f"    {class}_MAX,"
        }
      }
    }

    lines += [line]
    index += 1
  }

  lines += ["};"]
  lines += ["#if __clang__"]
  lines += ["#pragma clang diagnostic pop /* \"-Winitializer-overrides\" */"]
  lines += ["#elif __GNUC__"]
  lines += ["#pragma GCC diagnostic pop /* \"-Woverride-init\" */"]
  lines += ["#endif"]
  lines += [""]
  lines += ["struct name_entry {"]
  lines += ["    const char *name;"]
  lines += ["    unsigned int value;"]
  lines += ["};"]
  lines += [""]
  lines += ["static const struct name_entry tool_type_names[] = {"]
  lines += c_lookup_lines(defs, "mt_tool", max_codes)
  lines += ["};", ""]
  lines += ["static const struct name_entry ev_names[] = {"]
  lines += c_lookup_lines(defs, "ev", max_codes)
  lines += ["};", ""]
  lines += ["static const struct name_entry code_names[] = {"]

  for prefix in code_prefixes() {
    lines += c_lookup_lines(defs, attr_name(prefix), max_codes)
  }

  lines += ["};", ""]
  lines += ["static const struct name_entry prop_names[] = {"]
  lines += c_lookup_lines(defs, "input_prop", max_codes)
  lines += ["};", ""]
  lines += ["#endif /* EVENT_NAMES_H */"]
  f"{lines.join("\n")}\n"
}

proc write_event_names() [fs, error] {
  let headers = [p"include/linux/linux/input.h", p"include/linux/linux/input-event-codes.h"]
  fs.write(p"event-names.h", event_names_header([header.read_text()? for header in headers]))
}

proc patch_python_generator() [fs, error] {
  write_event_names()
  let meson = p"meson.build"
  var text = meson.read_text()?

  text = text.replace(
    """# event-names.h
make_event_names = find_program('libevdev/make-event-names.py')
event_names_h = configure_file(input: 'libevdev/libevdev.h',
			       output: 'event-names.h',
			       command: [make_event_names, input_h, input_event_codes_h],
			       capture: true)
""",
    """# event-names.h
event_names_h = files('event-names.h')
""",
  )

  text = text.replace(
    "dep_lm = cc.find_library('m')",
    """# musl packages libm as a libc symlink; link by name instead of recording the build-env path.
dep_lm = declare_dependency(link_args: ['-lm'])""",
  )

  text = text.replace(
    "dep_rt = cc.find_library('rt')",
    """# musl provides realtime interfaces in libc; avoid recording the build-env librt.
dep_rt = declare_dependency()""",
  )

  fs.write(meson, text)
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let muon = process.which("muon")?
  let jobs_flag = f"-j{cpu.count()}"
  let pc = pm_env.pkg_config_context()?
  patch_python_generator()

  env ({
    LD_LIBRARY_PATH: pc.ld_library_path,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    run $muon "setup" pm_env.meson_prefix_arg() pm_env.meson_libdir_arg() "-Ddefault_library=shared" "-Dtests=disabled" "-Dtools=disabled" "-Ddocumentation=disabled" "-Dcoverity=false" "build" ?
    run $muon "-C" "build" samu $jobs_flag ?

    env ({
      DESTDIR: dest,
    }) {
      run $muon "-C" "build" install ?
    }
  }

  fs.remove(fp"{dest}/usr/share/man", missing_ok: true)
}
