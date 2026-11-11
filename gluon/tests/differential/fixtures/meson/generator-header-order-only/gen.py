#!/usr/bin/env python3
import sys

with open(sys.argv[2], "w") as out:
    out.write("#define GENERATED_VALUE 7\n")
