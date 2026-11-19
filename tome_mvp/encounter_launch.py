"""Trusted local host entry. No campaign mutation and no arbitrary Lua input."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import socket
import shutil
import struct
import subprocess
import sys
import time
from urllib.request import urlopen
from uuid import uuid4
from .encounter import validate_encounter

ROOT = Path(__file__).resolve().parents[1]


def package_frozen(base, out, encounter):
    """Copy an immutable build and bind a validated manifest without compiling."""
    base=Path(base).resolve(strict=True)
    identity=json.loads((base/'identity.json').read_text(encoding='utf-8'))
    if 'host_scripts' in identity.get('inputs', {}):
        return _package_partition_frozen(base, Path(out), encounter, identity)
    requested=encounter.get('map',{})
    if 'zone' in encounter and 'native_zone.lua' not in identity.get('scene_overlay',{}).get('lua',{}):
        raise ValueError('frozen kernel has no native Zone support; build a current scene overlay')
    if requested.get('kind','rooms')!='rooms' or requested.get('size',20)!=20:
        current=hashlib.sha256((ROOT/'tome_mvp/headless/formal_map.lua').read_bytes()).hexdigest()
        compiled=identity.get('inputs',{}).get('lua',{}).get('bundle/headless/formal_map.lua',{}).get('sha256')
        if not identity.get('scene_overlay') and compiled!=current:
            raise ValueError('frozen kernel does not support the requested map; use a scene-capable build')
    source=base/'public'
    required=('tome.js','tome.wasm','tome.data','browser_worker.mjs','kernel_runtime.mjs','encounter_overlay.mjs')
    if any(not (source/name).is_file() for name in required):raise ValueError('incomplete frozen kernel')
    raw=json.dumps(encounter,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False)
    files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.iterdir()) if p.is_file()}
    material={'base_build_id':identity['build_id'],'base_files':files,'encounter':encounter,
              'host_validator_sha256':hashlib.sha256((ROOT/'scripts/tome_session_host.mjs').read_bytes()).hexdigest(),
              'host_validator_operations_sha256':hashlib.sha256((ROOT/'scripts/tome_validate_operations.mjs').read_bytes()).hexdigest()}
    build=hashlib.sha256(json.dumps(material,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    public=out/'public';public.mkdir(parents=True,exist_ok=False)
    for p in source.iterdir():
        if p.is_file():
            shutil.copyfile(p,public/p.name)
            if hashlib.sha256((public/p.name).read_bytes()).hexdigest()!=files[p.name]:raise ValueError('frozen kernel changed while copying')
    worker=public/'browser_worker.mjs';text=worker.read_text(encoding='utf-8')
    old=identity['build_id']
    if text.count(old)!=1 or "'__TOME_ENCOUNTER_OVERLAY__'==='enabled'" not in text:raise ValueError('incompatible frozen wrapper')
    text=text.replace(old,build).replace("'__TOME_ENCOUNTER_OVERLAY__'==='enabled'","'enabled'==='enabled'")
    # The base build's seed is embedded in this one constructor call.
    text,count=re.subn(r'new BattleSession\(kernel\.rpc,recorder\.build,\d+\)',f'new BattleSession(kernel.rpc,recorder.build,{encounter["seed"]})',text)
    if count!=1:raise ValueError('incompatible frozen seed wrapper')
    worker.write_text(text,encoding='utf-8')
    (public/'encounter.json').write_text(raw,encoding='utf-8')
    (out/'encounter.json').write_text(raw,encoding='utf-8')
    shutil.copyfile(ROOT/'scripts/tome_session_host.mjs',out/'validator.mjs')
    if hashlib.sha256((out/'validator.mjs').read_bytes()).hexdigest()!=material['host_validator_sha256']:raise ValueError('validator changed while copying')
    shutil.copyfile(ROOT/'scripts/tome_validate_operations.mjs',out/'tome_validate_operations.mjs')
    if hashlib.sha256((out/'tome_validate_operations.mjs').read_bytes()).hexdigest()!=material['host_validator_operations_sha256']:raise ValueError('validator operations changed while copying')
    (out/'identity.json').write_text(json.dumps({'build_id':build,'encounter_overlay':True,'inputs':material},ensure_ascii=False,indent=2),encoding='utf-8')
    return build


def _package_partition_frozen(base, out, encounter, identity):
    """Bind a scene while preserving the complete partition kernel and host."""
    inputs=identity['inputs']
    if hashlib.sha256(json.dumps(inputs,sort_keys=True).encode()).hexdigest()[:16]!=identity['build_id']:
        raise ValueError('base partition identity mismatch')
    descriptors=inputs['host_scripts']
    if not isinstance(descriptors,dict) or len(descriptors)!=14:
        raise ValueError('incomplete partition host')
    sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
    lua=inputs.get('lua',{})
    if 'zone' in encounter and 'bundle/headless/native_zone.lua' not in lua:
        raise ValueError('frozen kernel has no native Zone support')
    requested=encounter.get('map',{})
    if requested.get('kind','rooms')!='rooms' or requested.get('size',20)!=20:
        compiled=lua.get('bundle/headless/formal_map.lua',{}).get('sha256')
        if compiled!=sha(ROOT/'tome_mvp/headless/formal_map.lua'):
            raise ValueError('frozen kernel does not support the requested map')
    for name,info in descriptors.items():
        path=(base/name).resolve(strict=True)
        if not path.is_relative_to(base) or path.stat().st_size!=info['bytes'] or sha(path)!=info['sha256']:
            raise ValueError('base partition dependency mismatch: '+name)
    build_info=json.loads((base/'build.json').read_text(encoding='utf8'))
    for name in ('tome.js','tome.wasm','tome.data'):
        path=base/'public'/name;spec=build_info['outputs'][name]
        if path.stat().st_size!=spec['bytes'] or sha(path)!=spec['sha256']:raise ValueError('base binary mismatch')
    if out.exists():raise FileExistsError(out)
    shutil.copytree(base/'public',out/'public');shutil.copytree(base/'host',out/'host')
    shutil.copyfile(base/'build.json',out/'build.json')
    raw=json.dumps(encounter,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False)
    (out/'encounter.json').write_text(raw,encoding='utf8');(out/'public/encounter.json').write_text(raw,encoding='utf8')
    shutil.copyfile(ROOT/'scripts/tome_session_host.mjs',out/'validator.mjs')
    shutil.copyfile(base/'host/tome_validate_operations.mjs',out/'tome_validate_operations.mjs')
    # Freeze the original public files too; the browser worker is transformed below.
    inputs=dict(inputs)
    inputs['base_build_id']=identity['build_id']
    inputs['base_files']={p.name:sha(p) for p in sorted((base/'public').iterdir()) if p.is_file()}
    inputs['encounter']=encounter
    inputs['host_validator_sha256']=sha(out/'validator.mjs')
    inputs['host_validator_operations_sha256']=sha(out/'tome_validate_operations.mjs')
    build=hashlib.sha256(json.dumps(inputs,sort_keys=True).encode()).hexdigest()[:16]
    worker=out/'public/browser_worker.mjs';text=worker.read_text(encoding='utf8')
    if text.count(identity['build_id'])!=1 or text.count("'__TOME_ENCOUNTER_OVERLAY__'==='enabled'")!=1:raise ValueError('incompatible frozen wrapper')
    text=text.replace(identity['build_id'],build).replace("'__TOME_ENCOUNTER_OVERLAY__'==='enabled'","'enabled'==='enabled'")
    text,count=re.subn(r'new BattleSession\(kernel\.rpc,recorder\.build,\d+\)',f'new BattleSession(kernel.rpc,recorder.build,{encounter["seed"]})',text)
    if count!=1:raise ValueError('incompatible frozen seed wrapper')
    worker.write_text(text,encoding='utf8',newline='\n')
    (out/'identity.json').write_text(json.dumps({'build_id':build,'encounter_overlay':True,'inputs':inputs},ensure_ascii=False,indent=2),encoding='utf8')
    return build


def stage_portraits(entries, root):
    assets={}
    for entry in entries:
        alias, separator, source = entry.partition('=')
        if not separator or not re.fullmatch(r'[a-zA-Z0-9_-]{1,60}',alias): raise ValueError('portrait must be alias=path.png')
        rel=f'data/gfx/encounter/{alias}.png'
        if rel in assets: raise ValueError('duplicate portrait alias')
        source_path=Path(source)
        if not source_path.is_file() or source_path.stat().st_size>10*1024*1024: raise ValueError('portrait file is absent or too large')
        data=source_path.read_bytes()
        if not 24<=len(data)<=10*1024*1024 or data[:8]!=b'\x89PNG\r\n\x1a\n' or data[12:16]!=b'IHDR': raise ValueError('expected PNG, at most 10MiB')
        w,h=struct.unpack('>II',data[16:24])
        if not (1<=w<=4096 and 1<=h<=4096): raise ValueError('portrait dimensions out of range')
        target=root/rel;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        assets[rel]={'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}
    root.mkdir(parents=True,exist_ok=True)
    (root/'manifest.json').write_text(json.dumps({'version':1,'assets':assets},indent=2),encoding='utf-8')
    return assets


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest',required=True,type=Path)
    p.add_argument('--check',action='store_true',help='validate schema only; does not prove native construction')
    p.add_argument('--port',type=int,default=0)
    p.add_argument('--portrait-file',action='append',default=[],help='alias=explicit PNG path; manifest uses data/gfx/encounter/alias.png')
    p.add_argument('--frozen-kernel',type=Path,help='trusted host-configured immutable base build')
    p.add_argument('--party-bootstrap',action='store_true',help='trusted host only')
    p.add_argument('--native-checkpoints',action='store_true')
    p.add_argument('--resident-validation',action='store_true')
    p.add_argument('--native-partitions',action='store_true')
    p.add_argument('--native-partition-resident',action='store_true')
    a=p.parse_args(argv)
    encounter=validate_encounter(json.loads(a.manifest.read_text(encoding='utf-8-sig')),allow_bootstrap=a.party_bootstrap)
    if a.party_bootstrap and encounter.get('purpose')!='party_bootstrap':raise ValueError('bootstrap purpose required')
    if a.check:
        print(json.dumps({'schema_valid':True,'native_verified':False,'seed':encounter['seed']}));return
    if a.port<0 or a.port>65535: p.error('invalid port')
    run=ROOT/'artifacts'/('tome-dm-encounter-'+datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+uuid4().hex[:8])
    run.mkdir(parents=True,exist_ok=False)
    assets=stage_portraits(a.portrait_file,run/'portraits')
    builtin_path=ROOT/'artifacts/tome-formal-squad-20261111/assets/manifest.json'
    builtin=json.loads(builtin_path.read_text(encoding='utf-8'))['assets'] if builtin_path.is_file() else {}
    for actor in encounter['party']:
        if 'portrait' in actor and actor['portrait'] not in assets and actor['portrait'] not in builtin: raise ValueError('portrait not admitted by an asset manifest')
    manifest=run/'encounter.json';manifest.write_text(json.dumps(encounter,ensure_ascii=False,indent=2),encoding='utf-8')
    if a.frozen_kernel:
        package_frozen(a.frozen_kernel,run/'mvp',encounter)
    else:
        with (run/'build.log').open('w',encoding='utf-8') as log:
            command=[sys.executable,str(ROOT/'scripts/build_tome_wasm.py'),'--encounter',str(manifest),'--output',str(run/'mvp')]
            if a.party_bootstrap:command.append('--party-bootstrap')
            subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
    with (run/'verification.log').open('w',encoding='utf-8') as log:
        subprocess.run(['node',str(ROOT/'scripts/probe_tome_encounter.mjs'),str(run/'mvp/public'),str(run/'verification.json'),str(encounter['seed'])],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
    port=a.port
    if not port:
        with socket.socket() as s:
            s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    ready=run/'server-ready.json'
    cmd=[sys.executable,'-m','tome_mvp.wasm.session_server','--root',str(run/'mvp/public'),'--data',str(run/'session-data'),'--port',str(port),'--overlay-assets',str(run/'portraits'),'--ready-file',str(ready)]
    for option in ('native_checkpoints','resident_validation','native_partitions','native_partition_resident'):
        if getattr(a,option):cmd.append('--'+option.replace('_','-'))
    with (run/'server.stdout.log').open('w') as out,(run/'server.stderr.log').open('w') as err:
        process=subprocess.Popen(cmd,cwd=ROOT,stdout=out,stderr=err,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    url=f'http://127.0.0.1:{port}/'
    for _ in range(50):
        if process.poll() is not None: raise RuntimeError('static service exited; see server.stderr.log')
        if not ready.is_file(): time.sleep(.1);continue
        record=json.loads(ready.read_text(encoding='utf-8'))
        if record!={'pid':process.pid,'port':port}: process.terminate();raise RuntimeError('invalid static service receipt')
        try:
            with urlopen(url,timeout=.5) as response:
                if response.status==200: break
        except OSError: time.sleep(.1)
    else:
        process.terminate();raise RuntimeError('static service did not become ready')
    receipt={'format':'tome-local-launch-v1','url':url,'pid':process.pid,'root':str(run),'seed':encounter['seed'],'native_construction_verified':True,'campaign_settlement':False,'persistent_sessions':True,'nonterminal_handover':True,'session_data':str(run/'session-data'), 'host_token_file':str(run/'session-data/host-token')}
    (run/'launch.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8');print(json.dumps(receipt))


if __name__=='__main__': main()
