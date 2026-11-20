import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import subprocess
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('scenario', 'bench/scenario.py')
scenario = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scenario)
assert scenario.boot_oracle('LAPUTA_TINYLAND_GHOSTTY_PROOF_READY')
assert not scenario.boot_oracle('starting')
assert not scenario.boot_oracle('LAPUTA_TINYLAND_GHOSTTY_PROOF_FAILED LAPUTA_TINYLAND_GHOSTTY_PROOF_READY')
before = {'pid': 0, 'desired': 'down'}
after = {'pid': 42, 'state': 'running', 'ready': True}
assert scenario.service_oracle(before, after, 42)
assert not scenario.service_oracle(before, dict(after, ready=False), 42)
assert not scenario.service_oracle(before, after, 41)
assert not scenario.service_oracle(dict(before, pid=9), after, 42)
with tempfile.TemporaryDirectory(dir='.work/tmp') as tmp:
    store = Path(tmp)
    (store / 'Dockerfile.test').write_text('test image')
    expected_image = 'xsh-test:' + hashlib.sha256(b'test image').hexdigest()[:16]
    with patch.object(scenario.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as inspect:
        assert scenario.service_image(store) == expected_image
        assert inspect.call_args.args[0] == ['docker', 'image', 'inspect', expected_image]
    with patch.object(scenario.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
        try:
            scenario.service_image(store)
        except RuntimeError as error:
            assert expected_image in str(error)
        else:
            raise AssertionError('missing pinned image accepted')
    objects = {}
    nodes = []
    rows = []
    for key in ('a', 'b'):
        artifact = store / 'v2/sha256' / key
        artifact.mkdir(parents=True)
        payload = ('payload-' + key).encode()
        (artifact / 'payload.tar.gz').write_bytes(payload)
        (artifact / 'artifact.json').write_text(json.dumps({'proof_key': 'proof-' + key}))
        (artifact / 'proof.json').write_bytes(('proof-' + key).encode())
        objects['packages/' + key] = payload
        objects['metadata/' + key] = ('metadata-' + key).encode()
        objects['proof/' + key] = ('proof-' + key).encode()
        h = lambda value: hashlib.sha256(value).hexdigest()
        nodes.append({'artifact_key': key, 'proof_key': 'proof-' + key})
        rows.append({'artifact_key': key, 'proof_key': 'proof-' + key, 'tarball': 'packages/' + key,
                     'metadata': 'metadata/' + key, 'proof': 'proof/' + key, 'sha256': h(payload),
                     'metadata_sha256': h(objects['metadata/' + key]), 'proof_receipt_sha256': h(objects['proof/' + key])})
    def fetch(url, timeout):
        path = url.removeprefix('http://mirror/')
        return io.BytesIO(json.dumps(rows).encode() if path == 'index.json' else objects[path])
    with patch.object(scenario.urllib.request, 'urlopen', fetch):
        assert scenario.publish_oracle({'nodes': nodes}, store, 'http://mirror')
        objects['proof/b'] = b'corrupt'
        assert not scenario.publish_oracle({'nodes': nodes}, store, 'http://mirror')
        objects['proof/b'] = b'proof-b'
        objects['packages/b'] = b'corrupt'
        assert not scenario.publish_oracle({'nodes': nodes}, store, 'http://mirror')
        rows.pop()
        assert not scenario.publish_oracle({'nodes': nodes}, store, 'http://mirror')
        assert not scenario.publish_oracle({'nodes': []}, store, 'http://mirror')
print('scenario oracles passed')
