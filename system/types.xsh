##! Typed contracts for the supported Laputa reference systems.

## The execution mode selected for the reference QEMU system.
export enum QemuMode { Test, Interactive }

## The guest proof markers owned by one system profile. The guest emits the
## ready marker when its session accepts input, the success marker only
## after it consumes the injected input, and the failure marker on any
## proof failure; the kernel command line selects the proof with the flag.
export type ProofMarkers = {
  cmdline_flag: Str,
  ready_marker: Str,
  success_marker: Str,
  failure_marker: Str,
}

## The data-only description of a supported Laputa system profile. The
## QEMU machine, CPU, and accelerator belong to the host (`system.qemu`).
export type SystemProfile = {
  name: Str,
  package_roots: List[Str],
  kernel_package: Str,
  kernel_path: Path,
  qemu_smp: Int,
  qemu_memory: Str,
  qemu_width: Int,
  qemu_height: Int,
  forbidden_packages: List[Str],
  forbidden_sonames: List[Str],
  proof: ProofMarkers,
}

## Errors raised when a profile or system command violates its declared contract.
export error LaputaError = Usage : Usage | Profile : InvalidData | Docker : ProcessFailure | Incomplete : Unsupported

## Render a QEMU execution mode for diagnostics and persisted command records.
export pure qemu_mode_text(mode: QemuMode) -> Str {
  match mode {
    Test => "test"
    Interactive => "interactive"
  }
}
