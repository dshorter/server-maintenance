#!/usr/bin/env python3
"""Deploy Predictor branding with scoped settings backup and failure recovery.

The site's integration returns 501 for settings edits, so this host helper
updates only the four publication fields and two theme fields in branding.json.
Default is preflight. Pass --apply after inspecting the rendered preview.
"""
import argparse,hashlib,json,os,re,subprocess,tempfile,time,urllib.request
from pathlib import Path
from datetime import datetime,timezone

ROOT=Path(__file__).resolve().parents[1]/'ghost'/'predictor-branding'
BASE='https://blog.uzelhub.com/'
LINKS=['https://uzelhub.com/products/predictor-suite/','https://uzelhub.com/products/predictor-suite/ingest.html','https://uzelhub.com/products/predictor-suite/explorer.html']

def run(args,**kw): return subprocess.run(args,check=True,capture_output=True,**kw)
def sha(data): return hashlib.sha256(data.replace(b'\r\n',b'\n')).hexdigest()
def sql(text):
    r=run(['docker','exec','-i','ghost-mysql','sh','-lc','mysql --default-character-set=utf8mb4 -uroot -p"$MYSQL_ROOT_PASSWORD" -D ghost_prod -N -B'],input=text.encode())
    return r.stdout.decode()
def literal(value):
    return 'NULL' if value is None else "CONVERT(X'"+value.encode().hex()+"' USING utf8mb4)"
def read_settings(table,keys):
    assert table in ('settings','custom_theme_settings')
    where=' AND theme=\'source\'' if table=='custom_theme_settings' else ''
    q="SELECT JSON_OBJECT('key',`key`,'value',value) FROM "+table+' WHERE `key` IN ('+','.join(literal(k) for k in keys)+')'+where+';'
    rows=[json.loads(x) for x in sql(q).splitlines()]
    return {r['key']:r['value'] for r in rows}
def update_settings(table,values,expected):
    where=' AND theme=\'source\'' if table=='custom_theme_settings' else ''
    timestamp=',updated_at=UTC_TIMESTAMP()' if table=='settings' else ''
    commands=['START TRANSACTION;']
    for k,v in values.items():
        commands.append('UPDATE '+table+' SET value='+literal(v)+timestamp+' WHERE `key`='+literal(k)+where+' AND value <=> '+literal(expected[k])+';')
    commands.append('COMMIT;');sql('\n'.join(commands))
    assert read_settings(table,values)==values, 'Settings revision mismatch: '+table
def write_file(path,data,metadata):
    fd,tmp=tempfile.mkstemp(prefix='.branding-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f: f.write(data);f.flush();os.fsync(f.fileno())
        os.chmod(tmp,metadata.st_mode & 0o777);os.chown(tmp,metadata.st_uid,metadata.st_gid)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
def fetch(url):
    with urllib.request.urlopen(url,timeout=15) as r: return r.read().decode()
def verify(manifest):
    home=fetch(BASE)
    assert manifest['settings']['title'] in home
    assert manifest['settings']['meta_title'] in home
    assert manifest['settings']['description'] in home
    assert manifest['theme_settings']['header_text'] in home
    assert home.count('id="uz-predictor-intro"')==1
    header=re.search(r'<section class="gh-header.*?</section>',home,re.S).group()
    assert 'gh-header-image' not in header
    for link in LINKS: assert 'href="'+link+'"' in header
    for route in ['', 'what-your-agent-cant-tell-you/', 'about/', 'tag/ai-agents/']:
        page=home if not route else fetch(BASE+route)
        footer=re.search(r'<footer class="gh-footer[\s"].*?</footer>',page,re.S).group()
        assert footer.count('id="uz-blog-purpose-title"')==1
        assert 'How Predictor Suite was built.' in footer
        for link in LINKS: assert 'href="'+link+'"' in footer
    return ['homepage title, metadata and introduction','three product links in header and four footer surfaces','cover hidden behind text']
def retry(function):
    for n in range(15):
        try:return function()
        except Exception:
            if n==14:raise
            time.sleep(2)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--apply',action='store_true');args=parser.parse_args()
    manifest=json.loads((ROOT/'branding.json').read_text())
    assert set(manifest['settings'])=={'title','description','meta_title','meta_description'}
    assert set(manifest['theme_settings'])=={'header_text','background_image'}
    mounts=json.loads(run(['docker','inspect','ghost','--format','{{json .Mounts}}']).stdout)
    content=Path(next(m['Source'] for m in mounts if m['Destination']=='/var/lib/ghost/content')).resolve()
    target=(content/'themes/source/partials/components').resolve();assert target.is_relative_to(content)
    names=list(manifest['before'])+manifest['new_files']
    assert set(names)=={'header.hbs','header-content.hbs','footer.hbs','predictor-intro.hbs'}
    desired={n:(ROOT/n).read_bytes() for n in names}
    originals={n:(target/n).read_bytes() if (target/n).exists() else None for n in names}
    old=read_settings('settings',manifest['settings']);old_theme=read_settings('custom_theme_settings',manifest['theme_settings'])
    if old==manifest['settings'] and old_theme==manifest['theme_settings'] and all(originals[n] is not None and sha(originals[n])==sha(desired[n]) for n in names):
        print(json.dumps({'result':'already applied','verified':verify(manifest)}));return
    assert old==manifest['expected_settings'] and old_theme==manifest['expected_theme_settings'], 'Settings changed since preview'
    for n,data in originals.items():
        assert (data is None and n in manifest['new_files']) or (data is not None and sha(data)==manifest['before'].get(n)), 'Theme changed since preview: '+n
    for data in desired.values():
        run(['docker','exec','-i','-w','/var/lib/ghost/current','ghost','node','-e',"require('handlebars').precompile(require('fs').readFileSync(0,'utf8'))"],input=data)
    for link in LINKS:fetch(link)
    print('Preflight passed: settings and template revisions, Handlebars syntax, product links.',flush=True)
    if not args.apply:return
    backup=Path('/var/backups/ghost-branding')/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup.mkdir(parents=True,mode=0o700,exist_ok=False)
    (backup/'settings-before.json').write_text(json.dumps({'settings':old,'custom_theme_settings':old_theme},indent=2))
    for n,data in originals.items():
        if data is not None:(backup/n).write_bytes(data)
    metadata={n:(target/n).stat() if (target/n).exists() else (target/'header.hbs').stat() for n in names}
    try:
        for n,data in desired.items():write_file(target/n,data,metadata[n])
        update_settings('settings',manifest['settings'],old)
        update_settings('custom_theme_settings',manifest['theme_settings'],old_theme)
        run(['docker','restart','ghost'],timeout=60)
        verified=retry(lambda:verify(manifest))
        receipt={'result':'applied','backup':str(backup),'verified':verified}
        (backup/'result.json').write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt))
    except Exception:
        for n,data in originals.items():
            if data is None:
                if (target/n).exists():(target/n).unlink()
            else:write_file(target/n,data,metadata[n])
        # Restore only fields still carrying this deployment's values.
        update_settings('settings',old,manifest['settings'])
        update_settings('custom_theme_settings',old_theme,manifest['theme_settings'])
        run(['docker','restart','ghost'],timeout=60)
        def recovery():
            page=fetch(BASE);assert 'id="uz-predictor-intro"' not in page;assert old['title'] in page;return True
        restored=retry(recovery)
        print(json.dumps({'result':'restored after failure','recovery_verified':restored,'backup':str(backup)}));raise

if __name__=='__main__':main()
