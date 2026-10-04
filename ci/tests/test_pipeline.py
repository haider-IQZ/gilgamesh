"""Offline fault injection: no real Docker, GitHub, GPG, git commits or pushes."""
import contextlib
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

CI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CI))
import pipeline as p
import github

def vercmp(a, b):
    # Numeric packaging segments, including pkgrel (never lexicographic strings).
    def key(value):
        return tuple((1, int(x)) if x.isdigit() else (0, x)
                     for x in re.findall(r'[0-9]+|[A-Za-z]+', value))
    return str((key(a) > key(b)) - (key(a) < key(b)))


spec = importlib.util.spec_from_file_location('checks', CI / 'check-sources.py')
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class Fixture(unittest.TestCase):
    def setUp(self):
        (CI / 'artifacts').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=CI / 'artifacts')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(CI, self.root / 'ci', ignore=shutil.ignore_patterns('artifacts', '__pycache__', 'tests'))
        self.cfg = json.loads((CI / 'packages.json').read_text())
        for name in self.cfg:
            if name != 'linux-tkg':
                path = self.root / f'packages/{name}/PKGBUILD'
                path.parent.mkdir(parents=True)
                path.write_text(f'pkgname={name}\npkgver=1.0\npkgrel=4\nsha256sums=("' + 'a' * 64 + '")\n')
        (self.root / 'build').mkdir()
        (self.root / 'build/container.sh').write_text('commit=85fc90b0bad984902e5edd63ed9c39bbaa33a806\n')
        (self.root / 'kernel').mkdir()
        (self.root / 'kernel/customization.cfg').write_text('_version="v${KERNEL_VERSION:?Exact planned release required}"\n')
        self.art = self.root / 'ci/artifacts'
        self.art.mkdir()
        self.addCleanup(patch.stopall)
        patch.object(p, 'ROOT', self.root).start()
        patch.object(p, 'ART', self.art).start()
        self.env = patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40, 'GITHUB_REF': 'refs/heads/main',
            'GITHUB_EVENT_NAME': 'push', 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1',
            'TMPDIR': str(self.art)})
        self.env.start()

    def nv(self, kernel='7.2.1', nvidia='1.0'):
        data = {n: {'version': '1.0'} for n in self.cfg}
        data['linux-tkg']['version'] = kernel
        data['nvidia-open-tkg']['version'] = nvidia
        data['tkg'] = {'version': '85fc90b0bad984902e5edd63ed9c39bbaa33a806'}
        p.write(self.root / 'ci/newver.json', {'version': 2, 'data': data})

    def baseline(self):
        state = p.read(self.root / 'ci/state.json')
        state['units'] = {n: {'source': 'same', 'upstream': '7.2.1' if n == 'linux-tkg' else '1.0',
                              'outputs': [n]} for n in self.cfg}
        p.write(self.root / 'ci/state.json', state)
        return state


class SourceTests(unittest.TestCase):
    def test_missing_skip_and_weak_rejected(self):
        for suffix in ('', 'sha256sums = SKIP\n', 'md5sums = ' + 'a' * 32 + '\n'):
            with self.assertRaises(ValueError):
                checks.check('source = https://example.org/file\n' + suffix)

    def test_arch_specific_mixed_sources(self):
        checks.check('source_x86_64 = local\nsource_x86_64 = src::https://example.org/file\n'
                     'sha256sums_x86_64 = SKIP\nsha256sums_x86_64 = ' + 'a' * 64)
        with self.assertRaises(ValueError):
            checks.check('source_x86_64 = https://example.org/file\nsha256sums_x86_64 = SKIP')

    def test_vcs_exception_and_no_sources(self):
        checks.check('source = name::git+https://example.org/repo#commit=abc\nsha256sums = SKIP')
        checks.check('pkgname = local-settings')

    def test_mismatched_checksums(self):
        with self.assertRaises(ValueError):
            checks.check('source = https://example.org/a\nsource = https://example.org/b\nsha256sums = ' + 'a' * 64)


class PlanningTests(Fixture):
    def setUp(self):
        super().setUp()
        self.nv()
        self.baseline()
        patch.object(p, 'source_hash', return_value='same').start()
        patch.object(p, 'command', return_value='a' * 40).start()
        patch.object(p, 'arch', side_effect=lambda op, a, b, **kw: vercmp(a, b)).start()

    def plan(self, mode='update', force=''):
        with contextlib.redirect_stdout(io.StringIO()):
            p.plan(mode, force)
        return p.read(self.art / 'plan.json')

    def test_no_changes(self):
        self.assertEqual(self.plan()['jobs'], {})

    def test_kernel_bump_selects_nvidia_only(self):
        self.nv(kernel='7.2.2')
        data = self.plan()
        self.assertEqual(set(data['jobs']), {'linux-tkg', 'nvidia-open-tkg'})
        self.assertEqual(data['groups'], [{'group': 'kernel', 'packages': ['linux-tkg', 'nvidia-open-tkg']}])

    def test_push_does_not_update_unaffected_upstream(self):
        self.nv(kernel='7.2.2', nvidia='2.0')
        self.assertEqual(self.plan(mode='push')['jobs'], {})

    def test_source_retry_and_dependency_order(self):
        with patch.object(p, 'source_hash', side_effect=lambda name, cfg: 'changed' if name.startswith('gilgamesh') else 'same'):
            data = self.plan(mode='push')
        self.assertEqual(data['groups'][0]['packages'], ['gilgamesh-settings', 'gilgamesh-shell'])

    def test_force_kernel_rebuild_same_version(self):
        self.assertEqual(set(self.plan(force='linux-tkg')['jobs']), {'linux-tkg', 'nvidia-open-tkg'})

    def test_upstream_downgrade_ignored(self):
        self.nv(nvidia='0.9')
        self.assertEqual(self.plan()['jobs'], {})

    def test_partial_nv_and_series_change_fail(self):
        p.write(self.root / 'ci/newver.json', {'version': 2, 'data': {}})
        with self.assertRaises(ValueError):
            p.validate_nv()
        self.nv(kernel='7.3.1')
        with self.assertRaises(ValueError):
            p.validate_nv()

    def test_unregistered_package_fails(self):
        path = self.root / 'packages/new/PKGBUILD'
        path.parent.mkdir()
        path.write_text('pkgver=1\npkgrel=1\n')
        with self.assertRaises(ValueError):
            p.config()


class ShellTests(Fixture):
    def setUp(self):
        super().setUp()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        patch.dict(os.environ, {'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                               'MOCK_ROOT': str(self.root)}).start()
        self.executable('docker', '''#!/usr/bin/env python3
import os, pathlib, sys
args=sys.argv
op=args[args.index('/work/ci/arch-container.sh')+1:]
root=pathlib.Path(os.environ['MOCK_ROOT'])
with (root/'calls').open('a') as f: f.write(' '.join(op)+'\\n')
if op[0]=='compare':
    def v(x): return tuple(int(i) for i in x.split('.'))
    a,b=map(v,op[1:]); print((a>b)-(a<b))
elif op[0]=='checksums':
    if os.environ.get('FAIL_CHECKSUMS'): sys.exit(7)
    p=root/'packages'/op[1]/'PKGBUILD'; p.write_text(p.read_text().replace('a'*64,'b'*64))
''')

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def shell(self, script, *args, good=True):
        result = subprocess.run(['bash', str(self.root / 'ci' / script), *args],
            cwd=self.root, text=True, capture_output=True)
        if good:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_real_bump_shell_with_mocked_arch(self):
        path = self.root / 'packages/nvidia-open-tkg/PKGBUILD'
        self.shell('bump.sh', 'nvidia-open-tkg', '2.0')
        self.assertIn('pkgver=2.0\npkgrel=1', path.read_text())
        self.assertIn('b' * 64, path.read_text())
        self.shell('bump.sh', 'nvidia-open-tkg', '2.0', '--rebuild')
        self.assertIn('pkgrel=2', path.read_text())
        self.assertEqual((self.root / 'calls').read_text().count('checksums'), 1)

    def test_checksum_failure_restores_pkgbuild(self):
        path = self.root / 'packages/nvidia-open-tkg/PKGBUILD'
        original = path.read_bytes()
        with patch.dict(os.environ, {'FAIL_CHECKSUMS': '1'}):
            self.shell('bump.sh', 'nvidia-open-tkg', '2.0', good=False)
        self.assertEqual(path.read_bytes(), original)

    def test_epoch_plus_injection_downgrade_rejected(self):
        for value in ('2:1.0', '1.0+git', '$(touch forbidden)', '0.9'):
            self.shell('bump.sh', 'nvidia-open-tkg', value, good=False)
        path = self.root / 'packages/nvidia-open-tkg/PKGBUILD'
        path.write_text('epoch=1\n' + path.read_text())
        self.shell('bump.sh', 'nvidia-open-tkg', '2.0', good=False)

    def test_nv_keyfile_removed_and_token_not_logged(self):
        self.nv()
        shutil.copy2(self.root / 'ci/newver.json', self.root / 'candidate.json')
        self.executable('nvchecker', '''#!/usr/bin/env python3
import os, pathlib, shutil, tomllib, sys
root=pathlib.Path(os.environ['MOCK_ROOT']); key=pathlib.Path(os.environ['NVCHECKER_KEYFILE'])
assert tomllib.loads(key.read_text())['keys']['github.com']==os.environ['GH_TOKEN']
(root/'key-path').write_text(str(key))
shutil.copy2(root/'candidate.json', pathlib.Path(sys.argv[-1]).parent/'newver.json')
''')
        with patch.dict(os.environ, {'GH_TOKEN': 'fake-token-for-test-only'}):
            result = self.shell('nvcheck.sh')
        self.assertFalse(Path((self.root / 'key-path').read_text()).exists())
        self.assertNotIn('fake-token-for-test-only', result.stdout + result.stderr)

    def test_aur_diff_prints_without_modifying_local(self):
        self.executable('curl', '''#!/usr/bin/env python3
import pathlib, sys
pathlib.Path(sys.argv[sys.argv.index('-o')+1]).write_text('pkgver=9\\n')
''')
        path = self.root / 'packages/nvidia-open-tkg/PKGBUILD'
        original = path.read_bytes()
        result = self.shell('aur-diff.sh', 'example', 'nvidia-open-tkg')
        self.assertIn('+pkgver=9', result.stdout)
        self.assertEqual(path.read_bytes(), original)

    def test_sign_wrapper_cleans_secret_mount_and_never_passes_key_in_environment(self):
        self.executable('docker', '''#!/usr/bin/env python3
import os, pathlib, sys
assert 'GILGAMESH_GPG_KEY' not in os.environ
assert 'GILGAMESH_GPG_PASSPHRASE' not in os.environ
mount=next(a for a in sys.argv if 'dst=/secrets' in a)
source=pathlib.Path(next(v[4:] for v in mount.split(',') if v.startswith('src=')))
assert (source/'key').read_text()=='dummy signing key'
assert (source/'passphrase').read_text()=='dummy passphrase'
(pathlib.Path(os.environ['MOCK_ROOT'])/'secret-path').write_text(str(source))
''')
        with patch.dict(os.environ, {'GILGAMESH_GPG_KEY': 'dummy signing key',
            'GILGAMESH_GPG_PASSPHRASE': 'dummy passphrase', 'GILGAMESH_GPG_FINGERPRINT': 'F'*40}):
            result = self.shell('sign.sh')
        self.assertFalse(Path((self.root / 'secret-path').read_text()).exists())
        self.assertNotIn('dummy signing key', result.stdout + result.stderr)

    def test_disk_cleanup_refuses_local_machine(self):
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}):
            self.shell('free-space.sh', good=False)
        self.assertFalse((self.root / 'calls').exists())


class FakeRelease:
    def __init__(self):
        self.files = {}
        self.operations = []
        self.fail = None

    def assets(self):
        return {name: {} for name in self.files}

    def download(self, name, dest, expected=None):
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(self.files[name])
        if expected and github.sha(dest) != expected:
            raise ValueError('hash mismatch')

    def upload(self, path, replace=False):
        path = Path(path)
        self.operations.append(('upload', path.name))
        if self.fail == path.name:
            self.fail = None
            self.files.pop(path.name, None)  # Model delete succeeded, upload failed.
            raise RuntimeError('injected release upload failure')
        if path.name in self.files and not replace and self.files[path.name] != path.read_bytes():
            raise RuntimeError('immutable asset collision')
        self.files[path.name] = path.read_bytes()

    def rename(self, old, new):
        self.operations.append(('rename', new))
        if self.fail == new:
            self.fail = None
            raise RuntimeError('injected rename failure')
        self.files[new] = self.files.pop(old)

    def delete(self, name):
        self.operations.append(('delete', name))
        self.files.pop(name, None)


class PublishTests(Fixture):
    def setUp(self):
        super().setUp()
        self.release = FakeRelease()
        self.committed = False
        self.fail_push = False
        self.commands = []
        self.record = {'name': 'gilgamesh-settings', 'version': '1.0-5',
                       'file': 'gilgamesh-settings-1.0-5-any.pkg.tar.zst', 'depends': []}
        folder = self.art / 'result-desktop'
        folder.mkdir()
        path = folder / self.record['file']
        path.write_bytes(b'new package')
        self.record['sha256'] = github.sha(path)
        patchpath = folder / 'patches/gilgamesh-settings/PKGBUILD'
        patchpath.parent.mkdir(parents=True)
        patchpath.write_text((self.root / 'packages/gilgamesh-settings/PKGBUILD').read_text().replace('pkgrel=4', 'pkgrel=5'))
        p.write(folder / 'result.json', {'sha': 'a' * 40, 'packages': {
            'gilgamesh-settings': {'status': 'ok', 'version': '1.0', 'outputs': [self.record]}}})
        p.write(self.art / 'plan.json', {'sha': 'a' * 40, 'jobs': {'gilgamesh-settings': {'version': '1.0', 'source': 'new'}},
            'groups': [{'group': 'desktop', 'packages': ['gilgamesh-settings']}], 'tkg': 'f' * 40})
        old = dict(self.record, version='1.0-4', file='gilgamesh-settings-1.0-4-any.pkg.tar.zst')
        oldpath = self.art / old['file']
        oldpath.write_bytes(b'old package')
        old['sha256'] = github.sha(oldpath)
        self.release.files[old['file']] = b'old package'
        self.release.files[old['file'] + '.sig'] = b'old signature'
        self.release.files['gilgamesh-settings-1.0-3-any.pkg.tar.zst'] = b'stale package'
        snap = self.art / 'snapshot-old.tar.gz'
        with tarfile.open(snap, 'w:gz') as archive:
            for name in p.DB_NAMES:
                content = b'old ' + name.encode()
                self.release.files[name] = content
                info = tarfile.TarInfo(name)
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))
        self.release.files[snap.name] = snap.read_bytes()
        state = p.read(self.root / 'ci/state.json')
        state['packages'] = {'gilgamesh-settings': {'current': old, 'previous': None}}
        state['snapshot'] = {'file': snap.name, 'sha256': github.sha(snap)}
        state['units'] = {'gilgamesh-settings': {'source': 'old', 'upstream': '1.0', 'outputs': ['gilgamesh-settings']}}
        p.write(self.root / 'ci/state.json', state)
        self.base = 'a' * 40
        self.remote_state = (self.root / 'ci/state.json').read_text()
        patch.object(p, 'pages', return_value=[]).start()
        patch.object(p, 'Release', return_value=self.release).start()
        patch.object(p, 'metadata', return_value=self.record).start()
        patch.object(p, 'arch', return_value='1').start()
        patch.object(p, 'source_hash', return_value='new').start()
        patch.object(p, 'command', side_effect=self.command).start()
        patch.object(p.subprocess, 'run', side_effect=self.subprocess).start()

    def subprocess(self, args, **kwargs):
        self.assertEqual(args[:2], ['git', 'merge-base'])
        return subprocess.CompletedProcess(args, 0 if self.committed else 1)

    def command(self, *args, **kwargs):
        self.commands.append(args)
        if args[:2] == ('git', 'ls-remote'):
            return ('b' * 40 if self.committed else self.base) + '\trefs/heads/main\n'
        if args[:2] == ('git', 'show'):
            if args[2] == 'origin/main:ci/state.json':
                return self.remote_state
            return (self.root / args[2].split(':', 1)[1]).read_text()
        if args[:2] == ('git', 'rev-parse'):
            return self.base if args[2] == 'origin/main' else 'b' * 40
        if args[:2] == ('git', 'push'):
            if self.fail_push:
                raise RuntimeError('injected non-fast-forward push')
            self.committed = True
        if args[:2] == ('bash', 'ci/sign.sh'):
            dest = self.art / 'publish/repo'
            for file in (dest.parent / 'incoming.txt').read_text().splitlines():
                (dest / (file + '.sig')).write_bytes(b'new signature')
            for name in p.DB_NAMES:
                (dest / name).write_bytes(b'new ' + name.encode())
        if args[0] == 'docker':
            return '%FILENAME%\n' + self.record['file'] + '\n'
        return ''

    def test_success_packages_before_db_commit_after_db_retains_previous(self):
        p.publish()
        ops = self.release.operations
        self.assertLess(ops.index(('upload', self.record['file'])), ops.index(('rename', 'gilgamesh.db')))
        self.assertTrue(self.committed)
        self.assertNotIn('ci-transaction.json', self.release.files)
        self.assertIn('gilgamesh-settings-1.0-4-any.pkg.tar.zst', self.release.files)
        self.assertNotIn('gilgamesh-settings-1.0-3-any.pkg.tar.zst', self.release.files)
        self.assertEqual(p.read(self.root / 'ci/oldver.json')['data'], {'gilgamesh-settings': {'version': '1.0'}})

    def test_upload_failure_restores_all_aliases_without_push(self):
        self.release.fail = 'gilgamesh.files'
        with self.assertRaises(RuntimeError):
            p.publish()
        self.assertFalse(self.committed)
        for name in p.DB_NAMES:
            self.assertEqual(self.release.files[name], b'old ' + name.encode())
        self.assertFalse(any(c[:2] == ('git', 'push') for c in self.commands))

    def test_push_failure_restores_old_repo(self):
        self.fail_push = True
        with self.assertRaises(RuntimeError):
            p.publish()
        for name in p.DB_NAMES:
            self.assertEqual(self.release.files[name], b'old ' + name.encode())
        self.assertNotIn('ci-transaction.json', self.release.files)

    def test_hard_stop_journal_recovers_on_next_run(self):
        journal = {'commit': 'b' * 40, 'previous': p.read(self.root / 'ci/state.json')['snapshot']}
        self.release.files['ci-transaction.json'] = json.dumps(journal).encode()
        self.release.files['gilgamesh.db'] = b'partial new'
        p.recover(self.release)
        self.assertEqual(self.release.files['gilgamesh.db'], b'old gilgamesh.db')

    def test_uncertain_successful_push_does_not_rollback(self):
        self.committed = True
        journal = {'commit': 'b' * 40, 'previous': p.read(self.root / 'ci/state.json')['snapshot']}
        self.release.files['ci-transaction.json'] = json.dumps(journal).encode()
        self.release.files['gilgamesh.db'] = b'new live db'
        p.recover(self.release)
        self.assertEqual(self.release.files['gilgamesh.db'], b'new live db')

    def test_tampered_artifact_rejected_before_mutation(self):
        (self.art / 'result-desktop' / self.record['file']).write_bytes(b'tampered')
        with self.assertRaises(ValueError):
            p.publish()
        self.assertFalse(any(op == 'upload' for op, name in self.release.operations))

    def test_main_advancing_preserves_matching_success(self):
        self.base = 'c' * 40
        p.publish()
        self.assertTrue(self.committed)
        checkout = self.commands.index(('git', 'checkout', '--detach', 'origin/main'))
        commit = next(i for i, cmd in enumerate(self.commands) if cmd[:2] == ('git', 'commit'))
        self.assertLess(checkout, commit)

    def test_changed_state_refuses_publication(self):
        self.remote_state = '{}'
        with self.assertRaises(RuntimeError):
            p.publish()
        self.assertEqual(self.release.operations, [])

    def test_changed_sources_skip_success_without_failure(self):
        with patch.object(p, 'source_hash', return_value='changed'):
            p.publish()
        self.assertFalse(self.committed)
        self.assertNotIn('failures', p.read(self.root / 'ci/state.json'))

    def test_noop_moved_main_never_touches_release(self):
        self.base = 'c' * 40
        with patch.object(p, 'collected', return_value={}):
            p.publish()
        self.assertEqual(self.release.operations, [])

    def test_failed_build_persists_tuple_without_signing(self):
        result = {'gilgamesh-settings': {'status': 'failed'}}
        with patch.object(p, 'collected', return_value=result):
            p.publish()
        self.assertTrue(self.committed)
        self.assertEqual(p.read(self.root / 'ci/state.json')['failures'], {
            'gilgamesh-settings': {'version': '1.0', 'source': 'new'}})
        self.assertNotIn(('bash', 'ci/sign.sh'), self.commands)

    def test_tampered_recipe_rejected(self):
        patchpath = self.art / 'result-desktop/patches/gilgamesh-settings/PKGBUILD'
        patchpath.write_text(patchpath.read_text() + 'prepare() { touch /work/evil; }\n')
        with self.assertRaises(ValueError):
            p.publish()
        self.assertEqual(self.release.operations, [])

    def test_all_databases_staged_before_first_delete(self):
        p.publish()
        ops = self.release.operations
        first_delete = min(ops.index(('delete', n)) for n in p.DB_NAMES)
        self.assertTrue(all(ops.index(('upload', n + '.new')) < first_delete for n in p.DB_NAMES))

    def test_success_closes_failure_and_held_issues(self):
        issues = [{'number': 1, 'title': 'build failed: gilgamesh-settings 0.9'},
                  {'number': 2, 'title': 'held back: gilgamesh-settings 1.0 (waiting for pair)'},
                  {'number': 3, 'title': 'build failed: unrelated 1.0'}]
        with patch.object(p, 'pages', return_value=issues), patch.object(p, 'api') as api:
            p.publish()
        self.assertEqual(api.call_count, 2)
        self.assertTrue(all(c.args[2] == {'state': 'closed'} for c in api.call_args_list))

    def test_orphan_from_failed_attempt_is_removed_before_retry(self):
        self.release.files[self.record['file']] = b'previous incomplete attempt, different build bytes'
        p.publish()
        self.assertEqual(self.release.files[self.record['file']], b'new package')
        self.assertLess(self.release.operations.index(('delete', self.record['file'])),
                        self.release.operations.index(('upload', self.record['file'])))

    def test_pr_publish_rejected(self):
        with patch.dict(os.environ, {'GITHUB_EVENT_NAME': 'pull_request'}):
            with self.assertRaises(ValueError):
                p.publish()
        self.assertEqual(self.release.operations, [])


class ResultTests(Fixture):
    def test_nvidia_failure_holds_kernel_but_keeps_independent_success(self):
        jobs = {n: {'version': '7.2.1' if n == 'linux-tkg' else '1.0'}
                for n in ('linux-tkg', 'nvidia-open-tkg', 'gilgamesh-settings')}
        groups = [{'group': 'kernel', 'packages': ['linux-tkg', 'nvidia-open-tkg']},
                  {'group': 'desktop', 'packages': ['gilgamesh-settings']}]
        p.write(self.art / 'plan.json', {'sha': 'a' * 40, 'jobs': jobs, 'groups': groups})
        for group in groups:
            results = {n: {'status': 'failed' if n == 'nvidia-open-tkg' else 'ok', **jobs[n]} for n in group['packages']}
            p.write(self.art / f'result-{group["group"]}/result.json', {'sha': 'a' * 40, 'packages': results})
        results = p.collected()
        self.assertEqual(results['linux-tkg']['status'], 'blocked')
        self.assertEqual(results['gilgamesh-settings']['status'], 'ok')

    def test_missing_artifact_reports_setup_tail_and_updates_existing_issue(self):
        p.write(self.art / 'plan.json', {'sha': 'a' * 40,
            'jobs': {'gilgamesh-shell': {'version': '1.0'}},
            'groups': [{'group': 'desktop', 'packages': ['gilgamesh-shell']}]})
        directory = self.art / 'result-desktop'
        directory.mkdir()
        (directory / 'setup.log').write_text('old\n' * 200 + 'disk full @owner\n')
        title = 'build failed: gilgamesh-shell 1.0'
        with patch.object(p, 'pages', return_value=[{'title': title, 'number': 8}]), patch.object(p, 'api') as api_call:
            p.report()
        args = api_call.call_args.args
        self.assertTrue(args[0].endswith('/issues/8'))
        self.assertEqual(args[1], 'PATCH')
        self.assertIn('disk full', args[2]['body'])
        self.assertNotIn('@owner', args[2]['body'])
        self.assertLess(args[2]['body'].count('old\n'), 101)

    def test_missing_artifact_opens_issue(self):
        p.write(self.art / 'plan.json', {'sha': 'a' * 40,
            'jobs': {'gilgamesh-shell': {'version': '1.0'}},
            'groups': [{'group': 'desktop', 'packages': ['gilgamesh-shell']}]})
        with patch.object(p, 'pages', return_value=[]), patch.object(p, 'api') as api_call:
            p.report()
        args = api_call.call_args.args
        self.assertEqual(args[1], 'POST')
        self.assertEqual(args[2]['title'], 'build failed: gilgamesh-shell 1.0')

    def test_asset_name_policy(self):
        for name in ('pkg-1:2.pkg.tar.zst', 'pkg-1+2.pkg.tar.zst', '../evil', '.hidden'):
            with self.assertRaises(ValueError):
                github.safe_name(name)
        github.safe_name('linux-tkg-7.2.1-273-x86_64.pkg.tar.zst')


class BuildTests(Fixture):
    def setUp(self):
        super().setUp()
        (self.root / 'repo/x86_64').mkdir(parents=True)
        self.fail = None
        self.wrong_kernel = False
        self.outputs = {}
        patch.object(p, 'seed_dependencies').start()
        patch.object(p, 'command').start()
        patch.object(p, 'metadata', side_effect=lambda path: self.outputs[path.name]).start()
        patch.object(p.subprocess, 'Popen', side_effect=self.process).start()

    def process(self, args, **kwargs):
        name = args[-1]
        units = p.KERNEL_STACK if name == 'linux-tkg' else [name]
        for unit in units:
            if self.fail == unit:
                break
            names = ['linux-tkg', 'linux-tkg-headers'] if unit == 'linux-tkg' else [unit]
            ver = ('7.2.2' if self.wrong_kernel else '7.2.1') + '-273' if unit == 'linux-tkg' else '1.0-5'
            if unit != 'linux-tkg':
                p.replace_assignment(self.root / f'packages/{unit}/PKGBUILD', 'pkgrel', '5')
            for output in names:
                self.archive(output, ver, ['linux-tkg=7.2.1-273'] if unit == 'nvidia-open-tkg' else [])
        if name == 'linux-tkg':
            for source in p.NVIDIA_INPUTS:
                self.archive(source, '1.0-1', [])
        failed = self.fail in units
        class Process:
            stdout = io.StringIO('mock build log\n')
            def wait(self):
                return 1 if failed else 0
        return Process()

    def archive(self, name, version, depends):
        filename = f'{name}-{version}-x86_64.pkg.tar.zst'
        path = self.root / 'repo/x86_64' / filename
        path.write_bytes(b'fake archive')
        self.outputs[filename] = {'name': name, 'version': version, 'file': filename,
                                 'sha256': github.sha(path), 'depends': depends}
        return path

    def build(self, group, names):
        p.write(self.art / 'plan.json', {'sha': 'a' * 40,
            'jobs': {n: {'version': '7.2.1' if n == 'linux-tkg' else '1.0'} for n in names},
            'groups': [{'group': group, 'packages': names}]})
        with contextlib.redirect_stdout(io.StringIO()):
            p.build_group(group)
        return p.read(self.art / f'result-{group}/result.json')['packages']

    def test_kernel_then_nvidia_success(self):
        result = self.build('kernel', ['linux-tkg', 'nvidia-open-tkg'])
        self.assertEqual([r['status'] for r in result.values()], ['ok', 'ok'])
        self.assertEqual(len(result['linux-tkg']['outputs']), 2)

    def test_driver_failure_withholds_entire_stack(self):
        self.fail = 'nvidia-open-tkg'
        result = self.build('kernel', ['linux-tkg', 'nvidia-open-tkg'])
        self.assertEqual(result['linux-tkg']['status'], 'failed')
        self.assertEqual(result['nvidia-open-tkg']['status'], 'failed')

    def test_kernel_differing_from_plan_rejected(self):
        self.wrong_kernel = True
        result = self.build('kernel', ['linux-tkg', 'nvidia-open-tkg'])
        self.assertEqual(result['linux-tkg']['status'], 'failed')
        self.assertIn('differs from the exact planned version', result['linux-tkg']['error'])
        self.assertEqual(result['nvidia-open-tkg']['status'], 'failed')

    def test_shell_failure_preserves_settings(self):
        self.fail = 'gilgamesh-shell'
        result = self.build('desktop', ['gilgamesh-settings', 'gilgamesh-shell'])
        self.assertEqual(result['gilgamesh-settings']['status'], 'ok')
        self.assertEqual(result['gilgamesh-shell']['status'], 'failed')

    def test_failed_dependency_blocks_shell(self):
        self.fail = 'gilgamesh-settings'
        result = self.build('desktop', ['gilgamesh-settings', 'gilgamesh-shell'])
        self.assertEqual(result['gilgamesh-shell']['status'], 'failed')
        self.assertIn('Blocked by failed dependencies', result['gilgamesh-shell']['error'])


if __name__ == '__main__':
    unittest.main()
