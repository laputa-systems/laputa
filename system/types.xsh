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
export type ProofMarkers = {
  cmdline_flag: Str,
  ready_marker: Str,
  success_marker: Str,
  failure_marker: Str,
  input_mode: ProofInputMode,
}

## The guest GPU a profile requires. `Virtio2d` is a 2D virtio-gpu scanout.
## `Virgl` is virtio-gpu with virgl 3D acceleration, which the host QEMU
## renders on a host GPU through virglrenderer and a GL-capable display.
## `Venus` is virtio-gpu with blob resources and the Venus Vulkan protocol, which
## forwards the guest's Vulkan calls to the host driver through virglrenderer;
## its payload is the host-visible blob window in MiB.
export enum QemuGpu { Virtio2d, Virgl, Venus(Int) }

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
    Venus(hostmem_mib) => f"venus-{hostmem_mib}m"
  }
}

## Render the host input behavior selected by a profile's guest proof.
export pure proof_input_mode_text(mode: ProofInputMode) -> Str {
  match mode {
    ProofPlain => "plain"
    ProofModifiers => "modifiers"
  }
}
