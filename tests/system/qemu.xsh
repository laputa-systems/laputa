##! Unit coverage for QEMU construction and QEMU proof marker handling.
use system.build
use system.proof
use system.qemu
use system.types

type SupervisorFixture = {
  config: qemu.QemuConfig,
  outputs: build.ProfileOutputs,
  qemu_pid: Path,
}

pure fixture_proof() -> types.ProofMarkers {
  {
    cmdline_flag: "LAPUTA_QEMU_DWL_FOOT_PROOF",
    ready_marker: "LAPUTA_DWL_FOOT_PROOF_READY",
    success_marker: "LAPUTA_DWL_FOOT_PROOF_OK",
    failure_marker: "LAPUTA_DWL_FOOT_PROOF_FAILED",
    vt_away_marker: "",
    vt_back_marker: "",
    input_mode: types.ProofPlain,
  }
}

pure fixture_vt_proof() -> types.ProofMarkers {
  {...fixture_proof(), vt_away_marker: "LAPUTA_VT_SWITCH_AWAY", vt_back_marker: "LAPUTA_VT_SWITCH_BACK"}
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
    proof: fixture_proof(),
    qemu_gpu: types.Virtio2d,
    development: true,
  }
}

pure fixture_vt_profile() -> types.SystemProfile {
  {...fixture_profile(), proof: fixture_vt_proof()}
}

proc fixture_qemu(os: Str, arch: Str) -> Result[qemu.QemuConfig] {
  let target = qemu.qemu_target(os, arch)?
  {qemu: fp"{target.qemu_name}", target}
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

  assert "LAPUTA_QEMU_DWL_FOOT_PROOF=1" in qemu.kernel_cmdline(config.target, types.Test, fixture_proof()), "test proof flag"
  assert ! ("LAPUTA_QEMU_DWL_FOOT_PROOF=1" in qemu.kernel_cmdline(config.target, types.Interactive, fixture_proof())), "interactive omits proof flag"
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

pure display_of(argv: List[Str]) -> Str {
  for index in range(argv.len() - 1) {
    return argv[index + 1] when argv[index] == "-display"
  }
  ""
}

test test_virgl_profile_selects_the_gl_device_and_a_gl_display [error] {
  let outputs = build.outputs(p"target/laputa/qemu-dwl-foot")
  let virgl = {...fixture_profile(), qemu_gpu: types.Virgl}

  for host in [["Linux", "x86_64"], ["Linux", "aarch64"], ["Darwin", "aarch64"]] {
    let config = fixture_qemu(host[0], host[1])?
    let test_argv = qemu.qemu_command_argv(config, virgl, outputs, types.Test)
    let interactive_argv = qemu.qemu_command_argv(config, virgl, outputs, types.Interactive)

    for argv in [test_argv, interactive_argv] {
      var scanout = -1
      var render = -1
      for index in range(argv.len()) {
        if argv[index] == "virtio-gpu-pci,xres=1280,yres=800" { scanout = index }
        if argv[index] == "virtio-gpu-gl-pci,xres=1280,yres=800" { render = index }
      }
      assert scanout >= 0, "2D scanout gpu"
      assert render > scanout, "scanout gpu is card0 and precedes the virgl gpu"
    }

    assert display_of(test_argv) == "egl-headless", "headless GL test display"
    assert display_of(interactive_argv) != "", "interactive GL display"
    assert display_of(interactive_argv) != "egl-headless", "interactive display is visible"
  }
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
  let markers = fixture_proof()

  for marker in proof.failure_markers {
    assert proof.failure_marker(markers, f"before {marker} after") == marker
  }

  assert proof.failure_marker(markers, "LAPUTA_DWL_FOOT_PROOF_FAILED input") == "LAPUTA_DWL_FOOT_PROOF_FAILED"
  assert ! proof.succeeded(markers, "booting")
  assert proof.succeeded(markers, markers.success_marker)
  match proof.verify_console(markers, "LAPUTA_DWL_FOOT_PROOF_FAILED input") {
    Ok(_) => assert false
    Err(_) => {}
  }

  match proof.verify_console(markers, f"""{markers.success_marker}
QEMU_FATAL after success""") {
    Ok(_) => assert false
    Err(_) => {}
  }
}

proc fixture_marker(failed: Str) -> Result[Str, Error] {
  let marker = {format: "laputa-boot-marker-1", generation_id: "a", boot_serial: 3, failed_generation: failed, root_digest: "digest", profile: "qemu-maintained", services: [{name: "logger", state: "running"}, {name: "dhcp-eth0", state: "running"}]}
  Ok(f"LAPUTA_BOOT_MARKER {json.encode(marker)?}")
}

test test_boot_marker_names_the_selected_boot_and_its_history [error] {
  let good = fixture_marker("b")?
  let parsed = proof.boot_marker_report(f"booting\n{good}\nready\n", "a", 3, "b")?
  assert parsed.get("generation_id")?.require(Str)? == "a"
  assert parsed.get("failed_generation")?.require(Str)? == "b"
  assert (parsed.get("services")?.require(List[Record])?).len() == 2
  match proof.boot_marker_report("booting without a marker\n", "a", 3, "") {
    Ok(_) => assert false
    Err(_) => {}
  }
  match proof.boot_marker_report(fixture_marker("")?, "a", 3, "b") {
    Ok(_) => assert false
    Err(_) => {}
  }
  match proof.boot_marker_report(good, "a", 4, "b") {
    Ok(_) => assert false
    Err(_) => {}
  }
  match proof.boot_marker_report("LAPUTA_BOOT_MARKER {\"format\":\"laputa-boot-marker-1\",\"generation_id\":\"a\",\"boot_serial\":3,\"failed_generation\":\"\",\"root_digest\":\"digest\",\"profile\":\"qemu-maintained\",\"services\":[],\"extra\":\"ssh-ed25519 AAAAC3\"}", "a", 3, "") {
    Ok(_) => assert false
    Err(_) => {}
  }
}

test test_qmp_retry_type_rejects_input_dispatch [fs, process, error] { |ctx|
  let module_source = p"system/qemu.xsh".read_text()?
  let invalid_dispatch = module_source + """
proc qmp_retry_input(socket: Path) -> Result[Unit] {
  qemu_qmp_retry(QmpInput, socket, 1)
}
"""
  let result = test.run_script(ctx, invalid_dispatch)?
  assert result.status != 0, "QMP input unexpectedly type-checked as retryable"
  assert "QmpRetryOperation" in result.stderr, result.stderr
}

proc supervisor_fixture(ctx: TestContext) -> Result[SupervisorFixture] {
  let root = test.temp_dir(ctx, name: "qemu-supervisor")?
  let outputs = build.outputs(root)
  let bundle = fp"{outputs.builds}/fixture"
  bundle.mkdir()
  outputs.current.symlink(to: p"builds/fixture")
  outputs.kernel.write("kernel")
  outputs.disk.write("disk")
  let fake_qemu = fp"{root}/fake-qemu"
  fake_qemu.write(p"tests/system/fixtures/qmp-supervisor-peer.py".read_text()?)
  fake_qemu.chmod(0o755)
  {
    config: {qemu: fake_qemu, target: qemu.qemu_target("Linux", "x86_64")?},
    outputs,
    qemu_pid: fp"{root}/qemu-pid",
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

test test_qemu_supervisor_retries_safe_qmp_operations_and_injects_once [fs, process, net, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx)?
  fp"{fixture.outputs.root}/reject-ready".write("")
  fp"{fixture.outputs.root}/reject-screenshot".write("")
  qemu.run_test(fixture.config, fixture_profile(), fixture.outputs)?
  assert fp"{fixture.outputs.root}/connections".read_lines()?.len() == 5
  let events = fp"{fixture.outputs.root}/native-events".read_lines()?
  assert events.len() == 18
  assert "l" in events[0] and "ret" in events[12]
  assert fp"{fixture.outputs.root}/screenshot-requests".read_lines()? == [fixture.outputs.screenshot.display(), fixture.outputs.screenshot.display()]
  assert qemu.screenshot_is_valid(fixture.outputs.screenshot)?
}

test test_qemu_supervisor_switches_vt_once_each_way [fs, process, net, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx)?
  qemu.run_test(fixture.config, fixture_vt_profile(), fixture.outputs)?
  let events = fp"{fixture.outputs.root}/native-events".read_lines()?
  assert events.len() == 22
  assert "f2" in events[0] and "f1" in events[2]
  assert "ctrl" in events[0] and "alt" in events[0]
  assert "l" in events[4] and "ret" in events[16]
  assert qemu.screenshot_is_valid(fixture.outputs.screenshot)?
}

test test_qemu_supervisor_does_not_replay_input_and_reaps_qemu_after_disconnect [fs, process, net, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx)?
  fp"{fixture.outputs.root}/disconnect-input".write("")
  match qemu.run_test(fixture.config, fixture_profile(), fixture.outputs) {
    Ok(_) => test.fail("supervisor accepted an indeterminate input outcome"),
    Err(problem) => assert "OutcomeIndeterminate" in problem.message, problem.message,
  }
  assert fp"{fixture.outputs.root}/native-events".read_lines()?.len() == 1
  let pid = fixture.qemu_pid.read_text()?.trim().parse_int()?
  for entry in process.list()? {
    assert entry.pid != pid, f"QEMU process {pid} remained after input failure"
  }
}

test test_qemu_supervisor_rejects_capture_after_foot_reader_exits [fs, process, net, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx)?
  fp"{fixture.outputs.root}/reader-exits".write("")
  match qemu.run_test(fixture.config, fixture_profile(), fixture.outputs) {
    Ok(_) => test.fail("supervisor accepted a screenshot without the live foot marker")
    Err(problem) => assert "visual marker" in problem.message, problem.message
  }
  assert qemu.screenshot_is_valid(fixture.outputs.screenshot)?
}

test test_qemu_supervisor_rescans_final_qemu_log_after_screenshot [fs, process, net, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx)?
  fp"{fixture.outputs.root}/final-failure".write("")
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

test test_qemu_supervisor_reports_qemu_that_exits_at_startup [fs, process, net, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx)?
  fp"{fixture.outputs.root}/startup-exit".write("")

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
