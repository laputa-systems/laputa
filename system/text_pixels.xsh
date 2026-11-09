##! Pixel checks that a QMP screenshot shows international text as shaped glyphs rather than tofu.
##! A tofu line repeats one identical box, so a line of words passes only when its words differ.
error TextPixelsError = Failed(message: Str)

const sample_step = 2
const minimum_cell_ink = 8
const chroma_threshold = 60
const emoji_chroma_pixels = 40
const marker_cells = 40
const marker_rgb = 16711935

## A decoded screenshot: the PPM bytes, where its pixels start, and its size.
export type Raster = {data: Bytes, offset: Int, width: Int, height: Int}

## One maximal column range of ink: where it starts, its width, and its ink and strongly colored pixel counts.
export type Run = {left: Int, width: Int, chroma: Int, ink: Int}

pure channel(raster: Raster, x: Int, y: Int, index: Int) -> Int {
  raster.data.byte_at(raster.offset + (y * raster.width + x) * 3 + index) ?? -1
}

pure pixel(raster: Raster, x: Int, y: Int) -> Int {
  channel(raster, x, y, 0) * 65536 + channel(raster, x, y, 1) * 256 + channel(raster, x, y, 2)
}

## The pixel grid of a binary PPM, or an error naming what the header lacks.
export pure raster(image: Bytes) -> Result[Raster, Error] {
  guard image.starts_with(b"P6\n") else { fail "screenshot is not a binary PPM" }
  var newline = 3
  while (image.byte_at(newline) ?? 10) != 10 { newline += 1 }
  let dimensions = image.slice(3, newline - 3).utf8()?.split(" ")
  guard dimensions.len() == 2 else { fail "screenshot header lacks its dimensions" }
  let width = dimensions[0].parse_int()?
  let height = dimensions[1].parse_int()?
  let offset = newline + 5
  guard image.len() >= offset + width * height * 3 else { fail "screenshot is shorter than its header" }
  {data: image, offset, width, height}
}

pure is_background(value: Int, backgrounds: List[Int]) -> Bool {
  value in backgrounds
}

pure chroma_of(value: Int) -> Int {
  let red = value / 65536
  let green = value / 256 % 256
  let blue = value % 256
  let high = if red > green { red } else { green }
  let top = if high > blue { high } else { blue }
  let low = if red < green { red } else { green }
  let bottom = if low < blue { low } else { blue }
  top - bottom
}

## Maximal column ranges that hold ink in one band.
export pure runs(raster: Raster, left: Int, right: Int, top: Int, bottom: Int, backgrounds: List[Int]) -> List[Run] {
  var found: List[Run] = []
  var start = -1
  var chroma = 0
  var count = 0
  var x = left
  while x <= right {
    var ink = false
    var y = top
    while x < right and y < bottom {
      let value = pixel(raster, x, y)
      if ! is_background(value, backgrounds) {
        ink = true
        count += 1
        if chroma_of(value) > chroma_threshold { chroma += 1 }
      }
      y += sample_step
    }
    if ink {
      if start < 0 { start = x }
    } else if start >= 0 {
      found = found + [{left: start, width: x - start, chroma, ink: count}]
      start = -1
      chroma = 0
      count = 0
    }
    x += 1
  }
  found
}

## The ink of each nonempty character cell of one terminal row, as one run per cell.
export pure cells(raster: Raster, left: Int, cell_width: Int, count: Int, top: Int, bottom: Int, backgrounds: List[Int]) -> List[Run] {
  var found: List[Run] = []
  var index = 0
  while index < count {
    let from = left + index * cell_width
    let inside = runs(raster, from, from + cell_width, top, bottom, backgrounds)
    if inside.len() > 0 {
      var ink = 0
      var chroma = 0
      for part in inside {
        ink += part.ink
        chroma += part.chroma
      }
      let last = inside[inside.len() - 1]
      if ink >= minimum_cell_ink {
        found = found + [{left: inside[0].left, width: last.left + last.width - inside[0].left, chroma, ink}]
      }
    }
    index += 1
  }
  found
}

pure similar(a: Run, b: Run) -> Bool {
  let width_gap = if a.width > b.width { a.width - b.width } else { b.width - a.width }
  let ink_gap = if a.ink > b.ink { a.ink - b.ink } else { b.ink - a.ink }
  let larger = if a.ink > b.ink { a.ink } else { b.ink }
  width_gap <= 2 and ink_gap * 10 <= larger
}

## Two or more words that are not all one repeated box.
export pure shows_glyphs(found: List[Run]) -> Bool {
  var all_alike = true
  for word in found { all_alike = all_alike and similar(word, found[0]) }
  found.len() >= 2 and ! all_alike
}

proc require(condition: Bool, message: Str) [error] {
  return when condition
  Err(TextPixelsError.Failed(message:))?
}

proc check_line(name: Str, found: List[Run], glyphs: Bool) [error] {
  require(shows_glyphs(found) == glyphs, f"{name} line {if glyphs { "rendered as tofu or blank" } else { "was expected to be tofu" }}: {[f"{word.width}:{word.ink}" for word in found].join(" ")}")?
}

proc check_emoji_line(name: Str, found: List[Run], cluster_limit: Int) [error] {
  require(found.len() == 2, f"{name} emoji line has {found.len()} runs, expected a cluster and a party popper")?
  require(found[0].width <= cluster_limit, f"{name} ZWJ sequence is {found[0].width} px wide, over the {cluster_limit} px cluster limit")?
  require(! similar(found[0], found[1]), f"{name} emoji runs look alike")?
  require(found[1].chroma >= emoji_chroma_pixels, f"{name} party popper has {found[1].chroma} colored pixels, not a color emoji")?
}

## Ghostty prints a magenta marker of 40 cells followed by six rows: Arabic,
## Devanagari, CJK, a ZWJ family with a party popper, and a row of hieroglyphs
## no installed font covers. The cell size comes from the marker itself.
export proc check_terminal_text(image: Bytes) [error] {
  let screen = raster(image)?
  var x0 = -1
  var y0 = -1
  var y = 0
  while y0 < 0 and y < 200 {
    var x = 0
    while x0 < 0 and x < 500 {
      if pixel(screen, x, y) == marker_rgb {
        x0 = x
        y0 = y
      }
      x += 1
    }
    y += 1
  }
  require(y0 >= 0, "terminal marker is not on screen")?
  var marker_width = 0
  while pixel(screen, x0 + marker_width, y0) == marker_rgb { marker_width += 1 }
  var cell_height = 0
  while pixel(screen, x0, y0 + cell_height) == marker_rgb { cell_height += 1 }
  let cell_width = marker_width / marker_cells
  let page = pixel(screen, 0, 0)
  var lines: List[List[Run]] = []
  var row = 1
  while row <= 5 {
    let top = y0 + row * cell_height
    let background = pixel(screen, x0, top)
    if row == 4 {
      lines = lines + [runs(screen, x0, x0 + marker_width, top, top + cell_height, [background, page])]
    } else {
      lines = lines + [cells(screen, x0, cell_width, marker_cells, top, top + cell_height, [background, page])]
    }
    row += 1
  }
  check_line("Arabic", lines[0], true)?
  check_line("Devanagari", lines[1], true)?
  check_line("CJK", lines[2], true)?
  check_emoji_line("terminal", lines[3], 2 * cell_width)?
  check_line("uncovered-script", lines[4], false)?
}

## Play draws five centered subtitle lines on a black frame, in the order the
## terminal prints them, and separates them by blank pixel rows.
export proc check_player_text(image: Bytes) [error] {
  let screen = raster(image)?
  let left = screen.width / 4
  let right = screen.width * 3 / 4
  var bands: List[List[Int]] = []
  var top = -1
  var y = screen.height / 2
  while y <= screen.height {
    var ink = false
    var x = left
    while y < screen.height and ! ink and x < right {
      if pixel(screen, x, y) != 0 { ink = true }
      x += 4
    }
    if ink and top < 0 {
      top = y
    } else if ! ink and top >= 0 {
      bands = bands + [[top, y]]
      top = -1
    }
    y += 1
  }
  require(bands.len() == 5, f"Play shows {bands.len()} subtitle lines, expected 5")?
  var lines: List[List[Run]] = []
  for band in bands {
    lines = lines + [runs(screen, left, right, band[0], band[1], [0])]
  }
  check_line("Play Arabic", lines[0], true)?
  check_line("Play Devanagari", lines[1], true)?
  check_line("Play CJK", lines[2], true)?
  check_emoji_line("Play", lines[3], 2 * lines[3][1].width)?
  check_line("Play uncovered-script", lines[4], false)?
}
