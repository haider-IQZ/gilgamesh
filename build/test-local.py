#!/usr/bin/env python3
"""Offline failure-path tests. Arch commands use fixtures; no downloads or privilege."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalBuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def shell(self, code, ok=True, env=None):
        result = subprocess.run(
            ['bash', '-Eeuo', 'pipefail', '-c',
             'source "$TEST_ROOT/build/lib.sh"\n' + code],
            cwd=self.path, text=True, capture_output=True,
            env={**os.environ, 'TEST_ROOT': str(ROOT), **(env or {})})
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def test_package_order_and_cycle(self):
        for name, text in {
            'shell': 'pkgbase = gilgamesh-shell\n\tdepends = gilgamesh-settings>=1\n\npkgname = gilgamesh-shell\n',
            'settings': 'pkgbase = gilgamesh-settings\n\tdepends = systemd\n\npkgname = gilgamesh-settings\n',
            'driver': 'pkgbase = nvidia-open-tkg\n\tmakedepends = linux-tkg-headers\n\npkgname = nvidia-open-tkg\n\tdepends = linux-tkg=\n',
            'kernel': 'pkgname = linux-tkg\npkgname = linux-tkg-headers\n',
        }.items():
            (self.path / name).mkdir()
            (self.path / name / '.SRCINFO').write_text(text)
        result = self.shell('package_order shell driver settings kernel')
        order = result.stdout.splitlines()
        self.assertLess(order.index('settings'), order.index('shell'))
        self.assertLess(order.index('kernel'), order.index('driver'))
        (self.path / 'settings/.SRCINFO').write_text('pkgbase = gilgamesh-settings\n\tdepends = gilgamesh-shell\n\npkgname = gilgamesh-settings\n')
        self.shell('package_order shell settings', ok=False)

    def test_container_orders_builds_and_refreshes_only_local_database(self):
        work = self.path / 'work'
        for directory in ('build/cache', 'repo/x86_64', 'packages/gilgamesh-settings', 'packages/gilgamesh-shell', 'sync'):
            (work / directory).mkdir(parents=True)
        for name in ('gilgamesh-settings', 'gilgamesh-shell'):
            (work / 'packages' / name / 'PKGBUILD').write_text('pkgname=' + name + '\n')
        for name in ('lib.sh', 'check-sources.awk'):
            (work / 'build' / name).write_text((ROOT / 'build' / name).read_text())
        conf = self.path / 'pacman.conf'
        conf.write_text('[options]\nSigLevel = Required DatabaseOptional\n[core]\nServer = official\n')
        script = (ROOT / 'build/container.sh').read_text().replace('/work', str(work)).replace('/etc/pacman.conf', str(conf)).replace('/var/lib/pacman/sync', str(work / 'sync'))
        (self.path / 'container.sh').write_text(script)
        self.shell(r'''
id() { echo 0; }
groupmod() { :; }
usermod() { :; }
chown() { :; }
df() { printf 'header\nfs 100 20 999999999 1%% /\n'; }
bsdtar() { cat "$2"; }
vercmp() { echo 0; }
repo-add() { printf '%s\n' "$@" > "$1"; cp "$1" "${1/.db./.files.}"; }
pacman() {
    printf 'pacman %s\n' "$*" >> "$EVENTS"
    if [[ $1 == --config && " $* " == *' -Syy '* ]]; then
        ! grep -q '^\[core\]' "$2"
        grep -q '^\[gilgamesh\]' "$2"
    elif [[ $1 == -S && " $* " == *' gilgamesh-settings '* ]]; then
        grep -q 'gilgamesh-settings-' "$PKGDEST/gilgamesh.db"
    fi
}
runuser() {
    name=${PWD##*/}
    case ${@: -1} in
        metadata)
            printf 'pkgbase = %s\n' "$name" > .SRCINFO
            [[ $name != gilgamesh-shell ]] || printf '\tdepends = gilgamesh-settings\n' >> .SRCINFO
            printf '\npkgname = %s\n' "$name" >> .SRCINFO
            ;;
        build)
            printf 'build %s\n' "$name" >> "$EVENTS"
            printf 'pkgname = %s\npkgver = 1-1\n' "$name" > "$PKGDEST/$name-1-1.pkg.tar.zst"
            ;;
        *) return 1 ;;
    esac
}
export -f id groupmod usermod chown df bsdtar vercmp repo-add pacman runuser
export BUILDER_UID=1000 BUILDER_GID=1000 BUILD_JOBS=2 EVENTS=$PWD/events
bash container.sh pkg gilgamesh-shell gilgamesh-settings
''')
        events = (self.path / 'events').read_text().splitlines()
        settings = events.index('build gilgamesh-settings')
        shell = events.index('build gilgamesh-shell')
        self.assertLess(settings, shell)
        self.assertTrue(any('-Syy' in line for line in events[settings + 1:shell]))
        self.assertEqual(sum('-Syu' in line for line in events), 1)
        self.assertFalse(any('-Sy' in line and '-Syu' not in line and '--config' not in line for line in events))

    def test_missing_resolve_btfids_stops_before_packaging(self):
        worker = (ROOT / 'build/worker.sh').read_text()
        guard = worker.split("<<'WRAPPER'\n", 1)[1].split('\nWRAPPER', 1)[0]
        command = 'srcdir=$PWD/src; startdir=$PWD; mkdir -p src; build() { :; }; prepare() { :; };\n' + guard + '\nbuild\ntouch packaged\n'
        result = self.shell(command, ok=False)
        self.assertIn('resolve_btfids missing', result.stderr)
        self.assertFalse((self.path / 'packaged').exists())
        binary = self.path / 'src/linux/tools/bpf/resolve_btfids/resolve_btfids'
        binary.parent.mkdir(parents=True)
        binary.write_text('#!/bin/sh\nexit 0\n')
        binary.chmod(0o755)
        self.shell(command)
        self.assertTrue((self.path / 'packaged').exists())

    def test_iso_staging_and_cleanup(self):
        for failure in ('none', 'mkarchiso', 'go', 'checksum'):
            with self.subTest(failure=failure):
                work = self.path / failure
                for directory in ('build/cache', 'repo/x86_64', 'sync', 'out', 'tools/cmd', 'tools/internal'):
                    (work / directory).mkdir(parents=True)
                shutil.copytree(ROOT / 'iso', work / 'iso', symlinks=True)
                for name in ('lib.sh', 'iso-payload.sh'):
                    shutil.copyfile(ROOT / 'build' / name, work / 'build' / name)
                for name in ('installer', 'system', 'quickshell', 'hypr', 'fish', 'scripts', 'etc', 'branding', 'kernel'):
                    (work / name).mkdir()
                    (work / name / 'fixture').write_text(name)
                (work / 'installer/packages').write_text('base\n')
                (work / 'installer/install.sh').write_text('# manual fallback\n')
                (work / 'tools/go.mod').write_text('module fixture\ngo 1.26.0\n')
                (work / 'tools/go.sum').write_text('pinned-checksums\n')
                (work / 'tools/bin').mkdir()
                (work / 'tools/bin/stale').touch()
                (work / 'tools/.test-work').mkdir()
                (work / 'keys').mkdir()
                (work / 'keys/gilgamesh.asc').write_text('public-key-fixture\n')
                (work / 'keys/not-for-image').touch()
                for name in ('linux-tkg', 'linux-tkg-headers', 'nvidia-open-tkg', 'nvidia-utils',
                             'nvidia-open-dkms', 'gilgamesh-settings', 'gilgamesh-shell'):
                    deps = 'depend = linux-tkg=1-1\n' if name == 'nvidia-open-tkg' else ''
                    (work / f'repo/x86_64/{name}-1-1.pkg.tar.zst').write_text(
                        f'pkgname = {name}\npkgver = 1-1\n{deps}')
                conf = work / 'pacman.conf'
                conf.write_text('[options]\nSigLevel = Required DatabaseOptional\n[core]\nServer = official\n')
                script = (ROOT / 'build/container.sh').read_text().replace('/work/', str(work) + '/')
                script = script.replace('GILGAMESH_ROOT=/work ', f'GILGAMESH_ROOT={work} ')
                script = script.replace(' /work ', f' {work} ')
                script = script.replace(' /etc/pacman.conf', ' ' + str(conf)).replace('/var/lib/pacman/sync', str(work / 'sync'))
                (work / 'container.sh').write_text(script)
                self.shell(r'''
id() { echo 0; }
groupmod() { :; }
usermod() { :; }
chown() { :; }
df() { printf 'header\nfs 100 20 999999999 1%% /\n'; }
bsdtar() { cat "$2"; }
vercmp() { echo 0; }
repo-add() { printf 'database\n' > "$1"; cp "$1" "${1/.db./.files.}"; }
pacman() { printf 'pacman %s\n' "$*" >> "$FIXTURE/events"; }
go() {
    printf 'go %s\n' "$*" >> "$FIXTURE/events"
    [[ $CGO_ENABLED == 0 && $GOFLAGS == -mod=mod && $GOTOOLCHAIN == local && $GOENV == off ]]
    [[ $GOOS == linux && $GOARCH == amd64 ]]
    [[ ! -e bin/stale && ! -e .test-work ]]
    case "$*" in
        'mod download')
            if [[ $FAILURE == checksum ]]; then echo changed >> go.sum; fi
            ;;
        'mod verify') ;;
        *)
            [[ $1 == build && $2 == -trimpath && $3 == -buildvcs=false && $4 == -ldflags ]]
            [[ $5 == '-s -w -buildid=' && $6 == -o && $8 == ./cmd/gilgamesh-* ]]
            [[ $FAILURE != go ]] || return 1
            mkdir -p bin
            printf 'built %s\n' "$8" > "$7"
            ;;
    esac
}
mksquashfs() { :; }
mkarchiso() {
    printf 'mkarchiso\n' >> "$FIXTURE/events"
    [[ $1 == -v && $2 == -w && $4 == -o ]]
    mkdir -p "$3"
    touch "$3/diagnostic"
    cp -a "$6" "$FIXTURE/inspected-profile"
    [[ $FAILURE != mkarchiso ]] || return 1
    touch "$5/fixture.iso"
}
export -f id groupmod usermod chown df bsdtar vercmp repo-add pacman go mksquashfs mkarchiso
export BUILDER_UID=1000 BUILDER_GID=1000 BUILD_JOBS=2
bash "$FIXTURE/container.sh" iso
''', ok=failure == 'none', env={'FIXTURE': str(work), 'FAILURE': failure})
                runs = list((work / 'build/cache').glob('run.*'))
                self.assertEqual(len(runs), 0 if failure == 'none' else 1)
                self.assertEqual((work / 'out/fixture.iso').exists(), failure == 'none')
                self.assertEqual((work / 'tools/go.sum').read_text(), 'pinned-checksums\n')
                events = (work / 'events').read_text()
                self.assertIn('pacman -S --needed --noconfirm archiso mkinitcpio go', events)
                if failure in ('go', 'checksum'):
                    self.assertNotIn('mkarchiso', events)
                    continue
                live = work / 'inspected-profile/airootfs'
                payload = live / 'opt/gilgamesh/src'
                launcher = live / 'usr/local/bin/gilgamesh-install'
                self.assertTrue(launcher.is_symlink())
                binary = live / os.readlink(launcher).lstrip('/')
                self.assertTrue(os.access(binary, os.X_OK))
                self.assertEqual(binary.parent.parent.parent, payload)
                self.assertTrue((payload / 'installer/packages').is_file())
                self.assertTrue((payload / 'installer/install.sh').is_file())
                self.assertTrue(os.access(binary.with_name('gilgamesh-dns'), os.X_OK))
                self.assertEqual(sorted(p.name for p in (payload / 'tools').iterdir()), ['bin'])
                self.assertEqual(sorted(p.name for p in (payload / 'keys').iterdir()), ['gilgamesh.asc'])
                self.assertEqual((live / 'opt/gilgamesh/repo/gilgamesh.db').read_text(), 'database\n')
                self.assertEqual(len(list((live / 'opt/gilgamesh/repo').glob('*.pkg.tar.zst'))), 7)
                config = (live / 'etc/pacman.conf').read_text()
                self.assertIn('Server = file:///opt/gilgamesh/repo', config)
                self.assertLess(config.index('[gilgamesh]'), config.index('[core]'))
                self.assertEqual(config.count('SigLevel = Never'), 1)
                self.assertRegex(config, r'(?m)^SigLevel\s*= Required DatabaseOptional$')
                if failure == 'mkarchiso':
                    self.assertTrue((runs[0] / 'work/diagnostic').is_file())

    def test_iso_autostart_go_once_after_network_and_keyring(self):
        script = (ROOT / 'iso/airootfs/root/.automated_script.sh').read_text()
        script = script.replace('/proc/cmdline', str(self.path / 'cmdline'))
        script = script.replace('/run/gilgamesh-installer-started', str(self.path / 'started'))
        script = script.replace('/usr/local/bin/gilgamesh-install', 'installer_fixture')
        (self.path / 'startup.sh').write_text(script)
        (self.path / 'cmdline').write_text('quiet\n')
        self.shell(r'''
tty() { echo /dev/tty1; }
curl() { echo network >> events; }
systemctl() { [[ $* == 'start pacman-init.service' ]]; echo keyring >> events; }
installer_fixture() { [[ $TERM == linux ]]; echo installer >> events; }
export -f tty curl systemctl installer_fixture
export TERM=dumb
bash startup.sh
bash startup.sh
''')
        self.assertEqual((self.path / 'events').read_text().splitlines(), ['network', 'keyring', 'installer'])

    def test_signature_scope_and_precedence(self):
        source = self.path / 'pacman.conf'
        source.write_text('[options]\nSigLevel = Required DatabaseOptional\n[core]\nServer = official\n[gilgamesh]\nSigLevel = Never\nServer = old\n[extra]\nServer = official\n')
        self.shell('repo_config pacman.conf staged.conf file:///repo Never')
        config = (self.path / 'staged.conf').read_text()
        self.assertEqual(config.count('[gilgamesh]'), 1)
        self.assertLess(config.index('[gilgamesh]'), config.index('[core]'))
        self.assertEqual(config.count('SigLevel = Never'), 1)
        self.assertIn('[options]\nSigLevel = Required DatabaseOptional', config)
        self.shell('repo_config staged.conf signed.conf https://example.invalid/repo "Required DatabaseRequired"')
        self.assertNotIn('Never', (self.path / 'signed.conf').read_text())

    def test_space_guard(self):
        self.shell("df() { printf 'header\\nfs 100 20 1048576 20%% /\\n'; }; check_space . 1")
        self.shell("df() { printf 'header\\nfs 100 20 1048576 20%% /\\n'; }; check_space . 2", ok=False)
        self.shell('positive_integer BUILD_JOBS 0', ok=False)

    def archive(self, name, version, depends=()):
        (self.path / f'{name}-{version}.pkg.tar.zst').write_text(
            f'pkgname = {name}\npkgver = {version}\n' +
            ''.join(f'depend = {dep}\n' for dep in depends))

    def repo_shell(self, command, ok=True):
        return self.shell('''
export PKGDEST=$PWD
declare -A versions=() latest=() metadata=()
bsdtar() { cat "$2"; }
# Fixtures use numeric versions; production always uses libalpm's vercmp.
vercmp() {
    if [[ $1 == "$2" ]]; then echo 0
    elif [[ $(printf '%s\\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]; then echo 1
    else echo -1; fi
}
repo-add() {
    printf 'new-db' > "$1"
    printf 'new-files' > "${1/.db./.files.}"
}
''' + command, ok=ok)

    def test_newest_kernel_cannot_pair_with_old_driver(self):
        self.archive('linux-tkg', '7.2.1-1')
        self.archive('linux-tkg-headers', '7.2.1-1')
        self.archive('linux-tkg', '7.2.2-1')
        self.archive('linux-tkg-headers', '7.2.2-1')
        self.archive('nvidia-open-tkg', '615.1-1', ['linux-tkg=7.2.1-1'])
        (self.path / 'gilgamesh.db.tar.zst').write_text('old-db')
        self.repo_shell('index_repo strict', ok=False)
        self.assertEqual((self.path / 'gilgamesh.db.tar.zst').read_text(), 'old-db')
        self.repo_shell('select_packages; check_coherence bootstrap; [[ ! -v latest[nvidia-open-tkg] ]]')
        self.repo_shell('select_packages; check_coherence complete', ok=False)

    def test_kernel_headers_must_match(self):
        self.archive('linux-tkg', '7.2.1-2')
        self.archive('linux-tkg-headers', '7.2.1-1')
        self.repo_shell('index_repo bootstrap', ok=False)

    def test_complete_repo_and_exact_userspace(self):
        self.archive('linux-tkg', '7.2.1-2')
        self.archive('linux-tkg-headers', '7.2.1-2')
        self.archive('nvidia-open-tkg', '615.1-1', ['linux-tkg=7.2.1-2', 'nvidia-utils=615.1'])
        self.archive('nvidia-utils', '615.1-3')
        self.archive('gilgamesh-settings', '1-1')
        self.archive('gilgamesh-shell', '1-1', ['gilgamesh-settings'])
        self.repo_shell('index_repo complete')
        self.assertEqual((self.path / 'gilgamesh.db').read_text(), 'new-db')
        self.archive('nvidia-utils', '615.2-1')
        self.repo_shell('select_packages; check_coherence strict', ok=False)
        self.repo_shell('select_packages; check_coherence bootstrap; [[ ! -v latest[nvidia-open-tkg] ]]')

    def test_failed_repo_add_preserves_database(self):
        self.archive('gilgamesh-settings', '1-1')
        (self.path / 'gilgamesh.db.tar.zst').write_text('old-db')
        self.repo_shell('repo-add() { return 1; }; index_repo', ok=False)
        self.assertEqual((self.path / 'gilgamesh.db.tar.zst').read_text(), 'old-db')

    def test_source_policy_matches_ci(self):
        spec = importlib.util.spec_from_file_location('source_policy', ROOT / 'ci/check-sources.py')
        policy = importlib.util.module_from_spec(spec)
        # Execute without creating a bytecode cache in ci/.
        exec(compile(Path(spec.origin).read_text(), spec.origin, 'exec'), policy.__dict__)
        cases = [
            'source = local.patch\nsha256sums = SKIP\n',
            'source = https://example.invalid/file\nsha256sums = ' + 'a' * 64 + '\n',
            'source_x86_64 = file::https://example.invalid/file\nsha512sums_x86_64 = ' + 'b' * 128 + '\n',
            'source = https://example.invalid/file\nsha256sums = SKIP\n',
            'source = https://example.invalid/file\n',
            'source = https://example.invalid/file\nmd5sums = ' + 'a' * 32 + '\n',
            'source = https://example.invalid/file\nsha256sums = ' + 'a' * 64 + '\nsha256sums = ' + 'b' * 64 + '\n',
            'source = git+https://example.invalid/repo#commit=abc\nsha256sums = SKIP\n',
        ]
        for case in cases:
            expected = True
            try:
                policy.check(case)
            except ValueError:
                expected = False
            result = subprocess.run(['awk', '-f', str(ROOT / 'build/check-sources.awk')],
                                    input=case, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, expected, case)

    def test_config_gate_rejects_lost_btf_and_storage(self):
        symbols = '''64BIT X86_64 MODULES BLK_DEV_INITRD DEVTMPFS PCI VIRTIO VIRTIO_PCI VIRTIO_BLK
XFS_FS SCHED_BORE NUMA PREEMPT PREEMPT_DYNAMIC HZ_1000 NO_HZ_IDLE LRU_GEN TRANSPARENT_HUGEPAGE_MADVISE
HALTPOLL_CPUIDLE BPF BPF_SYSCALL BPF_JIT BPF_EVENTS FTRACE SCHED_CLASS_EXT DEBUG_INFO
DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES SYSFS TMPFS
SQUASHFS_XZ BLK_DEV_LOOP SQUASHFS OVERLAY_FS BLK_DEV_NVME ATA SATA_AHCI SCSI BLK_DEV_SD
USB_STORAGE USB_XHCI_HCD VIRTIO_NET ISO9660_FS VFAT_FS EXT4_FS BLK_DEV_SR BLK_DEV_NBD NFS_FS'''.split()
        config = ''.join(f'CONFIG_{name}=y\n' for name in symbols)
        (self.path / '.config').write_text(config)
        self.shell('bash "$TEST_ROOT/kernel/check-config.sh" .config')
        (self.path / '.config').write_text(config.replace('CONFIG_DEBUG_INFO_BTF=y', '# CONFIG_DEBUG_INFO_BTF is not set'))
        self.shell('bash "$TEST_ROOT/kernel/check-config.sh" .config', ok=False)
        (self.path / '.config').write_text(config.replace('CONFIG_VIRTIO_BLK=y', 'CONFIG_VIRTIO_BLK=m'))
        self.shell('bash "$TEST_ROOT/kernel/check-config.sh" .config', ok=False)

    def test_nvidia_unavailable_fails_before_install(self):
        (self.path / '.SRCINFO').write_text('depends = nvidia-utils=615.1\nmakedepends = nvidia-open-dkms=615.1\n')
        self.shell('''
pacman() { [[ $1 == -Sp ]] || touch unexpected-install; return 1; }
export -f pacman
bash "$TEST_ROOT/packages/nvidia-open-tkg/preflight.sh" .SRCINFO inputs repo
''', ok=False)
        self.assertFalse((self.path / 'unexpected-install').exists())

    def test_live_hook_precedence_and_stock_boot_paths(self):
        self.shell('''
source "$TEST_ROOT/system/etc/mkinitcpio.conf.d/gilgamesh.conf"
source "$TEST_ROOT/iso/airootfs/etc/mkinitcpio.conf.d/zz-archiso.conf"
[[ " ${HOOKS[*]} " == *' archiso '* && " ${HOOKS[*]} " == *' archiso_pxe_nfs '* ]]
''')
        packages = (ROOT / 'iso/packages.x86_64').read_text().splitlines()
        self.assertIn('linux', packages)
        self.assertNotIn('linux-tkg', packages)
        for folder in ('efiboot', 'syslinux', 'grub'):
            files = [p.read_text() for p in (ROOT / 'iso' / folder).rglob('*.conf')]
            files += [p.read_text() for p in (ROOT / 'iso' / folder).rglob('*.cfg')]
            self.assertIn('vmlinuz-linux', ''.join(files))
            self.assertNotIn('vmlinuz-linux-tkg', ''.join(files))

    def test_image_gate_runs_before_compression(self):
        script = (ROOT / 'build/iso-image.sh').read_text().replace('/work/build/lib.sh', str(ROOT / 'build/lib.sh'))
        (self.path / 'guard.sh').write_text(script)
        (self.path / 'initramfs-linux.img').touch()
        (self.path / 'vmlinuz-linux').touch()
        hooks = ['archiso', 'archiso_loop_mnt', 'archiso_pxe_common', 'archiso_pxe_nbd', 'archiso_pxe_http', 'archiso_pxe_nfs']
        (self.path / 'contents').write_text(''.join(f'hooks/{hook}\n' for hook in hooks))
        command = '''
lsinitcpio() { cat contents; }
compress() { touch compressed; }
export -f lsinitcpio compress
# exec cannot invoke a function, so use an executable fixture.
printf '#!/usr/bin/env bash\\ntouch compressed\\n' > squashfs
chmod +x squashfs
export GILGAMESH_ISO_WORK=$PWD GILGAMESH_MKSQUASHFS=$PWD/squashfs
bash guard.sh
'''
        self.shell(command)
        (self.path / 'compressed').unlink()
        (self.path / 'contents').write_text('hooks/archiso\n')
        self.shell(command, ok=False)
        self.assertFalse((self.path / 'compressed').exists())


if __name__ == '__main__':
    unittest.main()
