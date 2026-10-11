##! Reject a captured guest log unless every boot and XSH proof marker is present.
use infra.asterinas.guest_protocol as guest_protocol

error GuestOutputCheckError = Failed(message: Str)

proc main(console_log: Path) [fs, error] {
  let output = console_log.read_text()?
  let missing = guest_protocol.guest_missing_success_markers(output)

  if ! missing.is_empty() {
    return Err(GuestOutputCheckError.Failed(f"guest proof is missing: {missing.join(", ")}"))
  }

  print "Guest serial log contains every required Asterinas proof marker."
}
