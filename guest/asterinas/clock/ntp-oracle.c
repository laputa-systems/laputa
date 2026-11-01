#define _GNU_SOURCE
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static uint64_t raw_ms(void)
{
	struct timespec value;

	if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0)
		exit(1);
	return (uint64_t)value.tv_sec * 1000 + (uint64_t)value.tv_nsec / 1000000;
}

static void timestamp(uint64_t base_ms, uint64_t origin_raw_ms, long rate_ppm, uint8_t out[8])
{
	int64_t elapsed = (int64_t)(raw_ms() - origin_raw_ms);
	uint64_t millis = base_ms + elapsed + elapsed * rate_ppm / 1000000;
	uint32_t seconds = (uint32_t)(millis / 1000 + 2208988800ULL);
	uint32_t fraction = (uint32_t)(((millis % 1000) << 32) / 1000);

	seconds = htonl(seconds);
	fraction = htonl(fraction);
	memcpy(out, &seconds, 4);
	memcpy(out + 4, &fraction, 4);
}

int main(int argc, char **argv)
{
	uint8_t request[1024], response[48], time[8];
	struct sockaddr_in address = { .sin_family = AF_INET,
				       .sin_port = htons(32123) };
	uint64_t base_ms, origin_raw_ms;
	unsigned long count = 0;
	long rate_ppm = 0;
	int fd;

	if (argc == 2 && strcmp(argv[1], "--raw") == 0) {
		printf("%llu\n", (unsigned long long)raw_ms());
		return 0;
	}
	if (argc < 4)
		return 2;
	base_ms = strtoull(argv[1], NULL, 10);
	origin_raw_ms = strtoull(argv[2], NULL, 10);
	if (argc > 4)
		rate_ppm = strtol(argv[4], NULL, 10);

	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0)
		return 1;
	{
		FILE *ready = fopen(argv[3], "w");

		if (!ready)
			return 1;
		fputs("ready\n", ready);
		fclose(ready);
	}

	for (;;) {
		struct sockaddr_in peer;
		socklen_t peer_len = sizeof(peer);
		ssize_t len = recvfrom(fd, request, sizeof(request), 0,
				       (struct sockaddr *)&peer, &peer_len);
		FILE *counter;

		if (len < 0)
			return 1;
		count++;
		counter = fopen("/run/ntp-oracle-count", "w");
		if (counter) {
			fprintf(counter, "%lu", count);
			fclose(counter);
		}
		if (len < 48 || (request[0] & 7) != 3)
			continue;
		timestamp(base_ms, origin_raw_ms, rate_ppm, time);
		memset(response, 0, sizeof(response));
		response[0] = 0x24;
		response[1] = 1;
		response[2] = request[2];
		response[3] = (uint8_t)-20;
		response[8] = 0;
		response[9] = 0;
		response[10] = 0;
		response[11] = 16;
		memcpy(response + 12, "LOCL", 4);
		memcpy(response + 16, time, 8);
		memcpy(response + 24, request + 40, 8);
		memcpy(response + 32, time, 8);
		memcpy(response + 40, time, 8);
		sendto(fd, response, sizeof(response), 0, (struct sockaddr *)&peer, peer_len);
	}
}
