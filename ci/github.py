"""Small gh adapter. All callers use a single fixed release; uploads are verified."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

REPOSITORY = os.environ.get('GITHUB_REPOSITORY', 'haider-IQZ/gilgamesh')
TAG = 'repo'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs).stdout


def api(path, method='GET', body=None):
    args = ['gh', 'api', path, '--method', method]
    if body is not None:
        args += ['--input', '-']
    return json.loads(run(*args, input=json.dumps(body) if body is not None else None) or 'null')


def pages(path):
    items = []
    for page in range(1, 10000):
        batch = api(f'{path}{"&" if "?" in path else "?"}per_page=100&page={page}')
        items.extend(batch)
        if len(batch) < 100:
            return items
    raise RuntimeError('GitHub pagination limit exceeded')


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def safe_name(name):
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9._-]*', name) or name.endswith('.'):
        raise ValueError(f'GitHub-unsafe asset name (epochs and + are forbidden): {name}')
    return name


class Release:
    def __init__(self, create=False):
        # Listing distinguishes a missing release from auth/network errors.
        releases = pages(f'repos/{REPOSITORY}/releases')
        self.release = next((r for r in releases if r['tag_name'] == TAG), None)
        if self.release is None and create:
            self.release = api(f'repos/{REPOSITORY}/releases', 'POST', {
                'tag_name': TAG, 'target_commitish': os.environ['GITHUB_SHA'],
                'name': 'Gilgamesh pacman repository', 'draft': False,
                'prerelease': False, 'make_latest': 'false',
                'body': 'Signed x86_64 pacman repository. See ci/README.md on main.'})
        if self.release and self.release.get('immutable'):
            raise RuntimeError('The repo release must remain mutable; disable release immutability')

    def assets(self):
        if not self.release:
            return {}
        return {a['name']: a for a in pages(
            f'repos/{REPOSITORY}/releases/{self.release["id"]}/assets')}

    def delete(self, name):
        asset = self.assets().get(name)
        if asset:
            api(f'repos/{REPOSITORY}/releases/assets/{asset["id"]}', 'DELETE')

    def download(self, name, dest, expected=None):
        safe_name(name)
        asset = self.assets().get(name)
        if not asset or asset['state'] != 'uploaded':
            raise RuntimeError(f'Missing complete release asset: {name}')
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        partial = dest.with_name(dest.name + '.partial')
        try:
            with partial.open('wb') as out:
                subprocess.run(['gh', 'api',
                    f'repos/{REPOSITORY}/releases/assets/{asset["id"]}',
                    '-H', 'Accept: application/octet-stream'], stdout=out, check=True)
            digest = asset.get('digest')
            expected = expected or (digest.removeprefix('sha256:') if digest else None)
            if partial.stat().st_size != asset['size'] or (expected and sha(partial) != expected):
                raise RuntimeError(f'Asset hash/size mismatch: {name}')
            partial.replace(dest)
        finally:
            partial.unlink(missing_ok=True)

    def upload(self, path, replace=False):
        path = Path(path)
        safe_name(path.name)
        digest = sha(path)
        for attempt in range(4):
            try:
                asset = self.assets().get(path.name)
                if asset:
                    if (asset.get('digest') == 'sha256:' + digest and
                            asset['state'] == 'uploaded' and asset['size'] == path.stat().st_size):
                        return
                    if asset['state'] != 'uploaded' or replace:
                        self.delete(path.name)
                    else:
                        # Include verification in retries: older APIs can omit digest.
                        verify = path.with_name(path.name + '.verify')
                        try:
                            self.download(path.name, verify, digest)
                            return
                        finally:
                            verify.unlink(missing_ok=True)
                run('gh', 'release', 'upload', TAG, str(path), '--repo', REPOSITORY)
                assets = self.assets()
                asset = assets.get(path.name)
                if not asset or asset['size'] != path.stat().st_size:
                    raise RuntimeError(f'GitHub renamed or truncated asset: {path.name}')
                verify = path.with_name(path.name + '.verify')
                try:
                    self.download(path.name, verify, digest)
                finally:
                    verify.unlink(missing_ok=True)
                return
            except (subprocess.CalledProcessError, RuntimeError):
                if attempt == 3:
                    raise
                time.sleep(2 ** attempt)

    def rename(self, old, new):
        safe_name(new)
        asset = self.assets()[old]
        renamed = api(f'repos/{REPOSITORY}/releases/assets/{asset["id"]}', 'PATCH', {'name': new})
        if renamed['name'] != new or renamed['state'] != 'uploaded':
            raise RuntimeError('Asset rename did not preserve a complete asset')
