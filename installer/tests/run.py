#!/usr/bin/env python3
"""Run the unmodified installer in Bubblewrap; no root, network or devices needed."""
import errno
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
COMMANDS = ('gum lsblk findmnt findfs mount umount pacstrap gpgconf arch-chroot '
            'blkid genfstab sgdisk timedatectl getent reboot curl pacman lspci '
            'loadkeys wipefs partprobe udevadm mkfs.fat mkfs.xfs sync').split()
CASES = ('virtio', 'no-diskseq', 'double-signal', 'spinner-failure', 'dry-run',
         'size-swap', 'serial-swap', 'wwn-swap', 'sequence-swap', 'question-signal',
         'keys', 'username-keys', 'retry-validation', 'retry-identity', 'glob',
         'busy-retry', 'busy', 'reboot')


def inside():
    # The supervisor survives terminal signals; the actual installer receives them.
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)

    def reset_signals():
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_DFL)

    Path('/etc/pacman.conf').write_text('[options]\n#[multilib]\n#Include = mirrorlist\n')
    for name in ('vda1', 'vda2'):
        Path('/dev', name).touch()  # Regular files, never device nodes.
    Path('/tmp/archisolabel=LIVE-expanded').touch()
    command = ['bash', str(REPO / 'installer/install.sh')]
    if os.environ['CASE'] == 'dry-run':
        command.append('--dry-run')
    state = Path('/tmp/test/state')
    pid, terminal = pty.fork()
    if pid == 0:
        reset_signals()
        os.chdir('/tmp')
        os.execvp(command[0], command)
    # A separate controlling terminal keeps Ctrl+C away from Bubblewrap's monitor.
    case = os.environ['CASE']
    sent = False
    second_signal = None
    while True:
        if select.select([terminal], [], [], 0.02)[0]:
            try:
                data = os.read(terminal, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            os.write(sys.stdout.fileno(), data)
        ready = state / ('question-ready' if case == 'question-signal' else 'package-ready')
        if not sent and ready.exists():
            if case in ('double-signal', 'question-signal'):
                os.write(terminal, b'\x03')
                if case == 'double-signal':
                    second_signal = time.monotonic() + 0.05
            elif case in ('keys', 'username-keys'):
                os.write(terminal, b'stray keys\n')
            sent = True
        if second_signal is not None and time.monotonic() >= second_signal:
            os.write(terminal, b'\x03')
            mark = state / 'second-signal'
            mark.touch()
            second_signal = None
    os.close(terminal)
    _, status = os.waitpid(pid, 0)
    (state / 'exit').write_text(str(os.waitstatus_to_exitcode(status)))
    log = Path('/tmp/gilgamesh-install.log')
    if log.exists():
        shutil.copyfile(log, state / 'install.log')
    (state / 'tempfiles').write_text('\n'.join(p.name for p in Path('/tmp').glob('gilgamesh*')))
    # Check for surviving children before the PID namespace is torn down.
    survivors = []
    for process in Path('/proc').glob('[0-9]*'):
        try:
            cmd = (process / 'cmdline').read_bytes().replace(b'\0', b' ')
        except FileNotFoundError:
            continue
        if b'/tmp/test/bin/pacstrap' in cmd or b'while kill -0' in cmd:
            survivors.append(cmd.decode())
    (state / 'survivors').write_text('\n'.join(survivors))


def sandbox(case, work, library):
    state = work / 'state'
    state.mkdir()
    (state / 'mounts').write_text('{}')
    (state / 'calls').touch()
    (work / 'bin').mkdir()
    for name in COMMANDS:
        (work / 'bin' / name).symlink_to(HERE / 'stub.py')
    for disk in ('vda', 'vdb'):
        (work / 'sys/block' / disk / 'holders').mkdir(parents=True)
        if case != 'no-diskseq':
            (work / 'sys/block' / disk / 'diskseq').write_text('7\n')
    for part in ('vda1', 'vda2'):
        (work / 'sys/class/block' / part / 'holders').mkdir(parents=True)
    (work / 'sys/firmware/efi').mkdir(parents=True)
    (work / 'cmdline').write_text('archisolabel=LIVE*\n' if case == 'glob' else 'quiet\n')
    (work / 'swaps').write_text('Filename Type Size Used Priority\n')

    # This environment forbids creating a network namespace. Deny socket creation
    # with seccomp instead, in addition to stubbing all installer network commands.
    assert os.uname().machine == 'x86_64', 'seccomp syscall numbers require x86_64'
    seccomp = os.memfd_create('no-network', 0)
    instructions = [(0x20, 0, 0, 0), (0x15, 0, 1, 41),
                    (0x06, 0, 0, 0x50000 | errno.EPERM), (0x06, 0, 0, 0x7fff0000)]
    os.write(seccomp, b''.join(struct.pack('HBBI', *i) for i in instructions))
    os.lseek(seccomp, 0, os.SEEK_SET)
    command = ['bwrap', '--unshare-user', '--uid', '0', '--gid', '0',
               '--unshare-pid', '--die-with-parent', '--ro-bind', '/', '/',
               '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp',
               '--tmpfs', '/mnt', '--tmpfs', '/etc', '--bind', str(work), '/tmp/test',
               '--bind', str(work / 'sys'), '/sys',
               '--ro-bind', str(work / 'cmdline'), '/proc/cmdline',
               '--ro-bind', str(work / 'swaps'), '/proc/swaps',
               '--setenv', 'PATH', '/tmp/test/bin:' + os.environ['PATH'],
               '--setenv', 'LD_PRELOAD', str(library), '--setenv', 'CASE', case,
               '--seccomp', str(seccomp), sys.executable, str(HERE / 'run.py'), '--inside']
    pid, terminal = pty.fork()
    if pid == 0:
        os.execvp(command[0], command)
    os.close(seccomp)
    output = bytearray()
    deadline = time.monotonic() + 60
    try:
        while time.monotonic() < deadline:
            if select.select([terminal], [], [], 0.02)[0]:
                try:
                    data = os.read(terminal, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                output.extend(data)
        else:
            raise AssertionError('sandbox timed out')
    finally:
        os.close(terminal)
        os.waitpid(pid, 0)
        (state / 'output').write_bytes(output)
    return state, output.decode(errors='replace')


def verify(case, state, output):
    assert (state / 'exit').exists(), output[-3000:]
    rc = int((state / 'exit').read_text())
    expected = 130 if case in ('double-signal', 'question-signal') else 42 if case == 'spinner-failure' else 1 if case.endswith('-swap') or case == 'busy' else 0
    assert rc == expected, (case, rc, output[-3000:])
    calls = [json.loads(line) for line in (state / 'calls').read_text().splitlines()]
    names = [call[0] for call in calls]
    assert not (state / 'survivors').read_text(), 'worker survived cleanup'
    if case != 'busy':
        assert json.loads((state / 'mounts').read_text()) == {}, 'mounts left behind'
    if case in ('double-signal', 'spinner-failure'):
        assert (state / 'package-cleaned').exists(), 'worker killed before nested unmounts'
        assert 'partially installed' in output
        assert 'Installing packages' in output
        assert names.count('umount') == 2, 'cleanup repeated'
    if case == 'double-signal':
        assert 'Interrupted at step:' in output
        assert (state / 'second-signal').exists()
    elif case == 'spinner-failure':
        assert 'Progress display failed' in output and 'Interrupted at step:' not in output
    elif case.endswith('-swap'):
        assert 'refusing to wipe' in output
        assert 'partially installed' not in output
        assert not {'wipefs', 'sgdisk', 'mkfs.fat', 'mkfs.xfs'} & set(names)
    elif case == 'question-signal':
        assert 'Log:' not in output and not (state / 'install.log').exists()
    elif case == 'dry-run':
        assert output.rstrip().endswith('Dry run complete. Nothing was changed.')
        assert not (state / 'tempfiles').read_text()
        assert not {'pacman', 'pacstrap', 'mount', 'wipefs', 'curl'} & set(names)
    elif rc == 0:
        log = (state / 'install.log').read_text()
        assert log.count('==> ') == 14, log
        assert '==> DNS' in log and 'Installed successfully' in output
        assert all(command in names for command in ('wipefs', 'sgdisk', 'mkfs.fat', 'mkfs.xfs', 'pacstrap', 'arch-chroot', 'gpgconf'))
        assert names.index('gpgconf') < calls.index(['umount', '/mnt'])
        assert (state / 'reboot-input').read_text() == 'empty'
    if case == 'username-keys':
        assert (state / 'username-input').read_text() == 'empty'
    if case in ('retry-validation', 'retry-identity'):
        assert int((state / 'selections').read_text()) == 2
    if case == 'busy-retry':
        assert int((state / 'unmount-root').read_text()) == 3
    if case == 'busy':
        assert 'Run: umount -R /mnt before retrying' in output
        assert int((state / 'unmount-root').read_text()) == 4
    if case == 'reboot':
        assert (state / 'rebooted').exists()


def main():
    cases = sys.argv[1:] or CASES
    assert all(case in CASES for case in cases)
    # Everything created by the harness stays within installer/.
    with tempfile.TemporaryDirectory(prefix='.sandbox-', dir=HERE) as temp:
        root = Path(temp)
        library = root / 'fake-block.so'
        subprocess.run(['cc', '-shared', '-fPIC', str(HERE / 'fake-block.c'),
                        '-o', str(library), '-ldl'], check=True)
        for case in cases:
            work = root / case
            work.mkdir()
            start = time.monotonic()
            state, output = sandbox(case, work, library)
            verify(case, state, output)
            print(f'PASS {case} ({time.monotonic() - start:.1f}s)', flush=True)


if __name__ == '__main__':
    if sys.argv[1:] == ['--inside']:
        inside()
    else:
        main()
