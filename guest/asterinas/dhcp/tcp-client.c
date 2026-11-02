#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define PAYLOAD_BYTES (1024 * 1024)
#define HALFWAY_BYTES (256 * 1024)
#define PORT 9000
#define RESUME_FILE "/run/dhcp-case/resume"
#define HALFWAY_FILE "/run/dhcp-case/halfway"
#define DONE_FILE "/run/dhcp-case/tcp-done"
#define WAIT_LIMIT_MS 90000
#define IDLE_LIMIT_MS 60000

static unsigned char payload_byte(unsigned long offset)
{
    return (unsigned char)((offset * 131 + 17) % 251);
}

static int connect_peer(void)
{
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(PORT) };
    int fd = socket(AF_INET, SOCK_STREAM, 0);

    inet_pton(AF_INET, "192.0.2.1", &address.sin_addr);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) {
        close(fd);
        return -1;
    }
    return fd;
}

static long read_verified(int fd, unsigned long offset, unsigned long limit, int *error)
{
    unsigned char block[4096];

    *error = 0;
    while (offset < limit) {
        struct pollfd waiting = { .fd = fd, .events = POLLIN };
        size_t want = limit - offset < sizeof(block) ? limit - offset : sizeof(block);
        ssize_t got;

        if (poll(&waiting, 1, IDLE_LIMIT_MS) != 1) {
            *error = ETIMEDOUT;
            return -1;
        }
        got = recv(fd, block, want, 0);
        if (got < 0) {
            *error = errno;
            return -1;
        }
        if (got == 0)
            break;
        for (ssize_t index = 0; index < got; index++) {
            if (block[index] != payload_byte(offset + (unsigned long)index)) {
                *error = EBADMSG;
                return -1;
            }
        }
        offset += (unsigned long)got;
    }
    return (long)offset;
}

static int transfer_whole(void)
{
    int error;
    int fd = connect_peer();
    long got;

    if (fd < 0)
        return -1;
    got = read_verified(fd, 0, PAYLOAD_BYTES, &error);
    close(fd);
    return got == PAYLOAD_BYTES ? 0 : -1;
}

static void touch(const char *path)
{
    FILE *file = fopen(path, "w");

    if (file) {
        fputs("x\n", file);
        fclose(file);
    }
}

static int finish(const char *result)
{
    printf("%s\n", result);
    fflush(stdout);
    touch(DONE_FILE);
    return 0;
}

static int wait_for(const char *path)
{
    for (int waited = 0; waited < WAIT_LIMIT_MS; waited += 100) {
        if (access(path, F_OK) == 0)
            return 0;
        usleep(100 * 1000);
    }
    return -1;
}

int main(int argc, char **argv)
{
    int error;
    int fd;
    long got;

    alarm(240);
    if (argc == 2 && !strcmp(argv[1], "transfer")) {
        printf("%s\n", transfer_whole() ? "failed" : "ok");
        return 0;
    }
    if (argc != 2 || strcmp(argv[1], "disrupted")) {
        fprintf(stderr, "usage: tcp-client transfer|disrupted\n");
        return 2;
    }
    fd = connect_peer();
    if (fd < 0)
        return finish("failed connect");
    got = read_verified(fd, 0, HALFWAY_BYTES, &error);
    if (got != HALFWAY_BYTES)
        return finish("failed before_disruption");
    touch(HALFWAY_FILE);
    if (wait_for(RESUME_FILE))
        return finish("failed no_resume");
    got = read_verified(fd, HALFWAY_BYTES, PAYLOAD_BYTES, &error);
    close(fd);
    if (got == PAYLOAD_BYTES) {
        fprintf(stderr, "DHCP_DETAIL tcp the connection survived\n");
        return finish("recovered");
    }
    fprintf(stderr, "DHCP_DETAIL tcp the connection failed with errno %d\n", error);
    return finish(transfer_whole() ? "failed reconnect" : "recovered");
}
