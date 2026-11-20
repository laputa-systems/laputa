#!/usr/bin/env python3
import argparse
import datetime
import os
import pathlib
import platform
import shlex
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
TIERS = ('Edit', 'Change', 'Scenario', 'Full')
WORK = {
    'controls': ('Edit', 'harness', ['python3', '-m', 'unittest', 'discover', '-s', 'tests/benchmarks', '-p', 'test_*.py'], 'selection and preflight controls'),
    **{name: ('Change', name, ['cargo', 'bench', '--locked', '-p', name, '--bench', name], 'synthetic component measurements') for name in ('engine', 'graph', 'state', 'meson', 'ninja')},
    'cli-corpus': ('Scenario', 'cli', ['bash', 'tests/benchmarks/run.sh'], 'setup and incremental corpus'),
    'all-components': ('Full', 'components', ['cargo', 'bench', '--locked', '--workspace'], 'all component benchmarks'),
}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('action', choices=['run', 'check', 'list'])
    p.add_argument('--tier', choices=TIERS, default='Change')
    p.add_argument('--name', action='append', default=[])
    p.add_argument('--area', action='append', default=[])
    p.add_argument('--skip', action='append', default=[])
    p.add_argument('--dry-run', action='store_true')
    args = p.parse_args()
    if args.action == 'list':
        for name, (tier, area, cmd, purpose) in WORK.items():
            print(f'{name}: {tier} area={area} {purpose}; {shlex.join(cmd)}')
        return 0
    for label, values, valid in [('name', args.name, WORK), ('skip', args.skip, WORK), ('area', args.area, {v[1] for v in WORK.values()})]:
        for value in values:
            if value not in valid:
                p.error(f'unknown {label}: {value}')
    chosen = {n: w for n, w in WORK.items() if TIERS.index(w[0]) <= TIERS.index(args.tier) and (not args.name or n in args.name) and (not args.area or w[1] in args.area) and n not in args.skip}
    if not chosen:
        p.error('selection matches no workloads')
    for n, w in WORK.items():
        if n not in chosen:
            reason = 'tier ceiling' if TIERS.index(w[0]) > TIERS.index(args.tier) else 'selector or skip'
            print(f'excluded {n}: {reason}')
    if args.dry_run:
        for n, w in chosen.items():
            print(f'{n}: {shlex.join(w[2])}')
        return 0
    errors = []
    for n, w in chosen.items():
        if not shutil.which(w[2][0]):
            errors.append(f'{n}: missing {w[2][0]}; install it and retry')
    if shutil.disk_usage(ROOT).free < 1024 ** 3:
        errors.append('selected workloads: less than 1 GiB free; free disk space and retry')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print('preflight: selected tools available; cargo rebuilds its own artifacts; host timing validity and leftover processes are not checked')
    if args.action == 'check':
        return 0
    if 'all-components' in chosen and args.tier != 'Full':
        p.error('Full requires explicit --tier Full')
    run_dir = ROOT / '.work' / 'bench' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    run_dir.mkdir(parents=True)
    env = os.environ.copy()
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    env['TMPDIR'] = str(ROOT / '.work' / 'tmp')
    pathlib.Path(env['TMPDIR']).mkdir(parents=True, exist_ok=True)
    summary = [f'host: {platform.platform()}', f'commit: {subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}', f'dirty: {bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))}', 'timing: inconclusive; no qualified pre/post host gate; completion is not a performance verdict']
    summary += [f'excluded {n}: {"tier ceiling" if TIERS.index(w[0]) > TIERS.index(args.tier) else "selector or skip"}' for n, w in WORK.items() if n not in chosen]
    failed = False
    for n, w in chosen.items():
        start = time.monotonic()
        with (run_dir / f'{n}.log').open('w') as log:
            result = subprocess.run(w[2], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        summary.append(f'{n}: exit={result.returncode} duration={time.monotonic()-start:.2f}s log={n}.log')
        failed |= result.returncode != 0
    (run_dir / 'summary.txt').write_text('\n'.join(summary) + '\n')
    print('\n'.join(summary))
    print(f'run directory: {run_dir}')
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
