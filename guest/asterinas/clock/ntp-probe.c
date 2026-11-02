#define _GNU_SOURCE
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define NTP_PORT 123
#define CONTROL_PORT 32124

struct clocks {
	int64_t real_us, mono_us, boot_us;
};

static int64_t clock_us(clockid_t clock)
{
	struct timespec value;

	if (clock_gettime(clock, &value) != 0)
		exit(1);
	return (int64_t)value.tv_sec * 1000000 + value.tv_nsec / 1000;
}

static struct clocks read_clocks(void)
{
	return (struct clocks){ clock_us(CLOCK_REALTIME), clock_us(CLOCK_MONOTONIC), clock_us(CLOCK_BOOTTIME) };
}

static int64_t ntp_us(const uint8_t field[8])
{
	uint32_t seconds, fraction;

	memcpy(&seconds, field, 4);
	memcpy(&fraction, field + 4, 4);
	seconds = ntohl(seconds);
	fraction = ntohl(fraction);
	return ((int64_t)seconds - 2208988800LL) * 1000000 + (int64_t)(((uint64_t)fraction * 1000000) >> 32);
}

static void put_ntp(uint8_t field[8], int64_t micros)
{
	uint32_t seconds = htonl((uint32_t)(micros / 1000000 + 2208988800LL));
	uint32_t fraction = htonl((uint32_t)((((uint64_t)(micros % 1000000)) << 32) / 1000000));

	memcpy(field, &seconds, 4);
	memcpy(field + 4, &fraction, 4);
}

static int open_socket(const char *host, int port, struct sockaddr_in *peer)
{
	int fd = socket(AF_INET, SOCK_DGRAM, 0);

	*peer = (struct sockaddr_in){ .sin_family = AF_INET, .sin_port = htons(port) };
	if (fd < 0 || inet_pton(AF_INET, host, &peer->sin_addr) != 1)
		exit(1);
	return fd;
}

static int sample(const char *host)
{
	uint8_t request[48] = { 0x23 }, response[128];
	struct sockaddr_in peer;
	int fd = open_socket(host, NTP_PORT, &peer);
	int64_t sent, received, t2, t3;
	struct pollfd ready = { .fd = fd, .events = POLLIN };
	struct clocks at;

	sent = clock_us(CLOCK_REALTIME);
	put_ntp(request + 40, sent);
	if (sendto(fd, request, sizeof(request), 0, (struct sockaddr *)&peer, sizeof(peer)) != sizeof(request)) {
		perror("send request");
		return 1;
	}
	if (poll(&ready, 1, 1000) != 1) {
		fprintf(stderr, "no response\n");
		return 1;
	}
	if (recv(fd, response, sizeof(response), 0) < 48) {
		perror("receive response");
		return 1;
	}
	received = clock_us(CLOCK_REALTIME);
	at = read_clocks();
	if (memcmp(response + 24, request + 40, 8) != 0) {
		fprintf(stderr, "response does not echo the request\n");
		return 1;
	}
	t2 = ntp_us(response + 32);
	t3 = ntp_us(response + 40);
	printf("offset_us=%lld rtt_us=%lld real_us=%lld mono_us=%lld boot_us=%lld\n",
	       (long long)(((t2 - sent) + (t3 - received)) / 2), (long long)((received - sent) - (t3 - t2)),
	       (long long)at.real_us, (long long)at.mono_us, (long long)at.boot_us);
	return 0;
}

static int pause_guest(const char *host, long hold_ms)
{
	struct sockaddr_in peer;
	int fd = open_socket(host, CONTROL_PORT, &peer);
	struct pollfd ready = { .fd = fd, .events = POLLIN };
	char request[32], reply[128];
	struct clocks before, after;
	ssize_t length;

	snprintf(request, sizeof(request), "pause %ld", hold_ms);
	before = read_clocks();
	if (sendto(fd, request, strlen(request), 0, (struct sockaddr *)&peer, sizeof(peer)) < 0)
		return 1;
	if (poll(&ready, 1, (int)(hold_ms + 30000)) != 1)
		return 1;
	length = recv(fd, reply, sizeof(reply) - 1, 0);
	after = read_clocks();
	if (length <= 0)
		return 1;
	reply[length] = 0;
	printf("guest_real_ms=%lld guest_mono_ms=%lld guest_boot_ms=%lld %s\n",
	       (long long)((after.real_us - before.real_us) / 1000), (long long)((after.mono_us - before.mono_us) / 1000),
	       (long long)((after.boot_us - before.boot_us) / 1000), reply);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "sample") == 0)
		return sample(argv[2]);
	if (argc == 4 && strcmp(argv[1], "pause") == 0)
		return pause_guest(argv[2], strtol(argv[3], NULL, 10));
	fprintf(stderr, "usage: ntp-probe sample HOST | pause HOST HOLD_MS\n");
	return 2;
}
