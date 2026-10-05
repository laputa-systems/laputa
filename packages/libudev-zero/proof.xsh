##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libudev-zero")
  proof.target_elf(root, p"usr/lib/libudev.so.1", "libudev-zero")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "libudev-zero ok: cross-built"
    return
  }

  let cc = process.which("cc")?
  let tmp = fp"{root}/var/tmp/proof-libudev-zero"
  tmp.remove()
  tmp.mkdir(true)
  defer tmp.remove()

  # libinput and wlroots find input and DRM devices by enumerating sysfs and
  # reading each device's uevent; /sys/class/mem/null exists in every
  # container and guest, so the proof enumerates the mem subsystem.
  fp"{tmp}/proof-libudev.c".write(
    """#include <string.h>
#include <libudev.h>

int main(void) {
  struct udev *udev = udev_new();
  if (udev == NULL) return 1;
  struct udev_enumerate *e = udev_enumerate_new(udev);
  if (e == NULL || udev_enumerate_add_match_subsystem(e, "mem") < 0) return 2;
  if (udev_enumerate_scan_devices(e) < 0) return 3;
  int found = 0;
  struct udev_list_entry *entry;
  udev_list_entry_foreach(entry, udev_enumerate_get_list_entry(e)) {
    struct udev_device *dev = udev_device_new_from_syspath(udev, udev_list_entry_get_name(entry));
    if (dev == NULL) continue;
    const char *node = udev_device_get_devnode(dev);
    const char *subsystem = udev_device_get_subsystem(dev);
    if (node != NULL && strcmp(node, "/dev/null") == 0 && subsystem != NULL && strcmp(subsystem, "mem") == 0) found = 1;
    udev_device_unref(dev);
  }
  udev_enumerate_unref(e);
  udev_unref(udev);
  return found ? 0 : 4;
}
""",
  )

  let binary = fp"{tmp}/proof-libudev"
  run $cc fp"{tmp}/proof-libudev.c" f"-I{root}/usr/include" f"-L{root}/usr/lib" "-ludev" "-o" $binary

  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib".display(),
  }) {
    run $binary
  }

  print "libudev-zero ok: enumerated /dev/null through the mem subsystem"
}

main(@args)
