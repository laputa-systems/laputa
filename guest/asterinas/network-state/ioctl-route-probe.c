/*
 * Issues the legacy IPv4 route ioctls that XSH's guarded linux.ioctl cannot
 * express, because its catalogue admits only ifreq-shaped requests.
 *
 * usage: ioctl-route-probe LABEL add|del|add-family|add-bad-mask DST GENMASK GW DEV
 *
 * "-" stands for an absent gateway or device. Each run prints one NET_ line and
 * exits zero so the transcript records the kernel's errno, not the probe's.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <net/route.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

static void set_address(struct sockaddr *addr, int family, const char *text)
{
	struct sockaddr_in *sin = (struct sockaddr_in *)addr;

	memset(addr, 0, sizeof(*addr));
	sin->sin_family = family;
	if (family == AF_INET && text != NULL && strcmp(text, "-") != 0)
		inet_pton(AF_INET, text, &sin->sin_addr);
}

static void report(const char *label, int rc)
{
	if (rc == 0)
		printf("NET_%s_ACK errno=0\n", label);
	else
		printf("NET_%s_ERR errno=%d\n", label, errno);
	fflush(stdout);
}

int main(int argc, char **argv)
{
	const char *label;
	const char *operation;
	struct rtentry route;
	unsigned long request;
	int fd;
	int rc;

	if (argc != 7) {
		printf("NET_route_probe_ERR errno=%d\n", EINVAL);
		return 0;
	}

	label = argv[1];
	operation = argv[2];
	memset(&route, 0, sizeof(route));

	if (strcmp(operation, "add") == 0 || strcmp(operation, "add-family") == 0 ||
	    strcmp(operation, "add-bad-mask") == 0) {
		request = SIOCADDRT;
		route.rt_flags = RTF_UP;
	} else if (strcmp(operation, "del") == 0) {
		request = SIOCDELRT;
		route.rt_flags = RTF_UP;
	} else {
		printf("NET_%s_ERR errno=%d\n", label, EINVAL);
		return 0;
	}

	set_address(&route.rt_dst,
		    strcmp(operation, "add-family") == 0 ? AF_INET6 : AF_INET,
		    argv[3]);
	set_address(&route.rt_genmask, AF_INET, argv[4]);
	if (strcmp(argv[5], "-") != 0) {
		set_address(&route.rt_gateway, AF_INET, argv[5]);
		route.rt_flags |= RTF_GATEWAY;
	}
	if (strcmp(argv[6], "-") != 0)
		route.rt_dev = argv[6];
	if (strcmp(operation, "add-bad-mask") == 0)
		inet_pton(AF_INET, "255.0.255.0", &((struct sockaddr_in *)&route.rt_genmask)->sin_addr);

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		report(label, -1);
		return 0;
	}

	rc = ioctl(fd, request, &route);
	report(label, rc);
	close(fd);
	return 0;
}
