#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/timex.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    FILE *file = fopen(argv[2], "r");
    if (!file) { perror("open calibration"); return 1; }
    char text[4097];
    size_t len = fread(text, 1, sizeof(text) - 1, file);
    if (ferror(file) || !feof(file) || fclose(file)) return 1;
    text[len] = 0;
    const char *field = strstr(text, "\"correction\":");
    if (!field) return 1;
    char *end;
    errno = 0;
    double value = strtod(field + strlen("\"correction\":"), &end);
    if (errno || end == field + strlen("\"correction\":") || !isfinite(value) || value < 0.000005 || value >= 0.0005) return 1;
    if (strcmp(argv[1], "saved") == 0) return 0;
    int restored = strcmp(argv[1], "restored") == 0;
    if (!restored && strcmp(argv[1], "unrestored") != 0) return 2;
    struct timex state = {0};
    if (adjtimex(&state) < 0) { perror("read frequency"); return 1; }
    double actual = (double) state.freq / 65536.0 / 1000000.0;
    if ((fabs(actual - value) <= 0.000002) != restored) {
        fprintf(stderr, "unexpected frequency relative to calibration: %.9f %.9f\n", actual, value);
        return 1;
    }
    return 0;
}
