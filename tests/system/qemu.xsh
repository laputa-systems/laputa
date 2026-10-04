##! Unit coverage for QEMU construction and QEMU proof marker handling.
use system.build as build
use system.proof as proof
use system.qemu as qemu
use system.types as types

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
    package_roots: [
      "baselayout",
    ],
    kernel_package: "linux",
    kernel_path: p"boot/vmlinuz",
    qemu_machine: "virt,accel=hvf,highmem=off",
    qemu_cpu: "host",
    qemu_smp: 2,
    qemu_memory: "1536M",
    qemu_width: 1280,
    qemu_height: 800,
    forbidden_packages: [],
    forbidden_sonames: [],
  }
}

pure fixture_qemu() -> qemu.QemuConfig {
  {qemu: p"qemu-system-aarch64", python: p"python3", qmp_helper: p"boot/qmp-proof.py"}
}

test test_qemu_command_is_the_single_aarch64_hvf_contract [error] {
  let test_argv = qemu.qemu_command_argv(
    fixture_qemu(),
    fixture_profile(),
    build.outputs(p"target/laputa/qemu-dwl-foot"),
    types.Test,
  )
  let interactive_argv = qemu.qemu_command_argv(
    fixture_qemu(),
    fixture_profile(),
    build.outputs(p"target/laputa/qemu-dwl-foot"),
    types.Interactive,
  )

  for argv in [test_argv, interactive_argv] {
    assert "virt,accel=hvf,highmem=off" in argv, "machine"
    assert "virtio-blk-device,drive=root" in argv, "root device"
    assert "virtio-net-pci,netdev=net0" in argv, "network"
    assert "virtio-gpu-pci,xres=1280,yres=800" in argv, "gpu"
    assert "virtio-keyboard-pci" in argv, "keyboard"
    assert "virtio-tablet-pci" in argv, "tablet"
    assert "virtio-mouse-pci" in argv, "mouse"
    assert "-qmp" in argv, "qmp"
    assert "-no-reboot" in argv, "no reboot"
    assert argv |> any "root=PARTUUID=33333333-3333-3333-3333-333333333333" in ., "root partuuid"
    assert ! (argv |> any "x86_64" in .), "no host architecture"
  }

  assert "LAPUTA_QEMU_DWL_FOOT_PROOF=1" in qemu.kernel_cmdline(types.Test), "test proof flag"
  assert ! ("LAPUTA_QEMU_DWL_FOOT_PROOF=1" in qemu.kernel_cmdline(types.Interactive)), "interactive omits proof flag"
  assert "none" in test_argv, "headless test"
  assert "cocoa,zoom-to-fit=on,show-cursor=on" in interactive_argv, "cocoa interactive"
}

test test_console_markers_fail_before_success [error] {
  for marker in proof.failure_markers {
    assert proof.failure_marker(f"before {marker} after") == marker
  }

  assert ! proof.succeeded("booting")
  assert proof.succeeded(proof.success_marker)
  match proof.verify_console("LAPUTA_DWL_FOOT_PROOF_FAILED input") {
    Ok(_) => assert false
    Err(_) => {}
  }

  match proof.verify_console(f"""{proof.success_marker}
QEMU_FATAL after success""") {
    Ok(_) => assert false
    Err(_) => {}
  }
}

proc supervisor_fixture(ctx: TestContext, final_failure: Bool) [fs, error] -> Result[SupervisorFixture] {
  let root = test.temp_dir(ctx, name: "qemu-supervisor")?
  let outputs = build.outputs(root)
  let bundle = fp"{outputs.builds}/fixture"
  fs.mkdir(bundle)?
  fs.symlink(p"builds/fixture", outputs.current)?
  let fake_qemu = fp"{root}/fake-qemu.sh"
  let fake_qmp = fp"{root}/fake-qmp.sh"
  let attempt_one = fp"{root}/qmp-attempt-one"
  let attempt_two = fp"{root}/qmp-attempt-two"
  let attempt_three = fp"{root}/qmp-attempt-three"
  let input_record = fp"{root}/input-record"
  let final_log = if final_failure { f"printf 'QEMU_FATAL after screenshot\\n' > '{outputs.qemu_log}'" } else { "" }

  fs.write(outputs.kernel, "kernel")?
  fs.write(outputs.disk, "disk")?

  # This fake QEMU ignores TERM, proving managed cancellation escalates to KILL.
  fs.write(
    fake_qemu,
    [
      "#!/bin/sh",
      "trap '' TERM",
      f"printf qmp > '{outputs.qmp_socket}'",
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
      f"if [ ! -e '{attempt_one}' ]; then : > '{attempt_one}'; exit 1; fi",
      f"if [ ! -e '{attempt_two}' ]; then : > '{attempt_two}'; exit 0; fi",
      f"if [ ! -e '{attempt_three}' ]; then : > '{attempt_three}'; printf 'LAPUTA_DWL_FOOT_PROOF_READY\\nLAPUTA_DWL_FOOT_PROOF_OK\\n' > '{outputs.console_log}'; printf 'laputa\\n' > '{input_record}'; exit 0; fi",
      f"printf 'P6\\n1 1\\n255\\nX' > '{outputs.screenshot}'",
      final_log,
      "exit 0",
    ].join("\n") + "\n",
  )?
  fs.chmod(fake_qemu, 0o755)?
  fs.chmod(fake_qmp, 0o755)?
  {
    config: {
      qemu: fake_qemu,
      python: fake_qmp,
      qmp_helper: fp"{root}/qmp-helper.py",
    },
    outputs,
    qmp_attempt_one: attempt_one,
    qmp_attempt_two: attempt_two,
    qmp_attempt_three: attempt_three,
    input_record,
  }
}

test test_screenshot_evidence_must_be_nonempty [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "qemu-screenshot")?
  let screenshot = fp"{root}/screenshot.ppm"
  fs.write(screenshot, "")?
  assert ! qemu.screenshot_is_valid(screenshot)?
  fs.write(
    screenshot,
    """P6
1 1
255
X""",
  )?
  assert qemu.screenshot_is_valid(screenshot)?
}

test test_qemu_supervisor_retries_qmp_injects_once_and_escalates_shutdown [fs, process, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx, false)?
  qemu.run_test(fixture.config, fixture_profile(), fixture.outputs)?
  assert fs.exists(fixture.qmp_attempt_one)?
  assert fs.exists(fixture.qmp_attempt_two)?
  assert fs.exists(fixture.qmp_attempt_three)?
  assert fs.read_text(fixture.input_record)? == """laputa
"""
  assert qemu.screenshot_is_valid(fixture.outputs.screenshot)?
}

test test_qemu_supervisor_rescans_final_qemu_log_after_screenshot [fs, process, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx, true)?
  match qemu.run_test(fixture.config, fixture_profile(), fixture.outputs) {
    Ok(_) => test.fail("supervisor accepted QEMU fatal marker written with screenshot")?
    Err(_) => {}
  }

  assert qemu.screenshot_is_valid(fixture.outputs.screenshot)?
}

test test_generation_overlay_binds_guest_proof_after_run_mount [fs, error] {
  let hook_metadata = fs.metadata(p"profiles/qemu-dwl-foot/usr/lib/init/rc.d/laputa-qemu-dwl-foot.boot")?
  let hook = fs.read_text(p"profiles/qemu-dwl-foot/usr/lib/init/rc.d/laputa-qemu-dwl-foot.boot")?
  let builder = fs.read_text(p"system/container_build.xsh")?
  let guest = fs.read_text(p"guest/qemu-dwl-foot-proof.xsh")?
  assert hook_metadata.mode % 4096 == 0o755
  assert "/usr/lib/laputa/qemu-dwl-foot-proof.xsh" in hook
  assert guest.starts_with("""#!/bin/xsh
""")
  assert "fs.install(source, target, 0o755" in hook
  assert "container_prepare_overlay" in builder
  assert "fs.install(guest_proof" in builder
  assert ! ("process.which(" in guest)
  assert "/usr/bin/mdevd," in guest
  assert "/usr/bin/mdevd-coldplug" in guest
  assert "/usr/bin/seatd" in guest
  assert "SEATD_VTBOUND: \"0\"" in guest
  assert "SEATD_VTBOUND: \"0\"" in hook
  assert "/usr/bin/dwl," in guest
  assert "/usr/bin/foot -- /bin/xsh" in guest
  assert "io.stdin_text()?" in guest
  assert ! ("io.stdin().read_to_end()" in guest)
  assert "mdevd-coldplug" in guest
  assert "seatd" in guest and "dwl" in guest and "foot" in guest
  assert "guest_wait_for(/run/laputa-foot-read-ready, \"foot\", 30)" in guest
  assert "guest_console(\"LAPUTA_DWL_FOOT_PROOF_READY\")" in guest
}
