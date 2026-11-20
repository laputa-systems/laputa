import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import urllib.request


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def boot_oracle(console):
    return 'LAPUTA_TINYLAND_GHOSTTY_PROOF_READY' in console and 'LAPUTA_TINYLAND_GHOSTTY_PROOF_FAILED' not in console


def service_oracle(before, after, notified):
    return (before.get('pid', 0) == 0 and before.get('desired') == 'down' and
            after.get('pid', 0) > 0 and after.get('ready') is True and
            after.get('state') == 'running' and after.get('pid') == notified)


def publish_oracle(plan, store, url):
    rows = json.load(urllib.request.urlopen(url + '/index.json', timeout=10))
    nodes = plan['nodes']
    if not nodes or len(rows) != len(nodes):
        return False
    for node in nodes:
        matches = [r for r in rows if r['artifact_key'] == node['artifact_key'] and r['proof_key'] == node['proof_key']]
        if len(matches) != 1:
            return False
        row = matches[0]
        artifact = store / 'v2/sha256' / node['artifact_key']
        receipt = json.loads((artifact / 'artifact.json').read_text())
        proof = artifact / 'proof.json' if receipt['proof_key'] == node['proof_key'] else store / 'v2/proofs' / node['artifact_key'] / (node['proof_key'] + '.json')
        if row['proof_receipt_sha256'] != digest(proof):
            return False
        for path, expected in ((row['tarball'], digest(artifact / 'payload.tar.gz')),
                               (row['metadata'], row['metadata_sha256']),
                               (row['proof'], row['proof_receipt_sha256'])):
            if hashlib.sha256(urllib.request.urlopen(url + '/' + path, timeout=30).read()).hexdigest() != expected:
                return False
        if row['sha256'] != digest(artifact / 'payload.tar.gz'):
            return False
    return True


def stop_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=10)
    for _ in range(100):
        result = subprocess.run(['ps', '-eo', 'pgid=,stat='], capture_output=True, text=True, check=True)
        if not any(p[0] == str(proc.pid) for line in result.stdout.splitlines() if len(p := line.split()) == 2):
            return
        time.sleep(.01)
    raise RuntimeError('process group survived: ' + str(proc.pid))


def boot(round_dir):
    image = Path(os.environ['BENCH_PROFILE_IMAGE']).resolve()
    cmd = json.loads(subprocess.check_output([os.environ['BENCH_XSH'], 'bench/profile_argv.xsh', '--', str(image)], text=True))
    with (round_dir / 'console').open('w') as console, (round_dir / 'qemu.log').open('w') as err:
        start = time.monotonic_ns()
        proc = subprocess.Popen(cmd, cwd=round_dir, stdin=subprocess.DEVNULL, stdout=console, stderr=err, start_new_session=True)
        try:
            while time.monotonic_ns() - start < 180_000_000_000:
                output = (round_dir / 'console').read_text(errors='replace')
                if boot_oracle(output):
                    return time.monotonic_ns() - start
                if 'LAPUTA_TINYLAND_GHOSTTY_PROOF_FAILED' in output or proc.poll() is not None:
                    break
                time.sleep(.01)
            raise RuntimeError('guest did not reach readiness marker')
        finally:
            stop_group(proc)


def publish(round_dir):
    mirror = os.environ['BENCH_MIRROR']
    store = Path(os.environ['BENCH_STORE']).resolve()
    plan = Path(os.environ['BENCH_PLAN']).resolve()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    url = f'http://127.0.0.1:{port}'
    data = round_dir / 'mirror'; data.mkdir()
    with (round_dir / 'mirror.log').open('w') as log:
        server = subprocess.Popen([mirror, '--local', str(data), '--listen', f'127.0.0.1:{port}'], stdout=log, stderr=log, start_new_session=True)
        try:
            for _ in range(500):
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    if server.poll() is not None:
                        raise RuntimeError('mirror exited')
                    time.sleep(.01)
            else:
                raise RuntimeError('mirror did not listen')
            env = dict(os.environ, XSH_PM_REPO=url, XSH_PM_OFFLINE='1')
            start = time.monotonic_ns()
            subprocess.run([os.environ['BENCH_XSH'], 'pm.xsh', '--', 'repo', 'publish', str(plan), '--store', str(store)], env=env, check=True, stdout=log, stderr=log)
            elapsed = time.monotonic_ns() - start
            if not publish_oracle(json.loads(plan.read_text()), store, url):
                raise RuntimeError('published artifacts do not match plan and store')
            return elapsed
        finally:
            stop_group(server)


def service_guest():
    root = Path('/work'); (root / 'services').mkdir()
    (root / 'services/demo.xsh').write_text('''##! Benchmark service.\n## Supervised notifier.\nexport let service = {\n  name: "demo", command: process.command_argv("python3", ["python3", "/laputa/bench/scenario.py", "worker"]),\n  targets: ["bench"], readiness: "notify", ready_timeout_ms: 5000, stop_timeout_ms: 500, logging: "off",\n}\n''')
    os.environ.update(XINIT_SERVICE_DIR='/work/services', XINIT_RUN_DIR='/work/run', XINIT_LOG_ROOT='/work/logs', XSH_ROOT='/xsh', XSH_MODULE_PATH='/laputa')
    cmd = ['/tools/xsh', '/laputa/xinit/xinit.xsh', '--']
    scanner = subprocess.Popen(cmd + ['scan', 'bench'], stdout=sys.stderr)
    def status():
        try:
            return json.loads((root / 'run/demo.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}
    def wait_for(test):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            state = status()
            if test(state): return state
            if scanner.poll() is not None: raise RuntimeError('scanner exited')
            time.sleep(.005)
        raise RuntimeError('service state timed out: ' + str(status()))
    try:
        wait_for(lambda s: s.get('ready') is True)
        subprocess.run(cmd + ['stop', 'demo'], check=True, stdout=sys.stderr)
        before = wait_for(lambda s: s.get('desired') == 'down' and s.get('pid') == 0)
        (root / 'notification').unlink(missing_ok=True)
        start = time.monotonic_ns()
        subprocess.run(cmd + ['start', 'demo'], check=True, stdout=sys.stderr)
        after = wait_for(lambda s: s.get('state') == 'running' and s.get('ready') is True and (root / 'notification').exists())
        notified, end = map(int, (root / 'notification').read_text().split())
        if not service_oracle(before, after, notified) or end < start:
            raise RuntimeError('service readiness oracle failed')
        print(end - start, flush=True)
    finally:
        scanner.terminate(); scanner.wait(timeout=15)
        if scanner.returncode != 0: raise RuntimeError('scanner cleanup failed')
        remaining = [p.name for p in Path('/proc').iterdir() if p.name.isdecimal() and p.name != '1']
        if remaining: raise RuntimeError('container children remain: ' + str(remaining))


def worker():
    os.write(int(os.environ['NOTIFY_FD']), b'1')
    timestamp = time.monotonic_ns()
    temporary = Path(f'/work/notification-{os.getpid()}')
    temporary.write_text(f'{os.getpid()} {timestamp}')
    temporary.replace('/work/notification')
    signal.pause()


def service_image(xsh_root):
    dockerfile = xsh_root / 'Dockerfile.test'
    if not dockerfile.is_file():
        raise RuntimeError(f'missing XSH test image definition: {dockerfile}')
    image = 'xsh-test:' + digest(dockerfile)[:16]
    result = subprocess.run(['docker', 'image', 'inspect', image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode != 0:
        raise RuntimeError(f'missing pinned XSH test image {image}; build it with make host-xsh')
    return image


def service(round_dir):
    root = Path.cwd()
    group = round_dir / 'group'
    image = service_image(Path(os.environ['BENCH_XSH_ROOT']))
    raw = subprocess.check_output(['docker', 'run', '--rm', '--pull', 'never', '--entrypoint', 'cat', image, '/etc/group'], text=True)
    group.write_text(raw + '\nxinit-admin:x:1000:\n')
    name = f'laputa-bench-service-{os.getpid()}'
    cmd = ['docker', 'run', '--rm', '--pull', 'never', '--name', name, '--label', 'laputa.bench=xinit-service-start', '--network', 'none', '--user', '0:0', '--cap-drop', 'ALL', '--cap-add', 'CHOWN', '--read-only', '--pids-limit', '64', '--memory', '512m', '--cpus', '1', '--tmpfs', '/work:mode=0700',
           '--mount', f'type=bind,src={root},dst=/laputa,readonly', '--mount', f'type=bind,src={group.resolve()},dst=/etc/group,readonly',
           '--mount', f'type=bind,src={Path(os.environ["BENCH_XSH"]).resolve().parent},dst=/tools,readonly', '--mount', f'type=bind,src={Path(os.environ["BENCH_XSH_ROOT"]).resolve()},dst=/xsh,readonly', '--entrypoint', 'python3', image, '/laputa/bench/scenario.py', 'service-guest']
    try:
        result = subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=90)
        (round_dir / 'service.log').write_text(result.stderr)
        return int(result.stdout.strip())
    finally:
        subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=10)
        result = subprocess.run(['docker', 'ps', '-aq', '--filter', 'name=^/' + name + '$'], capture_output=True, text=True, check=True, timeout=10)
        if result.stdout.strip(): raise RuntimeError('container survived')


def cancelled(number, frame):
    raise SystemExit(128 + number)


if __name__ == '__main__':
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
        signal.signal(signum, cancelled)
    mode = sys.argv[1]
    if mode == 'worker': worker()
    elif mode == 'service-guest': service_guest()
    else:
        directory = Path(sys.argv[2]); directory.mkdir(parents=True)
        print({'boot': boot, 'publish': publish, 'service': service}[mode](directory))
