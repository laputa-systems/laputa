##! Typed contracts for the single supported Laputa reference system.

## The sole supported system target accepted by Laputa profiles and build adapters.
## XSH requires at least two tags to encode a tag union, so the second tag is an
## internal parse sentinel. Every profile and external parser rejects it.
export type SystemTarget = Aarch64LinuxMusl | UnsupportedSystemTarget

## The host display mode selected by a QEMU invocation.
export type DisplayMode = Headless | Cocoa

## The execution mode selected for the reference QEMU system.
export type QemuMode = Test | Interactive

## The guest session commands declared by a system profile.
export type SessionSpec = {
  compositor: Path,
  terminal: Path,
  interactive_argv: List[Str],
  proof_argv: List[Str],
}

## The hardware configuration declared by a system profile.
export type QemuSpec = {
  machine: Str,
  cpu: Str,
  smp: Int,
  memory: Str,
  width: Int,
  height: Int,
}

## The observable success and failure contract for a guest proof.
export type ProofSpec = {
  success_markers: List[Str],
  failure_markers: List[Str],
  input_text: Str,
  screenshot_required: Bool,
}

## The complete, typed description of a supported Laputa system profile.
export type SystemProfile = {
  name: Str,
  target: SystemTarget,
  package_roots: List[Str],
  kernel_package: Str,
  kernel_path: Path,
  session: SessionSpec,
  qemu: QemuSpec,
  proof: ProofSpec,
  forbidden_packages: List[Str],
  forbidden_sonames: List[Str],
}

## Errors raised when a profile or system command violates its declared contract.
export error LaputaError = Usage(message: Str) : Usage | Profile(message: Str) : InvalidData | Docker(message: Str) : ProcessFailure | Incomplete(message: Str) : Unsupported

## Render the sole supported target at the JSON and command-line boundary.
export pure system_target_text(target: SystemTarget) -> Str {
  match target {
    Aarch64LinuxMusl => "aarch64-linux-musl"
    UnsupportedSystemTarget => "unsupported"
  }
}

## Decode an externally supplied target without admitting unsupported systems.
export pure parse_system_target(raw: Str) -> Result[SystemTarget] {
  if raw == "aarch64-linux-musl" {
    return Aarch64LinuxMusl
  }

  return Err(LaputaError.Profile(f"unsupported system target ${raw}; expected aarch64-linux-musl"))
}

## Render a QEMU display mode for diagnostics and persisted command records.
export pure display_mode_text(mode: DisplayMode) -> Str {
  match mode {
    Headless => "headless"
    Cocoa => "cocoa"
  }
}

## Render a QEMU execution mode for diagnostics and persisted command records.
export pure qemu_mode_text(mode: QemuMode) -> Str {
  match mode {
    Test => "test"
    Interactive => "interactive"
  }
}
