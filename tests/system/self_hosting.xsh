use system.self_hosting as boot
use system.activation

pure receipt() -> activation.GenerationReceipt {
  {id: "successor", kernel: "boot/vmlinuz", root_digest: bytes.from_text("successor").sha256().hex()}
}

pure marker(id: Str, serial: Int, digest: Str) -> Result[Str, Error] {
  "LAPUTA_SELF_HOSTING_ACTIVATION " + json.encode({generation_id: id, boot_serial: serial, root_digest: digest})? + "\n"
}

test test_self_hosting_observation_requires_the_actual_receipt_and_boot [fs, error] { |ctx|
  let directory = test.temp_dir(ctx, name: "self-hosting-serial")?
  let console = fp"{directory}/console.log"
  let expected = receipt()
  let valid = marker(expected.id, 7, expected.root_digest)?
  console.write(valid)?
  assert boot.self_hosting_boot_report_complete(console, expected, 7)?
  console.write(valid.replace("\n", with: "\r\n"))?
  assert boot.self_hosting_boot_report_complete(console, expected, 7)?
  console.write("LAPUTA_SELF_HOSTING_SUCCESSOR_BOOTED\n")?
  assert ! boot.self_hosting_boot_report_complete(console, expected, 7)?
  console.write("LAPUTA_SELF_HOSTING_ACTIVATION {\"boot_serial\":")?
  assert ! boot.self_hosting_boot_report_complete(console, expected, 7)?
  for invalid in [
    valid + valid,
    marker("previous", 7, expected.root_digest)?,
    marker("LAPUTA_SELF_HOSTING_ACTIVATION " + expected.id, 7, expected.root_digest)?,
    marker(expected.id, 6, expected.root_digest)?,
    marker(expected.id, 7, bytes.from_text("other").sha256().hex())?,
    "LAPUTA_SELF_HOSTING_ACTIVATION {}\n",
  ] {
    console.write(invalid)?
    assert boot.self_hosting_boot_report_complete(console, expected, 7) is Err(_)
  }
}
