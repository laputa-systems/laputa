use profiles.qemu-tinyland-ghostty as tinyland
use system.build
use system.qemu
use system.types

proc main(image: Path) [fs, process, env, error] {
  let config = qemu.qemu_config(qemu.host_qemu_target()?)?
  let outputs = build.outputs(p".")
  let selected = {...outputs, disk: fp"{image}/disk.img", kernel: fp"{image}/vmlinuz", qmp_socket: p"qmp.sock"}
  print json.encode(qemu.qemu_command_argv(config, tinyland.profile, selected, types.Test))?
}
