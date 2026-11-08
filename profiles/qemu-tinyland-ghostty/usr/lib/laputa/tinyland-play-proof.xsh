#!/bin/xsh
##! Play gpu-next proof for qemu-tinyland-ghostty. Runs as laputa against the
##! live tinyland session: the packaged FFmpeg writes a PNG-in-Matroska test
##! pattern, then Play renders it through Vulkan (lavapipe) and Wayland and
##! exits at end of file. The outer guest proof owns the markers.
error PlayProofError = Failed(phase: Str, message: Str)

const fixture_frames = 10

proc require(condition: Bool, phase: Str, message: Str) [error] {
  return when condition
  Err(PlayProofError.Failed(phase:, message:))?
}

proc main() [fs, process, env, error] {
  let account = user.lookup("laputa")?
  let identity = unix.id()?
  require(identity.uid == account.uid, "play-identity", "Play proof is not running as laputa")?
  let runtime = fp"/run/user/{account.uid}"
  let icds = [entry.name for entry in fs.children(p"/usr/share/vulkan/icd.d")?]
  require(icds == ["lvp_icd.json"], "play-icd", f"expected only the lavapipe ICD, found {icds.join(" ")}")?

  let fixture = fp"{runtime}/laputa-play-fixture.mkv"
  fixture.remove()?
  let ffmpeg = p"/usr/bin/ffmpeg"
  run $ffmpeg "-hide_banner" "-loglevel" "error" "-filter_complex" "testsrc2=size=320x240:rate=10,format=rgb24" "-frames:v" f"{fixture_frames}" "-c:v" "png" $fixture

  let player = p"/usr/bin/player"
  let played = env ({
    XDG_RUNTIME_DIR: runtime.display(),
    WAYLAND_DISPLAY: "wayland-0",
    VK_LOADER_DEBUG: "driver",
  }) {
    run.capture --text --timeout=60s $player "--no-config" "--vo=gpu-next" "--gpu-context=waylandvk" "--gpu-sw=yes" "--ao=null" "--hwdec=no" "--keep-open=no" "--msg-level=all=info,vo=v" "--term-playing-msg=PLAY_FIXTURE \${width}x\${height} \${video-codec}" $fixture
  }?
  fixture.remove()?
  p"/dev/console".write(f"{played.stdout}{played.stderr}")?
  require(played.status.ok, "play-exit", f"player failed: {played.stderr.trim()}")?
  let log = f"{played.stdout}{played.stderr}"

  require("libvulkan_lvp.so" in log, "play-driver", "the Vulkan loader did not load lavapipe")?
  require("libplacebo: GPU 0: Vulkan device" in log, "play-vulkan", "Play created no Vulkan device")?
  require("vo/gpu-next/wayland: Registered output" in log, "play-wayland", "Play registered no Wayland output")?
  require("PLAY_FIXTURE 320x240 png" in log, "play-fixture", "Play did not load the fixture")?
}

main()
