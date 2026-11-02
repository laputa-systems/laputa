#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/netlink.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define KERNEL_GROUP 1
#define NETLINK_KOBJECT_UEVENT_PROTOCOL 15
#define EVENT_TIMEOUT_MS 3000
#define PATH_BUFFER (2 * PATH_MAX)

static const char *class_names[] = { "block", "mem" };

static int fail(const char *name, const char *what)
{
	printf("DEV_FAILED name=%s %s\n", name, what);
	fflush(stdout);
	return 1;
}

static int read_text(const char *path, char *buffer, size_t size)
{
	int fd = open(path, O_RDONLY);
	ssize_t len;

	if (fd < 0)
		return -1;
	len = read(fd, buffer, size - 1);
	close(fd);
	if (len < 0)
		return -1;
	buffer[len] = '\0';
	return (int)len;
}

static const char *skip_components(const char *path, int count)
{
	while (count-- > 0) {
		path = strchr(path + 1, '/');
		if (path == NULL)
			return "";
	}
	return path;
}

static void normalize_devpath(const char *devpath, char *out, size_t size)
{
	if (strncmp(devpath, "/devices/pci0000:", 16) == 0) {
		snprintf(out, size, "/devices/<transport>%s", skip_components(devpath, 3));
	} else if (strncmp(devpath, "/devices/virtio-mmio-cmdline/", 29) == 0) {
		snprintf(out, size, "/devices/<transport>%s", skip_components(devpath, 3));
	} else {
		snprintf(out, size, "%s", devpath);
	}
}

static int find_class(const char *name, char *class_path, size_t size, const char **class_name)
{
	struct stat st;

	for (size_t i = 0; i < sizeof(class_names) / sizeof(class_names[0]); i++) {
		snprintf(class_path, size, "/sys/class/%s/%s", class_names[i], name);
		if (lstat(class_path, &st) == 0) {
			*class_name = class_names[i];
			return 0;
		}
	}
	return -1;
}

static int resolve_devpath(const char *class_path, char *devpath, size_t size)
{
	char real[PATH_BUFFER];

	if (realpath(class_path, real) == NULL || strncmp(real, "/sys/", 5) != 0)
		return -1;
	snprintf(devpath, size, "%s", real + 4);
	return 0;
}

static int same_object(const char *a, const char *b)
{
	char real_a[PATH_BUFFER], real_b[PATH_BUFFER];

	return realpath(a, real_a) != NULL && realpath(b, real_b) != NULL && strcmp(real_a, real_b) == 0;
}

static int check_link_target(const char *link, const char *target)
{
	return same_object(link, target);
}

static int check_sysfs(const char *name)
{
	char class_path[PATH_BUFFER], devpath[PATH_BUFFER], sysdir[PATH_BUFFER], path[PATH_BUFFER], text[512];
	char normalized[PATH_BUFFER], real[PATH_BUFFER];
	const char *class_name;
	struct stat st;
	unsigned int major_number, minor_number;
	int is_block;

	if (find_class(name, class_path, sizeof(class_path), &class_name) != 0)
		return fail(name, "no class entry");
	if (lstat(class_path, &st) != 0 || !S_ISLNK(st.st_mode))
		return fail(name, "the class entry is not a symbolic link");
	if (resolve_devpath(class_path, devpath, sizeof(devpath)) != 0)
		return fail(name, "the class entry does not resolve below /sys");
	is_block = strcmp(class_name, "block") == 0;
	snprintf(sysdir, sizeof(sysdir), "/sys%s", devpath);

	snprintf(path, sizeof(path), "%s/dev", sysdir);
	if (read_text(path, text, sizeof(text)) < 0 || sscanf(text, "%u:%u", &major_number, &minor_number) != 2)
		return fail(name, "no readable dev attribute");

	snprintf(path, sizeof(path), "/sys/dev/%s/%u:%u", is_block ? "block" : "char", major_number, minor_number);
	if (!check_link_target(path, sysdir))
		return fail(name, "the /sys/dev entry does not lead to the device");

	snprintf(path, sizeof(path), "%s/subsystem", sysdir);
	snprintf(text, sizeof(text), "/sys/class/%s", class_name);
	if (!check_link_target(path, text))
		return fail(name, "the subsystem link does not lead to the class");

	snprintf(path, sizeof(path), "/dev/%s", name);
	if (stat(path, &st) != 0 || major(st.st_rdev) != major_number || minor(st.st_rdev) != minor_number)
		return fail(name, "the device node does not carry the sysfs device number");

	normalize_devpath(devpath, normalized, sizeof(normalized));
	printf("DEV_PATH name=%s class=%s devpath=%s\n", name, class_name, normalized);

	if (is_block) {
		char parent[PATH_BUFFER], *slash;
		char disk_name[64];
		const char *parent_name;

		snprintf(parent, sizeof(parent), "%s", devpath);
		slash = strrchr(parent, '/');
		*slash = '\0';
		parent_name = strrchr(parent, '/') + 1;
		if (strcmp(parent_name, "block") == 0) {
			char virtio[PATH_BUFFER], virtio_path[PATH_BUFFER];

			snprintf(virtio, sizeof(virtio), "%s", parent);
			slash = strrchr(virtio, '/');
			*slash = '\0';
			snprintf(virtio_path, sizeof(virtio_path), "/sys%s/subsystem", virtio);
			if (!check_link_target(virtio_path, "/sys/bus/virtio"))
				return fail(name, "the disk does not sit below a virtio device");
			printf("DEV_PARENT name=%s bus=virtio\n", name);
		} else {
			snprintf(disk_name, sizeof(disk_name), "%s", parent_name);
			if (strncmp(name, disk_name, strlen(disk_name)) != 0)
				return fail(name, "the partition does not sit below its disk");
			printf("DEV_PARENT name=%s disk=%s\n", name, disk_name);
		}
		snprintf(path, sizeof(path), "%s/partition", sysdir);
		printf("DEV_KIND name=%s partition=%s\n", name, access(path, F_OK) == 0 ? "yes" : "no");
	}

	if (realpath(class_path, real) == NULL)
		return fail(name, "the class entry vanished");
	printf("DEV_NUMBER name=%s major=%u minor=%u\n", name, major_number, minor_number);

	snprintf(path, sizeof(path), "%s/uevent", sysdir);
	if (read_text(path, text, sizeof(text)) < 0)
		return fail(name, "no readable uevent attribute");
	for (char *line = strtok(text, "\n"); line != NULL; line = strtok(NULL, "\n"))
		printf("DEV_UEVENT name=%s %s\n", name, line);
	fflush(stdout);
	return 0;
}

static int open_listener(void)
{
	struct sockaddr_nl address = { .nl_family = AF_NETLINK, .nl_groups = KERNEL_GROUP };
	int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_KOBJECT_UEVENT_PROTOCOL);

	if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0)
		return -1;
	return fd;
}

static const char *field(const char *message, size_t len, const char *key)
{
	size_t key_len = strlen(key);

	for (size_t offset = 0; offset < len; offset += strlen(message + offset) + 1) {
		if (strncmp(message + offset, key, key_len) == 0 && message[offset + key_len] == '=')
			return message + offset + key_len + 1;
	}
	return NULL;
}

static int receive_event(int fd, char *buffer, size_t size)
{
	struct pollfd poll_fd = { .fd = fd, .events = POLLIN };
	ssize_t len;

	if (poll(&poll_fd, 1, EVENT_TIMEOUT_MS) != 1)
		return -1;
	len = recv(fd, buffer, size - 1, 0);
	if (len < 0)
		return -1;
	buffer[len] = '\0';
	return (int)len;
}

static int check_event(const char *name, int fd, unsigned long long *previous_seqnum, int trigger)
{
	char class_path[PATH_BUFFER], devpath[PATH_BUFFER], uevent_path[PATH_BUFFER], normalized[PATH_BUFFER];
	char message[4096], header[PATH_BUFFER];
	const char *class_name, *action, *event_devpath, *seqnum;
	int len;

	if (find_class(name, class_path, sizeof(class_path), &class_name) != 0)
		return fail(name, "no class entry");
	if (resolve_devpath(class_path, devpath, sizeof(devpath)) != 0)
		return fail(name, "the class entry does not resolve below /sys");

	if (trigger) {
		int fd_uevent;

		snprintf(uevent_path, sizeof(uevent_path), "/sys%s/uevent", devpath);
		fd_uevent = open(uevent_path, O_WRONLY);
		if (fd_uevent < 0 || write(fd_uevent, "add\n", 4) != 4)
			return fail(name, "writing add to the uevent attribute failed");
		close(fd_uevent);
	}

	len = receive_event(fd, message, sizeof(message));
	if (len <= 0) {
		printf("DEV_EVENT_MISSING name=%s\n", name);
		fflush(stdout);
		return 2;
	}

	snprintf(header, sizeof(header), "add@%s", devpath);
	if (strcmp(message, header) != 0)
		return fail(name, "the event header does not name the device");
	action = field(message, len, "ACTION");
	event_devpath = field(message, len, "DEVPATH");
	seqnum = field(message, len, "SEQNUM");
	if (action == NULL || strcmp(action, "add") != 0)
		return fail(name, "the event is not an add event");
	if (event_devpath == NULL || strcmp(event_devpath, devpath) != 0)
		return fail(name, "the DEVPATH field is not the device path");
	if (seqnum == NULL)
		return fail(name, "the event has no SEQNUM");
	if (strtoull(seqnum, NULL, 10) <= *previous_seqnum)
		return fail(name, "SEQNUM did not increase");
	*previous_seqnum = strtoull(seqnum, NULL, 10);

	normalize_devpath(devpath, normalized, sizeof(normalized));
	printf("DEV_EVENT name=%s", name);
	for (const char *key = "ACTION\0SUBSYSTEM\0MAJOR\0MINOR\0DEVNAME\0DEVTYPE\0SYNTH_UUID"; *key; key += strlen(key) + 1) {
		const char *value = field(message, len, key);

		printf(" %s=%s", key, value == NULL ? "-" : value);
	}
	printf(" DEVPATH=%s SEQNUM=present\n", normalized);
	fflush(stdout);
	return 0;
}

int main(int argc, char **argv)
{
	int status = 0;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc < 3) {
		fprintf(stderr, "usage: device-probe sysfs|events|missing NAME...\n");
		return 64;
	}
	if (strcmp(argv[1], "sysfs") == 0) {
		for (int i = 2; i < argc; i++)
			status |= check_sysfs(argv[i]);
		return status;
	}
	if (strcmp(argv[1], "events") == 0 || strcmp(argv[1], "missing") == 0) {
		int fd = open_listener();
		unsigned long long previous_seqnum = 0;
		int trigger = strcmp(argv[1], "events") == 0;

		if (fd < 0) {
			printf("DEV_FAILED name=- cannot open the uevent socket\n");
			return 1;
		}
		for (int i = 2; i < argc; i++) {
			int result = check_event(argv[i], fd, &previous_seqnum, trigger);

			if (result != 0)
				status = result;
		}
		return status;
	}
	fprintf(stderr, "unknown mode %s\n", argv[1]);
	return 64;
}
