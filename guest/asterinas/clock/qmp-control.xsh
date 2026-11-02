use system.qemu

cli main(socket: Path, control: Str) [fs, process, net, time, error] {
  guard control == "stop" or control == "cont" else { fail f"unknown QEMU control {control}" }
  qemu.qemu_control(socket, if control == "stop" { qemu.QemuStop } else { qemu.QemuContinue })?
}
