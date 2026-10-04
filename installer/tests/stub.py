#!/usr/bin/env python3
"""External-command stand-ins for the real installer's sandbox tests."""
import json
import os
from pathlib import Path
import select
import signal
import sys
import time

state = Path('/tmp/test/state')
mode = os.environ['CASE']
name = Path(sys.argv[0]).name
args = sys.argv[1:]


def mark(key, value='yes'):
    (state / key).write_text(str(value))


def count(key):
    path = state / key
    value = int(path.read_text()) + 1 if path.exists() else 1
    mark(key, value)
    return value


def mounts():
    return json.loads((state / 'mounts').read_text())


def save_mounts(value):
    mark('mounts', json.dumps(value))


def check_input(key):
    with open('/dev/tty', 'rb', buffering=0) as tty:
        mark(key, 'buffered' if select.select([tty], [], [], 0.1)[0] else 'empty')


with (state / 'calls').open('a') as calls:
    calls.write(json.dumps([name, *args]) + '\n')

if name == 'gum':
    command = args[0]
    text = ' '.join(args)
    if command == 'style':
        print(args[-1])
    elif command == 'choose':
        if 'Disks' in args:
            choices = sys.stdin.read().splitlines()
            number = count('selections')
            disk = '/dev/vdb' if mode in ('retry-validation', 'retry-identity') and number == 1 else '/dev/vda'
            print(next(line for line in choices if line.startswith(disk + ' ')))
        else:
            if mode == 'question-signal':
                mark('question-ready')
                time.sleep(30)
            print(sys.stdin.readline().strip())
    elif command == 'input':
        if '--password' in args:
            print('pa ss$w0rd')
        elif 'Lowercase' in text:
            if count('user-inputs') > 1:
                check_input('username-input')
                print('newuser')
            else:
                print('enkidu')
        else:
            print('vmtest')
    elif command == 'filter':
        print('Etc/UTC')
    elif command == 'table':
        print(sys.stdin.read(), end='')
    elif command == 'confirm':
        if 'Reboot now?' in args:
            check_input('reboot-input')
            assert '--default=false' not in args
            mark('reboot-prompt')
            sys.exit(0 if mode == 'reboot' else 1)
    elif command == 'spin':
        if mode == 'spinner-failure' and 'Installing packages' in text:
            while not (state / 'package-ready').exists():
                time.sleep(0.01)
            sys.exit(42)
        command = args[args.index('--') + 1:]
        os.execvp(command[0], command)
    else:
        raise AssertionError(args)
elif name == 'lsblk':
    if args == ['-nrpo', 'NAME,TYPE,PKNAME,MOUNTPOINTS']:
        print('/dev/sr0 rom  /run/archiso/bootmnt\n/dev/vda disk\n/dev/vdb disk')
        if (state / 'parted').exists():
            table = mounts()
            for part in (1, 2):
                target = next((t for t, (s, _) in table.items() if s == f'/dev/vda{part}'), '')
                print(f'/dev/vda{part} part /dev/vda {target}')
    elif args == ['-dpno', 'NAME,TYPE,RO,SIZE,MODEL']:
        print('/dev/sr0 rom 1 1G QEMU DVD\n/dev/vda disk 0 60G Virtio\n/dev/vdb disk 0 60G Virtio')
    elif args[:2] == ['-bdno', 'SIZE']:
        changed = mode == 'size-swap' and (state / 'identities').exists() and int((state / 'identities').read_text()) >= 3
        print(64424509441 if changed else 64424509440)
    elif args[:2] == ['-dnro', 'RO']:
        print(1 if mode == 'retry-validation' and args[-1] == '/dev/vdb' else 0)
    elif args[:2] == ['-dnpo', 'MAJ:MIN,SERIAL,WWN']:
        number = count('identities')
        if mode == 'retry-identity' and args[-1] == '/dev/vdb':
            print('invalid')
        else:
            serial = ''
            if mode == 'serial-swap':
                serial = ' SERIAL-B' if number >= 3 else ' SERIAL-A'
            if mode == 'wwn-swap':
                serial = '  WWN-B' if number >= 3 else '  WWN-A'
            if mode == 'sequence-swap' and number >= 3:
                Path('/sys/block/vda/diskseq').write_text('8\n')
            print('253:0' + serial)
    else:
        raise AssertionError(args)
elif name == 'findmnt':
    table = mounts()
    if args == ['-rn', '-o', 'TARGET']:
        print('/\n/run/archiso/bootmnt')
        print('\n'.join(table))
    elif args[1:3] == ['-M', '/run/archiso/bootmnt']:
        print('/dev/sr0')
    elif args[1:3] == ['-M', '/run/archiso/img_dev']:
        sys.exit(1)
    elif args[1] == '-M':
        if args[2] not in table:
            sys.exit(1)
        source, ident = table[args[2]]
        print(ident if args[-1] == 'ID' else f'{source} {ident}')
    else:
        raise AssertionError(args)
elif name == 'findfs':
    assert args == ['LABEL=LIVE*'], args
    print('/dev/sr0')
elif name == 'mount':
    table = mounts()
    table[args[-1]] = [args[-2], len(table) + 10]
    save_mounts(table)
elif name == 'umount':
    target = args[0]
    table = mounts()
    attempt = count('unmount-root') if target == '/mnt' else 0
    busy = any(t.startswith(target + '/') for t in table)
    busy |= target == '/mnt' and (state / 'keyring-active').exists()
    busy |= target == '/mnt' and (mode == 'busy' or (mode == 'busy-retry' and attempt < 3))
    if busy:
        print(f'umount: {target}: target is busy.', file=sys.stderr)
        sys.exit(32)
    table.pop(target, None)
    save_mounts(table)
elif name == 'pacstrap':
    if mode in ('double-signal', 'spinner-failure', 'keys', 'username-keys'):
        table = mounts()
        for child in ('proc', 'sys', 'dev', 'run', 'tmp'):
            table['/mnt/' + child] = ['mock', 20]
        save_mounts(table)

        def cleanup(signum, frame):
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(1.0)  # More than the old 0.2-second grace period.
            save_mounts({k: v for k, v in mounts().items() if v[0] != 'mock'})
            mark('package-cleaned')
            sys.exit(143)

        signal.signal(signal.SIGTERM, cleanup)
        mark('package-ready')
        time.sleep(30 if mode in ('double-signal', 'spinner-failure') else 1.0)
        save_mounts({k: v for k, v in mounts().items() if v[0] != 'mock'})
    for directory in ('etc/default', 'etc/ufw', 'etc/pacman.d/gnupg', 'usr/bin', 'home'):
        Path('/mnt', directory).mkdir(parents=True, exist_ok=True)
    for file, content in {
        'pacman.conf': '[options]\n#[multilib]\n#Include = /etc/pacman.d/mirrorlist\n',
        'passwd': 'root:x:0:0::/root:/bin/bash\n',
        'group': 'root:x:0:\nwheel:x:998:\n',
        'locale.gen': '#en_US.UTF-8 UTF-8\n',
        'default/grub': 'GRUB_TIMEOUT=5\n',
        'ufw/ufw.conf': 'ENABLED=no\n',
    }.items():
        Path('/mnt/etc', file).write_text(content)
    if mode == 'username-keys':
        with Path('/mnt/etc/passwd').open('a') as f:
            f.write('enkidu:x:970:970::/:/bin/false\n')
    mark('keyring-active')
elif name == 'gpgconf':
    assert args == ['--homedir', '/mnt/etc/pacman.d/gnupg', '--kill', 'all']
    (state / 'keyring-active').unlink(missing_ok=True)
elif name == 'arch-chroot':
    if args[1] == 'chpasswd':
        assert ':' in sys.stdin.read()
    elif args[1] == 'starship':
        print('# starship init')
    elif args[1] == 'useradd':
        user = args[-1]
        Path('/mnt/home', user).mkdir(parents=True)
elif name == 'blkid':
    print('esp-uuid' if args[-1].endswith('1') else 'root-uuid')
elif name == 'genfstab':
    print('UUID=root-uuid / xfs defaults 0 1\nUUID=esp-uuid /boot/efi vfat defaults 0 2')
elif name == 'sgdisk':
    mark('parted')
elif name == 'timedatectl':
    print('Etc/UTC')
elif name == 'getent':
    sys.exit(2)
elif name == 'reboot':
    assert not mounts(), mounts()
    mark('rebooted')
elif name in ('curl', 'pacman', 'lspci', 'loadkeys', 'wipefs', 'partprobe',
              'udevadm', 'mkfs.fat', 'mkfs.xfs', 'sync'):
    pass
else:
    raise AssertionError(name)
