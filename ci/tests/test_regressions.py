"""Regression coverage using local fixtures and fake executables, never services."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
from unittest.mock import patch

from test_pipeline import Fixture, PlanningTests, ShellTests, p, github, CI


class FailurePlanningTests(PlanningTests):
    def test_numeric_point_release_order(self):
        state = self.baseline()
        state['units']['linux-tkg']['upstream'] = '7.2.9'
        p.write(self.root / 'ci/state.json', state)
        self.nv(kernel='7.2.10')
        self.assertEqual(self.plan()['jobs']['linux-tkg']['version'], '7.2.10')

    def test_failed_tuple_suppressed_until_source_version_or_force_changes(self):
        state = self.baseline()
        state['failures'] = {'nvidia-open-tkg': {'version': '2.0', 'source': 'same'}}
        p.write(self.root / 'ci/state.json', state)
        self.nv(nvidia='2.0')
        self.assertEqual(self.plan()['jobs'], {})
        self.assertIn('nvidia-open-tkg', self.plan(force='nvidia-open-tkg')['jobs'])
        with patch.object(p, 'source_hash', return_value='changed'):
            self.assertIn('nvidia-open-tkg', self.plan()['jobs'])
        self.nv(nvidia='3.0')
        self.assertIn('nvidia-open-tkg', self.plan()['jobs'])

    def test_suppressed_driver_also_holds_kernel_until_forced(self):
        state = self.baseline()
        state['failures'] = {'nvidia-open-tkg': {'version': '1.0', 'source': 'same'}}
        p.write(self.root / 'ci/state.json', state)
        self.nv(kernel='7.2.2')
        self.assertEqual(self.plan()['jobs'], {})
        self.assertEqual(set(self.plan(force='linux-tkg')['jobs']), {'linux-tkg', 'nvidia-open-tkg'})


class InputTests(Fixture):
    def digest(self, name='linux-tkg'):
        files = '\0'.join(str(f.relative_to(self.root)) for f in self.root.rglob('*') if f.is_file())
        with patch.object(p, 'command', return_value=files):
            return p.source_hash(name, self.cfg)

    def test_docs_cache_and_unused_kernel_files_do_not_hash(self):
        before = self.digest()
        for file in ('kernel/README.md', 'build/README.md', 'kernel/notes.cfg', 'build/cache/output'):
            path = self.root / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('ignored')
        self.assertEqual(before, self.digest())
        (self.root / 'kernel/gilgamesh.myfrag').write_text('CONFIG_TEST=y')
        self.assertNotEqual(before, self.digest())

    def test_mode_hash_uses_only_git_executable_bit(self):
        file = self.root / 'build/container.sh'
        file.chmod(0o644)
        before = self.digest()
        file.chmod(0o600)
        self.assertEqual(before, self.digest())
        file.chmod(0o744)
        self.assertNotEqual(before, self.digest())
        executable = self.digest()
        file.chmod(0o755)
        self.assertEqual(executable, self.digest())

    def test_build_inputs_affect_ordinary_packages_too(self):
        before = self.digest('gilgamesh-shell')
        (self.root / 'build/container.sh').write_text('changed')
        self.assertNotEqual(before, self.digest('gilgamesh-shell'))

    def test_new_source_and_resolved_config_checks_affect_build_hashes(self):
        for file in ('build/check-sources.awk', 'kernel/check-config.sh'):
            before = self.digest()
            (self.root / file).write_text('changed check')
            self.assertNotEqual(before, self.digest())

    def test_package_docs_ignored_and_symlink_target_hashed(self):
        folder = self.root / 'packages/gilgamesh-shell'
        before = self.digest('gilgamesh-shell')
        (folder / 'README.md').write_text('doc')
        self.assertEqual(before, self.digest('gilgamesh-shell'))
        (folder / 'link').symlink_to('PKGBUILD')
        first = self.digest('gilgamesh-shell')
        (folder / 'link').unlink()
        (folder / 'link').symlink_to('README.md')
        self.assertNotEqual(first, self.digest('gilgamesh-shell'))

    def test_metadata_checks_name_digest_dependency_and_filename(self):
        path = self.art / 'example-7.2.10-1-x86_64.pkg.tar.zst'
        path.write_bytes(b'archive')
        metadata = 'pkgname = example\npkgver = 7.2.10-1\narch = x86_64\ndepend = linux-tkg=7.2.10-273\n'
        with patch.object(p, 'arch', return_value=metadata):
            result = p.metadata(path)
            self.assertEqual(result['sha256'], github.sha(path))
            self.assertEqual(result['depends'], ['linux-tkg=7.2.10-273'])
            with self.assertRaises(ValueError):
                p.metadata(self.art / 'wrong.pkg.tar.zst')
        for version in ('1:2-1', '1+git-1'):
            with patch.object(p, 'arch', return_value=metadata.replace('7.2.10-1', version)):
                with self.assertRaises(ValueError):
                    p.metadata(path)

    def test_build_one_release_only_bumps_same_published_upstream(self):
        for name in ('linux-tkg', 'gilgamesh-shell'):
            target = '7.2.1' if name == 'linux-tkg' else '1.0'
            for old, expected in ((None, False), (target, True), ('0.9', False)):
                state = p.read(self.root / 'ci/state.json')
                state['units'] = {name: {'upstream': old}} if old else {}
                state['packages'] = {'linux-tkg': {'current': {'version': '7.2.1-280'}}} if old else {}
                p.write(self.root / 'ci/state.json', state)
                p.write(self.art / 'plan.json', {'jobs': {name: {'version': target},
                    'nvidia-open-tkg': {'version': '1.0'}}})
                with patch.object(p, 'command') as command:
                    p.build_one(name)
                if name == 'linux-tkg':
                    self.assertEqual(command.call_args.kwargs['env']['PKGREL'], '281' if expected else '273')
                else:
                    self.assertEqual('--rebuild' in command.call_args_list[0].args, expected)

    def test_patch_accepts_only_safe_literals(self):
        original = "pkgver=1.0\npkgrel=1\nsha256sums=('aaaa'\n 'bbbb')\nprepare() { echo ok; }\n"
        p.validate_patch(original, original.replace('1.0', '2.0').replace('aaaa', 'cccc'))
        for change in (original.replace('echo ok', 'echo bad'),
                       original.replace('aaaa', '$(evil)'),
                       original.replace('pkgver=1.0', 'pkgver=2.0; evil'),
                       original + 'source=(https://evil)\n'):
            with self.assertRaises(ValueError):
                p.validate_patch(original, change)

    def test_held_back_issue_title(self):
        result = {'linux-tkg': {'status': 'blocked', 'version': '7.2.1', 'waiting_for': 'nvidia-open-tkg'}}
        with patch.object(p, 'collected', return_value=result), patch.object(p, 'pages', return_value=[]), patch.object(p, 'api') as api:
            p.report()
        self.assertEqual(api.call_args.args[2]['title'], 'held back: linux-tkg 7.2.1 (waiting for nvidia-open-tkg)')


class ReleaseAdapterTests(Fixture):
    def setUp(self):
        super().setUp()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        shutil.copy2(CI / 'tests/fake-gh.py', self.bin / 'gh')
        (self.bin / 'gh').chmod(0o755)
        self.store = self.art / 'gh-state.json'
        self.data = {'releases': [{'id': 1, 'tag_name': 'repo'}], 'assets': [], 'next_id': 1000}
        self.save()
        patch.dict(os.environ, {'PATH': str(self.bin) + os.pathsep + os.environ['PATH'], 'FAKE_GH_STATE': str(self.store)}).start()
        patch.object(github.time, 'sleep').start()
        self.file = self.art / 'example.pkg.tar.zst'
        self.file.write_bytes(b'package')

    def save(self):
        self.store.write_text(json.dumps(self.data))

    def asset(self, state='uploaded', digest=True):
        asset = {'id': len(self.data['assets']) + 1, 'name': self.file.name, 'state': state,
                 'size': self.file.stat().st_size, 'bytes': self.file.read_bytes().hex()}
        if digest:
            asset['digest'] = 'sha256:' + github.sha(self.file)
        self.data['assets'].append(asset)
        self.save()
        return asset

    def test_upload_download_and_rename(self):
        release = github.Release()
        release.upload(self.file)
        release.download(self.file.name, self.art / 'download', github.sha(self.file))
        self.assertEqual((self.art / 'download').read_bytes(), b'package')
        release.rename(self.file.name, 'new-name')
        self.assertIn('new-name', release.assets())

    def test_nonuploaded_states_replaced(self):
        for state in ('open', 'starter'):
            self.data['assets'] = []
            self.asset(state)
            github.Release().upload(self.file)
            asset = github.Release().assets()[self.file.name]
            self.assertEqual(asset['state'], 'uploaded')
            self.assertGreaterEqual(asset['id'], 1000)

    def test_digest_match_reuses_asset(self):
        self.asset()
        github.Release().upload(self.file)
        self.assertFalse(any(c[:2] == ['release', 'upload'] for c in p.read(self.store)['calls']))

    def test_digestless_verify_transient_failure_retried(self):
        self.asset(digest=False)
        self.data['download_failures'] = 1
        self.save()
        github.Release().upload(self.file)
        self.assertEqual(p.read(self.store)['download_failures'], 0)
        self.assertFalse(self.file.with_name(self.file.name + '.verify').exists())

    def test_replace_uploaded_different_bytes(self):
        self.asset()
        self.file.write_bytes(b'replacement')
        github.Release().upload(self.file, replace=True)
        self.assertEqual(github.Release().assets()[self.file.name]['digest'], 'sha256:' + github.sha(self.file))

    def test_digest_size_and_immutable_collision_rejected(self):
        asset = self.asset()
        asset['bytes'] = b'changed'.hex()
        asset.pop('digest')
        self.save()
        with self.assertRaises(RuntimeError):
            github.Release().upload(self.file)
        asset['size'] = 999
        self.save()
        with self.assertRaises(RuntimeError):
            github.Release().download(self.file.name, self.art / 'bad')
        self.assertFalse((self.art / 'bad.partial').exists())

    def test_renamed_upload_rejected(self):
        self.data['rename_upload'] = True
        self.save()
        with self.assertRaises(RuntimeError):
            github.Release().upload(self.file)

    def test_release_and_asset_pagination(self):
        self.data['releases'] = [{'id': n, 'tag_name': str(n)} for n in range(100)] + [{'id': 101, 'tag_name': 'repo'}]
        self.data['assets'] = [{'id': n, 'name': f'asset-{n}', 'state': 'uploaded'} for n in range(205)]
        self.save()
        release = github.Release()
        self.assertEqual(release.release['id'], 101)
        self.assertEqual(len(release.assets()), 205)

    def test_create_missing_and_reject_immutable(self):
        self.data['releases'] = []
        self.save()
        self.assertIsNone(github.Release().release)
        self.assertEqual(github.Release(create=True).release['tag_name'], 'repo')
        self.data = p.read(self.store)
        self.data['releases'][0]['immutable'] = True
        self.save()
        with self.assertRaises(RuntimeError):
            github.Release()


class SigningTests(ShellTests):
    def test_signing_identity_requires_exactly_one_matching_primary(self):
        self.executable('gpg', '#!/usr/bin/env bash\nprintf "%s" "$FAKE_KEYS"\n')
        primary = 'sec:::::::::\nfpr:::::::::' + 'F'*40 + ':\n'
        for keys, good in ((primary, True), (primary.replace('F', 'A'), False),
                           (primary + primary, False), ('', False)):
            result = subprocess.run(['bash', '-ec', 'source "$1"; validate_signing_identity',
                'bash', str(CI / 'sign-repo.sh')], capture_output=True,
                env=dict(os.environ, GILGAMESH_GPG_FINGERPRINT='F'*40, FAKE_KEYS=keys))
            self.assertEqual(result.returncode == 0, good)

    def test_arch_mounts_checkout_readonly_and_only_scoped_writes(self):
        self.executable('docker', '#!/usr/bin/env python3\nimport os,json,pathlib,sys\n'
                        'pathlib.Path(os.environ["MOCK_ROOT"], "mounts").write_text(json.dumps(sys.argv))\n')
        for operation, args, writable in (('check', ['gilgamesh-shell'], []),
                ('checksums', ['gilgamesh-shell'], ['/work/packages/gilgamesh-shell']),
                ('kernel-check', [], ['/work/build/cache/linux-tkg']),
                ('nvcheck', [], ['/work/ci/artifacts'])):
            with patch.dict(os.environ, {'KERNEL_VERSION': '7.2.1'}):
                self.shell('arch.sh', operation, *args)
            argv = p.read(self.root / 'mounts')
            mounts = [argv[i + 1] for i, v in enumerate(argv) if v == '--mount']
            self.assertTrue(any('dst=/work,readonly' in mount for mount in mounts))
            self.assertEqual([next(x[4:] for x in mount.split(',') if x.startswith('dst='))
                              for mount in mounts if not mount.endswith(',readonly')], writable)

    def test_sign_repository_database_aliases_and_verification(self):
        self.executable('gpg', '''#!/usr/bin/env python3
import os, pathlib, sys
with (pathlib.Path(os.environ['MOCK_ROOT'])/'gpg-calls').open('a') as f: f.write(' '.join(sys.argv[1:])+'\\n')
if '--detach-sign' in sys.argv: pathlib.Path(sys.argv[-1]+'.sig').write_text('signature')
if '--verify' in sys.argv:
    assert pathlib.Path(sys.argv[-2]).is_file()
    assert pathlib.Path(sys.argv[-1]).is_file()
''')
        self.executable('repo-add', '''#!/usr/bin/env python3
import pathlib, sys
assert all(arg in sys.argv for arg in ('--sign', '--verify', '--include-sigs'))
for kind in ('db', 'files'): pathlib.Path('gilgamesh.'+kind+'.tar.zst').write_text(kind)
pathlib.Path('gilgamesh.db.tar.zst.sig').write_text('db signature')
''')
        folder = self.art / 'publish/repo'
        folder.mkdir(parents=True)
        (folder / 'pkg-1-1-any.pkg.tar.zst').write_bytes(b'package')
        for name in ('incoming', 'current'):
            (folder.parent / (name + '.txt')).write_text('pkg-1-1-any.pkg.tar.zst\n')
        home = self.art / 'gnupg'
        home.mkdir()
        env = dict(os.environ, GNUPGHOME=str(home), GILGAMESH_GPG_FINGERPRINT='F'*40)
        result = subprocess.run(['bash', '-ec', 'source "$1"; sign_repository "$2"', 'bash',
                                 str(CI / 'sign-repo.sh'), str(folder)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for kind in ('db', 'files'):
            for sig in ('', '.sig'):
                self.assertEqual((folder / f'gilgamesh.{kind}{sig}').read_bytes(),
                                 (folder / f'gilgamesh.{kind}.tar.zst{sig}').read_bytes())
                self.assertFalse((folder / f'gilgamesh.{kind}{sig}').is_symlink())
        self.assertIn('--verify', (self.root / 'gpg-calls').read_text())

    def test_sign_repository_rejects_traversal_and_empty_current(self):
        for incoming, current in (('../evil\n', 'pkg-1-1-any.pkg.tar.zst\n'), ('', '')):
            folder = self.art / 'publish/repo'
            folder.mkdir(parents=True, exist_ok=True)
            (folder.parent / 'incoming.txt').write_text(incoming)
            (folder.parent / 'current.txt').write_text(current)
            home = self.art / 'gnupg'
            shutil.rmtree(home, ignore_errors=True)
            home.mkdir()
            result = subprocess.run(['bash', '-ec', 'source "$1"; sign_repository "$2"', 'bash',
                str(CI / 'sign-repo.sh'), str(folder)], env=dict(os.environ, GNUPGHOME=str(home)), capture_output=True)
            self.assertNotEqual(result.returncode, 0)


def load_tests(loader, tests, pattern):
    # Imported fixture classes and inherited baseline tests run in test_pipeline once.
    import unittest
    suite = unittest.TestSuite()
    for cls in (FailurePlanningTests, InputTests, ReleaseAdapterTests, SigningTests):
        suite.addTests(cls(name) for name in cls.__dict__ if name.startswith('test_'))
    return suite
