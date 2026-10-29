/* Test-only libudev-zero consumer (P4 proof). Built by
 * tools/check-udev-consumer.sh against the pinned fork; receives handled
 * events on the "udev" group (0x4) and prints one line per device. */
#include <stdio.h>
#include <stdlib.h>
#include <sys/select.h>
#include <unistd.h>

#include "udev.h"

static const char *nonnull(const char *s) {
  return s ? s : "?";
}

int main(void) {
  struct udev *u = udev_new();
  struct udev_monitor *m;
  int fd, got = 0;
  if (!u) {
    fprintf(stderr, "consumer: udev_new failed\n");
    return 1;
  }
  m = udev_monitor_new_from_netlink(u, "udev");
  if (!m) {
    fprintf(stderr, "consumer: monitor failed\n");
    return 1;
  }
  if (udev_monitor_enable_receiving(m) < 0) {
    fprintf(stderr, "consumer: enable_receiving failed\n");
    return 1;
  }
  fd = udev_monitor_get_fd(m);
  while (got < 3) {
    fd_set rfds;
    struct timeval tv = { 5, 0 };
    struct udev_device *d;
    int r;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    r = select(fd + 1, &rfds, 0, 0, &tv);
    if (r <= 0) {
      fprintf(stderr, "consumer: timeout waiting for event %d\n", got);
      return 1;
    }
    d = udev_monitor_receive_device(m);
    if (!d) continue;
    printf(
      "ACTION=%s SUBSYSTEM=%s SYSNAME=%s DEVNAME=%s\n",
      nonnull(udev_device_get_action(d)),
      nonnull(udev_device_get_subsystem(d)),
      nonnull(udev_device_get_sysname(d)),
      nonnull(udev_device_get_property_value(d, "DEVNAME"))
    );
    fflush(stdout);
    udev_device_unref(d);
    got++;
  }
  return 0;
}
