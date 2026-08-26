##! Unit coverage for QEMU construction and QEMU proof marker handling.
use laputa.build as build
use laputa.proof as proof
use laputa.qemu as qemu
use laputa.types as types

type SupervisorFixture = {
  config: qemu.QemuConfig,
  outputs: build.ProfileOutputs,
  qmp_attempt_one: Path,
  qmp_attempt_two: Path,
  qmp_attempt_three: Path,
  input_record: Path,
}

pure fixture_profile() -> types.SystemProfile {
  {
    name: "qemu-dwl-foot",
    target: types.Aarch64LinuxMusl,
    package_roots: ["baselayout"],
    kernel_package: "linux",
    kernel_path: p"boot/vmlinuz",
    session: {compositor: p"/usr/bin/dwl", terminal: p"/usr/bin/foot", interactive_argv: ["dwl"], proof_argv: ["dwl"]},
    qemu: {machine: "virt,accel=hvf,highmem=off", cpu: "host", smp: 2, memory: "1536M", width: 1280, height: 800},
    proof: {
      success_markers: ["LAPUTA_DWL_FOOT_PROOF_OK"],
      failure_markers: [
        "Kernel panic",
        "not syncing",
        "Attempted to kill init",
        "Insufficient stack space",
        "LAPUTA_DWL_FOOT_PROOF_FAILED",
        "QEMU_FATAL",
      ],
      input_text: "laputa",
      screenshot_required: true,
    },
    forbidden_packages: [],
    forbidden_sonames: [],
  }
}

pure fixture_qemu() -> qemu.QemuConfig {
  {qemu: p"qemu-system-aarch64", python: p"python3", qmp_helper: p"boot/qmp-proof.py"}
}

proc test_qemu_command_is_the_single_aarch64_hvf_contract() [error] {
  let test_argv = qemu.qemu_command_argv(fixture_qemu(), fixture_profile(), build.outputs(p"target/laputa/qemu-dwl-foot"), types.Test)
  let interactive_argv = qemu.qemu_command_argv(fixture_qemu(), fixture_profile(), build.outputs(p"target/laputa/qemu-dwl-foot"), types.Interactive)

  for argv in [test_argv, interactive_argv] {
    test.ok("virt,accel=hvf,highmem=off" in argv, "machine")?
    test.ok("virtio-blk-device,drive=root" in argv, "root device")?
    test.ok("virtio-net-pci,netdev=net0" in argv, "network")?
    test.ok("virtio-gpu-pci,xres=1280,yres=800" in argv, "gpu")?
    test.ok("virtio-keyboard-pci" in argv, "keyboard")?
    test.ok("virtio-tablet-pci" in argv, "tablet")?
    test.ok("virtio-mouse-pci" in argv, "mouse")?
    test.ok("-qmp" in argv, "qmp")?
    test.ok("-no-reboot" in argv, "no reboot")?
    test.ok(argv |> any .contains("root=PARTUUID=33333333-3333-3333-3333-333333333333"), "root partuuid")?
    test.ok(! (argv |> any .contains("x86_64")), "no host architecture")?
  }

  test.ok("LAPUTA_QEMU_DWL_FOOT_PROOF=1" in qemu.kernel_cmdline(types.Test), "test proof flag")?
  test.ok(! ("LAPUTA_QEMU_DWL_FOOT_PROOF=1" in qemu.kernel_cmdline(types.Interactive)), "interactive omits proof flag")?
  test.ok("none" in test_argv, "headless test")?
  test.ok("cocoa,zoom-to-fit=on,show-cursor=on" in interactive_argv, "cocoa interactive")?
}

proc test_console_markers_fail_before_success() [error] {
  let value = fixture_profile().proof
  for marker in value.failure_markers {
    test.eq(proof.failure_marker(value, f"before ${marker} after"), marker)?
  }
  test.ok(! proof.succeeded(value, "booting"))?
  test.ok(proof.succeeded(value, "LAPUTA_DWL_FOOT_PROOF_OK"))?
  match proof.verify_console(value, "LAPUTA_DWL_FOOT_PROOF_FAILED input") {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
  match proof.verify_console(value, "LAPUTA_DWL_FOOT_PROOF_OK\nQEMU_FATAL after success") {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
}

proc supervisor_fixture(ctx: TestContext, final_failure: Bool) [fs, error] -> Result[SupervisorFixture] {
  let root = test.temp_dir(ctx, name: "qemu-supervisor")?
  let outputs = build.outputs(root)
  let fake_qemu = fp"${root}/fake-qemu.sh"
  let fake_qmp = fp"${root}/fake-qmp.sh"
  let attempt_one = fp"${root}/qmp-attempt-one"
  let attempt_two = fp"${root}/qmp-attempt-two"
  let attempt_three = fp"${root}/qmp-attempt-three"
  let input_record = fp"${root}/input-record"
  let final_log = if final_failure { f"printf 'QEMU_FATAL after screenshot\\n' > '${outputs.qemu_log}'" } else { "" }

  fs.write(outputs.kernel, "kernel")?
  fs.write(outputs.disk, "disk")?
  # This fake QEMU ignores TERM, proving managed cancellation escalates to KILL.
  fs.write(
    fake_qemu,
    [
      "#!/bin/sh",
      "trap '' TERM",
      f"printf qmp > '${outputs.qmp_socket}'",
      "printf 'LAPUTA_DWL_FOOT_PROOF_READY\\n'",
      "while :; do sleep 1; done",
    ].join("\n") + "\n",
  )?
  # The failed first call makes the side-effect-free QMP readiness check retry.
  # The third call is the one proof input; the fourth writes screenshot evidence.
  fs.write(
    fake_qmp,
    [
      "#!/bin/sh",
      f"if [ ! -e '${attempt_one}' ]; then : > '${attempt_one}'; exit 1; fi",
      f"if [ ! -e '${attempt_two}' ]; then : > '${attempt_two}'; exit 0; fi",
      f"if [ ! -e '${attempt_three}' ]; then : > '${attempt_three}'; printf 'LAPUTA_DWL_FOOT_PROOF_READY\\nLAPUTA_DWL_FOOT_PROOF_OK\\n' > '${outputs.console_log}'; printf 'laputa\\n' > '${input_record}'; exit 0; fi",
      f"printf 'P6\\n1 1\\n255\\nX' > '${outputs.screenshot}'",
      final_log,
      "exit 0",
    ].join("\n") + "\n",
  )?
  fs.chmod(fake_qemu, 0o755)?
  fs.chmod(fake_qmp, 0o755)?
  {
    config: {qemu: fake_qemu, python: fake_qmp, qmp_helper: fp"${root}/qmp-helper.py"},
    outputs,
    qmp_attempt_one: attempt_one,
    qmp_attempt_two: attempt_two,
    qmp_attempt_three: attempt_three,
    input_record,
  }
}

proc test_screenshot_evidence_must_be_nonempty(ctx: TestContext) [fs, error] {
  let root = test.temp_dir(ctx, name: "qemu-screenshot")?
  let screenshot = fp"${root}/screenshot.ppm"
  fs.write(screenshot, "")?
  test.ok(! qemu.screenshot_is_valid(screenshot)?)?
  fs.write(screenshot, "P6\n1 1\n255\nX")?
  test.ok(qemu.screenshot_is_valid(screenshot)?)?
}

proc test_qemu_supervisor_retries_qmp_injects_once_and_escalates_shutdown(ctx: TestContext) [fs, process, time, error] {
  let fixture = supervisor_fixture(ctx, false)?
  qemu.run_test(fixture.config, fixture_profile(), fixture.outputs)?
  test.ok(fs.exists(fixture.qmp_attempt_one)?)?
  test.ok(fs.exists(fixture.qmp_attempt_two)?)?
  test.ok(fs.exists(fixture.qmp_attempt_three)?)?
  test.eq(fs.read_text(fixture.input_record)?, "laputa\n")?
  test.ok(qemu.screenshot_is_valid(fixture.outputs.screenshot)?)?
}

proc test_qemu_supervisor_rescans_final_qemu_log_after_screenshot(ctx: TestContext) [fs, process, time, error] {
  let fixture = supervisor_fixture(ctx, true)?
  match qemu.run_test(fixture.config, fixture_profile(), fixture.outputs) {
    Ok(_) => test.fail("supervisor accepted QEMU fatal marker written with screenshot")?
    Err(_) => {}
  }
  test.ok(qemu.screenshot_is_valid(fixture.outputs.screenshot)?)?
}

proc test_generation_overlay_binds_guest_proof_after_run_mount() [fs, error] {
  let hook_metadata = fs.metadata(p"profiles/qemu-dwl-foot/usr/lib/init/rc.d/laputa-qemu-dwl-foot.boot")?
  let hook = fs.read_text(p"profiles/qemu-dwl-foot/usr/lib/init/rc.d/laputa-qemu-dwl-foot.boot")?
  let builder = fs.read_text(p"laputa/container_build.xsh")?
  let guest = fs.read_text(p"guest/qemu-dwl-foot-proof.xsh")?
  test.eq(hook_metadata.mode % 4096, 0o755)?
  test.ok("/usr/lib/laputa/qemu-dwl-foot-proof.xsh" in hook)?
  test.ok(guest.starts_with("#!/bin/xsh\n"))?
  test.ok("fs.install(source, target, 0o755" in hook)?
  test.ok("container_prepare_overlay" in builder)?
  test.ok("fs.install(guest_proof" in builder)?
  test.ok(! ("process.which(" in guest))?
  test.ok("/usr/bin/mdevd," in guest)?
  test.ok("/usr/bin/mdevd-coldplug" in guest)?
  test.ok("/usr/bin/seatd" in guest)?
  test.ok("SEATD_VTBOUND: \"0\"" in guest)?
  test.ok("SEATD_VTBOUND: \"0\"" in hook)?
  test.ok("/usr/bin/dwl," in guest)?
  test.ok("/usr/bin/foot -- /bin/xsh" in guest)?
  test.ok("io.stdin_text()?" in guest)?
  test.ok(! ("io.stdin().read_to_end()" in guest))?
  test.ok("mdevd-coldplug" in guest)?
  test.ok("seatd" in guest and "dwl" in guest and "foot" in guest)?
  test.ok("guest_wait_for(p\"/run/laputa-foot-read-ready\", \"foot\", 30)" in guest)?
  test.ok("guest_console(\"LAPUTA_DWL_FOOT_PROOF_READY\")" in guest)?
}
