##! Typed contracts for the single supported Laputa reference system.

## The execution mode selected for the reference QEMU system.
export type QemuMode = Test | Interactive

## The data-only description of the supported Laputa system profile.
export type SystemProfile = {
  name: Str,
  package_roots: List[Str],
  kernel_package: Str,
  kernel_path: Path,
  qemu_machine: Str,
  qemu_cpu: Str,
  qemu_smp: Int,
  qemu_memory: Str,
  qemu_width: Int,
  qemu_height: Int,
  forbidden_packages: List[Str],
  forbidden_sonames: List[Str],
}

## Errors raised when a profile or system command violates its declared contract.
export error LaputaError = Usage(message: Str) : Usage | Profile(message: Str) : InvalidData | Docker(message: Str) : ProcessFailure | Incomplete(message: Str) : Unsupported

## Render a QEMU execution mode for diagnostics and persisted command records.
export pure qemu_mode_text(mode: QemuMode) -> Str {
  match mode {
    Test => "test"
    Interactive => "interactive"
  }
}
