##! Typed contracts for the supported Laputa reference systems.

## The execution mode selected for the reference QEMU system.
export enum QemuMode { Test, Interactive }

## The keys the host injects when a profile's ready marker appears:
## `ProofPlain` types a lowercase line; `ProofModifiers` drives Caps Lock and
## Shift and expects an uppercase line with punctuation.
export enum ProofInputMode { ProofPlain, ProofModifiers }

## The guest proof markers owned by one system profile. The guest emits the
## ready marker when its session accepts input, the success marker only
## after it consumes the injected input, and the failure marker on any
## proof failure; the kernel command line selects the proof with the flag.
## The VT markers are optional: when set, the supervisor sends a VT switch
## through QMP once each marker appears, and the guest proves the seat
## suspends and resumes around the switches before printing readiness.
export type ProofMarkers = {
  cmdline_flag: Str,
  ready_marker: Str,
  success_marker: Str,
  failure_marker: Str,
  vt_away_marker: Str,
  vt_back_marker: Str,
  input_mode: ProofInputMode,
}

## The guest GPU a profile requires. `Virtio2d` is a 2D virtio-gpu scanout.
## `Virgl` is virtio-gpu with virgl 3D acceleration, which the host QEMU
## renders on a host GPU through virglrenderer and a GL-capable display.
export enum QemuGpu { Virtio2d, Virgl }

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
  qemu_gpu: QemuGpu,
  development: Bool,
}

## Errors raised when a profile or system command violates its declared contract.
export error LaputaError = Usage : Usage | Profile : InvalidData | Docker : ProcessFailure | Incomplete : Unsupported

## Render a guest GPU for diagnostics and the profile digest.
export pure qemu_gpu_text(gpu: QemuGpu) -> Str {
  match gpu {
    Virtio2d => "virtio-2d"
    Virgl => "virgl"
  }
}

## Render a QEMU execution mode for diagnostics and persisted command records.
export pure qemu_mode_text(mode: QemuMode) -> Str {
  match mode {
    Test => "test"
    Interactive => "interactive"
  }
}
