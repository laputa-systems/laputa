#!/usr/bin/env python3
import sys

with open(sys.argv[1]) as source, open(sys.argv[2], "w") as target:
    target.write(source.read())
