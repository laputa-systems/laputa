/* Minimal ordinary libseat client for the combined qualification guest.
 * Opens seat0, opens one supported virtual device, closes both, exits 0.
 * Built like harness/vm-probe.c in seatd-rs against the retained oracle
 * headers; it is test-only and not a runtime dependency of any daemon. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "libseat.h"

static int enabled;
static void enable(struct libseat *s, void *data) {
	(void)s;
	(void)data;
	enabled = 1;
}
static void disable(struct libseat *s, void *data) {
	(void)data;
	if (libseat_disable_seat(s) != 0) {
		perror("disable");
		exit(1);
	}
}

int main(int argc, char **argv) {
	const char *devpath = argc > 1 ? argv[1] : "/dev/dri/card0";
	struct libseat_seat_listener listener = {
		.enable_seat = enable,
		.disable_seat = disable,
	};
	struct libseat *s = libseat_open_seat(&listener, NULL);
	if (!s) {
		perror("open seat");
		return 1;
	}
	int i;
	for (i = 0; i < 50 && !enabled; i++) {
		if (libseat_dispatch(s, 1000) < 0) {
			perror("dispatch");
			return 1;
		}
	}
	if (!enabled) {
		fprintf(stderr, "client: seat never enabled\n");
		return 1;
	}
	int fd, id = libseat_open_device(s, devpath, &fd);
	if (id < 0) {
		perror("open device");
		return 1;
	}
	puts("COMBINED_SEAT_DEVICE_OK");
	fflush(stdout);
	close(fd);
	if (libseat_close_device(s, id) != 0) {
		perror("close device");
		return 1;
	}
	if (libseat_close_seat(s) != 0) {
		perror("close seat");
		return 1;
	}
	puts("COMBINED_SEAT_OK");
	return 0;
}
