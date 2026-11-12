#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

extern char **environ;

#ifndef ATTACK_BODY
static void probe(const char *path, const char *token)
{
    char bytes[32] = {0};
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t count = read(fd, bytes, sizeof(bytes));
        close(fd);
        if (count > 8 && !memcmp(bytes, "OUTSIDE_", 8))
            fprintf(stderr, "%s\n", token);
    }
}
#endif

int main(int argc, char **argv)
{
#ifdef ATTACK_BODY
    fprintf(stderr, "OUTSIDE_EXECUTABLE_RAN\n");
    fflush(stderr);
    const char *path = getenv("LAPUTA_MANUAL_INDEX_SENTINEL");
    int fd = path ? open(path, O_WRONLY | O_TRUNC) : -1;
    if (fd < 0)
        return 91;
    if (write(fd, "malicious executable ran\n", 25) != 25)
        return 92;
    close(fd);
    return 0;
#else
    if (argc != 5)
        return 80;
    char path[4096];
    snprintf(path, sizeof(path), "%s/retained-loader", argv[2]);
    int loader = open(path, O_RDONLY | O_CLOEXEC);
    if (loader < 0)
        return 81;
    snprintf(path, sizeof(path), "%s/.race-release", argv[4]);
    if (mkfifo(path, 0600))
        return 82;
    int release = open(path, O_RDWR | O_CLOEXEC);
    if (release < 0)
        return 83;
    snprintf(path, sizeof(path), "%s/.race-ready.tmp", argv[4]);
    int ready = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (ready < 0)
        return 84;
    char pid[32];
    int length = snprintf(pid, sizeof(pid), "%ld", (long)getpid());
    if (write(ready, pid, length) != length)
        return 84;
    close(ready);
    char published[4096];
    snprintf(published, sizeof(published), "%s/.race-ready", argv[4]);
    if (rename(path, published))
        return 84;
    char byte;
    alarm(10);
    if (read(release, &byte, 1) != 1)
        return 85;
    alarm(0);
    close(release);
    snprintf(path, sizeof(path), "%s/libz.so.1", argv[2]);
    probe(path, "OUTSIDE_LIBRARY_READ");
    snprintf(path, sizeof(path), "%s/man1/outside.1", argv[4]);
    probe(path, "OUTSIDE_MANUAL_READ");
    syscall(SYS_execveat, loader, "", argv, environ, AT_EMPTY_PATH);
    perror("retained loader");
    return 86;
#endif
}
