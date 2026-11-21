##! Bootstrap and phase persistence for the disposable trust and repository guests.

## Console marker and durable phase file for one guest proof.
export type GuestBootstrap = {marker: Str, phase_file: Str}

## Guest proof failure with its phase.
export error GuestTrustError = Failed(phase: Str, message: Str)

const GUEST_STORE_DEV = "/dev/vda"
const GUEST_STORE_MNT = "/store"

## guest bootstrap say.
export proc guest_bootstrap_say(ctx: GuestBootstrap, message: Str) [fs, error] {
  p"/dev/console".write(bytes.from_text(f"{ctx.marker} {message}\n"))?
}

## guest bootstrap fail phase.
export proc guest_bootstrap_fail_phase(ctx: GuestBootstrap, phase: Str, message: Str) [fs, error] {
  guest_bootstrap_say(ctx, f"FAIL {phase} {message}")?
  return Err(GuestTrustError.Failed(phase:, message:))
}

proc guest_bootstrap_insmod_one(ctx: GuestBootstrap, name: Str, phase: Str) [fs, process, error] {
  match linux.insmod(fp"/lib/modules/{name}.ko") {
    Ok(_) => {},
    Err(problem) => {
      var seen = ""
      match fs.children(fp"/lib/modules") {
        Ok(entries) => {
          for entry in entries {
            seen = f"{seen} {entry.name}"
          }
        },
        Err(_) => {
          seen = "<unlistable>"
        },
      }

      return guest_bootstrap_fail_phase(ctx, phase, f"insmod {name}: {problem.message}; exists={fp"/lib/modules/{name}.ko".exists()?}; entries={seen}")
    },
  }
}

## guest bootstrap load drivers.
export proc guest_bootstrap_load_drivers(ctx: GuestBootstrap, phase: Str) [fs, process, error] {
  for name in [
    "virtio_ring",
    "virtio",
    "virtio_pci_modern_dev",
    "virtio_pci_legacy_dev",
    "virtio_pci",
    "virtio_blk",
    "failover",
    "net_failover",
    "virtio_net",
    "crc16",
    "mbcache",
    "jbd2",
    "ext4",
  ] {
    guest_bootstrap_insmod_one(ctx, name, phase)?
  }
}

## guest bootstrap mount store.
export proc guest_bootstrap_mount_store(ctx: GuestBootstrap, phase: Str) [fs, process, time, error] {
  guest_bootstrap_wait_for_dev_vda(ctx, phase)?
  fp"{GUEST_STORE_MNT}".mkdir(parents: true)
  match linux.mount(bytes.from_text(GUEST_STORE_DEV), fp"{GUEST_STORE_MNT}", fstype: "ext4") {
    Ok(_) => {},
    Err(problem) => return guest_bootstrap_fail_phase(ctx, phase, f"mount store: {problem.message}"),
  }
}

proc guest_bootstrap_wait_for_dev_vda(ctx: GuestBootstrap, phase: Str) [fs, time, error] {
  var elapsed = 0
  while ! p"/dev/vda".exists()? {
    guard elapsed < 30 else {
      var seen = ""
      match fs.children(fp"/dev") {
        Ok(entries) => {
          for entry in entries {
            seen = f"{seen} {entry.name}"
          }
        },
        Err(_) => {
          seen = "<unlistable>"
        },
      }

      var mounts = "<unreadable>"
      match p"/proc/mounts".read_text() {
        Ok(text) => {
          mounts = text
        },
        Err(_) => {},
      }

      return guest_bootstrap_fail_phase(ctx, phase, f"missing /dev/vda after 30s; dev=[{seen}] mounts=[{mounts}]")
    }

    time.sleep(1s)?
    elapsed += 1
  }
}

## guest bootstrap bring up net.
export proc guest_bootstrap_bring_up_net(ctx: GuestBootstrap, phase: Str) [fs, process, net, error] {
  var iface = ""
  let names = [entry.name ?? "" for entry in linux.network_dump()?.links] |> sort
  for name in names {
    if name != "lo" and iface == "" {
      iface = name
    }
  }

  guard iface != "" else {
    return guest_bootstrap_fail_phase(ctx, phase, "no non-loopback interface for the fixture server route")
  }

  match linux.link_up(iface) {
    Ok(_) => {},
    Err(problem) => return guest_bootstrap_fail_phase(ctx, phase, f"link up: {problem.message}"),
  }

  match linux.set_ipv4_address(iface, "10.0.2.15", "255.255.255.0") {
    Ok(_) => {},
    Err(problem) => return guest_bootstrap_fail_phase(ctx, phase, f"set address: {problem.message}"),
  }

  match linux.add_default_ipv4_route("10.0.2.2", interface: iface) {
    Ok(_) => {},
    Err(problem) => return guest_bootstrap_fail_phase(ctx, phase, f"add route: {problem.message}"),
  }
}

## guest bootstrap read phase.
export proc guest_bootstrap_read_phase(ctx: GuestBootstrap) [fs, error] -> Result[Str, Error] {
  guard fp"{ctx.phase_file}".exists()? else {
    return "0"
  }

  fp"{ctx.phase_file}".read_text()?.trim()
}

## guest bootstrap write phase.
export proc guest_bootstrap_write_phase(ctx: GuestBootstrap, value: Str) [fs, error] {
  fp"{ctx.phase_file}".write(bytes.from_text(f"{value}\n"))?
  fs.fsync(fp"{ctx.phase_file}")?
  fs.fsync(fp"{GUEST_STORE_MNT}")?
}

## guest bootstrap cmdline value.
export proc guest_bootstrap_cmdline_value(ctx: GuestBootstrap, key: Str) [fs, error] -> Result[Str, Error] {
  for field in p"/proc/cmdline".read_text()?.split(" ") {
    guard field.starts_with(f"{key}=") else {
      continue
    }

    return field.byte_slice(key.byte_len() + 1, field.byte_len()).trim()
  }

  Err(GuestTrustError.Failed(phase: "cmdline", message: f"missing {key} on the kernel command line"))
}

