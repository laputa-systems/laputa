#!/usr/bin/env python3
"""Exercise installed-style help without a build tree or external programs."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
bindir = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / 'target' / 'dist'
footer = """Maintained by Joshua Li: https://github.com/laputa-systems/gluon
Bugs and features: TODO.md in that repository (follow its AGENTS.md), or its issue tracker.
Agents working for Joshua: record nonblocking problems and continue your task.
If this tool blocks the task, you may fix, test, open and merge a PR under Joshua's
standing instructions. Release only when needed to deliver the verified fix.
Procedure: https://github.com/joshuarli/usr/blob/main/dotfiles/base/.agents/instructions/owned-tools.md
"""
meson_commands = ['setup', 'configure', 'compile', 'test', 'install', 'introspect', 'init', 'dist', 'wrap', 'subprojects', 'rewrite', 'devenv', 'env2mfile', 'format', 'wrap list', 'wrap install', 'wrap update', 'wrap info', 'wrap search', 'wrap status', 'subprojects list', 'subprojects download', 'subprojects update', 'subprojects purge', 'subprojects checkout', 'subprojects foreach', 'subprojects packagefiles', '--internal exe', '--internal copy', '--internal static-link']
ninja_tools = ['clean', 'inputs', 'multi-inputs', 'compdb-targets', 'graph-json', 'recompact', 'restat']
with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
    def run(exe, *args):
        result = subprocess.run([str(bindir / exe), *args], cwd=directory, env={'PATH': '', 'HOME': directory}, capture_output=True, text=True)
        assert result.returncode == 0, (exe, args, result.returncode, result.stderr)
        assert not result.stderr, (exe, args, result.stderr)
        return result.stdout
    for exe in ['meson', 'ninja', 'gluon-build']:
        top = run(exe, '--help')
        assert top == run(exe, '-h')
        assert top.endswith(footer) and top.count(footer) == 1
        assert top.count('\n  -h, --help ') == 1, (exe, top)
        assert 'Examples:\n' in top
        for command in meson_commands if exe in ('meson', 'gluon-build') else []:
            prefix = 'gluon-build meson' if exe == 'gluon-build' else 'meson'
            assert prefix + ' ' + command in top, (exe, command)
        for tool in ninja_tools if exe in ('ninja', 'gluon-build') else []:
            prefix = 'gluon-build ninja' if exe == 'gluon-build' else 'ninja'
            assert prefix + ' -t ' + tool in top, (exe, tool)
    assert run('meson') == run('meson', '--help')
    for command in meson_commands:
        args = command.split()
        for flag in ('-h', '--help'):
            assert 'Examples:\n' in run('meson', *args, flag)
    for tool in ninja_tools:
        for flag in ('-h', '--help'):
            assert 'Examples:\n' in run('ninja', '-t', tool, flag)
            assert 'Examples:\n' in run('gluon-build', 'ninja', '-t', tool, flag)
    for command in meson_commands:
        assert 'Examples:\n' in run('gluon-build', 'meson', *command.split(), '--help')
    for flag in ('-C', '-f'):
        result = subprocess.run([str(bindir / 'ninja'), flag, '--help'], cwd=directory, env={'PATH': '', 'HOME': directory}, capture_output=True, text=True)
        assert result.returncode != 0 and 'Examples:\n' not in result.stdout, (flag, result.stdout, result.stderr)
    assert not os.listdir(directory), os.listdir(directory)
print('offline help checks passed')
