##! Concrete console-marker validation for the sole qemu-dwl-foot proof.
use laputa.types as types

## The marker emitted only after foot's reader receives the injected input.
export let success_marker: Str = "LAPUTA_DWL_FOOT_PROOF_OK"

## Fatal kernel and guest markers that invalidate the one supported proof.
export let failure_markers: List[Str] = [
  "Kernel panic",
  "not syncing",
  "Attempted to kill init",
  "Insufficient stack space",
  "LAPUTA_DWL_FOOT_PROOF_FAILED",
  "QEMU_FATAL",
]

## Return the first configured failure marker found in `console`, if any.
export pure failure_marker(console: Str) -> Str {
  for marker in failure_markers {
    if marker in console {
      return marker
    }
  }

  return ""
}

## Return whether the guest has emitted every required success marker.
export pure succeeded(console: Str) -> Bool {
  success_marker in console
}

## Fail closed when a console contains a kernel or guest-proof failure marker.
export proc verify_console(console: Str) [error] {
  let failed = failure_marker(console)
  if failed != "" {
    return Err(types.LaputaError.Profile(f"guest proof failed with marker ${failed}"))
  }

  if ! succeeded(console) {
    return Err(types.LaputaError.Profile(f"guest proof did not emit ${success_marker}"))
  }
}
