##! Unit coverage for QEMU construction and QEMU proof marker handling.
use laputa.build as build
use laputa.proof as proof
use laputa.qemu as qemu
use laputa.types as types

pure fixture_profile() -> types.SystemProfile {
  {
    name: "qemu-dwl-foot",
    target: types.Aarch64LinuxMusl,
    package_roots: ["baselayout"],
    kernel_package: "linux",
    kernel_path: p"boot/vmlinuz",
    session: {compositor: p"/usr/bin/dwl", terminal: p"/usr/bin/foot", interactive_argv: ["dwl"], proof_argv: ["dwl"]},
    qemu: {machine: "virt,accel=hvf,highmem=off", cpu: "host", smp: 2, memory: "1536M", width: 1280, height: 800},
    proof: {success_markers: ["LAPUTA_DWL_FOOT_PROOF_OK"], failure_markers: ["Kernel panic", "LAPUTA_DWL_FOOT_PROOF_FAILED"], input_text: "laputa", screenshot_required: true},
    forbidden_packages: [],
    forbidden_sonames: [],
  }
}

pure fixture_qemu() -> qemu.QemuConfig {
  {qemu: p"qemu-system-aarch64", python: p"python3", qmp_helper: p"boot/qmp-proof.py"}
}

proc test_qemu_command_is_the_single_aarch64_hvf_contract() [error] {
  let argv = qemu.qemu_command_argv(fixture_qemu(), fixture_profile(), build.outputs(p"target/laputa/qemu-dwl-foot"), types.Test)
  test.ok("virt,accel=hvf,highmem=off" in argv)?
  test.ok("virtio-blk-device,drive=root" in argv)?
  test.ok("virtio-net-pci,netdev=net0" in argv)?
  test.ok("virtio-keyboard-pci" in argv)?
  test.ok("virtio-tablet-pci" in argv)?
  test.ok("virtio-mouse-pci" in argv)?
  test.ok("-no-reboot" in argv)?
  test.ok(argv |> any .contains("root=PARTUUID=33333333-3333-3333-3333-333333333333"))?
  test.ok(! (argv |> any .contains("x86_64")))?
}

proc test_console_markers_fail_before_success() [error] {
  let value = fixture_profile().proof
  test.eq(proof.failure_marker(value, "Kernel panic - not syncing"), "Kernel panic")?
  test.ok(! proof.succeeded(value, "booting"))?
  test.ok(proof.succeeded(value, "LAPUTA_DWL_FOOT_PROOF_OK"))?
  match proof.verify_console(value, "LAPUTA_DWL_FOOT_PROOF_FAILED input") {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
}
