import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[2]
if len(sys.argv) != 3:
    raise SystemExit('usage: storage_fault.py KERNEL ROOT_DISK')
kernel, disk = (pathlib.Path(arg).resolve(strict=True) for arg in sys.argv[1:])
scratch = root / '.work/tmp'
scratch.mkdir(parents=True, exist_ok=True)
work = pathlib.Path(tempfile.mkdtemp(prefix='storage-fault-', dir=scratch))
print(f'evidence: {work}', flush=True)
inputs = work / 'inputs/inputs'
(inputs / 'lib').mkdir(parents=True)
shutil.copy(root / 'tests/integration/fixtures/storage-fault-guest.xsh', inputs / 'entry.xsh')
shutil.copy('/sbin/e2fsck', inputs / 'e2fsck')
for name in ('libext2fs.so.2', 'libcom_err.so.2', 'libblkid.so.1', 'libuuid.so.1', 'libe2p.so.2', 'libeconf.so.0'):
    shutil.copy(pathlib.Path('/usr/lib') / name, inputs / 'lib' / name)


def image(path, source=None):
    with path.open('wb') as stream:
        stream.truncate(32 * 1024 * 1024)
    argv = ['/sbin/mkfs.ext4', '-q', '-F']
    if source is not None:
        argv += ['-d', str(source)]
    subprocess.run([*argv, str(path)], check=True, timeout=30)


def boot(label, volume, marker, flags=''):
    log = work / f'{label}.log'
    args = ['qemu-system-x86_64', '-M', 'q35,accel=kvm', '-vga', 'none', '-cpu', 'host', '-smp', '2', '-m', '1G',
            '-kernel', str(kernel), '-append', 'root=PARTUUID=33333333-3333-3333-3333-333333333333 rootfstype=ext4 rootwait rw init=/init earlyprintk=serial console=ttyS0 ignore_loglevel loglevel=8 XSH_LINUX_REAL=1 XSH_UNIX_REAL=1 LAPUTA_SELF_HOSTING_PROOF=1 ' + flags,
            '-drive', f'if=none,id=root,format=raw,file={disk},snapshot=on', '-device', 'virtio-blk-pci,drive=root',
            '-drive', f'if=none,id=inputs,format=raw,file={work / "inputs.ext4"},readonly=on', '-device', 'virtio-blk-pci,drive=inputs',
            '-drive', f'if=none,id=data,format=raw,file={volume}', '-device', 'virtio-blk-pci,drive=data',
            '-display', 'none', '-serial', 'stdio', '-no-reboot']
    with log.open('wb') as output:
        child = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                contents = log.read_text(errors='replace')
                if marker in contents:
                    return
                if 'LAPUTA_SELF_HOSTING_FAILED' in contents or child.poll() is not None:
                    raise RuntimeError(f'{label} failed; inspect {log}')
                time.sleep(0.1)
            raise RuntimeError(f'{label} timed out; inspect {log}')
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=10)


for case, flag, marker, expected in (
    ('staged', 'LAPUTA_STORAGE_STAGE=1', 'STORAGE_STAGED', 'old\n'),
    ('renamed', '', 'STORAGE_RENAMED', 'either\n'),
    ('synced', 'LAPUTA_STORAGE_SYNC=1', 'STORAGE_SYNCED', 'new\n'),
):
    (inputs / 'expected').write_text(expected)
    image(work / 'inputs.ext4', work / 'inputs')
    volume = work / f'{case}.ext4'
    image(volume)
    boot(f'{case}-write', volume, marker, f'LAPUTA_STORAGE_WRITE=1 {flag}')
    boot(f'{case}-recover', volume, f'STORAGE_RECOVERED ', '')
    lines = (work / f'{case}-recover.log').read_text(errors='replace').splitlines()
    recovered = next(line for line in lines if line.startswith('STORAGE_RECOVERED '))
    print(f'PASS {case}: {recovered}', flush=True)
