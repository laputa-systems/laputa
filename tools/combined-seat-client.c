/* Minimal raw-protocol libseat client for the combined guest.
 * Opens seat0, opens one supported device, closes both, exits 0.
 * Speaks the seatd wire protocol directly (u16 opcode + u16 size,
 * device FD via SCM_RIGHTS) with no upstream code. Test-only. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define C_OPEN_SEAT 1
#define C_CLOSE_SEAT 2
#define C_OPEN_DEVICE 3
#define C_CLOSE_DEVICE 4
#define S_DEVICE_OPENED 0x8003
#define S_DISABLE_SEAT 0x8005
#define S_ENABLE_SEAT 0x8006
#define S_SEAT_DISABLED 0x8009

static int sock = -1;
static uint8_t rbuf[4096];
static size_t rlen = 0;
static int pending_fd = -1;

static void require(int ok, const char *what) {
	if (!ok) {
		perror(what);
		exit(1);
	}
}

static void refill(void) {
	uint8_t cbuf[CMSG_SPACE(sizeof(int))];
	struct iovec iov = { .iov_base = rbuf + rlen, .iov_len = sizeof rbuf - rlen };
	struct msghdr m;
	memset(&m, 0, sizeof m);
	m.msg_iov = &iov;
	m.msg_iovlen = 1;
	m.msg_control = cbuf;
	m.msg_controllen = sizeof cbuf;
	ssize_t n = recvmsg(sock, &m, 0);
	require(n > 0, "recvmsg");
	rlen += (size_t)n;
	struct cmsghdr *c;
	for (c = CMSG_FIRSTHDR(&m); c; c = CMSG_NXTHDR(&m, c)) {
		if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
			size_t nfd = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
			int *fds = (int *)CMSG_DATA(c);
			for (size_t i = 0; i < nfd; i++) {
				if (pending_fd >= 0)
					close(fds[i]);
				else
					pending_fd = fds[i];
			}
		}
	}
}

static void take_msg(uint16_t *op, uint8_t *body, size_t *nbody) {
	for (;;) {
		if (rlen >= 4) {
			uint16_t o = rbuf[0] | ((uint16_t)rbuf[1] << 8);
			uint16_t s = rbuf[2] | ((uint16_t)rbuf[3] << 8);
			require(s <= sizeof rbuf - 4, "frame too large");
			if (rlen >= 4u + s) {
				*op = o;
				memcpy(body, rbuf + 4, s);
				*nbody = s;
				memmove(rbuf, rbuf + 4 + s, rlen - 4 - s);
				rlen -= 4 + s;
				return;
			}
		}
		require(rlen < sizeof rbuf, "reply overflow");
		refill();
	}
}

static void send_msg(uint16_t op, const void *body, uint16_t n) {
	uint8_t f[4] = { op & 0xff, (op >> 8) & 0xff, n & 0xff, (n >> 8) & 0xff };
	require(write(sock, f, 4) == 4, "send header");
	if (n)
		require(write(sock, body, n) == (ssize_t)n, "send body");
}

static void expect(uint16_t want, uint8_t *rb, size_t *rn) {
	uint16_t op;
	take_msg(&op, rb, rn);
	if (op != want) {
		fprintf(stderr, "client: opcode 0x%x, want 0x%x\n", op, want);
		exit(1);
	}
}

static int32_t to_i32(uint8_t *b) {
	int32_t v;
	memcpy(&v, b, 4);
	return v;
}

int main(int argc, char **argv) {
	const char *devpath = argc > 1 ? argv[1] : "/dev/dri/card0";
	const char *sockpath = getenv("SEATD_SOCK");
	struct sockaddr_un addr;
	uint8_t rb[256];
	size_t rn = 0;
	if (!sockpath)
		sockpath = "/run/combined-seatd.sock";
	memset(&addr, 0, sizeof addr);
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, sockpath, sizeof addr.sun_path - 1);
	sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	require(sock >= 0, "socket");
	require(connect(sock, (struct sockaddr *)&addr, sizeof addr) == 0, "connect");
	send_msg(C_OPEN_SEAT, NULL, 0);
	expect(0x8001, rb, &rn);
	expect(S_ENABLE_SEAT, rb, &rn);
	uint8_t body[2 + 256];
	size_t plen = strlen(devpath) + 1;
	require(plen <= 256, "path too long");
	body[0] = plen & 0xff;
	body[1] = (plen >> 8) & 0xff;
	memcpy(body + 2, devpath, plen);
	send_msg(C_OPEN_DEVICE, body, (uint16_t)(2 + plen));
	expect(S_DEVICE_OPENED, rb, &rn);
	require(rn == 4, "device id size");
	require(pending_fd >= 0, "no device fd arrived");
	int fd = pending_fd;
	pending_fd = -1;
	int32_t id = to_i32(rb);
	printf("COMBINED_SEAT_DEVICE_OK\n");
	fflush(stdout);
	close(fd);
	uint8_t idb[4];
	memcpy(idb, &id, 4);
	send_msg(C_CLOSE_DEVICE, idb, 4);
	expect(0x8004, rb, &rn);
	send_msg(C_CLOSE_SEAT, NULL, 0);
	expect(0x8002, rb, &rn);
	if (pending_fd >= 0)
		close(pending_fd);
	printf("COMBINED_SEAT_OK\n");
	return 0;
}
