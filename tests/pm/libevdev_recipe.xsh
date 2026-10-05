##! Contract coverage for the libevdev recipe's port of make-event-names.py.
use packages.libevdev.PKGBUILD as libevdev_recipe

pure lines_between(text: Str, start: Str, end: Str) -> List[Str] {
  var inside = false
  var lines = []

  for line in text.split("\n") {
    if line == start {
      inside = true
    } else if inside and line == end {
      inside = false
    } else if inside {
      lines += [line]
    }
  }

  lines
}

test test_event_name_lookups_are_sorted_by_name [error] { |ctx|
  let header = libevdev_recipe.event_names_header(
    [
      """#define EV_SYN 0x00
#define EV_KEY 0x01
#define EV_REL 0x02
#define EV_MAX 0x1f
#define KEY_RESERVED 0
#define KEY_ESC 1
#define REL_X 0x00
#define REL_MAX 0x0f
""",
    ],
  )

  # libevdev binary-searches these tables, so file order would break lookups.
  assert lines_between(header, "static const struct name_entry ev_names[] = {", "};") == [
    """    { .name = "EV_KEY", .value = EV_KEY },""",
    """    { .name = "EV_MAX", .value = EV_MAX },""",
    """    { .name = "EV_REL", .value = EV_REL },""",
    """    { .name = "EV_SYN", .value = EV_SYN },""",
  ]
}

test test_event_names_keep_the_last_name_per_code [error] { |ctx|
  let header = libevdev_recipe.event_names_header(
    [
      """#define EV_SND 0x12
#define EV_MAX 0x1f
#define SND_CLICK 0x00
#define SND_PROFILE_SILENT 0x00
#define SND_MAX 0x07
#define FF_STATUS_STOPPED 0x00
#define FF_STATUS_PLAYING 0x01
#define FF_STATUS_MAX 0x01
#define FF_MAX 0x7f
#define FF_LEGACY 010
""",
    ],
  )

  # A later define of a code replaces the earlier name, SND_PROFILE_ codes
  # never take a sound code's name, and a leading-zero decimal is no code.
  assert """    [FF_STATUS_MAX] = "FF_STATUS_MAX",""" in header
  assert "FF_STATUS_PLAYING" not in header
  assert """    [SND_CLICK] = "SND_CLICK",""" in header
  assert "SND_PROFILE_SILENT" not in header
  assert "FF_LEGACY" not in header
}
