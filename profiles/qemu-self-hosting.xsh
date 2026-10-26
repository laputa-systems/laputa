##! The Linux x86_64 headless self-hosting proof profile.
use system.types

## Runtime packages for a serial-only guest with separately declared build inputs.
export let profile: types.SystemProfile = types.SystemProfile(
  name: "qemu-self-hosting",
  package_roots: ["baselayout", "xsh", "laputa-pm", "xinit"],
  kernel_package: "linux",
  kernel_path: p"boot/vmlinuz",
  qemu_smp: 2,
  qemu_memory: "12G",
  qemu_width: 640,
  qemu_height: 480,
  forbidden_packages: [],
  forbidden_sonames: [],
)
