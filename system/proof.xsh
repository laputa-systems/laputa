##! Console-marker validation for the QEMU guest proofs. Markers come from
##! the profile under test; nothing here names a profile.
use system.types

## Fatal kernel and guest markers that invalidate any proof. Profile failure
## markers are checked separately through the profile's own marker.
export const failure_markers = [
  "Kernel panic",
  "not syncing",
  "Attempted to kill init",
  "Insufficient stack space",
  "QEMU_FATAL",
]

## Return the first configured failure marker found in `console`, if any.
export pure failure_marker(proof: types.ProofMarkers, console: Str) -> Str {
  for marker in failure_markers {
    return marker when marker in console
  }

  return proof.failure_marker when proof.failure_marker in console

  ""
}

## Return whether the guest has emitted its required success marker.
export pure succeeded(proof: types.ProofMarkers, console: Str) -> Bool {
  proof.success_marker in console
}

## Fail closed when a console contains a kernel or guest-proof failure marker.
export proc verify_console(proof: types.ProofMarkers, console: Str) [error] {
  let failed = failure_marker(proof, console)

  if failed != "" {
    return Err(types.LaputaError.Profile(f"guest proof failed with marker {failed}"))
  }

  if ! succeeded(proof, console) {
    return Err(types.LaputaError.Profile(f"guest proof did not emit {proof.success_marker}"))
  }
}

## The exact boot marker fields a maintained guest reports. The key set is
## closed: generation identity and service states only, never secrets.
export const boot_marker_keys = ["boot_serial", "failed_generation", "format", "generation_id", "profile", "root_digest", "services"]

## Parse the last boot marker line from a maintained guest console and check
## it against the selected boot. A missing marker, a field mismatch, an
## unexpected key, or a secret-looking payload fails closed. Returns the
## parsed marker for the harness to record.
export proc boot_marker_report(console: Str, id: Str, serial: Int, failed: Str) [error] -> Result[Record, Error] {
  var found = ""

  for line in console.lines() {
    if line.starts_with("LAPUTA_BOOT_MARKER ") {
      found = line.byte_slice(19)
    }
  }

  guard found != "" else {
    return Err(types.LaputaError.Profile("guest console names no boot marker"))
  }

  let parsed = json.decode(found)?.require(Record)?
  let keys = [key for key in parsed.keys()] |> sort

  guard keys == boot_marker_keys else {
    return Err(types.LaputaError.Profile(f"guest boot marker carries unexpected fields"))
  }

  guard parsed.get("format")?.require(Str)? == "laputa-boot-marker-1" else {
    return Err(types.LaputaError.Profile("guest boot marker has the wrong format"))
  }

  guard parsed.get("generation_id")?.require(Str)? == id else {
    return Err(types.LaputaError.Profile("guest boot marker names the wrong generation"))
  }

  guard parsed.get("boot_serial")?.require(Int)? == serial else {
    return Err(types.LaputaError.Profile("guest boot marker names the wrong boot serial"))
  }

  guard parsed.get("failed_generation")?.require(Str)? == failed else {
    return Err(types.LaputaError.Profile("guest boot marker names the wrong failed generation"))
  }

  guard parsed.get("root_digest")?.require(Str)? != "" else {
    return Err(types.LaputaError.Profile("guest boot marker is missing its root digest"))
  }

  guard parsed.get("profile")?.require(Str)? != "" else {
    return Err(types.LaputaError.Profile("guest boot marker is missing its profile"))
  }

  let services = parsed.get("services")?.require(List[Record])?

  guard ! services.is_empty() else {
    return Err(types.LaputaError.Profile("guest boot marker names no services"))
  }

  for service in services {
    guard service.get("name")?.require(Str)? != "" and service.get("state")?.require(Str)? != "" else {
      return Err(types.LaputaError.Profile("guest boot marker names a malformed service"))
    }
  }

  for secret in ["ssh-ed25519", "tskey", "password", "secret"] {
    guard ! (secret in found) else {
      return Err(types.LaputaError.Profile("guest boot marker leaks a secret"))
    }
  }

  parsed
}
