#include <stdio.h>

int main(int argc, char **argv) {
    FILE *in;
    FILE *out;
    char line[256];

    (void)argc;
    in = fopen(argv[1], "r");
    out = fopen(argv[2], "w");
    if (in == NULL || out == NULL) {
        return 1;
    }
    fputs("#ifndef GENERATED_H\n#define GENERATED_H\n", out);
    while (fgets(line, sizeof line, in) != NULL) {
        fputs(line, out);
    }
    fputs("#endif\n", out);
    fclose(in);
    fclose(out);
    return 0;
}
