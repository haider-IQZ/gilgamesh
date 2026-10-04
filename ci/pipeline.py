#!/usr/bin/env python3
"""Plan and build without credentials; publish only validated main-branch results.

Tracked state records successful publications, not merely observed upstream versions.
All mutable outputs live under ci/artifacts; external build outputs use build/'s API.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

from github import Release, REPOSITORY, api, pages, safe_name, sha

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / 'ci/artifacts'
DB_NAMES = [f'gilgamesh.{kind}{ext}{sig}' for kind in ('db', 'files')
            for ext in ('', '.tar.zst') for sig in ('', '.sig')]
KERNEL_STACK = ('linux-tkg', 'nvidia-open-tkg')
NVIDIA_INPUTS = {'nvidia-utils', 'nvidia-open-dkms'}


def read(path):
    return json.loads(Path(path).read_text())


def write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def command(*args, capture=False, **kwargs):
    print('+ ' + ' '.join(map(str, args)), file=sys.stderr, flush=True)
    return subprocess.run(list(map(str, args)), cwd=ROOT, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None, **kwargs).stdout


def arch(*args, capture=False):
    return command('bash', 'ci/arch.sh', *args, capture=capture)


def version(value):
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9._]*', value):
        raise ValueError(f'Unsafe pkgver: {value!r}; epochs, plus, hyphens forbidden')
    return value


def kernel_version(value):
    if not re.fullmatch(r'7\.2\.[0-9]+', value):
        raise ValueError('Only exact kernel.org 7.2.x point releases are allowed')
    return value


def assignment(path, key):
    matches = re.findall(r'^' + key + r'=[\'"]?([A-Za-z0-9._:+-]+)[\'"]?\s*(?:#.*)?$',
                         Path(path).read_text(), re.M)
    if len(matches) != 1:
        raise ValueError(f'{path}: require one literal {key} assignment')
    return matches[0]


def replace_assignment(path, key, value):
    assignment(path, key)
    text = Path(path).read_text()
    text, count = re.subn(r'^' + key + r'=.*$', f'{key}={value}', text, flags=re.M)
    if count != 1:
        raise ValueError(f'Ambiguous {key}: {path}')
    Path(path).write_text(text)


def config():
    import tomllib
    cfg = read(ROOT / 'ci/packages.json')
    nv = tomllib.loads((ROOT / 'ci/nvchecker.toml').read_text())
    dirs = {p.parent.name for p in (ROOT / 'packages').glob('*/PKGBUILD')}
    if set(cfg) != dirs | {'linux-tkg'} or set(nv) - {'__config__', 'tkg'} != set(cfg):
        raise ValueError('Every package needs packages.json and nvchecker.toml entries')
    for name in cfg:
        safe_name(name)
        if set(cfg[name]['after']) - set(cfg):
            raise ValueError('Unknown dependency unit')
        for prefix in cfg[name]['sources']:
            if prefix.startswith('/') or '..' in Path(prefix).parts:
                raise ValueError('Unsafe source mapping')
        if name.startswith('gilgamesh-') and nv[name]['source'] != 'manual':
            raise ValueError('gilgamesh-* must use local/manual version tracking')
    pin = nv['tkg']['manual']
    if not re.fullmatch('[0-9a-f]{40}', pin) or f'commit={pin}' not in (ROOT / 'build/container.sh').read_text():
        raise ValueError('Deliberately update tkg entry and build/container.sh pin together')
    settings = re.findall(r'^_version=(.*)$',
                          (ROOT / 'kernel/customization.cfg').read_text(), re.M)
    if len(settings) != 1 or not re.fullmatch(
            r'"v\$\{KERNEL_VERSION:\?[^"$`{}\n]*\}"[ \t]*(?:#.*)?', settings[0]):
        raise ValueError('Kernel config must require the exact planned KERNEL_VERSION tag')
    return cfg, nv


def source_hash(name, cfg):
    prefixes = [f'packages/{name}/', *cfg[name]['sources']]
    def included(file):
        if file.lower().endswith('.md'):
            return False
        build_input = (file in ('build/Dockerfile', 'build/check-sources.awk') or
                       (file.startswith('build/') and len(Path(file).parts) == 2 and file.endswith('.sh')) or
                       file.startswith('build/makepkg.conf.d/'))
        if build_input:
            return True
        if name == 'linux-tkg':
            return file in ('kernel/customization.cfg', 'kernel/gilgamesh.myfrag', 'kernel/check-config.sh')
        return any(file == prefix or (prefix.endswith('/') and file.startswith(prefix)) for prefix in prefixes)
    files = command('git', 'ls-files', '-z', capture=True).split('\0')
    digest = hashlib.sha256()
    for file in sorted(f for f in files if f and included(f)):
        path = ROOT / file
        digest.update(file.encode() + b'\0')
        if path.is_symlink():
            digest.update(b'link\0' + os.readlink(path).encode())
        elif path.exists():
            digest.update((b'x' if path.stat().st_mode & 0o100 else b'-') + b'\0' + path.read_bytes())
        else:
            digest.update(b'deleted')
    return digest.hexdigest()


def validate_nv():
    cfg, nv = config()
    data = read(ROOT / 'ci/newver.json')
    if data.get('version') != 2 or set(data['data']) != set(cfg) | {'tkg'}:
        raise ValueError('Incomplete nvchecker result; refusing stale/partial candidates')
    for name, record in data['data'].items():
        version(record['version'])
    kernel_version(data['data']['linux-tkg']['version'])
    if data['data']['tkg']['version'] != nv['tkg']['manual']:
        raise ValueError('tkg commit may not be bumped automatically')


def plan(mode, force):
    cfg, nv = config()
    state = read(ROOT / 'ci/state.json')
    candidates = read(ROOT / 'ci/newver.json')['data']
    validate_nv()
    forced = set(filter(None, re.split(r'[,\s]+', force)))
    if 'all' in forced:
        forced = set(cfg)
    if forced - set(cfg):
        raise ValueError(f'Unknown forced packages: {forced - set(cfg)}')
    jobs = {}
    targets = {}
    for name in cfg:
        old = state['units'].get(name, {})
        digest = source_hash(name, cfg)
        current = (old.get('upstream', '') if name == 'linux-tkg' else
                   assignment(ROOT / f'packages/{name}/PKGBUILD', 'pkgver'))
        target = candidates.get(name, {}).get('version', current) if mode == 'update' or name == 'linux-tkg' else current
        if nv[name]['source'] == 'manual':
            target = current
        newer = bool(target and target != current and
                     (not current or int(arch('compare', target, current, capture=True).strip()) > 0))
        if target != current and not newer:
            target = current  # Never downgrade, including Arch mirror rollbacks.
        if name == 'linux-tkg' and not target:
            # Push bootstrap also checks upstream in prepare, then plans as update.
            raise ValueError('Kernel bootstrap needs nvchecker; use update mode')
        if name == 'linux-tkg':
            kernel_version(target)
        targets[name] = {'version': version(target), 'newer': newer, 'source': digest}
        if (newer and mode == 'update') or not old or old.get('source') != digest or name in forced:
            jobs[name] = targets[name]
    # NVIDIA-only changes also need a freshly built kernel and its toolchain.
    if set(KERNEL_STACK) & jobs.keys():
        for name in KERNEL_STACK:
            jobs.setdefault(name, targets[name])
    # A pair must not partially retry while its identical failure is suppressed.
    if set(KERNEL_STACK) & forced:
        forced.update(KERNEL_STACK)
    suppressed = {n for n, job in jobs.items() if n not in forced and
                  state.get('failures', {}).get(n) == {'version': job['version'], 'source': job['source']}}
    for name in suppressed:
        jobs.pop(name)
    if suppressed & {'linux-tkg', 'nvidia-open-tkg'}:
        jobs.pop('linux-tkg', None)
        jobs.pop('nvidia-open-tkg', None)
    # Pull requests have no signing credentials and cannot write state.
    # Group connected dependency components, preserving a topological build order.
    # Kernel component always has its own runner; independent packages get matrix jobs.
    remaining = set(jobs)
    groups = []
    while remaining:
        first = min(remaining)
        component = {first}
        changed = True
        while changed:
            changed = False
            for name in remaining - component:
                if any(dep in component for dep in cfg[name]['after']) or any(
                        name in cfg[member]['after'] for member in component):
                    component.add(name)
                    changed = True
        ordered = []
        pending = set(component)
        while pending:
            ready = sorted(n for n in pending if not (set(cfg[n]['after']) & pending))
            if not ready:
                raise ValueError('Dependency cycle in packages.json')
            ordered.extend(ready)
            pending.difference_update(ready)
        label = ('kernel' if component & {'linux-tkg', 'nvidia-open-tkg'} else
                 'desktop' if component & {'gilgamesh-settings', 'gilgamesh-shell'} else first)
        # Disconnected desktop components can occur when both have no dependency edge
        # only if configuration is wrong; labels must always be unique.
        if any(g['group'] == label for g in groups):
            label = first
        groups.append({'group': label, 'packages': ordered})
        remaining.difference_update(component)
    result = {'sha': command('git', 'rev-parse', 'HEAD', capture=True).strip(),
              'jobs': jobs, 'groups': groups, 'mode': mode, 'tkg': nv['tkg']['manual']}
    write(ART / 'plan.json', result)
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        ordinary = [g for g in groups if g['group'] != 'kernel']
        with open(output, 'a') as stream:
            stream.write('kernel=' + str(any(g['group'] == 'kernel' for g in groups)).lower() + '\n')
            stream.write('ordinary=' + str(bool(ordinary)).lower() + '\n')
            stream.write('matrix=' + json.dumps({'include': ordinary}) + '\n')
    print(json.dumps(result, indent=2))


def bump(name, target, rebuild):
    cfg, _ = config()
    if name not in cfg or name == 'linux-tkg':
        raise ValueError('Use PKGREL for linux-tkg; there is no local kernel PKGBUILD')
    target = version(target)
    path = ROOT / f'packages/{name}/PKGBUILD'
    original = path.read_bytes()
    current = assignment(path, 'pkgver')
    release = assignment(path, 'pkgrel')
    if not re.fullmatch(r'[1-9][0-9]*', release):
        raise ValueError('Automated pkgrel must be a positive integer')
    if re.search(r'^epoch=', path.read_text(), re.M):
        raise ValueError('Epochs are forbidden for GitHub release assets')
    try:
        arch('check', name)
        compared = int(arch('compare', target, current, capture=True).strip())
        if compared < 0:
            raise ValueError(f'Refusing downgrade {current} -> {target}')
        if compared > 0:
            replace_assignment(path, 'pkgver', target)
            replace_assignment(path, 'pkgrel', '1')
            arch('checksums', name)
        elif rebuild:
            replace_assignment(path, 'pkgrel', str(int(release) + 1))
        arch('check', name)
    except BaseException:
        path.write_bytes(original)
        raise


def metadata(path):
    values = {}
    for line in arch('metadata', str(path.relative_to(ROOT)), capture=True).splitlines():
        key, sep, val = line.partition(' = ')
        if sep:
            values.setdefault(key, []).append(val)
    name = values['pkgname'][0]
    ver = values['pkgver'][0]
    safe_name(name)
    if ':' in ver or '+' in ver:
        raise ValueError('Epoch/plus in package metadata is forbidden')
    expected = f'{name}-{ver}-{values["arch"][0]}.pkg.tar.zst'
    if path.name != safe_name(expected):
        raise ValueError(f'Package filename does not match .PKGINFO: {path.name}')
    return {'name': name, 'version': ver, 'file': path.name, 'sha256': sha(path),
            'depends': values.get('depend', [])}


def seed_dependencies(names, state):
    cfg, _ = config()
    needed = set()
    def visit(name):
        for dep in cfg[name]['after']:
            if dep not in needed:
                needed.add(dep)
                visit(dep)
    for name in names:
        visit(name)
    release = Release()
    out = ROOT / 'repo/x86_64'
    out.mkdir(parents=True, exist_ok=True)
    downloaded = []
    for unit in needed - set(names):
        for package in state['units'].get(unit, {}).get('outputs', []):
            record = state['packages'][package]['current']
            release.download(record['file'], out / record['file'], record['sha256'])
            release.download(record['file'] + '.sig', out / (record['file'] + '.sig'))
            downloaded.append(str((out / record['file']).relative_to(ROOT)))
    if downloaded:
        arch('verify', *downloaded)
        command('bash', 'build/build.sh', 'repo')


def build_group(group):
    plan_data = read(ART / 'plan.json')
    selected = next(g['packages'] for g in plan_data['groups'] if g['group'] == group)
    state = read(ROOT / 'ci/state.json')
    cfg, _ = config()
    output = ART / f'result-{group}'
    output.mkdir(parents=True, exist_ok=True)
    results = {}
    # Write failure defaults before setup so hard failures/timeouts are reportable.
    for name in selected:
        results[name] = {'status': 'failed', 'version': plan_data['jobs'][name]['version'],
                         'error': 'Job setup interrupted or timed out; see Actions log'}
    write(output / 'result.json', {'sha': plan_data['sha'], 'packages': results})
    try:
        seed_dependencies(selected, state)
    except Exception as exc:
        for record in results.values():
            record['error'] = f'Dependency setup failed: {exc}'
        write(output / 'result.json', {'sha': plan_data['sha'], 'packages': results})
        return
    batches = []
    for name in selected:
        if name in KERNEL_STACK:
            if not set(KERNEL_STACK) <= set(selected):
                raise ValueError('Kernel and NVIDIA must be planned together')
            if name == 'linux-tkg':
                batches.append(list(KERNEL_STACK))
        else:
            batches.append([name])
    for batch in batches:
        leader = batch[0]
        log = output / f'{leader}.log'
        before = {p.name for p in (ROOT / 'repo/x86_64').glob('*.pkg.tar.zst')}
        try:
            failed_deps = [d for name in batch for d in cfg[name]['after']
                           if d not in batch and d in results and results[d]['status'] != 'ok']
            if failed_deps:
                raise RuntimeError(f'Blocked by failed dependencies: {failed_deps}')
            # One subprocess captures bump + build; the kernel pair shares a container.
            with log.open('w') as stream:
                process = subprocess.Popen([sys.executable, 'ci/pipeline.py', 'build-one', leader],
                    cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in process.stdout:
                    print(line, end='', flush=True)
                    stream.write(line)
                    stream.flush()
                if process.wait():
                    raise RuntimeError(f'{leader} build/checksum command failed')
            archives = [p for p in (ROOT / 'repo/x86_64').glob('*.pkg.tar.zst') if p.name not in before]
            if not archives:
                raise RuntimeError('Build produced no new archives')
            records = [metadata(p) for p in archives]
            inputs = []
            if leader == 'linux-tkg':
                inputs = [r for r in records if r['name'] in NVIDIA_INPUTS]
                records = [r for r in records if r['name'] not in NVIDIA_INPUTS]
                # Preflight may reuse already retained inputs; preserve those too.
                for path in (ROOT / 'repo/x86_64').glob('*.pkg.tar.zst'):
                    if path.name in before and any(path.name.startswith(n + '-') for n in NVIDIA_INPUTS):
                        record = metadata(path)
                        if record['name'] in NVIDIA_INPUTS:
                            inputs.append(record)
                if {r['name'] for r in inputs} != NVIDIA_INPUTS:
                    raise RuntimeError('Missing retained NVIDIA build inputs')
                target = plan_data['jobs']['nvidia-open-tkg']['version']
                if any(r['version'].rsplit('-', 1)[0] != target for r in inputs):
                    raise RuntimeError('Retained NVIDIA inputs differ from the planned version')
            names = {r['name'] for r in records}
            if len(names) != len(records):
                raise RuntimeError('Duplicate package outputs')
            if leader == 'linux-tkg' and names != {'linux-tkg', 'linux-tkg-headers', 'nvidia-open-tkg'}:
                raise RuntimeError(f'Unexpected kernel stack outputs: {names}')
            by_unit = {leader: records}
            if leader == 'linux-tkg':
                by_unit = {'linux-tkg': [r for r in records if r['name'] in {'linux-tkg', 'linux-tkg-headers'}],
                           'nvidia-open-tkg': [r for r in records if r['name'] == 'nvidia-open-tkg']}
            completed = {}
            for name in batch:
                job = plan_data['jobs'][name]
                owned = by_unit[name]
                for record in owned:
                    prior = state['packages'].get(record['name'], {}).get('current')
                    if prior and int(arch('compare', record['version'], prior['version'], capture=True).strip()) <= 0:
                        raise RuntimeError('Built package must be newer than the live version')
                    if any(record['name'] in unit.get('outputs', []) for owner, unit in state['units'].items() if owner != name):
                        raise RuntimeError('Output package belongs to another build unit')
                if name == 'linux-tkg':
                    if len({r['version'] for r in owned}) != 1:
                        raise RuntimeError('Kernel and headers versions differ')
                    for record in owned:
                        match = re.match(r'^(7\.2\.[0-9]+)(?:[._-]|$)', record['version'])
                        if not match or match[1] != kernel_version(job['version']):
                            raise RuntimeError('Built kernel differs from the exact planned version')
                elif name not in {r['name'] for r in owned}:
                    raise RuntimeError(f'Expected package missing: {name}')
                else:
                    expected = job['version'] + '-' + assignment(ROOT / f'packages/{name}/PKGBUILD', 'pkgrel')
                    if any(r['version'] != expected for r in owned):
                        raise RuntimeError('Built version differs from bumped local PKGBUILD')
                if name == 'nvidia-open-tkg':
                    kernel = next(r for r in records if r['name'] == 'linux-tkg')
                    if any('linux-tkg=' + kernel['version'] not in r['depends'] for r in owned):
                        raise RuntimeError('NVIDIA lacks exact built kernel dependency')
                completed[name] = {'status': 'ok', 'version': job['version'], 'outputs': owned}
            command('bash', 'build/build.sh', 'repo')
            for record in records:
                shutil.copy2(ROOT / 'repo/x86_64' / record['file'], output / record['file'])
            if inputs:
                directory = output / 'inputs'
                directory.mkdir(exist_ok=True)
                for record in inputs:
                    source = ROOT / 'repo/x86_64' / record['file']
                    shutil.copy2(source, directory / source.name)
                    signature = source.with_name(source.name + '.sig')
                    if signature.exists():
                        shutil.copy2(signature, directory / signature.name)
                completed[leader]['inputs'] = inputs
            for name in batch:
                if name != 'linux-tkg':
                    patch = output / f'patches/{name}/PKGBUILD'
                    patch.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(ROOT / f'packages/{name}/PKGBUILD', patch)
            results.update(completed)
        except Exception as exc:
            for name in batch:
                results[name] = {'status': 'failed', 'version': plan_data['jobs'][name]['version'], 'error': str(exc)}
            with log.open('a') as stream:
                stream.write('\n' + str(exc) + '\n')
            for path in (ROOT / 'repo/x86_64').glob('*.pkg.tar.zst'):
                if path.name not in before:
                    path.unlink()
                    path.with_name(path.name + '.sig').unlink(missing_ok=True)
        for name in batch[1:]:
            shutil.copy2(log, output / f'{name}.log')
        write(output / 'result.json', {'sha': plan_data['sha'], 'packages': results})


def build_one(name):
    planned = read(ART / 'plan.json')
    job = planned['jobs'][name]
    state = read(ROOT / 'ci/state.json')
    same_version = state['units'].get(name, {}).get('upstream') == job['version']
    if name == 'linux-tkg':
        env = dict(os.environ, KERNEL_VERSION=kernel_version(job['version']))
        driver = planned['jobs']['nvidia-open-tkg']
        rebuild = state['units'].get('nvidia-open-tkg', {}).get('upstream') == driver['version']
        # Update the recipe before kernel-stack retains exact NVIDIA inputs in preflight.
        command('bash', 'ci/bump.sh', 'nvidia-open-tkg', driver['version'], *(['--rebuild'] if rebuild else []))
        current = state['packages'].get('linux-tkg', {}).get('current', {}).get('version', '')
        release = max(273, int(current.rsplit('-', 1)[1]) + 1 if current and same_version else 273)
        env['PKGREL'] = str(release)
        command('timeout', '--signal=TERM', '--kill-after=2m', '10m',
                'bash', 'ci/arch.sh', 'kernel-check', env=env)
        command('timeout', '--signal=TERM', '--kill-after=2m', '305m',
                'bash', 'build/build.sh', 'kernel-stack', env=env)
    elif name == 'nvidia-open-tkg':
        raise ValueError('Build NVIDIA through the planned linux-tkg kernel-stack run')
    else:
        command('bash', 'ci/bump.sh', name, job['version'], *(['--rebuild'] if same_version else []))
        command('timeout', '--signal=TERM', '--kill-after=2m', '35m',
                'bash', 'build/build.sh', 'pkg', name)


def collected():
    planned = read(ART / 'plan.json')
    found = {}
    for path in ART.glob('result-*/result.json'):
        data = read(path)
        if data['sha'] != planned['sha']:
            raise ValueError('Artifact belongs to another checkout')
        for name, record in data['packages'].items():
            if name in found or name not in planned['jobs']:
                raise ValueError('Duplicate/unplanned result')
            found[name] = dict(record, directory=str(path.parent))
    for name, job in planned['jobs'].items():
        group = next(g['group'] for g in planned['groups'] if name in g['packages'])
        found.setdefault(name, {'status': 'failed', 'version': job['version'],
                               'directory': str(ART / f'result-{group}'),
                               'error': 'No result artifact: runner/setup failure, cancellation or timeout'})
    if 'linux-tkg' in found and any(found.get(n, {}).get('status') != 'ok'
                                   for n in ('linux-tkg', 'nvidia-open-tkg')):
        for name in ('linux-tkg', 'nvidia-open-tkg'):
            if found.get(name, {}).get('status') == 'ok':
                found[name].update(status='blocked', error='Kernel/NVIDIA publication group incomplete',
                                   waiting_for='nvidia-open-tkg' if name == 'linux-tkg' else 'linux-tkg')
    return found


def report():
    failures = {name: result for name, result in collected().items() if result['status'] != 'ok'}
    issues = pages(f'repos/{REPOSITORY}/issues?state=open') if failures else []
    for name, result in failures.items():
        title = (f'held back: {name} {result["version"]} (waiting for {result["waiting_for"]})'
                 if result['status'] == 'blocked' else f'build failed: {name} {result["version"]}')
        log = Path(result.get('directory', '/nonexistent')) / f'{name}.log'
        if not log.exists():
            log = log.parent / 'setup.log'
        tail = '\n'.join(log.read_text(errors='replace').splitlines()[-100:])[-18000:] if log.exists() else ''
        # HTML details + fenced text; neutralize mention spam and fence injection.
        tail = tail.replace('@', '@\u200b').replace('```', '~~~')
        body = (f'{result.get("error", "Build failed")}\n\n'
                f'Run: https://github.com/{REPOSITORY}/actions/runs/{os.environ["GITHUB_RUN_ID"]}\n\n'
                f'Old published version remains live.\n\n```text\n{tail}\n```\n')
        existing = next((i for i in issues if i['title'] == title and 'pull_request' not in i), None)
        if existing:
            api(f'repos/{REPOSITORY}/issues/{existing["number"]}', 'PATCH', {'body': body})
        else:
            api(f'repos/{REPOSITORY}/issues', 'POST', {'title': title, 'body': body})


def snapshot_extract(release, snapshot, destination):
    destination.mkdir(parents=True, exist_ok=True)
    path = destination / snapshot['file']
    release.download(path.name, path, snapshot['sha256'])
    with tarfile.open(path, 'r:gz') as archive:
        members = archive.getmembers()
        if {m.name for m in members} != set(DB_NAMES) or len(members) != len(DB_NAMES):
            raise ValueError('Invalid snapshot members')
        for member in members:
            if not member.isfile() or member.size > 256 * 1024 * 1024:
                raise ValueError('Unsafe database snapshot')
            (destination / member.name).write_bytes(archive.extractfile(member).read())


def restore(release, snapshot):
    if snapshot:
        directory = ART / 'recovery'
        snapshot_extract(release, snapshot, directory)
        swap_databases(release, directory)
    else:
        for name in DB_NAMES:
            release.delete(name)
            release.delete(name + '.new')


def recover(release):
    if 'ci-transaction.json' not in release.assets():
        return
    path = ART / 'ci-transaction.json'
    release.download(path.name, path)
    journal = read(path)
    commit = journal['commit']
    if not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('Invalid transaction commit')
    command('git', 'fetch', 'origin', 'main')
    committed = subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'origin/main'],
                               cwd=ROOT).returncode == 0
    if not committed:
        restore(release, journal['previous'])
    release.delete('ci-transaction.json')


def assert_head(expected):
    actual = command('git', 'ls-remote', 'origin', 'refs/heads/main', capture=True).split()[0]
    if actual != expected:
        raise RuntimeError('main advanced during build; no publication. Scheduled run retries source hashes')


def validate_patch(original, patched):
    """Accept only literal version/release assignments and literal checksum arrays."""
    def normalized(text):
        for key in ('pkgver', 'pkgrel'):
            literal = r"(?:[A-Za-z0-9._]+|'[A-Za-z0-9._]+'|\"[A-Za-z0-9._]+\")"
            pattern = r'^' + key + '=' + literal + r'[ \t]*(?:#.*)?$'
            text, count = re.subn(pattern, key + '=<value>', text, flags=re.M)
            if count != 1:
                raise ValueError('Patch requires one literal ' + key)
        pattern = r'^([a-z0-9]+sums(?:_[A-Za-z0-9_]+)?)=\((.*?)\)[ \t]*$'
        def checksum(match):
            # No substitutions, commands, redirects or shell punctuation in sums.
            token = r"(?:[a-fA-F0-9]+|SKIP)"
            literal = rf"(?:{token}|'{token}'|\"{token}\")"
            if not re.fullmatch(rf"\s*(?:{literal}(?:\s+{literal})*)?\s*", match[2]):
                raise ValueError('Nonliteral checksum patch')
            return match[1] + '=(<checksums>)'
        return re.sub(pattern, checksum, text, flags=re.M | re.S)
    if normalized(original) != normalized(patched):
        raise ValueError('Artifact PKGBUILD changes more than pkgver/pkgrel/checksums')


def close_issues(successes):
    if not successes:
        return
    for issue in pages(f'repos/{REPOSITORY}/issues?state=open'):
        if 'pull_request' not in issue and any(
                issue['title'].startswith(f'{prefix}: {name} ')
                for name in successes for prefix in ('build failed', 'held back')):
            api(f'repos/{REPOSITORY}/issues/{issue["number"]}', 'PATCH', {'state': 'closed'})


def commit_state(tracked, description):
    command('git', 'config', 'user.name', 'gilgamesh-repo[bot]')
    command('git', 'config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
    command('git', 'add', '--', *tracked)
    command('git', 'commit', '-m', f'ci: {description} [skip ci]')
    return command('git', 'rev-parse', 'HEAD', capture=True).strip()


def current_head():
    return command('git', 'ls-remote', 'origin', 'refs/heads/main', capture=True).split()[0]


def publish(prepare_only=False):
    if os.environ.get('GITHUB_REF') != 'refs/heads/main' or os.environ.get('GITHUB_EVENT_NAME') == 'pull_request':
        raise ValueError('Publishing is restricted to main; pull requests never publish')
    cfg, _ = config()
    planned = read(ART / 'plan.json')
    results = collected()
    old_state = read(ROOT / 'ci/state.json')
    if not results:
        # No release creation/recovery required, and a moved main is not an error.
        if current_head() == planned['sha']:
            release = Release()
            recover(release)
            if current_head() == planned['sha']:
                cleanup(release, old_state)
        print('Nothing to publish')
        return
    release = Release(create=True)
    recover(release)
    command('git', 'fetch', 'origin', 'main')
    base = command('git', 'rev-parse', 'origin/main', capture=True).strip()
    remote_state = command('git', 'show', 'origin/main:ci/state.json', capture=True)
    if remote_state != (ROOT / 'ci/state.json').read_text():
        raise RuntimeError('Publication state advanced; replan against main')
    command('git', 'checkout', '--detach', 'origin/main')
    cfg, _ = config()
    results = {n: r for n, r in results.items()
               if source_hash(n, cfg) == planned['jobs'][n]['source']}
    # If a source changed, leave the entire kernel pair for the next run.
    if 'linux-tkg' in planned['jobs'] and not {'linux-tkg', 'nvidia-open-tkg'} <= results.keys():
        results.pop('linux-tkg', None)
        results.pop('nvidia-open-tkg', None)
    successes = {n: r for n, r in results.items() if r['status'] == 'ok'}
    state = copy.deepcopy(old_state)
    for name, result in results.items():
        if result['status'] == 'failed':
            state.setdefault('failures', {})[name] = {
                key: planned['jobs'][name][key] for key in ('version', 'source')}
        elif result['status'] == 'ok':
            state.setdefault('failures', {}).pop(name, None)
    if not successes:
        if state != old_state:
            write(ROOT / 'ci/state.json', state)
            commit_state(['ci/state.json'], 'record failed build attempts')
            command('git', 'push', 'origin', 'HEAD:refs/heads/main')
        elif current_head() == base:
            cleanup(release, old_state)
        print('No successful changes to publish')
        return
    # Validate every recipe against the fetched HEAD before copying any artifact.
    for name, result in successes.items():
        if name != 'linux-tkg':
            original = command('git', 'show', f'HEAD:packages/{name}/PKGBUILD', capture=True)
            patched = (Path(result['directory']) / f'patches/{name}/PKGBUILD').read_text()
            validate_patch(original, patched)
    # An interrupted run may have uploaded packages before switching the DB.
    # Remove those unreferenced assets before retrying the same version.
    cleanup(release, old_state)
    dest = ART / 'publish/repo'
    dest.mkdir(parents=True, exist_ok=True)
    incoming = []
    records_seen = set()
    nvstate = read(ROOT / 'ci/oldver.json')
    for name, result in successes.items():
        for record in result['outputs']:
            filename = safe_name(record['file'])
            source = Path(result['directory']) / filename
            if sha(source) != record['sha256'] or metadata(source) != record:
                raise ValueError('Package artifact metadata/hash mismatch')
            pkgname = record['name']
            if pkgname in records_seen:
                raise ValueError('Multiple units produced the same package')
            records_seen.add(pkgname)
            previous = state['packages'].get(pkgname, {}).get('current')
            if previous and int(arch('compare', record['version'], previous['version'], capture=True).strip()) <= 0:
                raise ValueError('Publication must increase the Arch package version')
            state['packages'][pkgname] = {'current': record, 'previous': previous}
            shutil.copy2(source, dest / filename)
            incoming.append(filename)
        if name != 'linux-tkg':
            patch = Path(result['directory']) / f'patches/{name}/PKGBUILD'
            shutil.copy2(patch, ROOT / f'packages/{name}/PKGBUILD')
        previous_outputs = set(state['units'].get(name, {}).get('outputs', []))
        if previous_outputs - {r['name'] for r in result['outputs']}:
            raise ValueError('Split output removal requires an explicit reviewed migration')
        state['units'][name] = {'upstream': result['version'], 'source': source_hash(name, cfg),
                                'outputs': [r['name'] for r in result['outputs']]}
        nvstate['data'][name] = {'version': result['version']}
        if name == 'linux-tkg':
            nvstate['data']['tkg'] = {'version': planned['tkg']}
    current = [p['current']['file'] for p in state['packages'].values()]
    for package in state['packages'].values():
        record = package['current']
        if record['file'] not in incoming:
            release.download(record['file'], dest / record['file'], record['sha256'])
            release.download(record['file'] + '.sig', dest / (record['file'] + '.sig'))
    if old_state['snapshot']:
        snapshot_extract(release, old_state['snapshot'], dest)
    (dest.parent / 'incoming.txt').write_text('\n'.join(incoming) + '\n')
    (dest.parent / 'current.txt').write_text('\n'.join(current) + '\n')
    write(dest.parent / 'prepared.json', {'base': base, 'state': state, 'old_state': old_state,
          'successes': successes, 'nvstate': nvstate, 'incoming': incoming, 'current': current})
    if prepare_only:
        return
    command('bash', 'ci/sign.sh')
    finish_publish()


def finish_publish():
    if os.environ.get('GITHUB_REF') != 'refs/heads/main' or os.environ.get('GITHUB_EVENT_NAME') == 'pull_request':
        raise ValueError('Publishing is restricted to trusted main')
    prepared = ART / 'publish/prepared.json'
    if not prepared.exists():
        return
    data = read(prepared)
    base, state, old_state, successes, nvstate, incoming, current = (
        data[k] for k in ('base', 'state', 'old_state', 'successes', 'nvstate', 'incoming', 'current'))
    release = Release()
    dest = prepared.parent / 'repo'
    assert_head(base)
    # Check repo-add actually indexed every selected package, with exact filenames.
    db_listing = command('docker', 'run', '--rm', '--user', f'{os.getuid()}:{os.getgid()}',
        '--mount', f'type=bind,src={ROOT},dst=/work,readonly', 'gilgamesh-builder',
        'bsdtar', '-xOf', '/work/ci/artifacts/publish/repo/gilgamesh.db.tar.zst', capture=True)
    indexed = re.findall(r'%FILENAME%\n([^\n]+)', db_listing)
    if sorted(indexed) != sorted(current):
        raise ValueError('Database contents do not match intended current packages')
    snap = dest.parent / f'snapshot-{os.environ["GITHUB_RUN_ID"]}-{os.environ["GITHUB_RUN_ATTEMPT"]}.tar.gz'
    with tarfile.open(snap, 'w:gz') as archive:
        for name in DB_NAMES:
            if (dest / name).is_symlink():
                raise ValueError('Release database aliases must be real files')
            archive.add(dest / name, arcname=name)
    state['previous_snapshot'] = old_state['snapshot']
    state['snapshot'] = {'file': snap.name, 'sha256': sha(snap)}
    write(ROOT / 'ci/state.json', state)
    # Only successful versions advance nvchecker publication state.
    write(ROOT / 'ci/oldver.json', nvstate)
    write(ROOT / 'ci/newver.json', nvstate)
    tracked = ['ci/state.json', 'ci/oldver.json', 'ci/newver.json']
    tracked += [f'packages/{n}/PKGBUILD' for n in successes if n != 'linux-tkg']
    description = ', '.join(f'{n} {r["version"]}' for n, r in sorted(successes.items()))
    commit = commit_state(tracked, 'publish ' + description)
    assert_head(base)
    # Upload immutable packages and snapshot before touching any live DB alias.
    for filename in incoming:
        release.upload(dest / filename)
        release.upload(dest / (filename + '.sig'))
    release.upload(snap)
    journal = dest.parent / 'ci-transaction.json'
    write(journal, {'commit': commit, 'previous': old_state['snapshot'], 'next': state['snapshot']})
    release.upload(journal)
    try:
        swap_databases(release, dest)
        # A normal fast-forward push provides compare-and-swap against concurrent edits.
        command('git', 'push', 'origin', 'HEAD:refs/heads/main')
    except BaseException:
        # Handles uncertain push outcome too: inspect remote before deciding to roll back.
        recover(release)
        raise
    release.delete('ci-transaction.json')
    if current_head() == commit:
        cleanup(release, state)
    close_issues(successes)


def swap_databases(release, directory):
    for name in DB_NAMES:
        staged = directory / (name + '.new')
        shutil.copy2(directory / name, staged)
        release.upload(staged, replace=True)
    for name in DB_NAMES:
        release.delete(name)
        release.rename(name + '.new', name)


def cleanup(release, state):
    keep = set(DB_NAMES)
    for item in state['packages'].values():
        for record in (item['current'], item.get('previous')):
            if record:
                keep.update((record['file'], record['file'] + '.sig'))
    for snap in (state['snapshot'], state['previous_snapshot']):
        if snap:
            keep.add(snap['file'])
    for name in release.assets():
        managed = (name.endswith(('.pkg.tar.zst', '.pkg.tar.zst.sig')) or name.startswith('snapshot-')
                   or name in {n + '.new' for n in DB_NAMES})
        if managed and name not in keep:
            release.delete(name)


def main():
    parser = argparse.ArgumentParser(__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    p = sub.add_parser('plan')
    p.add_argument('--mode', choices=['update', 'push'], required=True)
    p.add_argument('--force', default='')
    p = sub.add_parser('bump')
    p.add_argument('package')
    p.add_argument('version')
    p.add_argument('--rebuild', action='store_true')
    for name in ('build-group', 'build-one'):
        sub.add_parser(name).add_argument('name')
    pub = sub.add_parser('publish')
    phases = pub.add_mutually_exclusive_group()
    phases.add_argument('--prepare', action='store_true')
    phases.add_argument('--finish', action='store_true')
    for name in ('validate-nv', 'report', 'recover'):
        sub.add_parser(name)
    args = parser.parse_args()
    if args.action == 'plan':
        plan(args.mode, args.force)
    elif args.action == 'bump':
        bump(args.package, args.version, args.rebuild)
    elif args.action == 'build-group':
        build_group(args.name)
    elif args.action == 'build-one':
        build_one(args.name)
    elif args.action == 'validate-nv':
        validate_nv()
    elif args.action == 'publish':
        finish_publish() if args.finish else publish(prepare_only=args.prepare)
    elif args.action == 'report':
        report()
    elif args.action == 'recover':
        if os.environ.get('GITHUB_REF') != 'refs/heads/main' or os.environ.get('GITHUB_EVENT_NAME') == 'pull_request':
            raise ValueError('Recovery is restricted to trusted main')
        recover(Release())


if __name__ == '__main__':
    main()
