#!/usr/bin/env python3
"""Stateful, offline gh executable used by adapter integration tests."""
import hashlib
import json
import os
from pathlib import Path
import sys
from urllib.parse import parse_qs, urlsplit

store = Path(os.environ['FAKE_GH_STATE'])
data = json.loads(store.read_text())
args = sys.argv[1:]
data.setdefault('calls', []).append(args)

def save():
    store.write_text(json.dumps(data))

def asset_info(a):
    return {k: v for k, v in a.items() if k != 'bytes'}

def emit(value):
    save()
    print(json.dumps(value))

if args[:2] == ['release', 'upload']:
    path = Path(args[3])
    content = path.read_bytes()
    name = path.name
    if data.get('rename_upload'):
        name = 'renamed'
    asset = dict(id=data['next_id'], name=name, state='uploaded', size=len(content),
                 bytes=content.hex(), digest='sha256:' + hashlib.sha256(content).hexdigest())
    data['next_id'] += 1
    data['assets'].append(asset)
    save()
    sys.exit(0)
assert args[0] == 'api', args
url = urlsplit(args[1])
method = args[args.index('--method') + 1] if '--method' in args else 'GET'
body = json.load(sys.stdin) if '--input' in args else {}
if '/releases/assets/' in url.path:
    aid = int(url.path.rsplit('/', 1)[1])
    asset = next(a for a in data['assets'] if a['id'] == aid)
    if method == 'DELETE':
        data['assets'].remove(asset)
        emit(None)
    elif method == 'PATCH':
        asset.update(body)
        emit(asset_info(asset))
    elif '-H' in args:
        if data.get('download_failures', 0):
            data['download_failures'] -= 1
            save()
            sys.exit(1)
        save()
        sys.stdout.buffer.write(bytes.fromhex(asset['bytes']))
    else:
        emit(asset_info(asset))
elif url.path.endswith('/assets'):
    page = int(parse_qs(url.query)['page'][0])
    emit([asset_info(a) for a in data['assets'][(page-1)*100:page*100]])
elif method == 'POST':
    release = dict(id=1, **body)
    data['releases'].append(release)
    emit(release)
else:
    page = int(parse_qs(url.query)['page'][0])
    emit(data['releases'][(page-1)*100:page*100])
