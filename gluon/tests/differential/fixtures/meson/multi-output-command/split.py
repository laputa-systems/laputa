#!/usr/bin/env python3
import sys

first, second, *sources = sys.argv[1:]
text = "".join(open(source).read() for source in sources)
open(first, "w").write(text)
open(second, "w").write(str(len(sources)) + "\n")
