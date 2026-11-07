##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

const cues = """1
00:00:00,000 --> 00:00:01,500
Laputa proof

2
00:00:02,000 --> 00:00:03,000
Second cue
"""

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "ffmpeg")
  proof.target_elf(root, p"usr/bin/ffmpeg", "ffmpeg")
  proof.target_elf(root, p"usr/bin/ffprobe", "ffprobe")
  for library in ["libavcodec.so.63.1.102", "libavdevice.so.63.1.102", "libavformat.so.63.1.102", "libavfilter.so.12.1.102", "libavutil.so.61.1.102", "libswresample.so.7.1.102", "libswscale.so.10.1.102"] {
    proof.target_elf(root, fp"usr/lib/{library}", library)
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"ffmpeg ok: {pm_util.target_arch()?} binaries"
    return
  }

  let ffmpeg = fp"{root}/usr/bin/ffmpeg"
  let ffprobe = fp"{root}/usr/bin/ffprobe"
  let ffmpeg_version = run.text $ffmpeg "-hide_banner" "-version"
  proof.ensure(
    ffmpeg_version.lines()[0] == "ffmpeg version 9.0.2 Copyright (c) 2000-2026 the FFmpeg developers",
    "ffmpeg-version",
    f"unexpected ffmpeg -version: {ffmpeg_version.lines()[0]}",
  )
  let ffprobe_version = run.text $ffprobe "-hide_banner" "-version"
  proof.ensure(
    ffprobe_version.lines()[0] == "ffprobe version 9.0.2 Copyright (c) 2007-2026 the FFmpeg developers",
    "ffprobe-version",
    f"unexpected ffprobe -version: {ffprobe_version.lines()[0]}",
  )
  let protocols = run.text $ffmpeg "-hide_banner" "-protocols"
  proof.ensure(
    protocols == "Supported file protocols:\nInput:\n  fd\n  file\n  pipe\nOutput:\n  fd\n  file\n  pipe\n",
    "ffmpeg-local-protocols",
    f"unexpected ffmpeg -protocols:\n{protocols}",
  )

  tempdir tmp at fp"{root}/var/tmp/proof-ffmpeg" {
    let source = fp"{tmp}/cues.srt"
    let muxed = fp"{tmp}/cues.mp4"
    let restored = fp"{tmp}/restored.srt"
    source.write(cues)
    run $ffmpeg "-nostdin" "-hide_banner" "-loglevel" "error" "-i" $source "-c:s" "mov_text" $muxed
    let streams = run.text $ffprobe "-v" "error" "-show_entries" "stream=codec_type,codec_name" "-of" "compact" $muxed
    proof.ensure(
      streams == "stream|codec_name=mov_text|codec_type=subtitle\n",
      "ffprobe-mov-text",
      f"unexpected ffprobe streams: {streams}",
    )
    run $ffmpeg "-nostdin" "-hide_banner" "-loglevel" "error" "-i" $muxed "-c:s" "subrip" $restored
    let roundtrip = restored.read_text()?
    proof.ensure(roundtrip == f"{cues}\n", "ffmpeg-subtitle-roundtrip", f"unexpected restored cues:\n{roundtrip}")
    print "ffmpeg ok: ffmpeg/ffprobe 9.0.2, local protocols only, SubRip to mov_text MP4 and back"
  }
}
