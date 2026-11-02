#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define NTP_PORT 123
#define CONTROL_PORT 32124

static uint64_t clock_ms(clockid_t clock)
{
	struct timespec value;

	if (clock_gettime(clock, &value) != 0)
		exit(1);
	return (uint64_t)value.tv_sec * 1000 + (uint64_t)value.tv_nsec / 1000000;
}

static void ntp_now(uint8_t out[8])
{
	struct timespec value;
	uint32_t seconds, fraction;

	if (clock_gettime(CLOCK_REALTIME, &value) != 0)
		exit(1);
	seconds = htonl((uint32_t)value.tv_sec + 2208988800U);
	fraction = htonl((uint32_t)(((uint64_t)value.tv_nsec << 32) / 1000000000ULL));
	memcpy(out, &seconds, 4);
	memcpy(out + 4, &fraction, 4);
}

static void reap_children(int signal_number)
{
	(void)signal_number;
	while (waitpid(-1, NULL, WNOHANG) > 0)
		;
}

static int bound_socket(const char *address, int port)
{
	struct sockaddr_in local = { .sin_family = AF_INET, .sin_port = htons(port) };
	int fd = socket(AF_INET, SOCK_DGRAM, 0);

	if (fd < 0 || inet_pton(AF_INET, address, &local.sin_addr) != 1 ||
	    bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0) {
		perror("bind");
		exit(1);
	}
	return fd;
}

static void answer_time(int fd)
{
	uint8_t request[1024], response[48], time[8];
	struct sockaddr_in peer;
	socklen_t peer_len = sizeof(peer);
	ssize_t length = recvfrom(fd, request, sizeof(request), 0, (struct sockaddr *)&peer, &peer_len);

	if (length < 48 || (request[0] & 7) != 3)
		return;
	ntp_now(time);
	memset(response, 0, sizeof(response));
	response[0] = 0x24;
	response[1] = 1;
	response[2] = request[2];
	response[3] = (uint8_t)-20;
	response[11] = 16;
	memcpy(response + 12, "LOCL", 4);
	memcpy(response + 16, time, 8);
	memcpy(response + 24, request + 40, 8);
	memcpy(response + 32, time, 8);
	memcpy(response + 40, time, 8);
	sendto(fd, response, sizeof(response), 0, (struct sockaddr *)&peer, peer_len);
}

static void vmm_control(const char *script, const char *action)
{
	char command[1024];

	snprintf(command, sizeof(command), "bash '%s' %s", script, action);
	if (system(command) != 0) {
		fprintf(stderr, "ntp-peer: %s failed\n", command);
		exit(1);
	}
}

static void pause_guest(int fd, const char *script, struct sockaddr_in guest, socklen_t guest_len, long hold_ms)
{
	uint64_t real_start, mono_start;
	struct timespec hold = { .tv_sec = hold_ms / 1000, .tv_nsec = (hold_ms % 1000) * 1000000L };
	char reply[128];

	real_start = clock_ms(CLOCK_REALTIME);
	mono_start = clock_ms(CLOCK_MONOTONIC);
	vmm_control(script, "pause");
	nanosleep(&hold, NULL);
	vmm_control(script, "resume");
	snprintf(reply, sizeof(reply), "resumed peer_real_ms=%llu peer_mono_ms=%llu",
		 (unsigned long long)(clock_ms(CLOCK_REALTIME) - real_start),
		 (unsigned long long)(clock_ms(CLOCK_MONOTONIC) - mono_start));
	fprintf(stderr, "ntp-peer: %s\n", reply);
	sendto(fd, reply, strlen(reply), 0, (struct sockaddr *)&guest, guest_len);
}

static void answer_control(int fd, const char *script)
{
	char request[64];
	struct sockaddr_in guest;
	socklen_t guest_len = sizeof(guest);
	ssize_t length = recvfrom(fd, request, sizeof(request) - 1, 0, (struct sockaddr *)&guest, &guest_len);
	long hold_ms;

	if (length <= 0)
		return;
	request[length] = 0;
	if (sscanf(request, "pause %ld", &hold_ms) != 1 || hold_ms <= 0 || hold_ms > 60000)
		return;
	if (fork() == 0) {
		signal(SIGCHLD, SIG_DFL);
		pause_guest(fd, script, guest, guest_len, hold_ms);
		_exit(0);
	}
}

int main(int argc, char **argv)
{
	int time_fd, control_fd;
	struct pollfd fds[2];

	if (argc != 4) {
		fprintf(stderr, "usage: ntp-peer ADDRESS VMM_CONTROL_SCRIPT READY_FILE\n");
		return 2;
	}
	signal(SIGCHLD, reap_children);
	time_fd = bound_socket(argv[1], NTP_PORT);
	control_fd = bound_socket(argv[1], CONTROL_PORT);
	{
		FILE *ready = fopen(argv[3], "w");

		if (!ready)
			return 1;
		fputs("ready\n", ready);
		fclose(ready);
	}
	fds[0] = (struct pollfd){ .fd = time_fd, .events = POLLIN };
	fds[1] = (struct pollfd){ .fd = control_fd, .events = POLLIN };
	for (;;) {
		if (poll(fds, 2, -1) < 0 && errno != EINTR)
			return 1;
		if (fds[0].revents & POLLIN)
			answer_time(time_fd);
		if (fds[1].revents & POLLIN)
			answer_control(control_fd, argv[2]);
	}
}
