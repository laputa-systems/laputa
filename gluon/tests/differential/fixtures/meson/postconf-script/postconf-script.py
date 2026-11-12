#!/usr/bin/env python3

import os
import shlex
import subprocess

source = os.environ['MESON_SOURCE_ROOT']
build = os.environ['MESON_BUILD_ROOT']
assert os.path.isfile(os.path.join(source, 'meson.build')), source
assert os.path.isfile(os.path.join(build, 'build.ninja')), build

introspection = subprocess.run(
    shlex.split(os.environ['MESONINTROSPECT']) + ['--projectinfo', build],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
assert introspection.returncode == 0, introspection.stderr

with open(os.path.join(build, 'generated.h'), 'w') as handle:
    handle.write('#define POSTCONF_VALUE 42\n')
