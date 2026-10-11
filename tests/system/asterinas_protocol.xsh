##! The host must accept only a complete initramfs-to-XSH guest proof.
use infra.asterinas.guest_protocol as guest_protocol

test test_guest_protocol_requires_every_boot_and_xsh_marker {
  let output = guest_protocol.guest_success_markers.join("\n")
  assert guest_protocol.guest_missing_success_markers(output) == []
}

test test_guest_protocol_reports_each_missing_marker_in_protocol_order {
  var output = ""
  for marker in guest_protocol.guest_success_markers {
    if marker != "LAPUTA_ASTERINAS_EXT2_MOUNT_OK" and marker != "LAPUTA_ASTERINAS_XSH_OK" {
      output = f"{output}{marker}\n"
    }
  }
  assert guest_protocol.guest_missing_success_markers(output) == [
    "LAPUTA_ASTERINAS_EXT2_MOUNT_OK",
    "LAPUTA_ASTERINAS_XSH_OK",
  ]
}
