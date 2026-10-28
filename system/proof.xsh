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
