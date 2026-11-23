#!/bin/xsh
##! Play session client for the qemu-tinyland-venus proof: a solid
##! magenta clip held on its last frame, rendered through the Vulkan device the loader selects. It
##! signals readiness once Play has created that device. Runs as laputa inside
##! tinyland.
const magenta_frame_png = "iVBORw0KGgoAAAANSUhEUgAAAUAAAADwCAIAAAD+Tyo8AAACDElEQVR42u3TQQkAAAwDsfo33XnobxCIgoNLU+CpSAAGBgwMGBgMDBgYMDBgYDAwYGDAwGBgwMCAgQEDg4EBAwMGBgwMBgYMDBgYDAwYGDAwYGAwMGBgwMCAgcHAgIEBA4OBAQMDBgYMDAYGDAwYGAysAhgYMDBgYDAwYGDAwICBwcCAgQEDg4EBAwMGBgwMBgYMDBgYMDAYGDAwYGAwMGBgwMCAgcHAgIEBAwMGBgMDBgYMDAYGDAwYGDAwGBgwMGBgMDBgYMDAgIHBwICBAQMDBgYDAwYGDAwGBgwMGBgwMBgYMDBgYMDAYGDAwICBwcCAgQEDAwYGAwMGBgwMGBgMDBgYMDAYGDAwYGDAwGBgwMCAgcHAgIEBAwMGBgMDBgYMDBgYDAwYGDAwGBgwMGBgwMBgYMDAgIEBA4OBAQMDBgYDAwYGDAwYGAwMGBgwMBhYBTAwYGDAwGBgwMCAgQEDg4EBAwMGBgMDBgYMDBgYDAwYGDAwYGAwMGBgwMBgYMDAgIEBA4OBAQMDBgYMDAYGDAwYGAwMGBgwMGBgMDBgYMDAYGDAwICBAQODgQEDAwYGDAwGBgwMGBgMDBgYMDBgYDAwYGDAwICBwcCAgQEDg4EBAwMGBgwMBgYMDBgYMDAYGDAwYGAwMGBgwMCAgcHAgIEBA4OBAQMDBgYMDAYGDAwYGDAwGBgwMLA7z5TK/KyI6GoAAAAASUVORK5CYII="

proc main() [fs, process, env, time, error] {
  let account = user.lookup("laputa")?
  let runtime = fp"/run/user/{account.uid}"
  let log = fp"{runtime}/laputa-play-session.log"
  let clip = fp"{runtime}/laputa-play-session.mkv"
  log.remove()
  clip.remove()
  let frame = fp"{runtime}/laputa-play-session.png"
  frame.write(magenta_frame_png.base64_decode()?)
  let ffmpeg = p"/usr/bin/ffmpeg"
  run $ffmpeg "-hide_banner" "-loglevel" "error" "-loop" "1" "-framerate" "1" "-i" $frame "-frames:v" "3" "-c:v" "png" $clip
  frame.remove()
  let player = spawn process.command_argv(
    p"/usr/bin/player",
    ["player", "--no-config", "--keep-open=yes", "--vo=gpu-next", "--gpu-context=waylandvk", "--ao=null", "--hwdec=no", "--input-default-bindings=no", "--msg-level=all=info,vo=v", clip],
    stdout: log,
    stderr: log,
    env: {XDG_RUNTIME_DIR: runtime, WAYLAND_DISPLAY: "wayland-0", VK_LOADER_DEBUG: "driver", MESA_VK_WSI_DEBUG: "sw"},
  )?
  var waited = 0
  while ! log.exists() or ! ("libplacebo: GPU 0: Vulkan device" in log.read_text()?) {
    if waited >= 120 {
      p"/dev/console".write(f"LAPUTA_TINYLAND_PLAY_LOG {log.read_text()?}\n")
      fail "Play created no Vulkan device"
    }
    time.sleep(500ms)
    waited += 1
  }
  fp"{runtime}/laputa-play-ready".write(e"LAPUTA_SESSION_ID" ?? "")
  let _ = wait player
}

main()
