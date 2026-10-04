"""Offline integration coverage for the shared kernel/NVIDIA build contract."""
import os
import shutil
import subprocess
import unittest
from unittest.mock import patch

from test_pipeline import Fixture, PlanningTests, BuildTests, ShellTests, CI, p


class ExactKernelTests(Fixture):
    def test_current_config_requires_planned_tag(self):
        with patch.object(p, 'ROOT', CI.parent):
            p.config()
        for value in ('7.2.0', '7.2.10'):
            self.assertEqual(p.kernel_version(value), value)
        for value in ('', '7.2-latest', 'v7.2.1', '7.3.1', '7.2.1-rc1', '7.2.1;false'):
            with self.assertRaises(ValueError):
                p.kernel_version(value)

    def test_config_rejects_floating_missing_and_default_versions(self):
        config = self.root / 'kernel/customization.cfg'
        for setting in ('', '_version="7.2-latest"', '_version="v${KERNEL_VERSION:-7.2.1}"',
                        '_version="v${KERNEL_VERSION}"', config.read_text() * 2):
            config.write_text(setting)
            with self.assertRaises(ValueError):
                p.config()

    def test_planned_version_and_driver_bump_precede_shared_preflight(self):
        state = self.baseline()
        state['packages']['linux-tkg'] = {'current': {'version': '7.2.1-280'}}
        p.write(self.root / 'ci/state.json', state)
        for target, release in (('7.2.1', '281'), ('7.2.2', '273')):
            p.write(self.art / 'plan.json', {'mode': 'update', 'jobs': {
                'linux-tkg': {'version': target}, 'nvidia-open-tkg': {'version': '2.0'}}})
            with patch.object(p, 'command') as command, patch.dict(os.environ, {'KERNEL_VERSION': '7.2.99'}):
                p.build_one('linux-tkg')
            bump, check, build = command.call_args_list
            self.assertEqual(bump.args, ('bash', 'ci/bump.sh', 'nvidia-open-tkg', '2.0'))
            self.assertEqual(check.args[-2:], ('ci/arch.sh', 'kernel-check'))
            self.assertEqual(build.args[-2:], ('build/build.sh', 'kernel-stack'))
            for call in (check, build):
                self.assertEqual(call.kwargs['env']['KERNEL_VERSION'], target)
                self.assertEqual(call.kwargs['env']['PKGREL'], release)
            self.assertIn('305m', build.args)

    def test_same_driver_version_bumped_before_shared_run(self):
        self.baseline()
        p.write(self.art / 'plan.json', {'jobs': {
            'linux-tkg': {'version': '7.2.2'}, 'nvidia-open-tkg': {'version': '1.0'}}})
        with patch.object(p, 'command') as command:
            p.build_one('linux-tkg')
        self.assertEqual(command.call_args_list[0].args,
                         ('bash', 'ci/bump.sh', 'nvidia-open-tkg', '1.0', '--rebuild'))

    def test_bad_kernel_plan_fails_before_bump_or_build(self):
        for version in ('', '7.2-latest', '7.3.1'):
            p.write(self.art / 'plan.json', {'jobs': {
                'linux-tkg': {'version': version}, 'nvidia-open-tkg': {'version': '1.0'}}})
            with patch.object(p, 'command') as command, self.assertRaises(ValueError):
                p.build_one('linux-tkg')
            command.assert_not_called()

    def test_failed_driver_bump_prevents_kernel_preflight(self):
        p.write(self.art / 'plan.json', {'jobs': {
            'linux-tkg': {'version': '7.2.1'}, 'nvidia-open-tkg': {'version': '2.0'}}})
        with patch.object(p, 'command', side_effect=RuntimeError('checksums failed')) as command:
            with self.assertRaisesRegex(RuntimeError, 'checksums failed'):
                p.build_one('linux-tkg')
        self.assertEqual(command.call_count, 1)
        self.assertEqual(command.call_args.args[:2], ('bash', 'ci/bump.sh'))

    def test_standalone_driver_cannot_bypass_shared_toolchain(self):
        p.write(self.art / 'plan.json', {'jobs': {'nvidia-open-tkg': {'version': '1.0'}}})
        with patch.object(p, 'command') as command, self.assertRaisesRegex(ValueError, 'kernel-stack'):
            p.build_one('nvidia-open-tkg')
        command.assert_not_called()

    def test_seeding_skips_dependencies_built_in_same_group(self):
        state = self.baseline()
        with patch.object(p, 'Release') as release, patch.object(p, 'command') as command:
            p.seed_dependencies(list(p.KERNEL_STACK), state)
        release.return_value.download.assert_not_called()
        command.assert_not_called()


class SharedPlanningTests(PlanningTests):
    def test_driver_update_also_selects_kernel_and_preserves_update_target(self):
        self.nv(nvidia='2.0')
        planned = self.plan()
        self.assertEqual(planned['groups'], [{'group': 'kernel', 'packages': list(p.KERNEL_STACK)}])
        self.assertEqual(planned['jobs']['nvidia-open-tkg']['version'], '2.0')
        self.assertEqual(planned['jobs']['linux-tkg']['version'], '7.2.1')

    def test_kernel_and_driver_updates_keep_both_new_versions(self):
        self.nv(kernel='7.2.2', nvidia='2.0')
        planned = self.plan()
        self.assertEqual(planned['jobs']['nvidia-open-tkg']['version'], '2.0')
        self.assertEqual(planned['jobs']['linux-tkg']['version'], '7.2.2')

    def test_push_driver_change_retains_recipe_pin(self):
        self.nv(nvidia='2.0')
        planned = self.plan(mode='push', force='nvidia-open-tkg')
        self.assertEqual(set(planned['jobs']), set(p.KERNEL_STACK))
        self.assertEqual(planned['jobs']['nvidia-open-tkg']['version'], '1.0')

    def test_force_driver_retries_suppressed_kernel_pair(self):
        state = self.baseline()
        state['failures'] = {'linux-tkg': {'version': '7.2.1', 'source': 'same'}}
        p.write(self.root / 'ci/state.json', state)
        self.nv(nvidia='2.0')
        self.assertEqual(self.plan()['jobs'], {})
        self.assertEqual(set(self.plan(force='nvidia-open-tkg')['jobs']), set(p.KERNEL_STACK))


class SharedBuildTests(BuildTests):
    def test_one_subprocess_splits_outputs_and_retains_signed_inputs(self):
        # Existing inputs can be reused by preflight rather than newly discovered.
        for name in p.NVIDIA_INPUTS:
            path = self.archive(name, '1.0-1', [])
            path.with_name(path.name + '.sig').write_bytes(b'official signature')
        result = self.build('kernel', list(p.KERNEL_STACK))
        self.assertEqual({r['status'] for r in result.values()}, {'ok'})
        p.subprocess.Popen.assert_called_once()
        self.assertEqual(p.subprocess.Popen.call_args.args[0][-1], 'linux-tkg')
        self.assertEqual({r['name'] for r in result['linux-tkg']['outputs']}, {'linux-tkg', 'linux-tkg-headers'})
        self.assertEqual([r['name'] for r in result['nvidia-open-tkg']['outputs']], ['nvidia-open-tkg'])
        inputs = result['linux-tkg']['inputs']
        self.assertEqual({r['name'] for r in inputs}, p.NVIDIA_INPUTS)
        folder = self.art / 'result-kernel'
        for record in inputs:
            self.assertTrue((folder / 'inputs' / record['file']).is_file())
            self.assertTrue((folder / 'inputs' / (record['file'] + '.sig')).is_file())
            self.assertFalse((folder / record['file']).exists())
        self.assertEqual((folder / 'nvidia-open-tkg.log').read_text(), (folder / 'linux-tkg.log').read_text())
        self.assertIn('pkgrel=5', (folder / 'patches/nvidia-open-tkg/PKGBUILD').read_text())

    def malformed_build(self, mutate):
        def process(*args, **kwargs):
            result = self.process(*args, **kwargs)
            mutate()
            return result
        with patch.object(p.subprocess, 'Popen', side_effect=process):
            result = self.build('kernel', list(p.KERNEL_STACK))
        self.assertEqual({r['status'] for r in result.values()}, {'failed'})
        self.assertFalse(list((self.root / 'repo/x86_64').glob('*.pkg.tar.zst')))
        return result['linux-tkg']['error']

    def test_unknown_output_is_not_treated_as_input(self):
        error = self.malformed_build(lambda: self.archive('nvidia-unexpected', '1.0-1', []))
        self.assertIn('Unexpected kernel stack outputs', error)

    def test_input_version_must_match_bumped_driver(self):
        error = self.malformed_build(lambda: self.archive('nvidia-utils', '2.0-1', []))
        self.assertIn('inputs differ from the planned version', error)

    def test_missing_retained_input_fails_pair(self):
        def remove():
            for path in (self.root / 'repo/x86_64').glob('nvidia-utils-*.pkg.tar.zst'):
                path.unlink()
        self.assertIn('Missing retained NVIDIA build inputs', self.malformed_build(remove))

    def test_mismatched_headers_fail_pair(self):
        def mismatch():
            record = next(r for r in self.outputs.values() if r['name'] == 'linux-tkg-headers')
            record['version'] = '7.2.1-274'
        self.assertIn('Kernel and headers versions differ', self.malformed_build(mismatch))

    def test_driver_must_depend_on_exact_shared_kernel(self):
        def mismatch():
            record = next(r for r in self.outputs.values() if r['name'] == 'nvidia-open-tkg')
            record['depends'] = ['linux-tkg=7.2.1-272']
        self.assertIn('NVIDIA lacks exact built kernel dependency', self.malformed_build(mismatch))

    def test_stack_failure_removes_partial_archives_and_reports_both_units(self):
        self.fail = 'nvidia-open-tkg'
        result = self.build('kernel', list(p.KERNEL_STACK))
        self.assertEqual({r['status'] for r in result.values()}, {'failed'})
        self.assertFalse(list((self.root / 'repo/x86_64').glob('*.pkg.tar.zst')))
        self.assertEqual({r['status'] for r in p.collected().values()}, {'failed'})


class VersionWrapperTests(ShellTests):
    def record_docker(self):
        self.executable('docker', '#!/usr/bin/env python3\nimport os,json,pathlib,sys\n'
                        'pathlib.Path(os.environ["MOCK_ROOT"], "docker-args").write_text(json.dumps(sys.argv))\n')

    def test_kernel_check_forwards_required_version(self):
        self.record_docker()
        with patch.dict(os.environ, {'KERNEL_VERSION': '7.2.10'}):
            self.shell('arch.sh', 'kernel-check')
        self.assertIn('KERNEL_VERSION', p.read(self.root / 'docker-args'))
        (self.root / 'docker-args').unlink()
        for value in ('', '7.2-latest', '7.3.1'):
            with patch.dict(os.environ, {'KERNEL_VERSION': value}):
                self.shell('arch.sh', 'kernel-check', good=False)
            self.assertFalse((self.root / 'docker-args').exists())

    def test_build_wrapper_forwards_exact_version_to_stack_container(self):
        self.record_docker()
        for name in ('build.sh', 'lib.sh'):
            shutil.copy2(CI.parent / 'build' / name, self.root / 'build' / name)
        self.executable('id', '#!/usr/bin/env bash\necho 1000\n')
        self.executable('df', '#!/usr/bin/env bash\necho "mock 999999999 0 999999999 0 /"\n')
        env = dict(os.environ, KERNEL_VERSION='7.2.10', PKGREL='281')
        result = subprocess.run(['bash', str(self.root / 'build/build.sh'), 'kernel-stack'],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = p.read(self.root / 'docker-args')
        self.assertIn('KERNEL_VERSION=7.2.10', argv)
        self.assertIn('PKGREL=281', argv)
        self.assertEqual(argv[-1], 'kernel-stack')


class PublicationGateTests(unittest.TestCase):
    def test_existing_workflow_publication_gates(self):
        workflows = CI.parent / '.github/workflows'
        for name in ('build', 'update'):
            text = (workflows / f'{name}.yml').read_text()
            publication = text.split('  publication:\n', 1)[1]
            self.assertIn("vars.GILGAMESH_PUBLISH_ENABLED == 'true'", publication)
            self.assertIn('uses: ./.github/workflows/publish.yml', publication)
        text = (workflows / 'publish.yml').read_text()
        self.assertIn('environment: pacman-repo', text)
        for job in ('report', 'publish'):
            block = text.split(f'  {job}:\n', 1)[1]
            self.assertIn("vars.GILGAMESH_PUBLISH_ENABLED == 'true'", block.split('    steps:', 1)[0])


def load_tests(loader, tests, pattern):
    # Reuse fixtures without rerunning their inherited baseline tests.
    suite = unittest.TestSuite()
    for cls in (ExactKernelTests, SharedPlanningTests, SharedBuildTests, VersionWrapperTests, PublicationGateTests):
        suite.addTests(cls(name) for name in cls.__dict__ if name.startswith('test_'))
    return suite
