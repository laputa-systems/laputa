##! Installer argument failures stop before disk discovery or mutation.

test test_installer_rejects_invalid_arguments_before_inspecting_disks [fs, process, error] { |ctx|
  for input in [
    {argv: ["--disk"], message: "--disk requires a device"},
    {argv: ["--unknown"], message: "unknown argument --unknown"},
  ] {
    let argv = input.argv
    let result = run.capture --text $ctx.xsh_bin installer/setup-laputa.xsh -- @argv
    assert result.status.exited_with(3), result.stderr
    assert "err: usage:" in result.stderr, result.stderr
    assert input.message in result.stderr, result.stderr
    assert result.stdout == "", result.stdout
    assert "Available disks:" not in result.stderr, result.stderr
  }
}
