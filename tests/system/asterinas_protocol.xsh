##! The host must accept only a complete initramfs-to-XSH guest proof.
use infra.asterinas.guest_protocol

test test_guest_protocol_requires_every_boot_and_xsh_marker {
  let output = guest_protocol.guest_success_markers.join("\n")
  assert guest_protocol.guest_missing_success_markers(output) == []
}

test test_guest_protocol_requires_the_selected_xsh_test_marker {
  let base_output = guest_protocol.guest_success_markers.join("\n")
  let start = "LAPUTA_ASTERINAS_XSH_TEST_START tests/xsh/stdlib/fs.xsh"
  assert guest_protocol.guest_missing_success_markers(f"{base_output}\n{start}") == [
    "LAPUTA_ASTERINAS_XSH_TEST_OK",
  ]
  let selected_output = f"{base_output}\n{start}\nLAPUTA_ASTERINAS_XSH_TEST_OK"
  assert guest_protocol.guest_missing_success_markers(selected_output) == []
}

test test_guest_protocol_reports_each_missing_marker_in_protocol_order {
  var output = ""
  for marker in guest_protocol.guest_success_markers {
    if marker != "LAPUTA_ASTERINAS_EXT2_MOUNT_OK"
      and marker != "LAPUTA_ASTERINAS_LOOPBACK_OK"
      and marker != "LAPUTA_ASTERINAS_XSH_OK" {
      output = f"{output}{marker}\n"
    }
  }
  assert guest_protocol.guest_missing_success_markers(output) == [
    "LAPUTA_ASTERINAS_EXT2_MOUNT_OK",
    "LAPUTA_ASTERINAS_LOOPBACK_OK",
    "LAPUTA_ASTERINAS_XSH_OK",
  ]
}

test test_guest_output_failure_keeps_its_nominal_error [process, error] {
  let output = run.capture --text "xsh" infra/asterinas/check-guest-output.xsh -- infra/asterinas/inputs.lock

  assert ! output.status.ok, output.stderr
  assert "GuestOutputCheckError.Failed" in output.stderr, output.stderr
  assert "guest proof is missing:" in output.stderr, output.stderr
}
