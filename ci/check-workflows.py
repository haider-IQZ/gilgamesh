#!/usr/bin/env python3
"""Offline workflow policy checks supplement actionlint; require PyYAML."""
from pathlib import Path
import json
import re
import tomllib

import yaml

root = Path(__file__).resolve().parent.parent
for path in (root / '.github/workflows').glob('*.yml'):
    # BaseLoader preserves the YAML 1.2 workflow key 'on' (YAML 1.1 calls it True).
    workflow = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
    assert 'on' in workflow and 'jobs' in workflow, path
    assert 'pull_request_target' not in workflow['on'], path
    for name, job in workflow['jobs'].items():
        if 'runs-on' in job:
            assert 0 < int(job['timeout-minutes']) < 360, (path, name)
            assert job['runs-on'] == 'ubuntu-24.04'
            permissions = job['permissions']
            if permissions.get('contents') == 'write':
                assert path.name == 'publish.yml' and name == 'publish', (path, name)
            if permissions.get('issues') == 'write':
                assert path.name == 'publish.yml' and name in ('report', 'publish'), (path, name)
        for step in job.get('steps', []):
            action = step.get('uses', '')
            if action and not action.startswith('./'):
                assert re.fullmatch(r'[^@]+@[0-9a-f]{40}', action), action
            if action.startswith('actions/checkout@'):
                assert step['with']['persist-credentials'] == ('true' if name == 'publish' else 'false')
            assert '${{'  not in step.get('run', ''), 'Pass expressions via env, not shell interpolation'
    print('Parsed and checked', path.relative_to(root))
build = yaml.load((root / '.github/workflows/build.yml').read_text(), Loader=yaml.BaseLoader)
assert 'secrets' not in build['jobs']['pr']
assert build['jobs']['pr']['permissions'] == {'contents': 'read'}
assert 'secrets:' not in (root / '.github/workflows/pipeline.yml').read_text()
for path in (root / 'ci').glob('*.json'):
    json.loads(path.read_text())
with (root / 'ci/nvchecker.toml').open('rb') as stream:
    nv = tomllib.load(stream)
assert nv['__config__']['keyfile'] == '$NVCHECKER_KEYFILE'
assert nv['tkg']['source'] == 'manual'
pattern = re.compile(nv['linux-tkg']['regex'])
assert pattern.findall('href="linux-7.2.9.tar.xz" href="linux-7.2.10.tar.xz" href="linux-7.3.1.tar.xz"') == ['7.2.9', '7.2.10']
assert re.compile(nv['nvidia-open-tkg']['regex']).findall('{"pkgver": "615.71.09"}') == ['615.71.09']
print('Parsed JSON/TOML; checked source regexes and PR/publish permissions')

update = yaml.load((root / '.github/workflows/update.yml').read_text(), Loader=yaml.BaseLoader)
publish = yaml.load((root / '.github/workflows/publish.yml').read_text(), Loader=yaml.BaseLoader)
for workflow, jobs in ((build, ('trusted', 'publication')), (update, ('pipeline', 'publication')),
                       (publish, ('report', 'publish'))):
    for job in jobs:
        assert "vars.GILGAMESH_PUBLISH_ENABLED == 'true'" in workflow['jobs'][job]['if']
assert publish['jobs']['publish']['environment'] == 'pacman-repo'
assert not publish['on']['workflow_call']
assert "github.event_name == 'pull_request'" in build['concurrency']['cancel-in-progress']
for step in publish['jobs']['publish']['steps']:
    if any(key.startswith('GILGAMESH_GPG_') for key in step.get('env', {})):
        assert 'bash ci/sign.sh' in step['run'] and 'pipeline.py' not in step['run']

expected_actions = {
    'actions/checkout': ('3d3c42e5aac5ba805825da76410c181273ba90b1', {'fetch-depth', 'persist-credentials'}),
    'actions/upload-artifact': ('043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
        {'name', 'path', 'if-no-files-found', 'retention-days', 'compression-level'}),
    'actions/download-artifact': ('3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c', {'name', 'path'}),
}
for path in (root / '.github/workflows').glob('*.yml'):
    workflow = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
    for job in workflow['jobs'].values():
        assert 'secrets' not in job
        for step in job.get('steps', []):
            if step.get('uses', '').startswith('actions/'):
                action, revision = step['uses'].split('@')
                expected, inputs = expected_actions[action]
                assert revision == expected
                assert set(step.get('with', {})) <= inputs
