#!/usr/bin/env python3
"""Apply the Uzelhub Source footer, with syntax check, backup and rollback.

Run on the Ghost host. Default is preflight; pass --apply to deploy.
This makes the bundled Source 1.5.0 theme persistent in the content volume
and overrides its shared footer. Re-review after theme upgrades.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.request

BASELINE = 'e45f1ef43993b18471b70e3dd97478c0c1e413626452fd875247a6379254d65a'
RELPATH = Path('themes/source/partials/components/footer.hbs')
MARKER = 'id="uz-blog-purpose-title"'
URLS = [
    'https://blog.uzelhub.com/',
    'https://blog.uzelhub.com/what-your-agent-cant-tell-you/',
    'https://blog.uzelhub.com/about/',
    'https://blog.uzelhub.com/tag/ai-agents/',
]

def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs)

def digest(content):
    # A Windows checkout may use CRLF; ignore that transport-only difference.
    return hashlib.sha256(content.replace(b'\r\n', b'\n')).hexdigest()

def atomic_write(target, content, metadata):
    fd, name = tempfile.mkstemp(prefix='.footer-', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(content); f.flush(); os.fsync(f.fileno())
        os.chmod(name, metadata.st_mode & 0o777)
        os.chown(name, metadata.st_uid, metadata.st_gid)
        os.replace(name, target)
    finally:
        if os.path.exists(name): os.unlink(name)

def verify():
    checked=[]
    for url in URLS:
        with urllib.request.urlopen(url, timeout=15) as response:
            body=response.read().decode('utf8')
        assert body.count(MARKER)==1, f'Footer missing or duplicated: {url}'
        for phrase in ['AI orchestration.', 'https://uzelhub.com/', 'aria-label="Explore Uzelhub"']:
            assert phrase in body, f'Footer content missing: {url}'
        assert '{{' not in body.split(MARKER,1)[1].split('</footer>',1)[0], 'Unrendered template'
        checked.append(url)
    return checked

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    source=Path(__file__).resolve().parents[1]/'ghost'/'source-footer.hbs'
    desired=source.read_bytes()
    assert desired.count(MARKER.encode())==1
    mounts=json.loads(run(['docker','inspect','ghost','--format','{{json .Mounts}}']).stdout)
    content=Path(next(m['Source'] for m in mounts if m['Destination']=='/var/lib/ghost/content')).resolve()
    theme=content/'themes'/'source'
    target=theme/'partials/components/footer.hbs'
    assert theme.parent.resolve().is_relative_to(content)
    symlink=os.readlink(theme) if theme.is_symlink() else None
    if symlink not in (None,'/var/lib/ghost/current/content/themes/source'):
        raise RuntimeError('Unexpected theme link; inspect before proceeding.')
    current=run(['docker','exec','ghost','cat','/var/lib/ghost/content/'+str(RELPATH)]).stdout
    if digest(current) not in (BASELINE,digest(desired)):
        raise RuntimeError('Footer changed since review; refusing to overwrite it. Re-review the theme.')
    run(['docker','exec','-i','-w','/var/lib/ghost/current','ghost','node','-e',
         "require('handlebars').precompile(require('fs').readFileSync(0,'utf8')); console.log('Handlebars syntax verified')"],input=desired)
    print('Preflight passed: original revision and Handlebars syntax.',flush=True)
    if not args.apply: return
    if digest(current)==digest(desired):
        print(json.dumps({'result':'already applied','verified':verify()})); return
    backup=Path('/var/backups/ghost-footer')/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup.mkdir(parents=True,mode=0o700,exist_ok=False)
    (backup/'footer.hbs').write_bytes(current)
    (backup/'manifest.json').write_text(json.dumps({'target':str(target),'original_symlink':symlink,'before_sha256':digest(current),'after_sha256':digest(desired)},indent=2))
    stage=None
    materialized=False
    if symlink:
        original_theme=backup/'original-theme'
        original_theme.mkdir()
        run(['docker','cp','ghost:/var/lib/ghost/content/themes/source/.',str(original_theme)])
        assert (original_theme/'partials/components/footer.hbs').read_bytes()==current
        stage=Path(tempfile.mkdtemp(prefix='.uzelhub-source-',dir=theme.parent))
        shutil.copytree(original_theme,stage,dirs_exist_ok=True)
        (stage/'partials/components/footer.hbs').write_bytes(desired)
        owner=theme.lstat()
        for path in [stage,*stage.rglob('*')]: os.chown(path,owner.st_uid,owner.st_gid)
    else:
        assert target.resolve().is_relative_to(content)
        metadata=target.stat()
    try:
        if symlink:
            theme.unlink()  # Remove only the verified symlink, never its target.
            try: os.replace(stage,theme)
            except Exception:
                theme.symlink_to(symlink); raise
            materialized=True
        else:
            atomic_write(target,desired,metadata)
        run(['docker','restart','ghost'],timeout=60)
        for attempt in range(15):
            try:
                checked=verify(); break
            except Exception:
                if attempt==14: raise
                time.sleep(2)
        result={'result':'applied','backup':str(backup),'verified':checked,'sha256':digest(desired)}
        (backup/'result.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result),flush=True)
    except Exception:
        if symlink:
            if materialized:
                failed=theme.parent/('.failed-source-'+backup.name)
                os.replace(theme,failed)
                theme.symlink_to(symlink)
        else:
            atomic_write(target,current,metadata)
        run(['docker','restart','ghost'],timeout=60)
        restored=False
        for _ in range(15):
            try:
                with urllib.request.urlopen(URLS[0],timeout=10) as r:
                    restored=r.status==200 and MARKER not in r.read().decode('utf8')
                if restored: break
            except Exception: pass
            time.sleep(2)
        print(json.dumps({'result':'restored after failed verification','recovery_verified':restored,'backup':str(backup)}),flush=True)
        raise

if __name__=='__main__': main()
