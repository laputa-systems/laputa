#!/usr/bin/env python3

import os
import shlex
import subprocess
import sys

prefix = os.environ['MESON_INSTALL_PREFIX']
root = os.environ['MESON_INSTALL_DESTDIR_PREFIX']
assert prefix == '/usr', prefix
assert root.endswith('/usr'), root

for name in ('MESON_SOURCE_ROOT', 'MESON_BUILD_ROOT', 'MESONINTROSPECT'):
    assert os.environ.get(name), name

introspection = subprocess.run(
    shlex.split(os.environ['MESONINTROSPECT'])
    + ['--projectinfo', os.environ['MESON_BUILD_ROOT']],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
assert introspection.returncode == 0, introspection.stderr

out = os.path.join(root, 'share', 'script-fixture')
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, 'script-written.txt'), 'w') as handle:
    handle.write('written by install script\n')
os.symlink('script-written.txt', os.path.join(out, 'script-link.txt'))
with open(os.path.join(out, 'arguments.txt'), 'w') as handle:
    handle.write(' '.join(sys.argv[1:]) + '\n')
