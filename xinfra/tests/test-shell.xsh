use infra.shell

const hostile = [
  "plain",
  "",
  "-leading-hyphen",
  "--",
  "it's",
  "'",
  "''",
  "a b",
  "tab\there",
  "line\nbreak",
  "trailing newline\n",
  "$HOME",
  "$(echo injected)",
  "`echo injected`",
  "; echo injected",
  "&& echo injected",
  "| cat",
  "\\",
  "\\'\\\\",
  "*",
  "~",
  "{a,b}",
  "#comment",
  "!history",
  "caf\u{e9}",
  "\u{1f980}",
  "\"double\"",
]

test quote_round_trips_hostile_values_through_a_real_shell {
  let script = r"""printf '%s\0' "$@" """
  for value in hostile {
    let command = shell.command(script, [value, "second"])?
    let out = run.capture --bytes sh -c $command
    assert out.status.ok, f"exit for {value}"
    assert out.stdout.utf8()? == value + "\0second\0"
  }
}

const alphabet = ["'", "\"", "\\", "$", "`", " ", "\n", "\t", "-", "*", "?", "[", "]", "{", "}", "(", ")", ";", "&", "|", "<", ">", "!", "~", "#", "%", "a", "Z", "0", "\u{e9}", "\u{1f980}"]

pure next_state(state: Int) -> Int {
  (state * 1103515245 + 12345) % 2147483648
}

type Made = {word: Str, state: Int}

pure random_word(seed: Int, length: Int) -> Made {
  var state = seed
  var pieces: List[Str] = []
  for _ in range(length) {
    state = next_state(state)
    pieces += [alphabet[state / 65536 % alphabet.len()]]
  }

  Made(word: pieces.join(""), state:)
}

test random_hostile_words_round_trip_through_a_real_shell_as_single_arguments {
  var state = 20261103
  var words: List[Str] = []
  for index in range(150) {
    let made = random_word(state, index % 24)
    state = made.state
    words += [made.word]
  }

  let script = r"""printf '%s\0' "$@" """
  let command = shell.command(script, words)?
  let out = run.capture --bytes sh -c $command
  assert out.status.ok
  let expected = words |> map { |word| word + "\0" } |> collect()
  assert out.stdout.utf8()? == expected.join("")
}
