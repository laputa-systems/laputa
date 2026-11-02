#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define PAYLOAD_BYTES (1024 * 1024)
#define PORT 9000

static unsigned char payload_byte(unsigned long offset)
{
    return (unsigned char)((offset * 131 + 17) % 251);
}

static int send_payload(int fd)
{
    unsigned char block[4096];
    unsigned long offset = 0;

    while (offset < PAYLOAD_BYTES) {
        size_t length = sizeof(block);
        size_t done = 0;

        for (size_t index = 0; index < length; index++)
            block[index] = payload_byte(offset + index);
        while (done < length) {
            ssize_t sent = send(fd, block + done, length - done, MSG_NOSIGNAL);

            if (sent < 0)
                return -1;
            done += (size_t)sent;
        }
        offset += length;
    }
    return 0;
}

int main(void)
{
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(PORT) };
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;

    signal(SIGPIPE, SIG_IGN);
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 4)) {
        perror("peer-tcp");
        return 1;
    }
    for (;;) {
        int fd = accept(listener, NULL, NULL);

        if (fd < 0)
            continue;
        send_payload(fd);
        shutdown(fd, SHUT_WR);
        close(fd);
    }
}
