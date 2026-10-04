#!/usr/bin/env python3
"""Deploy the two-branch Ghost article tree with exact-revision checks and rollback.

Default is read-only preflight. Pass --apply after reviewing the template diff.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
import urllib.request
from urllib.parse import urljoin
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'ghost' / 'article-tree'
BASE = 'https://blog.uzelhub.com/'
FILES = {
    'home.hbs': '7b6913c2174264e692b97cb0fd513f1b44e71e5a093b4b6ba348aafa47666d32',
    'index.hbs': '907fc2b0e0438a4ceb6b7ad76e3a56d88449d78b4608e4c5267b849653f76284',
    'partials/components/post-list.hbs': '21333795a1398900c411461321490e2370a40b8259d90f955804463fdcdd5450',
    'partials/components/article-tree.hbs': None,
}


def run(args, **kw):
    return subprocess.run(args, check=True, capture_output=True, **kw)


def digest(data):
    return hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest()


def fetch(url):
    with urllib.request.urlopen(url, timeout=15) as response:
        return response.read().decode('utf8')


def verify():
    home = fetch(BASE)
    assert home.count('class="uz-article-tree"') == 1
    tree = re.search(r'<nav class="uz-article-tree".*?</nav>', home, re.S)
    assert tree, 'article tree absent from homepage'
    tree = tree.group()
    assert '<summary>Predictor Suite</summary>' in tree
    assert '<summary>Beyond Predictor</summary>' in tree
    assert tree.count('<details class="uz-tree-branch">') == 2
    assert '{{#get' not in tree
    assert 'id="uz-predictor-intro"' in home
    assert 'id="uz-blog-purpose-title"' in home
    links = re.findall(r'<li><a href="([^"]+)"', tree)
    if links:
        article = fetch(urljoin(BASE, links[0]))
        assert 'id="uz-blog-purpose-title"' in article
        assert 'gh-article-title' in article
    fetch(BASE + 'about/')
    return ['two native details branches', 'Ghost queries rendered',
            'Predictor branding and linked article routes']


def retry(function):
    for n in range(15):
        try:
            return function()
        except Exception:
            if n == 14:
                raise
            time.sleep(2)


def write_file(path, data, metadata):
    fd, temp = tempfile.mkstemp(prefix='.article-tree-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as file:
            file.write(data.replace(b'\r\n', b'\n'))
            file.flush()
            os.fsync(file.fileno())
        os.chmod(temp, metadata.st_mode & 0o777)
        os.chown(temp, metadata.st_uid, metadata.st_gid)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    mounts = json.loads(run(['docker', 'inspect', 'ghost', '--format', '{{json .Mounts}}']).stdout)
    content = Path(next(m['Source'] for m in mounts if m['Destination'] == '/var/lib/ghost/content')).resolve()
    theme = (content / 'themes/source').resolve()
    assert theme.is_relative_to(content) and theme.is_dir()
    desired = {name: (ROOT / name).read_bytes() for name in FILES}
    paths = {name: (theme / name) for name in FILES}
    assert all(path.parent.resolve().is_relative_to(theme) for path in paths.values())
    original = {name: path.read_bytes() if path.exists() else None for name, path in paths.items()}
    if all(original[name] is not None and digest(original[name]) == digest(desired[name]) for name in FILES):
        print(json.dumps({'result': 'already applied', 'verified': retry(verify)}))
        return
    for name, expected in FILES.items():
        assert (original[name] is None and expected is None) or (
            original[name] is not None and digest(original[name]) == expected
        ), 'Theme changed since review: ' + name
    for data in desired.values():
        run(['docker', 'exec', '-i', '-w', '/var/lib/ghost/current', 'ghost', 'node', '-e',
             "require('handlebars').precompile(require('fs').readFileSync(0,'utf8'))"], input=data)
    print('Preflight passed: exact theme revisions and Handlebars syntax.', flush=True)
    if not args.apply:
        return
    backup = Path('/var/backups/ghost-article-tree') / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup.mkdir(parents=True, mode=0o700, exist_ok=False)
    metadata = {name: (path.stat() if path.exists() else (theme / 'home.hbs').stat())
                for name, path in paths.items()}
    for name, data in original.items():
        if data is not None:
            dest = backup / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
    try:
        for name, data in desired.items():
            write_file(paths[name], data, metadata[name])
        run(['docker', 'restart', 'ghost'], timeout=60)
        checked = retry(verify)
        result = {'result': 'applied', 'backup': str(backup), 'verified': checked}
        (backup / 'result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result))
    except Exception:
        for name, data in original.items():
            if data is None:
                if paths[name].exists() and digest(paths[name].read_bytes()) == digest(desired[name]):
                    paths[name].unlink()
            else:
                write_file(paths[name], data, metadata[name])
        run(['docker', 'restart', 'ghost'], timeout=60)
        def recovered():
            page = fetch(BASE)
            assert 'class="uz-article-tree"' not in page
            assert 'id="uz-predictor-intro"' in page
            return True
        retry(recovered)
        print(json.dumps({'result': 'restored after failure', 'backup': str(backup)}))
        raise


if __name__ == '__main__':
    main()
