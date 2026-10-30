##! Headless maintained QEMU profile without a development graphical session.
use system.types

## Direct package roots for an operator login over Dropbear. Dependencies are resolved by PM.
export let profile: types.SystemProfile = types.SystemProfile(
  name: "qemu-maintained",
  package_roots: [
    "baselayout",
    "ca-certificates",
    "xsh",
    "laputa-pm",
    "xinit",
    "dropbear",
    "nftables",
    "laputa-net",
    "laputa-syslog",
  ],
  kernel_package: "linux",
  kernel_path: p"boot/vmlinuz",
  qemu_smp: 2,
  qemu_memory: "1536M",
  qemu_width: 1280,
  qemu_height: 800,
  forbidden_packages: [
    "llvm-toolchain",
    "pkgconf",
    "cmake",
    "muon",
    "samurai",
    "m4",
    "flex",
    "bison",
    "dbus",
    "systemd",
    "python",
  ],
  forbidden_sonames: ["libLLVM", "libclang", "libpython"],
  proof: {
    cmdline_flag: "LAPUTA_MAINTAINED_PROOF_FLAG",
    ready_marker: "LAPUTA_MAINTAINED_PROOF_READY",
    success_marker: "LAPUTA_MAINTAINED_PROOF_OK",
    failure_marker: "LAPUTA_MAINTAINED_PROOF_FAILED",
    vt_away_marker: "",
    vt_back_marker: "",
  },
  development: false,
)
