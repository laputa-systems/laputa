#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
import math
import os
import pathlib
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tarfile
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORK = ROOT / '.work/tmp/libdrm-bench'
ANCHOR = ROOT / 'tests/benchmarks/libdrm-anchor.json'
CACHE = pathlib.Path('/home/josh/repos/laputa-systems/laputa/.cache/sources/sha256')
PHASES = ('setup', 'build', 'noop', 'incremental')
OPTIONS = ['-Ddefault_library=shared', '-Dudev=false', '-Dtests=false', '-Dinstall-test-programs=false'] + [f'-D{x}=disabled' for x in ('man-pages', 'valgrind', 'cairo-tests', 'intel', 'radeon', 'amdgpu', 'nouveau', 'vmwgfx', 'omap', 'exynos', 'freedreno', 'tegra', 'vc4', 'etnaviv')]


def pins():
    return dict(line.strip().split('=', 1) for line in (ROOT / 'tests/upstream/PINS').read_text().splitlines() if line and not line.startswith('#'))


def load_anchor(path):
    data = json.loads(path.read_text())
    if set(data) != {'commit', 'host', 'date', 'metrics'} or not all(isinstance(data[k], str) and data[k] for k in ('commit', 'host', 'date')):
        raise ValueError('invalid anchor metadata')
    datetime.date.fromisoformat(data['date'])
    if not re.fullmatch(r'[0-9a-f]{40}', data['commit']):
        raise ValueError('invalid anchor commit')
    if set(data['metrics']) != set(PHASES):
        raise ValueError('invalid anchor metrics')
    for metric in data['metrics'].values():
        if set(metric) != {'value', 'tolerance'} or any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in metric.values()) or metric['value'] <= 0 or metric['tolerance'] < 0:
            raise ValueError('invalid anchor value or tolerance')
    return data


def verdict(anchor, values, qualified, host):
    if not qualified:
        return 'inconclusive', 'perf-gate-ready reported busy or overlap'
    if anchor is None:
        return 'inconclusive', 'anchor missing'
    if anchor['host'] != host:
        return 'inconclusive', 'anchor host differs'
    regressions = [p for p in PHASES if values[p] > anchor['metrics'][p]['value'] * (1 + anchor['metrics'][p]['tolerance'])]
    return ('regression', ', '.join(regressions)) if regressions else ('within budget', 'all metrics within tolerance')


def check_oracle(ref, candidate):
    for phase in ('build', 'noop', 'incremental'):
        if ref['counts'][phase] != candidate['counts'][phase]:
            raise ValueError(f'{phase} command count mismatch: {ref["counts"][phase]} != {candidate["counts"][phase]}')
    if ref['counts']['noop'] != 0 or ref['counts']['build'] == 0 or ref['counts']['incremental'] == 0:
        raise ValueError('unexpected command count')
    if not any(re.fullmatch(r'libdrm\.so\.\d+\.\d+\.\d+', pathlib.Path(name).name) for name in ref['outputs']) or ref['outputs'] != candidate['outputs']:
        raise ValueError(f'build outputs differ: {ref["outputs"]} != {candidate["outputs"]}')


def reference(name, expected, candidate):
    path = shutil.which(name)
    if not path or pathlib.Path(path).resolve() == candidate.resolve() or pathlib.Path(path).read_bytes() == candidate.read_bytes():
        raise RuntimeError(f'missing distinct reference {name}')
    if subprocess.check_output([path, '--version'], text=True).strip() != expected:
        raise RuntimeError(f'reference {name} version does not match {expected}')
    return path


def source_archive(pin):
    cached = CACHE / pin['LIBDRM_SHA256']
    archive = WORK / 'libdrm.tar.xz'
    if cached.is_file():
        shutil.copyfile(cached, archive)
    else:
        urllib.request.urlretrieve(pin['LIBDRM_URL'], archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != pin['LIBDRM_SHA256']:
        raise ValueError(f'libdrm SHA256 mismatch: {digest}')
    print(f'libdrm SHA256 verified: {digest}', flush=True)
    return archive


def gate(*args):
    return subprocess.run(['perf-gate-ready', *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def run_command(cmd):
    ready = gate()
    start = time.monotonic() if ready else None
    result = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env={**os.environ, 'NINJA_STATUS': '[%f/%t] '})
    elapsed = time.monotonic() - start if ready else None
    after = gate('-1')
    if result.returncode:
        raise RuntimeError(f'{cmd}: exit {result.returncode}\n{result.stdout}')
    return elapsed if ready and after else None, len(re.findall(r'^\[\d+/\d+\]', result.stdout, re.MULTILINE))


def outputs(build):
    return sorted(str(p.relative_to(build)) for p in build.rglob('*') if p.is_file() and (p.name.endswith('.o') or re.fullmatch(r'libdrm\.so\.\d+\.\d+\.\d+', p.name)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture-anchor', action='store_true')
    parser.add_argument('--tolerance', type=float, default=0.1)
    args = parser.parse_args()
    if not math.isfinite(args.tolerance) or args.tolerance < 0:
        parser.error('tolerance must be finite and nonnegative')
    pin = pins()
    gluon_meson, gluon_ninja = (ROOT / 'target/release' / name for name in ('meson', 'ninja'))
    tools = {'ref': (reference('meson', pin['MESON_VERSION'], gluon_meson), reference('ninja', pin['NINJA_VERSION'], gluon_ninja)), 'gluon': (str(gluon_meson), str(gluon_ninja))}
    WORK.mkdir(parents=True, exist_ok=True)
    archive = source_archive(pin)
    samples = {runner: {phase: [] for phase in PHASES} for runner in tools}
    qualified = True
    for iteration in range(3):
        states = {}
        for runner in (('ref', 'gluon') if iteration % 2 == 0 else ('gluon', 'ref')):
            directory = WORK / runner
            if directory.exists():
                shutil.rmtree(directory)
            directory.mkdir()
            with tarfile.open(archive) as tar:
                tar.extractall(directory, filter='data')
            states[runner] = {'source': directory / f'libdrm-{pin["LIBDRM_VERSION"]}', 'build': directory / 'build', 'counts': {}}
        for phase in PHASES:
            for runner in (('ref', 'gluon') if iteration % 2 == 0 else ('gluon', 'ref')):
                state = states[runner]
                meson, ninja = tools[runner]
                if phase == 'setup':
                    cmd = [meson, 'setup', str(state['build']), str(state['source']), *OPTIONS]
                else:
                    if phase == 'incremental':
                        os.utime(state['source'] / 'xf86drm.c', None)
                    cmd = [ninja, '-C', str(state['build'])]
                elapsed, count = run_command(cmd)
                if elapsed is None:
                    qualified = False
                else:
                    samples[runner][phase].append(elapsed)
                if phase != 'setup':
                    state['counts'][phase] = count
                print(f'{iteration + 1} {runner} {phase}: seconds={elapsed if elapsed is not None else "discarded"} commands={count}', flush=True)
        for state in states.values():
            state['outputs'] = outputs(state['build'])
        check_oracle(states['ref'], states['gluon'])
        print(f'oracle: matched outputs={len(states["ref"]["outputs"])} counts={states["ref"]["counts"]}', flush=True)
    medians = {}
    for runner in tools:
        medians[runner] = {phase: statistics.median(values) for phase, values in samples[runner].items() if values}
        print(f'{runner} medians seconds: {medians[runner]}', flush=True)
    host = platform.platform()
    if args.capture_anchor:
        if not qualified:
            raise RuntimeError('cannot capture anchor: perf gate deferred')
        if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True):
            raise RuntimeError('cannot capture anchor from dirty worktree')
        data = {'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'host': host, 'date': datetime.date.today().isoformat(), 'metrics': {p: {'value': medians['gluon'][p], 'tolerance': args.tolerance} for p in PHASES}}
        ANCHOR.write_text(json.dumps(data, indent=2) + '\n')
    anchor = None
    if ANCHOR.exists():
        committed = subprocess.run(['git', 'show', 'HEAD:tests/benchmarks/libdrm-anchor.json'], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if committed.returncode == 0 and committed.stdout == ANCHOR.read_bytes():
            anchor = load_anchor(ANCHOR)
    result, reason = verdict(anchor, medians['gluon'], qualified, host)
    print(f'verdict: {result}: {reason}')
    return int(result == 'regression')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'libdrm benchmark: {error}', file=sys.stderr)
        sys.exit(1)
