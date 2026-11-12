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
    cmdline_flag: "LAPUTA_QEMU_FIXTURE_PROOF",
    ready_marker: "LAPUTA_FIXTURE_PROOF_READY",
    success_marker: "LAPUTA_FIXTURE_PROOF_OK",
    failure_marker: "LAPUTA_FIXTURE_PROOF_FAILED",
    input_mode: types.ProofPlain,
  }
}

pure fixture_profile() -> types.SystemProfile {
  {
    name: "qemu-fixture",
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

proc fixture_qemu(os: Str, arch: Str) -> Result[qemu.QemuConfig] {
  let target = qemu.qemu_target(os, arch)?
  {qemu: fp"{target.qemu_name}", target}
}

proc command_pair(config: qemu.QemuConfig) [error] -> Result[List[List[Str]]] {
  let outputs = build.outputs(p"target/laputa/qemu-fixture")
  [
    qemu.qemu_command_argv(config, fixture_profile(), outputs, types.Test),
    qemu.qemu_command_argv(config, fixture_profile(), outputs, types.Interactive),
  ]
}

test test_qemu_qualification_boots_the_disposable_ext2_payload [error] {
  let config = fixture_qemu("Linux", "x86_64")?
  let input = qemu.QemuAsterinasReference(
    kernel: p"/tmp/kernel",
    initramfs: p"/tmp/initramfs",
    disk: p"/tmp/root",
    memory_mib: 4096,
    data_disk: qemu.NoDataDisk,
    network: qemu.NoNetwork,
    control: qemu.NoControl,
  )
  let argv = qemu.qemu_asterinas_reference_argv(config, input)?
  assert "q35,accel=kvm" in argv
  assert "4096" in argv
  assert "/tmp/kernel" in argv
  assert "/tmp/initramfs" in argv
  assert !("if=none,id=data,format=raw,file=/tmp/data" in argv)
  assert "if=none,id=root,format=raw,file=/tmp/root" in argv
  assert "virtio-blk-pci,drive=root" in argv
  assert !("-netdev" in argv)
  assert !("-qmp" in argv)
  let controlled = qemu.qemu_asterinas_reference_argv(config, {...input, control: qemu.QmpSocket(p"/run/vmm.sock")})?
  assert "unix:/run/vmm.sock,server=on,wait=off" in controlled
  let networked = qemu.qemu_asterinas_reference_argv(config, {...input, network: qemu.Tap("tap0")})?
  assert "tap,id=net0,ifname=tap0,script=no,downscript=no" in networked
  assert "virtio-net-pci,netdev=net0,mac=AA:FC:00:00:00:01" in networked
  match qemu.qemu_asterinas_reference_argv(config, {...input, network: qemu.Tap("tap0,script=x")}) {
    Ok(_) => fail "accepted a TAP name that injects QEMU options"
    Err(_) => {}
  }
  let unsupported = fixture_qemu("Linux", "aarch64")?
  match qemu.qemu_asterinas_reference_argv(unsupported, input) {
    Ok(_) => fail "accepted an unsupported qualification target"
    Err(_) => {}
  }
}

pure position(items: List[Str], wanted: Str) -> Int {
  for index in range(items.len()) {
    if items[index] == wanted { return index }
  }
  -1
}

test test_qemu_qualification_attaches_a_second_disk_after_the_root_disk [error] {
  let config = fixture_qemu("Linux", "x86_64")?
  let input = qemu.QemuAsterinasReference(
    kernel: p"/tmp/kernel",
    initramfs: p"/tmp/initramfs",
    disk: p"/tmp/root",
    memory_mib: 1024,
    data_disk: qemu.DataDisk(p"/tmp/data"),
    network: qemu.Tap("tap0"),
    control: qemu.NoControl,
  )
  let argv = qemu.qemu_asterinas_reference_argv(config, input)?
  let root = position(argv, "if=none,id=root,format=raw,file=/tmp/root")
  let data = position(argv, "if=none,id=data,format=raw,file=/tmp/data")
  assert root < data
  assert argv[data + 1] == "-device"
  assert argv[data + 2] == "virtio-blk-pci,drive=data"
  assert data < position(argv, "tap,id=net0,ifname=tap0,script=no,downscript=no")
}

test test_qemu_qualification_rejects_a_guest_without_completion [fs, process, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "qemu-qualification")?
  let fake = fp"{root}/qemu"
  fake.write("#!/bin/sh\nprintf 'incomplete guest output\\n'\n")
  fake.chmod(0o755)
  let config = qemu.QemuConfig(qemu: fake, target: qemu.qemu_target("Linux", "x86_64")?)
  let input = qemu.QemuAsterinasReference(kernel: fp"{root}/kernel", initramfs: fp"{root}/init", disk: fp"{root}/disk", memory_mib: 1024, data_disk: qemu.NoDataDisk, network: qemu.NoNetwork, control: qemu.NoControl)
  match qemu.qemu_run_asterinas_reference(config, input, fp"{root}/console", fp"{root}/qemu-log", 5, 2) {
    Ok(_) => fail "accepted a guest without its completion marker"
    Err(_) => {}
  }
}

test test_qemu_qualification_stops_a_guest_after_failure [fs, process, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "qemu-qualification-failure")?
  let fake = fp"{root}/qemu"
  let pid_file = fp"{root}/pid"
  fake.write(f"#!/bin/sh\nprintf '%s' $$ > '{pid_file}'\nprintf 'LAPUTA_ASTERINAS_TEST_FAILED\\n'\nexec sleep 30\n")
  fake.chmod(0o755)
  let config = qemu.QemuConfig(qemu: fake, target: qemu.qemu_target("Linux", "x86_64")?)
  let input = qemu.QemuAsterinasReference(kernel: fp"{root}/kernel", initramfs: fp"{root}/init", disk: fp"{root}/disk", memory_mib: 1024, data_disk: qemu.NoDataDisk, network: qemu.NoNetwork, control: qemu.NoControl)
  match qemu.qemu_run_asterinas_reference(config, input, fp"{root}/console", fp"{root}/qemu-log", 5, 2) {
    Ok(_) => fail "accepted a failed guest"
    Err(_) => {}
  }
  let pid = pid_file.read_text()?.parse_int()?
  for entry in process.list()? {
    assert entry.pid != pid, f"qualification guest {pid} remained after failure"
  }
}

proc fake_qualification_qemu(root: Path, script: Str) [fs, process, error] -> Result[qemu.QemuConfig] {
  let fake = fp"{root}/qemu"
  fake.write(script)
  fake.chmod(0o755)
  qemu.QemuConfig(qemu: fake, target: qemu.qemu_target("Linux", "x86_64")?)
}

pure qualification_input(root: Path) -> qemu.QemuAsterinasReference {
  qemu.QemuAsterinasReference(kernel: fp"{root}/kernel", initramfs: fp"{root}/init", disk: fp"{root}/disk", memory_mib: 1024, data_disk: qemu.NoDataDisk, network: qemu.NoNetwork, control: qemu.NoControl)
}

test test_qemu_qualification_accepts_a_guest_that_powers_off_after_completion [fs, process, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "qemu-qualification-poweroff")?
  let config = fake_qualification_qemu(root, "#!/bin/sh\nprintf 'LAPUTA_ASTERINAS_TEST_OK\\n'\nexit 0\n")?
  qemu.qemu_run_asterinas_reference(config, qualification_input(root), fp"{root}/console", fp"{root}/qemu-log", 5, 2)?
}

test test_qemu_qualification_rejects_a_guest_that_stays_up_after_completion [fs, process, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "qemu-qualification-stalled")?
  let pid_file = fp"{root}/pid"
  let config = fake_qualification_qemu(root, f"#!/bin/sh\nprintf '%s' $$ > '{pid_file}'\nprintf 'LAPUTA_ASTERINAS_TEST_OK\\n'\nexec sleep 30\n")?
  match qemu.qemu_run_asterinas_reference(config, qualification_input(root), fp"{root}/console", fp"{root}/qemu-log", 5, 1) {
    Ok(_) => fail "accepted a guest that never powered off"
    Err(problem) => assert "did not power off" in problem.message
  }
  let pid = pid_file.read_text()?.parse_int()?
  for entry in process.list()? {
    assert entry.pid != pid, f"qualification guest {pid} remained after the poweroff deadline"
  }
}

test test_qemu_qualification_rejects_a_guest_that_exits_with_failure_after_completion [fs, process, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "qemu-qualification-status")?
  let config = fake_qualification_qemu(root, "#!/bin/sh\nprintf 'LAPUTA_ASTERINAS_TEST_OK\\n'\nexit 3\n")?
  match qemu.qemu_run_asterinas_reference(config, qualification_input(root), fp"{root}/console", fp"{root}/qemu-log", 5, 2) {
    Ok(_) => fail "accepted a guest whose QEMU exited with a failure status"
    Err(_) => {}
  }
}

test test_qemu_qualification_keeps_native_and_laputa_completion_separate [fs, process, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "qemu-native-proof")?
  let native = fake_qualification_qemu(root, "#!/bin/sh\nprintf 'XSH_NATIVE_RESULT pass\\n'\nexit 0\n")?
  qemu.qemu_run_asterinas_reference(native, qualification_input(root), fp"{root}/console", fp"{root}/qemu-log", 5, 2, proof: qemu.NativeXsh)?
  match qemu.qemu_run_asterinas_reference(native, qualification_input(root), fp"{root}/console", fp"{root}/qemu-log", 5, 2) {
    Ok(_) => fail "accepted native test completion as the maintained Laputa proof"
    Err(problem) => assert "before its completion marker" in problem.message
  }
  let laputa = fake_qualification_qemu(root, "#!/bin/sh\nprintf 'LAPUTA_ASTERINAS_TEST_OK\\n'\nexit 0\n")?
  match qemu.qemu_run_asterinas_reference(laputa, qualification_input(root), fp"{root}/console", fp"{root}/qemu-log", 5, 2, proof: qemu.NativeXsh) {
    Ok(_) => fail "accepted maintained Laputa completion as native test completion"
    Err(problem) => assert "before its completion marker" in problem.message
  }
}

test test_qemu_native_qualification_rejects_failure_before_a_success_marker [fs, process, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "qemu-native-failure")?
  let config = fake_qualification_qemu(root, "#!/bin/sh\nprintf 'XSH_NATIVE_RESULT fail status=1\\nXSH_NATIVE_RESULT pass\\n'\nexit 0\n")?
  match qemu.qemu_run_asterinas_reference(config, qualification_input(root), fp"{root}/console", fp"{root}/qemu-log", 5, 2, proof: qemu.NativeXsh) {
    Ok(_) => fail "accepted native qualification failure"
    Err(problem) => assert "reported failure" in problem.message
  }
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

  assert "LAPUTA_QEMU_FIXTURE_PROOF=1" in qemu.kernel_cmdline(config.target, types.Test, fixture_proof()), "test proof flag"
  assert ! ("LAPUTA_QEMU_FIXTURE_PROOF=1" in qemu.kernel_cmdline(config.target, types.Interactive, fixture_proof())), "interactive omits proof flag"
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
  let outputs = build.outputs(p"target/laputa/qemu-fixture")
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

  assert proof.failure_marker(markers, "LAPUTA_FIXTURE_PROOF_FAILED input") == "LAPUTA_FIXTURE_PROOF_FAILED"
  assert ! proof.succeeded(markers, "booting")
  assert proof.succeeded(markers, markers.success_marker)
  match proof.verify_console(markers, "LAPUTA_FIXTURE_PROOF_FAILED input") {
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
  let hook_metadata = p"profiles/qemu-tinyland-ghostty/usr/lib/init/rc.d/laputa-qemu-tinyland-ghostty.boot".metadata()?
  let hook = p"profiles/qemu-tinyland-ghostty/usr/lib/init/rc.d/laputa-qemu-tinyland-ghostty.boot".read_text()?
  let builder = p"system/container_build.xsh".read_text()?
  let guest = p"guest/qemu-tinyland-ghostty-proof.xsh".read_text()?
  let session = p"profiles/qemu-tinyland-ghostty/usr/lib/laputa/tinyland-session.xsh".read_text()?
  assert hook_metadata.mode % 4096 == 0o755
  assert "tinyland-runtime-setup.xsh" in hook
  assert guest.starts_with("""#!/bin/xsh
""")
  assert "container_prepare_overlay" in builder
  assert "fs.install(guest_proof" in builder
  assert ! ("process.which(" in guest)
  assert "/usr/bin/su" in guest
  assert "process.kill(seatd_pid" in guest
  assert "/sys/bus/pci/devices/{virtio_pci}/remove" in guest
  assert "loaded OpenGL 4.3" in guest
  assert "LAPUTA_TINYLAND_GHOSTTY_PROOF_OK" in guest
  assert "/usr/bin/tinyland" in session
  assert "/usr/bin/ghostty-custom" in session
  assert "/usr/lib/laputa/tinyland-ghostty-read.xsh" in session
}

test test_qemu_supervisor_reports_qemu_that_exits_at_startup [fs, process, net, time, error] { |ctx|
  let fixture = supervisor_fixture(ctx)?
  fp"{fixture.outputs.root}/startup-exit".write("")

  match qemu.run_test(fixture.config, fixture_profile(), fixture.outputs) {
    Ok(_) => test.fail("supervisor accepted a QEMU that exited at startup")
    Err(problem) => assert "QEMU exited before qemu-fixture proof" in problem.message, problem.message
  }
}

test test_qmp_socket_fits_a_unix_socket_path_from_any_checkout_depth [error] {
  let deep = fp"/{["very-long-directory-name" for _ in range(12)].join("/")}/target/laputa/qemu-fixture"
  let socket = build.outputs(deep).qmp_socket.display()
  assert socket.byte_len() < 108, socket
  assert build.outputs(deep).qmp_socket != build.outputs(p"/other/target/laputa/qemu-fixture").qmp_socket
}

test test_self_hosting_runtime_output_is_readonly_at_the_block_device [error] {
  let config = fixture_qemu("Linux", "x86_64")?
  let writable = qemu.qemu_self_hosting_disks_argv(config.target, p"/inputs", p"/output")
  let readonly = qemu.qemu_self_hosting_disks_argv(config.target, p"/inputs", p"/output", qemu.InspectOutput)
  assert "if=none,id=inputs,format=raw,file=/inputs,readonly=on" in writable
  assert "if=none,id=inputs,format=raw,file=/inputs,readonly=on" in readonly
  assert "if=none,id=output,format=raw,file=/output" in writable
  assert "if=none,id=output,format=raw,file=/output,readonly=on" in readonly
  assert !("if=none,id=output,format=raw,file=/output" in readonly)
}
