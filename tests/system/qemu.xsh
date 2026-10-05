##! Unit coverage for QEMU construction and QEMU proof marker handling.
use system.build
use system.proof
use system.qemu
use system.types

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
    qemu_smp: 2,
    qemu_memory: "1536M",
    qemu_width: 1280,
    qemu_height: 800,
    forbidden_packages: [],
    forbidden_sonames: [],
  }
}

proc fixture_qemu(os: Str, arch: Str) -> Result[qemu.QemuConfig] {
  let target = qemu.qemu_target(os, arch)?
  {qemu: fp"{target.qemu_name}", python: p"python3", qmp_helper: p"boot/qmp-proof.py", target}
}

proc command_pair(config: qemu.QemuConfig) [error] -> Result[List[List[Str]]] {
  let outputs = build.outputs(p"target/laputa/qemu-dwl-foot")
  [
    qemu.qemu_command_argv(config, fixture_profile(), outputs, types.Test),
    qemu.qemu_command_argv(config, fixture_profile(), outputs, types.Interactive),
  ]
}

proc assert_profile_devices(argv: List[Str]) {
  assert "virtio-net-pci,netdev=net0" in argv, "network"
  assert "virtio-gpu-pci,xres=1280,yres=800" in argv, "gpu"
  assert "virtio-keyboard-pci" in argv, "keyboard"
  assert "virtio-tablet-pci" in argv, "tablet"
  assert "virtio-mouse-pci" in argv, "mouse"
  assert "-qmp" in argv, "qmp"
  assert "-no-reboot" in argv, "no reboot"
  assert argv |> any "root=PARTUUID=33333333-3333-3333-3333-333333333333" in ., "root partuuid"
}

test test_qemu_command_on_macos_is_aarch64_under_hvf [error] {
  let config = fixture_qemu("Darwin", "aarch64")?
  let pair = command_pair(config)?

  for argv in pair {
    assert argv[0] == "qemu-system-aarch64"
    assert "virt,accel=hvf,highmem=off" in argv, "machine"
    assert "virtio-blk-device,drive=root" in argv, "root device"
    assert argv |> any "console=ttyAMA0" in ., "pl011 console"
    assert ! (argv |> any "x86_64" in .), "no other architecture"
    assert_profile_devices(argv)
  }

  assert "LAPUTA_QEMU_DWL_FOOT_PROOF=1" in qemu.kernel_cmdline(config.target, types.Test), "test proof flag"
  assert ! ("LAPUTA_QEMU_DWL_FOOT_PROOF=1" in qemu.kernel_cmdline(config.target, types.Interactive)), "interactive omits proof flag"
  assert "none" in pair[0], "headless test"
  assert "cocoa,zoom-to-fit=on,show-cursor=on" in pair[1], "cocoa interactive"
}

test test_qemu_command_on_linux_x86_64_is_q35_under_kvm [error] {
  let config = fixture_qemu("Linux", "x86_64")?
  let pair = command_pair(config)?

  for argv in pair {
    assert argv[0] == "qemu-system-x86_64"
    assert "q35,accel=kvm" in argv, "machine"
    assert argv |> any . == "-vga", "virtio-gpu is the only display"
    assert "host" in argv, "cpu"
    assert "virtio-blk-pci,drive=root" in argv, "root device"
    assert argv |> any "console=ttyS0" in ., "16550 console"
    assert ! (argv |> any "ttyAMA0" in .), "no PL011 console"
    assert_profile_devices(argv)
  }

  assert "none" in pair[0], "headless test"
  assert ! ("cocoa,zoom-to-fit=on,show-cursor=on" in pair[1]), "no cocoa on Linux"
}

test test_qemu_target_runs_on_linux_aarch64_under_kvm_and_rejects_other_hosts [error] {
  let target = qemu.qemu_target("Linux", "aarch64")?
  assert target.machine == "virt,accel=kvm"
  assert target.block_device == "virtio-blk-device"

  for host in [["Darwin", "x86_64"], ["FreeBSD", "x86_64"]] {
    match qemu.qemu_target(host[0], host[1]) {
      Ok(_) => test.fail(f"{host[0]} {host[1]} unexpectedly has a QEMU target")
      Err(_) => {}
    }
  }
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

proc supervisor_fixture(ctx: TestContext, final_failure: Bool) -> Result[SupervisorFixture] {
  let root = test.temp_dir(ctx, name: "qemu-supervisor")?
  let outputs = build.outputs(root)
  let bundle = fp"{outputs.builds}/fixture"
  bundle.mkdir()
  outputs.current.symlink(to: p"builds/fixture")
  let fake_qemu = fp"{root}/fake-qemu.sh"
  let fake_qmp = fp"{root}/fake-qmp.sh"
  let attempt_one = fp"{root}/qmp-attempt-one"
  let attempt_two = fp"{root}/qmp-attempt-two"
  let attempt_three = fp"{root}/qmp-attempt-three"
  let input_record = fp"{root}/input-record"
  let final_log = if final_failure { f"printf 'QEMU_FATAL after screenshot\\n' > '{outputs.qemu_log}'" } else { "" }

  outputs.kernel.write("kernel")
  outputs.disk.write("disk")

  # This fake QEMU ignores TERM, proving managed cancellation escalates to KILL.
  fake_qemu.write_lines(
    [
      "#!/bin/sh",
      "trap '' TERM",
      f"printf qmp > '{outputs.qmp_socket}'",
      "printf 'LAPUTA_DWL_FOOT_PROOF_READY\\n'",
      "while :; do sleep 1; done",
    ],
  )

  # The failed first call makes the side-effect-free QMP readiness check retry.
  # The third call is the one proof input; the fourth writes screenshot evidence.
  fake_qmp.write_lines(
    [
      "#!/bin/sh",
      f"if [ ! -e '{attempt_one}' ]; then : > '{attempt_one}'; exit 1; fi",
      f"if [ ! -e '{attempt_two}' ]; then : > '{attempt_two}'; exit 0; fi",
      f"if [ ! -e '{attempt_three}' ]; then : > '{attempt_three}'; printf 'LAPUTA_DWL_FOOT_PROOF_READY\\nLAPUTA_DWL_FOOT_PROOF_OK\\n' > '{outputs.console_log}'; printf 'laputa\\n' > '{input_record}'; exit 0; fi",
      f"printf 'P6\\n1 1\\n255\\nX' > '{outputs.screenshot}'",
      final_log,
      "exit 0",
    ],
  )
  fake_qemu.chmod(0o755)
  fake_qmp.chmod(0o755)
  {
    config: {
      qemu: fake_qemu,
      python: fake_qmp,
      qmp_helper: fp"{root}/qmp-helper.py",
      target: qemu.qemu_target("Linux", "x86_64")?,
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
  screenshot.write("")
  assert ! qemu.screenshot_is_valid(screenshot)?
  screenshot.write(
    """P6
1 1
255
X""",
  )
  assert qemu.screenshot_is_valid(screenshot)?
}

test test_qemu_supervisor_retries_qmp_injects_once_and_escalates_shutdown [fs, process, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx, false)?
  qemu.run_test(fixture.config, fixture_profile(), fixture.outputs)
  assert fixture.qmp_attempt_one.exists()?
  assert fixture.qmp_attempt_two.exists()?
  assert fixture.qmp_attempt_three.exists()?
  assert fixture.input_record.read_text()? == """laputa
"""
  assert qemu.screenshot_is_valid(fixture.outputs.screenshot)?
}

test test_qemu_supervisor_rescans_final_qemu_log_after_screenshot [fs, process, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx, true)?
  match qemu.run_test(fixture.config, fixture_profile(), fixture.outputs) {
    Ok(_) => test.fail("supervisor accepted QEMU fatal marker written with screenshot")
    Err(_) => {}
  }

  assert qemu.screenshot_is_valid(fixture.outputs.screenshot)?
}

test test_generation_overlay_binds_guest_proof_after_run_mount [fs, error] {
  let hook_metadata = p"profiles/qemu-dwl-foot/usr/lib/init/rc.d/laputa-qemu-dwl-foot.boot".metadata()?
  let hook = p"profiles/qemu-dwl-foot/usr/lib/init/rc.d/laputa-qemu-dwl-foot.boot".read_text()?
  let builder = p"system/container_build.xsh".read_text()?
  let guest = p"guest/qemu-dwl-foot-proof.xsh".read_text()?
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

# A QEMU that dies at startup (a missing device model, say) stays an unreaped
# child until the supervisor waits for it, so liveness must not count it. A
# supervisor that does would wait out its 180 s proof timeout, past xsht's
# per-test limit.
test test_qemu_supervisor_reports_qemu_that_exits_at_startup [fs, process, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx, false)?
  fixture.config.qemu.write("#!/bin/sh\necho 'qemu: device model missing' >&2\nexit 1\n")

  match qemu.run_test(fixture.config, fixture_profile(), fixture.outputs) {
    Ok(_) => test.fail("supervisor accepted a QEMU that exited at startup")
    Err(problem) => assert "QEMU exited before qemu-dwl-foot proof" in problem.message, problem.message
  }
}

test test_qmp_socket_fits_a_unix_socket_path_from_any_checkout_depth [error] {
  let deep = fp"/{["very-long-directory-name" for _ in range(12)].join("/")}/target/laputa/qemu-dwl-foot"
  let socket = build.outputs(deep).qmp_socket.display()
  assert socket.byte_len() < 108, socket
  assert build.outputs(deep).qmp_socket != build.outputs(/other/target/laputa/qemu-dwl-foot).qmp_socket
}
