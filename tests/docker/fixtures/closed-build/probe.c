#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static void require(int condition, const char *name) {
    if (!condition) { fprintf(stderr, "closed build violation: %s (errno %d)\n", name, errno); exit(1); }
}

int main(void) {
    require(getuid() != 0, "unprivileged recipe");
    require(getenv("LAPUTA_AMBIENT_POISON") == NULL, "ambient environment absent");
    const char *sentinel = getenv("LAPUTA_SENTINEL_PATH");
    require(sentinel != NULL, "explicit sentinel coordinate available");
    require(access(sentinel, F_OK) < 0 && errno == ENOENT, "undeclared host read unavailable");
    require(open(sentinel, O_WRONLY | O_TRUNC) < 0 && errno == ENOENT, "undeclared host write unavailable");
    require(symlink(sentinel, "/scratch/escape") == 0, "scratch symlink created");
    require(open("/scratch/escape", O_RDONLY) < 0 && errno == ENOENT, "symlink host read unavailable");
    require(unlink("/scratch/escape") == 0, "scratch symlink removed");
    require(symlink("/escape", "/scratch/escape") == 0, "scratch write symlink created");
    require(open("/scratch/escape", O_WRONLY | O_CREAT, 0600) < 0 && errno == EROFS, "symlink root write rejected");
    require(unlink("/scratch/escape") == 0, "scratch write symlink removed");
    require(access("/usr/bin/curl", F_OK) < 0 && errno == ENOENT, "undeclared executable unavailable");
    require(access("/usr/lib/libambient.so", F_OK) < 0 && errno == ENOENT, "undeclared library unavailable");
    require(open("/escape", O_WRONLY | O_CREAT, 0600) < 0 && errno == EROFS, "root write rejected");
    const char *source = getenv("LAPUTA_COHORT_SOURCE");
    require(source != NULL, "explicit source coordinate available");
    require(open(source, O_WRONLY | O_TRUNC) < 0 && errno == EROFS, "source write rejected");
    require(open("/usr/lib/libc.a", O_WRONLY | O_TRUNC) < 0 && errno == EROFS, "seed write rejected");
    require(socket(AF_INET, SOCK_RAW, 1) < 0 && errno == EPERM, "raw socket privilege rejected");
    int connection = socket(AF_INET, SOCK_STREAM, 0);
    require(connection >= 0, "ordinary socket available");
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(9), .sin_addr = {.s_addr = htonl(0xc0000201)}};
    require(connect(connection, (struct sockaddr *)&address, sizeof(address)) < 0 && errno == ENETUNREACH, "external network unavailable");
    require(close(connection) == 0, "ordinary socket closed");
    require(chroot("/") < 0 && errno == EPERM, "chroot privilege rejected");
    DIR *descriptors = opendir("/proc/self/fd");
    require(descriptors != NULL, "descriptor inventory available");
    struct dirent *entry;
    while ((entry = readdir(descriptors)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        int fd = atoi(entry->d_name);
        require(fd < 3 || fd == dirfd(descriptors), "no inherited descriptor");
    }
    require(closedir(descriptors) == 0, "descriptor inventory closed");
    puts("closed build authority probes passed");
    return 0;
}
