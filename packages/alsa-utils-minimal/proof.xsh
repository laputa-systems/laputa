##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

# A 16-frame 8 kHz mono S16_LE WAVE file: RIFF size 68, a 16-byte PCM fmt
# chunk (byte rate 16000, block align 2), and a 32-byte square-wave data chunk.
const square_wav = b"RIFF\x44\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x80\x3e\x00\x00\x02\x00\x10\x00data\x20\x00\x00\x00\x00\x10\x00\x10\x00\x10\x00\x10\x00\xf0\x00\xf0\x00\xf0\x00\xf0\x00\x10\x00\x10\x00\x10\x00\x10\x00\xf0\x00\xf0\x00\xf0\x00\xf0"

const kind = "proof-alsa-utils-minimal"

type ToolRun = {code: Int, stdout: Str, stderr: Str}

proc tool(root: Path, name: Str, args: List[Str]) [fs, process, env, error] -> Result[ToolRun] {
  let os = system.uname()?
  let loader = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let program = fp"{root}/usr/bin/{name}"

  # The proof root's libasound reads the proof root's configuration tree.
  let result = env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib".display(),
    ALSA_CONFIG_DIR: fp"{root}/usr/share/alsa".display(),
  }) {
    run.capture --text $loader $program @args ?
  }?

  {code: result.status.exit_code()?, stdout: result.stdout, stderr: result.stderr}
}

proc expect_ok(root: Path, name: Str, args: List[Str]) -> Result[ToolRun] {
  let result = tool(root, name, args)?
  proof.ensure(result.code == 0, kind, f"{name} {args.join(" ")} exited {result.code}: {result.stderr.trim()}")
  result
}

proc expect_failure(root: Path, name: Str, args: List[Str], code: Int, message: Str) {
  let result = tool(root, name, args)?
  proof.ensure(result.code == code, kind, f"{name} {args.join(" ")} exited {result.code}, expected {code}: {result.stderr.trim()}")
  proof.ensure(result.stderr.trim() == message, kind, f"{name} {args.join(" ")} reported: {result.stderr.trim()}")
}

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "alsa-utils-minimal")

  for name in ["aplay", "amixer", "alsactl", "alsaucm", "speaker-test"] {
    proof.target_elf(root, fp"usr/bin/{name}", "alsa-utils-minimal")
  }

  proof.ensure(fs.exists(fp"{root}/usr/share/alsa/init/00main")?, kind, "missing alsactl init database")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"alsa-utils-minimal ok: cross-built {pm_util.target_arch()?}"
    return
  }

  # The no-card failures below are the behavior of a machine without sound
  # hardware; a build container that passed /dev/snd through would change them.
  proof.ensure(! fs.exists(p"/dev/snd")?, kind, "the proof host exposes /dev/snd; the no-card checks need a host without sound devices")

  let aplay = expect_ok(root, "aplay", ["--version"])?
  proof.ensure(aplay.stdout.trim() == "aplay: version 1.2.16 by Jaroslav Kysela <perex@perex.cz>", kind, f"unexpected aplay version: {aplay.stdout.trim()}")
  let amixer = expect_ok(root, "amixer", ["--version"])?
  proof.ensure(amixer.stdout.trim() == "amixer version 1.2.16", kind, f"unexpected amixer version: {amixer.stdout.trim()}")
  let alsactl = expect_ok(root, "alsactl", ["--version"])?
  proof.ensure(alsactl.stdout.trim() == "alsactl version 1.2.16", kind, f"unexpected alsactl version: {alsactl.stdout.trim()}")
  let alsaucm = expect_ok(root, "alsaucm", ["--version"])?
  proof.ensure(alsaucm.stdout.trim().ends_with(": version 1.2.16"), kind, f"unexpected alsaucm version: {alsaucm.stdout.trim()}")

  let tmp = fp"{root}/var/tmp/proof-alsa-utils-minimal"
  fs.remove(tmp, missing_ok: true)
  fs.mkdir(tmp, true)
  defer fs.remove(tmp, missing_ok: true)?

  # Playback of a WAVE file through the null PCM parses the header and
  # configures the stream from it.
  let wav = fp"{tmp}/square.wav"
  fs.write(wav, square_wav)
  let played = expect_ok(root, "aplay", ["-D", "null", wav.display()])?
  let playing = f"Playing WAVE '{wav}' : Signed 16 bit Little Endian, Rate 8000 Hz, Mono"
  proof.ensure(played.stderr.trim() == playing, kind, f"unexpected aplay report: {played.stderr.trim()}")

  # One second of 8 kHz mono S16 capture from the null PCM is 16000 data
  # bytes behind a 44-byte WAVE header, and aplay plays it back.
  let recorded = fp"{tmp}/capture.wav"
  let capture = expect_ok(root, "arecord", ["-D", "null", "-d", "1", "-f", "S16_LE", "-r", "8000", "-c", "1", "-t", "wav", recorded.display()])?
  proof.ensure(capture.stderr.trim() == f"Recording WAVE '{recorded}' : Signed 16 bit Little Endian, Rate 8000 Hz, Mono", kind, f"unexpected arecord report: {capture.stderr.trim()}")
  let wave = recorded.read_bytes()?
  proof.ensure(wave.len() == 16044, kind, f"arecord wrote {wave.len()} bytes, expected 16044")
  proof.ensure(wave[0..4] == b"RIFF" and wave[8..16] == b"WAVEfmt " and wave[36..40] == b"data", kind, "arecord did not write a WAVE header")
  let _ = expect_ok(root, "aplay", ["-D", "null", "-q", recorded.display()])?

  let tone = expect_ok(root, "speaker-test", ["-D", "null", "-c", "2", "-l", "1", "-t", "sine", "-r", "8000"])?
  proof.ensure("Playback device is null" in tone.stdout and "Rate set to 8000Hz (requested 8000Hz)" in tone.stdout, kind, f"unexpected speaker-test output: {tone.stdout.trim()}")

  # Without a card, mixer and UCM clients fail at card lookup.
  expect_failure(root, "amixer", ["-c", "0", "scontrols"], 1, "Invalid card number '0'.")
  let ucm = tool(root, "alsaucm", ["-c", "hw:0", "list", "_verbs"])?
  proof.ensure(ucm.code == 1, kind, f"alsaucm on a missing card exited {ucm.code}")
  proof.ensure("error failed to open sound card hw:0: No such file or directory" in ucm.stderr, kind, f"unexpected alsaucm failure: {ucm.stderr.trim()}")

  # alsactl over every card succeeds with nothing to save or restore and
  # leaves an empty state file; naming card 0 fails with its lookup error.
  let state = fp"{tmp}/asound.state"
  let _ = expect_ok(root, "alsactl", ["-f", state.display(), "store"])?
  proof.ensure(state.read_text()? == "", kind, "alsactl store with no cards wrote state")
  let _ = expect_ok(root, "alsactl", ["-f", state.display(), "restore"])?
  let missing_card = f"{root}/usr/bin/alsactl: snd_card_iterator_sinit:281: Cannot find soundcard '0'..."
  expect_failure(root, "alsactl", ["-f", state.display(), "store", "0"], 2, missing_card)
  expect_failure(root, "alsactl", ["-f", state.display(), "restore", "0"], 2, missing_card)

  print "alsa-utils-minimal ok: WAVE playback and capture and speaker-test on the null PCM, no-card amixer, alsaucm, and alsactl store/restore errors"
}

main(@args)
