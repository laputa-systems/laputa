##! XSH module `proof` package and build operations.
use pm.proof

pure le(value: Int, width: Int) -> List[Int] {
  var rest = value
  var octets: List[Int] = []
  for _ in range(width) {
    octets += [rest % 256]
    rest = rest / 256
  }
  octets
}

proc square_wave_wav(wav: Path) [fs, error] {
  let rate = 8000
  let frames = rate / 2
  var samples: List[Int] = []
  for frame in range(frames) {
    let level = if frame / 20 % 2 == 0 { 8000 } else { 65536 - 8000 }
    samples += le(level, 2)
  }
  var header = [82, 73, 70, 70] + le(36 + samples.len(), 4) + [87, 65, 86, 69]
  header += [102, 109, 116, 32] + le(16, 4) + le(1, 2) + le(1, 2)
  header += le(rate, 4) + le(rate * 2, 4) + le(2, 2) + le(16, 2)
  header += [100, 97, 116, 97] + le(samples.len(), 4)
  let _ = bytes.write_at(wav, 0, bytes.from_ints(header + samples)?, create: true)?
}

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "play")
  proof.target_elf(root, p"usr/bin/player", "play")
  let needed = elf.inspect(fp"{root}/usr/bin/player")?.needed
  let listed = needed.join(" ")
  proof.ensure("libgcc_s.so.1" not in needed, "player-gnu-runtime", f"player still needs libgcc_s.so.1: {listed}")

  let player = fp"{root}/usr/bin/player"
  env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display()}) {
    let version = run.text $player "--version"
    proof.ensure(version.trim() == "player mpv-compatible 0.43.1", "player-version", f"unexpected player --version: {version.trim()}")

    tempdir tmp at fp"{root}/var/tmp/proof-play" {
      let tone = fp"{tmp}/tone.wav"
      square_wave_wav(tone)?
      let played = run.text $player "--no-config" "--vo=null" "--ao=null" "--term-playing-msg=duration=\${duration}" $tone
      proof.ensure("duration=0.5\n" in played, "player-wav-playback", f"unexpected playback output:\n{played}")
    }
  }?
  print "play ok: player 0.43.1 links Laputa's libraries and plays a WAV headlessly"
}
