##! Behavior coverage for the screenshot checks that tell shaped glyphs from tofu.
use system.text_pixels

const black = 0
const white = 16777215
const band_width = 60
const band_height = 6

proc ppm(columns: List[Int]) [error] -> Result[Bytes, Error] {
  let header = bytes.from_text(f"P6\n{band_width} {band_height}\n255\n")
  let row = bytes.from_ints(
    [
      channel
      for column in columns
      for channel in [column / 65536, column / 256 % 256, column % 256]
    ],
  )?
  bytes.concat([header, row, row, row, row, row, row])
}

pure word(width: Int, ink: Int) -> List[Int] {
  [ink for _ in range(0, width)]
}

pure gap(width: Int) -> List[Int] {
  word(width, black)
}

pure line(words: List[List[Int]]) -> List[Int] {
  var columns: List[Int] = gap(2)
  for item in words { columns = columns + item + gap(4) }
  columns + gap(band_width - columns.len())
}

proc words_of(columns: List[Int]) [error] -> Result[List[text_pixels.Run], Error] {
  let screen = text_pixels.raster(ppm(columns)?)?
  text_pixels.runs(screen, 0, band_width, 0, band_height, [black])
}

test test_distinct_words_show_glyphs [error] {
  let found = words_of(line([word(9, white), word(5, white)]))?
  assert found.len() == 2
  assert text_pixels.shows_glyphs(found)
}

test test_repeated_boxes_are_tofu [error] {
  let found = words_of(line([word(7, white), word(7, white), word(7, white)]))?
  assert found.len() == 3
  assert ! text_pixels.shows_glyphs(found)
}

test test_antialiasing_between_repeated_boxes_is_still_tofu [error] {
  let found = words_of(line([word(10, white), word(9, white), word(10, white)]))?
  assert ! text_pixels.shows_glyphs(found)
}

test test_blank_or_merged_text_is_not_glyphs [error] {
  assert ! text_pixels.shows_glyphs(words_of(line([]))?)
  assert ! text_pixels.shows_glyphs(words_of(line([word(20, white)]))?)
}

test test_colored_pixels_are_counted_per_word [error] {
  let found = words_of(line([word(4, white), word(4, 16711680)]))?
  assert found[0].chroma == 0
  assert found[1].chroma == 4 * 3
}

test test_screenshot_must_be_a_complete_binary_ppm [error] {
  match text_pixels.raster(b"P5\n1 1\n255\nX") {
    Ok(_) => test.fail("accepted a non-P6 image")
    Err(problem) => assert "binary PPM" in problem.message, problem.message
  }
  match text_pixels.raster(b"P6\n2 2\n255\nXX") {
    Ok(_) => test.fail("accepted a truncated image")
    Err(problem) => assert "shorter" in problem.message, problem.message
  }
}
