error XpsPreflightError = Failed(kind: Str, message: Str)

proc ensure(condition: Bool, kind: Str, message: Str) [error] {
  if ! condition {
    Err(XpsPreflightError.Failed(kind, message))?
  }
}

proc ensure_file(root: Path, rel: Path, label: Str) [fs, error] {
  let path_value = fp"${root}/${rel}"
  ensure(fs.exists(path_value)?, "xps-preflight", f"missing ${label}: ${path_value.display()}")?
}

proc ensure_abs(path_value: Path, label: Str) [fs, error] {
  ensure(fs.exists(path_value)?, "xps-preflight", f"missing ${label}: ${path_value.display()}")?
}

proc ensure_config(config_path: Path, key: Str, label: Str) [fs, error] {
  if ! fs.exists(config_path)? {
    print f"xps-preflight skip config check: missing ${config_path.display()}"
    return
  }

  for raw in config_path.read_text()?.split("\n") {
    if raw.trim() == f"${key}=y" {
      return
    }
  }

  Err(XpsPreflightError.Failed("xps-preflight", f"${label}: expected ${key}=y"))?
}

proc verify_kernel_config(root: Path) [fs, error] {
  let config = fp"${root}/usr/share/linux/config-7.0.5"
  ensure_config(config, "CONFIG_X86_64", "x86_64 kernel")?
  ensure_config(config, "CONFIG_DRM", "DRM core")?
  ensure_config(config, "CONFIG_DRM_KMS_HELPER", "DRM KMS helper")?
  ensure_config(config, "CONFIG_DRM_I915", "Intel i915 DRM")?
  ensure_config(config, "CONFIG_DRM_SIMPLEDRM", "EFI/simpledrm boot display")?
  ensure_config(config, "CONFIG_FW_LOADER", "firmware loader")?
  ensure_config(config, "CONFIG_INPUT_EVDEV", "evdev input")?
  ensure_config(config, "CONFIG_I2C_HID", "I2C HID")?
  ensure_config(config, "CONFIG_HID_MULTITOUCH", "multitouch HID")?
  ensure_config(config, "CONFIG_ACPI_VIDEO", "ACPI video")?
  ensure_config(config, "CONFIG_BACKLIGHT_CLASS_DEVICE", "backlight")?
  ensure_config(config, "CONFIG_BLK_DEV_NVME", "NVMe storage")?
  ensure_config(config, "CONFIG_USB_XHCI_HCD", "USB xHCI")?
  ensure_config(config, "CONFIG_USB_HID", "USB HID")?
  ensure_config(config, "CONFIG_SND_HDA_INTEL", "Intel HDA audio")?
  ensure_config(config, "CONFIG_IWLWIFI", "Intel Wi-Fi")?
  ensure_config(config, "CONFIG_IWLMVM", "Intel MVM Wi-Fi")?
  ensure_config(config, "CONFIG_CFG80211", "wireless cfg80211")?
  ensure_config(config, "CONFIG_MAC80211", "wireless mac80211")?
  ensure_config(config, "CONFIG_DELL_LAPTOP", "Dell laptop platform")?
  ensure_config(config, "CONFIG_DELL_WMI", "Dell WMI")?
  ensure_config(config, "CONFIG_DELL_SMBIOS", "Dell SMBIOS")?
}

proc verify_live_hardware() [fs, error] {
  ensure_abs(/sys/module/i915, "loaded i915 module state")?
  ensure_abs(/sys/bus/pci/drivers/i915, "i915 PCI driver binding")?
  ensure_abs(/dev/dri/card0, "DRM card node")?
  ensure_abs(/dev/dri/renderD128, "DRM render node")?
}

proc verify_mesa_runtime(root: Path) [fs, error] {
  ensure_file(root, p"usr/lib/libEGL.so.1", "Mesa EGL runtime")?
  ensure_file(root, p"usr/lib/libGLESv2.so.2", "Mesa GLESv2 runtime")?
  ensure_file(root, p"usr/lib/libgbm.so.1", "Mesa GBM runtime")?
  ensure_file(root, p"usr/lib/dri/iris_dri.so", "Intel iris DRI driver")?
  ensure_file(root, p"usr/lib/dri/swrast_dri.so", "software DRI fallback")?
  ensure(! fs.exists(fp"${root}/usr/lib/libGLX.so.0")?, "xps-preflight", "GLX must not be installed in the XPS profile")?

  ensure(
    ! fs.exists(fp"${root}/usr/lib/libvulkan.so.1")?,
    "xps-preflight",
    "Vulkan must not be installed in the XPS profile",
  )?
}

proc verify_session(root: Path) [fs, error] {
  ensure_file(root, p"usr/bin/seatd", "seatd")?
  ensure_file(root, p"usr/bin/dwl", "dwl")?
}

proc main(root: Path = /, mode: Str = "live") [fs, error] {
  verify_kernel_config(root)?

  if mode == "live" {
    verify_live_hardware()?
  } else if mode != "no-live" {
    Err(XpsPreflightError.Failed("xps-preflight", f"unknown mode ${mode}; expected live or no-live"))?
  }

  verify_mesa_runtime(root)?
  verify_session(root)?
  print "xps preflight ok"
}

main(@args)?
