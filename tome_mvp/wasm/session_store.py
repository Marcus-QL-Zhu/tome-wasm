"""Durable battle checkpoints and nonterminal DM handovers, with replay admission."""
from contextlib import contextmanager, closing
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import threading
import tempfile
import time
import uuid

ROOT=Path(__file__).resolve().parents[2]
NATIVE_BLOB_LIMIT=64*1024*1024
CHECKPOINT_ENVELOPE_LIMIT=80*1024*1024
def wire(value):return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False)


def validate_loot_choices(choices):
    if not isinstance(choices,list) or len(choices)>4096:
        raise ValueError('invalid loot choices')
    last_uid=0
    for row in choices:
        if (not isinstance(row,dict) or set(row)!={'uid','count','keep','transmo_cents'}
                or type(row['uid']) is not int or row['uid']<=last_uid
                or type(row['count']) is not int or row['count']<1 or type(row['keep']) is not bool):
            raise ValueError('invalid loot selection')
        price=row['transmo_cents']
        if (price is None and not row['keep']) or (price is not None and (type(price) is not int or price<0)):
            raise ValueError('invalid loot price')
        last_uid=row['uid']


def scene_number(archive):
    """Legacy encounters and persistent-area entries both start a scene scope."""
    return sum(isinstance(e,dict) and (e.get('kind')=='campaign_next' or
               e.get('kind')=='dm_transition' and e.get('body',{}).get('operation')=='area_enter')
               for e in archive.get('audit',[])+archive.get('events',[]))


def _partition_no_active_capabilities(caps):
    """Bridge state adds two non-command capability descriptors."""
    if not isinstance(caps,dict):return False
    for name,value in caps.items():
        if name=='ai_continuous':
            if type(value) is not bool:return False
        elif name=='ai_modes':
            if not isinstance(value,list) or any(x not in ('sweep','explore','rest') for x in value):return False
        elif value is not False:return False
    return True


def loadout_boundary(document):
    """Use committed native departure state, not a browser's pause claim."""
    view=document.get('view')or{}
    areas=(document.get('native')or{}).get('local_areas')or{}
    current=areas.get('current_area')
    outside=(areas.get('outside')is True and isinstance(current,str) and current.startswith('area:')
             and current in areas.get('areas',{}))
    if document.get('state')=='suspended':return outside
    return document.get('state')=='active' and (outside or view.get('campaign_bootstrap')is True
            or view.get('status')=='victory' or view.get('campaign_withdrawn')is True)


class SessionStore:
    def __init__(self,path,public_root,validator=None,*,native_checkpoints=False,resident_validation=False,native_partitions=False,native_partition_resident=False):
        self.path=Path(path);self.path.parent.mkdir(parents=True,exist_ok=True)
        self.public_root=Path(public_root).resolve();self.lock=threading.RLock();self.validator=validator or self._validate;self.native_checkpoints=native_checkpoints;self.resident_validation=resident_validation;self._partition_experimental=native_partitions;self._partition_resident=native_partition_resident;self._partition_binary_cache={}
        with self.connect() as db:
            db.executescript('''CREATE TABLE IF NOT EXISTS battles(id TEXT PRIMARY KEY,version INTEGER,state TEXT,archive TEXT,view TEXT);
            CREATE TABLE IF NOT EXISTS receipts(request_id TEXT PRIMARY KEY,request TEXT,receipt TEXT);
            CREATE TABLE IF NOT EXISTS handovers(id TEXT PRIMARY KEY,battle_id TEXT,version INTEGER,state TEXT,receipt TEXT);
            CREATE TABLE IF NOT EXISTS defeat_snapshots(battle_id TEXT NOT NULL,scene_id TEXT NOT NULL,version INTEGER NOT NULL,archive TEXT NOT NULL,view TEXT NOT NULL,native TEXT NOT NULL,archive_sha256 TEXT NOT NULL,PRIMARY KEY(battle_id,scene_id));''')
            if 'native' not in {r[1] for r in db.execute('PRAGMA table_info(battles)')}:
                db.execute('ALTER TABLE battles ADD COLUMN native TEXT')

    @contextmanager
    def connect(self):
        db=sqlite3.connect(self.path,timeout=30)
        try:
            with db:yield db
        finally:db.close()

    def _resident_compatible(self):
        # Never substitute live operation code for a different frozen validator.
        frozen=self.public_root.parent/'validator.mjs'
        if not frozen.is_file():return True
        source=ROOT/'scripts/tome_session_host.mjs'
        helper=ROOT/'scripts/tome_validate_operations.mjs'
        frozen_helper=frozen.parent/helper.name
        try:
            if frozen.read_bytes()!=source.read_bytes() or frozen_helper.read_bytes()!=helper.read_bytes():return False
            identity=json.loads((self.public_root.parent/'identity.json').read_text(encoding='utf-8'))
            expected=identity.get('inputs',{}).get('host_validator_sha256')
            if expected and hashlib.sha256(frozen.read_bytes()).hexdigest()!=expected:return False
            helper_hash=identity.get('inputs',{}).get('host_validator_operations_sha256')
            return bool(helper_hash) and hashlib.sha256(frozen_helper.read_bytes()).hexdigest()==helper_hash
        except (OSError,ValueError,TypeError):return False

    def _validate(self,archive,operations):
        if self.resident_validation and self._resident_compatible():
            from .resident_validator import validator_for
            response=validator_for(self.path,self.public_root,ROOT/'scripts/tome_resident_validator.mjs').request(
                {'archive':archive,'operations':operations,'native_checkpoints':self.native_checkpoints})
            if not response.get('ok'):raise ValueError('resident native validation failed')
            return response
        work=self.path.parent/'verification'/uuid.uuid4().hex;work.mkdir(parents=True)
        source=work/'input.json';output=work/'result.json';source.write_text(wire({'archive':archive,'operations':operations,'native_checkpoints':self.native_checkpoints}),encoding='utf-8')
        with (work/'log.txt').open('w',encoding='utf-8') as log:
            frozen_host=self.public_root.parent/'validator.mjs'
            host=frozen_host if frozen_host.is_file() else ROOT/'scripts/tome_session_host.mjs'
            result=subprocess.run(['node',str(host),str(self.public_root),str(source),str(output)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=180,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        response=json.loads(output.read_text(encoding='utf-8')) if output.is_file() else {}
        if result.returncode or not response.get('ok'):raise ValueError('native replay validation failed; evidence '+str(work))
        return response

    def _legacy_validate(self,archive,operations):
        if isinstance(archive,dict) and archive.get('format')=='tome-partition-session-v1':
            raise ValueError('operation is unavailable for partition sessions')
        return self.validator(archive,operations)

    def get(self,battle_id):
        with self.connect() as db:
            row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row:raise KeyError('unknown battle')
            view=json.loads(row[3])
            result={'battle_id':battle_id,'version':row[0],'state':row[1],'archive':json.loads(row[2]),
                    'view':view,'native':json.loads(row[4]) if row[4] else None}
            if view.get('status')=='defeat' and view.get('campaign_bound') is True:
                result['terminal_pending']=(view.get('campaign_withdrawn') is True or db.execute(
                    "SELECT 1 FROM handovers WHERE battle_id=? AND version=? AND state='terminal_pending'",
                    (battle_id,row[0])).fetchone() is not None)
            return result

    def save(self,request):
        from .browser_checkpoint import restore_submission
        request=restore_submission(self.path,request)
        if set(request)-{'request_id','battle_id','version','archive','handover','snapshot','loot_choices'} or not {'request_id','version','archive','handover'}<=set(request):raise ValueError('invalid checkpoint fields')
        rid=request['request_id'];version=request['version'];handover=request['handover']
        if not isinstance(rid,str) or not 1<=len(rid)<=100 or type(version) is not int or version<0 or type(handover) is not bool:raise ValueError('invalid checkpoint identity')
        if 'loot_choices' in request:
            if not handover or not self.native_checkpoints:raise ValueError('loot requires a native handover')
            validate_loot_choices(request['loot_choices'])
        encoded=wire(request)
        if len(encoded.encode('utf-8'))>CHECKPOINT_ENVELOPE_LIMIT:raise ValueError('checkpoint capacity exceeded')
        if 'snapshot' in request:
            from .browser_checkpoint import retain_submission
            retain_submission(self.path,encoded)
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(rid,)).fetchone()
            if old:
                if old[0]!=encoded:raise ValueError('request ID conflict')
                return json.loads(old[1])
            bid=request.get('battle_id') or uuid.uuid4().hex
            prior=db.execute('SELECT version,state,archive,view FROM battles WHERE id=?',(bid,)).fetchone()
            incoming=request['archive'];events=incoming.get('events',[])
            if not isinstance(events,list):raise ValueError('invalid checkpoint events')
            if incoming.get('format')=='tome-native-session-v1':
                if not self.native_checkpoints:raise ValueError('native checkpoints unavailable')
                base=incoming.get('base');checkpoint=base.get('checkpoint') if isinstance(base,dict) else None
                blob=checkpoint.get('blob') if isinstance(checkpoint,dict) else None
                if not isinstance(blob,str) or len(blob.encode('utf-8'))>NATIVE_BLOB_LIMIT:raise ValueError('native checkpoint blob capacity exceeded')
            if prior:
                if prior[0]!=version or prior[1]!='active':raise ValueError('stale or suspended battle')
                prev=json.loads(prior[2])
                prior_view=json.loads(prior[3]); generation=prior_view.get('generation')
                if type(generation) is int:
                    scene=str(generation)+'.'+str(scene_number(prev))
                    if db.execute('SELECT 1 FROM defeat_snapshots WHERE battle_id=? AND scene_id=?',(bid,scene)).fetchone():raise ValueError('defeat settlement frozen')
                if incoming.get('format')!=prev.get('format') or incoming.get('seed')!=prev.get('seed') or incoming.get('build')!=prev.get('build') or events[:len(prev['events'])]!=prev['events']:raise ValueError('checkpoint is not an extension')
                if prev.get('format') in ('tome-native-session-v1','tome-partition-session-v1') and (incoming.get('base')!=prev.get('base') or incoming.get('audit')!=prev.get('audit')):raise ValueError('untrusted checkpoint base')
                if prev.get('format')=='tome-partition-session-v1' and (not isinstance(incoming.get('final'),str) or len(incoming['final'])!=64 or set(incoming)!=set(prev) or any(not isinstance(e,dict) or e.get('kind') not in ('command','inspect') for e in events)):
                    raise ValueError('invalid partition incremental events')
                permitted=[e for e in prev['events'] if e['kind'] in ('dm_transition','campaign_next','campaign_items','campaign_adopt','campaign_reconcile','campaign_settle','campaign_wipeout')]
            else:
                if version or request.get('battle_id'):raise ValueError('unknown battle version')
                if incoming.get('format')=='tome-partition-session-v1':raise ValueError('initial partition checkpoint forbidden')
                if self.native_checkpoints and incoming.get('format')!='tome-replay-save-v1':raise ValueError('initial checkpoint requires replay admission')
                permitted=[]
            if [e for e in events if e.get('kind') in ('dm_transition','campaign_next','campaign_items','campaign_adopt','campaign_reconcile','campaign_settle','campaign_wipeout')]!=permitted:raise ValueError('unauthorized DM transition')
            partitioned=bool(prior and prev.get('format')=='tome-partition-session-v1')
            if partitioned:
                from .browser_checkpoint import accept_snapshot
                verified=accept_snapshot(db,bid,version,prev,incoming,request.get('snapshot'))
                self._partition_stage_tx(db,bid,version,rid,verified)
            else:
                if 'snapshot' in request:raise ValueError('browser snapshot requires a partition parent')
                verified=self._legacy_validate(request['archive'],[])
            # Verification may append a safe pause. Clients must restore this
            # canonical archive, or use the exact archive if no append occurred.
            archive=verified['archive'];view=verified['view'];next_version=version+1
            if 'loot_choices' in request:
                areas=(verified.get('native') or {}).get('local_areas') or {}
                if (view.get('status')=='defeat' or not str(areas.get('current_area','')).startswith('area:')
                        or areas.get('outside') is not False):
                    raise ValueError('loot requires an active native area')
            terminal_handover=handover and view.get('status')=='defeat' and view.get('campaign_bound') is True
            state='suspended' if handover and not terminal_handover else 'active'
            db.execute('INSERT OR REPLACE INTO battles(id,version,state,archive,view,native) VALUES(?,?,?,?,?,?)',(bid,next_version,state,wire(archive),wire(view),wire(verified['native']) if verified.get('native') else None))
            receipt={'format':'tome-checkpoint-receipt-v1','battle_id':bid,'version':next_version,'state':state,'turn':view['turn'],'status':view['status'],'verified':True}
            if archive.get('format')=='tome-native-session-v1':receipt['native_checkpoint']=True
            if archive.get('format')=='tome-partition-session-v1':receipt['partition_checkpoint']=True
            if partitioned:receipt.update(validation='snapshot_integrity',combat_replayed=False)
            if terminal_handover:
                receipt['terminal_pending']=True
                db.execute('INSERT INTO handovers VALUES(?,?,?,?,?)',
                           (uuid.uuid4().hex,bid,next_version,'terminal_pending',wire({'receipt':receipt})))
            elif handover:
                hid=uuid.uuid4().hex;receipt['handover_id']=hid
                payload={'receipt':receipt,'view':view}
                if 'loot_choices' in request:
                    payload['loot_choices']=request['loot_choices']
                    receipt['loot_pending']=True
                if partitioned:
                    from dm_mvp.battle_summary import summary_from_store
                    payload['battle_summary']=summary_from_store(db,bid,next_version,view,verified.get('native')or{})
                db.execute('INSERT INTO handovers VALUES(?,?,?,?,?)',(hid,bid,next_version,'pending',wire(payload)))
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(rid,encoded,wire(receipt)))
            return receipt

    def pending(self):
        with self.connect() as db:
            return [json.loads(r[0]) for r in db.execute("SELECT receipt FROM handovers WHERE state='pending' ORDER BY rowid")]

    def freeze_defeat(self,battle_id,version):
        """Preserve the verified terminal replay before any post-battle operation."""
        if not isinstance(battle_id,str) or not battle_id or type(version) is not int: raise ValueError('invalid defeat identity')
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version or row[1]!='active': raise ValueError('stale defeat checkpoint')
            archive=json.loads(row[2]); view=json.loads(row[3]); native=json.loads(row[4]) if row[4] else None
            events=archive.get('audit',[])+archive.get('events',[]); generation=view.get('generation'); party=view.get('party'); native_party=native.get('party') if isinstance(native,dict) else None
            if (view.get('status')!='defeat' or type(generation) is not int or not isinstance(events,list)
                or not isinstance(party,list) or not party or not isinstance(native_party,list) or len(party)!=len(native_party)
                or any(not isinstance(x,dict) or x.get('down') is not True for x in party)
                or any(not isinstance(x,dict) or x.get('down') is not True or not isinstance(x.get('world_id'),str) or not x['world_id'] or not isinstance(x.get('origin'),str) or not x['origin'] for x in native_party)
                or len({x['world_id'] for x in native_party})!=len(party)
                or [x.get('uid') for x in native_party]!=[x.get('id') for x in party]): raise ValueError('verified complete bound defeat required')
            scene=str(generation)+'.'+str(scene_number(archive))
            digest=hashlib.sha256(row[2].encode('utf-8')).hexdigest()
            old=db.execute('SELECT version,archive_sha256 FROM defeat_snapshots WHERE battle_id=? AND scene_id=?',(battle_id,scene)).fetchone()
            if old:
                return {'battle_id':battle_id,'scene_id':scene,'version':old[0],'archive_sha256':old[1],'verified':True}
            db.execute('INSERT INTO defeat_snapshots VALUES(?,?,?,?,?,?,?)',(battle_id,scene,row[0],row[2],row[3],row[4],digest))
            return {'battle_id':battle_id,'scene_id':scene,'version':row[0],'archive_sha256':digest,'verified':True}

    def apply_wipeout(self,battle_id,version,request_id,world_id,world_location,victor=None):
        if type(version) is not int or not all(isinstance(x,str) and 1<=len(x)<=100 for x in (battle_id,request_id,world_id,world_location)): raise ValueError('invalid wipeout request')
        operation={'operation':'campaign_wipeout','world_id':world_id,'world_location':world_location}
        if victor is not None:
            if (not isinstance(victor,dict) or set(victor)!={'person_id','uid'}
                    or not isinstance(victor['person_id'],str) or not 1<=len(victor['person_id'])<=100
                    or type(victor['uid']) is not int):
                raise ValueError('invalid defeat victor')
            operation['victor_id']=victor['person_id']
        encoded=wire({'operation':'wipeout','battle_id':battle_id,'version':version,'world_id':world_id,
                      'world_location':world_location,**({'victor':victor} if victor else {})})
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=encoded: raise ValueError('request ID conflict')
                return json.loads(old[1])
            row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version or row[1]!='active': raise ValueError('stale defeat checkpoint')
            frozen=db.execute('SELECT scene_id,archive_sha256 FROM defeat_snapshots WHERE battle_id=? AND version=?',(battle_id,version)).fetchone()
            if not frozen or frozen[1]!=hashlib.sha256(row[2].encode('utf8')).hexdigest(): raise ValueError('original defeat not frozen')
            before_native=json.loads(row[4])
            if victor and (before_native.get('defeat_victor') or {}).get('uid')!=victor['uid']:
                raise ValueError('defeat victor changed')
            verified,partitioned=self._partition_or_legacy_tx(db,battle_id,version,json.loads(row[2]),[operation],expected_world=world_id,request_id=request_id)
            results=verified.get('results',[]); native=verified.get('native') or {}; view=verified.get('view') or {}
            if len(results)!=1 or results[0].get('accepted') is not True or not isinstance(results[0].get('transition'),dict): raise ValueError('wipeout replay unavailable')
            transition=results[0]['transition']; prior=before_native['party']; after=native.get('party')
            if (transition.get('world_id')!=world_id or transition.get('location')!=world_location or transition.get('leader_uid')!=prior[0]['uid'] or transition.get('leader_hp')!=1
                or not isinstance(after,list) or len(after)!=1 or after[0].get('uid')!=prior[0]['uid'] or after[0].get('world_id')!=prior[0]['world_id'] or after[0].get('hp')!=1 or after[0].get('down') is not False
                or view.get('status')!='defeat'): raise ValueError('wipeout projection mismatch')
            if transition.get('victor')!=victor: raise ValueError('defeat victor receipt mismatch')
            participants=transition.get('participants')
            if not isinstance(participants,list) or len(participants)!=len(prior) or any(x.get('uid')!=p['uid'] or x.get('person_id')!=p['world_id'] or x.get('role')!=('leader' if i==0 else 'member') for i,(x,p) in enumerate(zip(participants,prior))): raise ValueError('wipeout participant mismatch')
            new_version=self._partition_stage_tx(db,battle_id,version,request_id,verified) if partitioned else version+1
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',(new_version,wire(verified['archive']),wire(view),wire(native),battle_id))
            receipt={'verified':True,'battle_id':battle_id,'scene_id':frozen[0],'parent_version':version,'version':new_version,'archive_sha256':frozen[1],'transition':transition}
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(receipt)))
            return receipt

    def next_scene(self,battle_id,version,request_id,scene):
        if not getattr(self,'_campaign_next_certified',False):
            raise ValueError('native cross-scene transition is experimental and unavailable')
        from tome_mvp.encounter import validate_encounter
        if not isinstance(scene,dict) or set(scene)!={'enemies','map'} or type(version) is not int or not isinstance(request_id,str) or not 1<=len(request_id)<=100:
            raise ValueError('invalid next scene')
        checked=validate_encounter({'format':'tome-encounter-v1','seed':0,'party':[{'template':x} for x in ('184917','159442','425367')],**scene})
        scene={'enemies':checked['enemies'],'map':checked['map']}
        request=wire({'battle_id':battle_id,'version':version,'scene':scene})
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=request:raise ValueError('request ID conflict')
                return json.loads(old[1])
            row=db.execute('SELECT version,state,archive,view FROM battles WHERE id=?',(battle_id,)).fetchone()
            view=json.loads(row[3]) if row else {}
            if not row or row[0]!=version or row[1]!='active': raise ValueError('active checkpoint required')
            if view.get('status')!='victory' and view.get('campaign_bootstrap') is not True:
                archive=json.loads(row[2]); events=archive.get('audit',[])+archive.get('events',[])
                last_next=max((i for i,e in enumerate(events) if e.get('kind')=='campaign_next'),default=-1)
                wipeouts=[e for e in events[last_next+1:] if e.get('kind')=='campaign_wipeout']
                if view.get('status')!='defeat' or len(wipeouts)!=1: raise ValueError('verified victory or settled defeat required')
                candidates=db.execute("SELECT receipt FROM receipts WHERE request_id LIKE 'wipeout-%'").fetchall()
                scene_id=str(view.get('generation'))+'.'+str(scene_number(archive))
                if not any((lambda r:r.get('verified') is True and r.get('battle_id')==battle_id and r.get('scene_id')==scene_id and r.get('version')<=version)(json.loads(x[0])) for x in candidates): raise ValueError('wipeout receipt required')
            verified=self._legacy_validate(json.loads(row[2]),[{'operation':'campaign_next','scene':scene}])
            new_version=version+1
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',(new_version,wire(verified['archive']),wire(verified['view']),wire(verified['native']) if verified.get('native') else None,battle_id))
            receipt={'battle_id':battle_id,'version':new_version,'state':'active','turn':verified['view']['turn'],'verified':True}
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,request,wire(receipt)))
            return receipt

    def _partition_db_identity_tx(self,db):
        """Experimental persistent instance identity, created under a write lock."""
        if not self._partition_experimental or not db.in_transaction:raise ValueError('partition identity transaction required')
        actual=Path(db.execute('PRAGMA database_list').fetchone()[2]).resolve()
        if actual!=self.path.resolve():raise ValueError('partition database identity mismatch')
        db.execute('CREATE TABLE IF NOT EXISTS native_partition_runtime_identity (singleton INTEGER PRIMARY KEY CHECK(singleton=1), instance_id TEXT NOT NULL)')
        db.execute('INSERT OR IGNORE INTO native_partition_runtime_identity VALUES(1,?)',(uuid.uuid4().hex,))
        value=db.execute('SELECT instance_id FROM native_partition_runtime_identity WHERE singleton=1').fetchone()[0]
        stat=actual.stat()
        return {'path':str(actual),'instance_id':value,'device':str(stat.st_dev) if stat.st_dev else None,'inode':str(stat.st_ino) if stat.st_ino else None}

    @staticmethod
    def _partition_abort_resident(validator,token):
        abort=getattr(validator,'abort_pending',None)
        if callable(abort):return abort(token)
        try:validator.request({'kind':'abort','pending_token':token})
        except BaseException:pass
        finally:validator.discard()

    def _partition_confirm_committed(self,lease,validator,proof=None):
        """Default-off handshake seam. Verify COMMIT on a new independently locked connection.

        Call only after the write transaction has exited. A confirmed DB receipt
        remains authoritative even if the cache confirmation is lost. No caller
        may re-execute the operation on an uncertain result.
        """
        required={'pending_token','scope','parent_version','parent_manifest_sha256','parent_hot_sha256',
                  'parent_envelope_sha256','new_version','new_manifest_sha256','hot_sha256',
                  'new_envelope_sha256','frozen_identity','db_identity','request_id'}
        confirmed_receipt=None
        try:
            if not self._partition_experimental or not isinstance(lease,dict) or set(lease)!=required:
                raise ValueError('invalid partition pending lease')
            scope=lease['scope'];ident=lease['db_identity']
            if (not isinstance(scope,dict) or set(scope)!={'battle_id','build','world_id','campaign_id'} or
                not isinstance(ident,dict) or set(ident)!={'path','instance_id','device','inode'} or
                not isinstance(lease['pending_token'],str) or not lease['pending_token'] or
                not isinstance(lease['request_id'],str) or not lease['request_id'] or
                type(lease['parent_version']) is not int or type(lease['new_version']) is not int or lease['new_version']!=lease['parent_version']+1):
                raise ValueError('invalid partition pending identity')
            from . import native_partition_store as parts
            for name in ('parent_manifest_sha256','parent_hot_sha256','parent_envelope_sha256','new_manifest_sha256','hot_sha256','new_envelope_sha256','frozen_identity'):
                if not isinstance(lease[name],str) or not parts.DIGEST.fullmatch(lease[name]):raise ValueError('invalid partition pending digest')
            self._partition_frozen_host('tome_partition_host.mjs',scope['build'])
            identity_hash=hashlib.sha256((self.public_root.parent/'identity.json').read_bytes()).hexdigest()
            if identity_hash!=lease['frozen_identity']:raise ValueError('partition frozen identity changed')
            actual=self.path.resolve();stat=actual.stat()
            if ident!={'path':str(actual),'instance_id':ident['instance_id'],'device':str(stat.st_dev) if stat.st_dev else None,'inode':str(stat.st_ino) if stat.st_ino else None}:
                raise ValueError('partition database file changed')
            with closing(sqlite3.connect(actual.as_uri()+'?mode=rw',uri=True,timeout=30)) as db:
                # This lock is separate from, and begins after, the actual
                # candidate COMMIT. It prevents a later writer racing the ACK.
                db.execute('BEGIN IMMEDIATE')
                instance=db.execute('SELECT instance_id FROM native_partition_runtime_identity WHERE singleton=1').fetchone()
                row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(scope['battle_id'],)).fetchone()
                receipt_row=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(lease['request_id'],)).fetchone()
                if not instance or instance[0]!=ident['instance_id'] or not row or not receipt_row:
                    raise ValueError('partition committed version or receipt unavailable')
                request,confirmed_receipt=map(json.loads,receipt_row)
                if (request.get('operation')!='loadout_reconcile' or request.get('battle_id')!=scope['battle_id'] or
                    request.get('version')!=lease['parent_version'] or request.get('world_id')!=scope['world_id'] or
                    confirmed_receipt.get('battle_id')!=scope['battle_id'] or confirmed_receipt.get('version')!=lease['new_version'] or confirmed_receipt.get('verified') is not True):
                    confirmed_receipt=None;raise ValueError('partition committed receipt mismatch')
                if row[0]!=lease['new_version']:raise ValueError('partition committed version advanced')
                archive,view,native=json.loads(row[2]),json.loads(row[3]),json.loads(row[4]) if row[4] else {}
                areas=native.get('local_areas') or {}
                if (not loadout_boundary({'state':row[1],'view':view,'native':native}) or areas.get('outside') is not True or
                    view.get('area_outside') is not True or view.get('map_available') is not False or view.get('input_request') is not None or
                    view.get('ai_status') not in ('idle','stopped') or (view.get('navigation') or {}).get('status')=='running' or
                    not _partition_no_active_capabilities(view.get('capabilities'))):
                    raise ValueError('partition committed camp boundary changed')
                if row[1]=='suspended':
                    handovers=db.execute("SELECT version FROM handovers WHERE battle_id=? AND state='pending'",(scope['battle_id'],)).fetchall()
                    if len(handovers)!=1 or handovers[0][0]!=lease['new_version']:raise ValueError('partition committed handover mismatch')
                current=db.execute('SELECT manifest FROM native_partition_versions WHERE battle_id=? AND version=?',(scope['battle_id'],lease['new_version'])).fetchone()
                parent=db.execute('SELECT manifest FROM native_partition_versions WHERE battle_id=? AND version=?',(scope['battle_id'],lease['parent_version'])).fetchone()
                parent_battle=db.execute('SELECT archive FROM native_partition_battle_history WHERE battle_id=? AND version=?',(scope['battle_id'],lease['parent_version'])).fetchone()
                if not current or not parent or not parent_battle:raise ValueError('partition committed history missing')
                old_archive=json.loads(parent_battle[0])
                if proof is None:
                    current_manifest=json.loads(current[0]);parent_manifest=json.loads(parent[0])
                    if (parts.validate_manifest(current_manifest)!=current[0] or parts.validate_manifest(parent_manifest)!=parent[0] or
                        current_manifest['hot_root']['blob_digest']!=lease['hot_sha256'] or parent_manifest['hot_root']['blob_digest']!=lease['parent_hot_sha256'] or
                        any(current_manifest.get(k)!=scope[k] or parent_manifest.get(k)!=scope[k] for k in ('build','world_id','campaign_id'))):
                        raise ValueError('partition committed manifest mismatch')
                else:
                    # Exact immutable bytes from the same transaction in which
                    # both v1 manifests underwent full validation; never key by
                    # mutable dict identity, mtime, or a claimed digest alone.
                    expected=(parent[0],current[0],lease['parent_hot_sha256'],lease['hot_sha256'],scope['build'],scope['world_id'],scope['campaign_id'])
                    if not isinstance(proof,tuple) or proof!=expected:raise ValueError('partition committed bytes changed')
                if (hashlib.sha256(current[0].encode('utf8')).hexdigest()!=lease['new_manifest_sha256'] or
                    hashlib.sha256(parent[0].encode('utf8')).hexdigest()!=lease['parent_manifest_sha256'] or
                    archive.get('base',{}).get('version')!=lease['new_version'] or archive['base'].get('manifest_sha256')!=lease['new_manifest_sha256'] or
                    hashlib.sha256(wire(archive['base'].get('envelope')).encode('utf8')).hexdigest()!=lease['new_envelope_sha256'] or
                    hashlib.sha256(wire(old_archive.get('base',{}).get('envelope')).encode('utf8')).hexdigest()!=lease['parent_envelope_sha256']):
                    raise ValueError('partition committed manifest or envelope mismatch')
                blob=db.execute('SELECT data FROM native_partition_blobs WHERE digest=?',(lease['hot_sha256'],)).fetchone()
                if not blob or hashlib.sha256(blob[0]).hexdigest()!=lease['hot_sha256']:raise ValueError('partition committed hot blob mismatch')
                # Hold the independent verification lock through ACK so a
                # second writer cannot advance the version between check and use.
                now=actual.stat()
                if (str(now.st_dev) if now.st_dev else None,str(now.st_ino) if now.st_ino else None)!=(ident['device'],ident['inode']):raise ValueError('partition database file replaced')
                response=validator.request({'kind':'confirm','lease':lease})
                if response.get('confirmed') is not True or response.get('version')!=lease['new_version'] or response.get('manifest_sha256')!=lease['new_manifest_sha256']:
                    raise ValueError('partition confirmation unavailable')
                db.rollback()
            return {'receipt':confirmed_receipt,'confirmed':True}
        except BaseException as exc:
            self._partition_abort_resident(validator,lease.get('pending_token') if isinstance(lease,dict) else None)
            if isinstance(exc,Exception) and confirmed_receipt is not None:return {'receipt':confirmed_receipt,'confirmed':False}
            raise

    def _partition_frozen_host(self,entry,expected_build):
        """Validate frozen host dependencies; never fall back to the workspace."""
        if entry not in ('tome_partition_host.mjs','tome_partition_migrate.mjs','tome_partition_resident.mjs'):
            raise ValueError('invalid partition host entry')
        package=self.public_root.parent
        required={
            'host/tome_partition_host.mjs','host/tome_partition_migrate.mjs','host/tome_partition_candidate.mjs',
            'host/tome_validate_operations.mjs','host/partition_session_host.mjs','host/partition_transport.mjs',
            'public/battle_session.mjs','public/engine_bridge.mjs','public/kernel_runtime.mjs',
            'public/encounter_overlay.mjs','public/partition_session.mjs','public/partition_transport.mjs'}
        try:
            identity=json.loads((package/'identity.json').read_text(encoding='utf8'))
            inputs=identity['inputs'];descriptors=inputs['host_scripts']
            computed=hashlib.sha256(json.dumps(inputs,sort_keys=True).encode('utf8')).hexdigest()[:16]
            if identity['build_id']!=computed or computed!=expected_build or not isinstance(descriptors,dict) or set(descriptors) not in (required,required|{'host/tome_partition_resident.mjs'},required|{'host/tome_partition_resident.mjs','host/partition_hot_codec.mjs'}) or (entry=='tome_partition_resident.mjs' and 'host/tome_partition_resident.mjs' not in descriptors):
                raise ValueError('partition frozen identity mismatch')
            for name,info in descriptors.items():
                path=(package/name).resolve()
                if not path.is_relative_to(package.resolve()) or not isinstance(info,dict) or set(info)!={'sha256','bytes'}:
                    raise ValueError('invalid partition frozen dependency')
                raw=path.read_bytes()
                if type(info['bytes']) is not int or len(raw)!=info['bytes'] or hashlib.sha256(raw).hexdigest()!=info['sha256']:
                    raise ValueError('partition frozen dependency mismatch: '+name)
            build=json.loads((package/'build.json').read_text(encoding='utf8'))
            outputs=build['outputs']
            for name in ('tome.js','tome.wasm','tome.data'):
                path=(self.public_root/name).resolve()
                if not path.is_relative_to(self.public_root):raise ValueError('invalid partition binary path')
                spec=outputs[name];st=path.stat();key=(str(path),st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns,st.st_ctime_ns,spec['sha256'])
                if st.st_size!=spec['bytes']:raise ValueError('partition binary size mismatch')
                if key not in self._partition_binary_cache:
                    h=hashlib.sha256()
                    with path.open('rb') as source:
                        for block in iter(lambda:source.read(1024*1024),b''):h.update(block)
                    if h.hexdigest()!=spec['sha256']:raise ValueError('partition binary digest mismatch')
                    self._partition_binary_cache={k:v for k,v in self._partition_binary_cache.items() if k[0]!=str(path)}
                    self._partition_binary_cache[key]=True
            return package/'host'/entry
        except (OSError,KeyError,TypeError,json.JSONDecodeError) as exc:
            raise ValueError('partition frozen dependencies unavailable') from exc

    def _migrate_partition_session(self,battle_id,version,request_id,trusted_scope,*,bootstrap_clock=None):
        """Host-only migration from a committed native-v1 archive; no client route."""
        from . import native_partition_store as parts
        if not self._partition_experimental:raise ValueError('partition sessions unavailable')
        if (type(version)is not int or not isinstance(request_id,str) or not 1<=len(request_id)<=100 or
            not isinstance(trusted_scope,dict) or set(trusted_scope)!={'build','world_id','campaign_id'} or
            any(not isinstance(v,str) or not v for v in trusted_scope.values())):raise ValueError('invalid migration scope')
        if bootstrap_clock is not None:
            from dm_mvp.local_area import elapsed_days
            elapsed_days(bootstrap_clock,bootstrap_clock)
            if bootstrap_clock['world_tick']>10000000000000:raise ValueError('invalid world clock')
        migration={'operation':'partition_migration','battle_id':battle_id,'version':version,'scope':trusted_scope}
        if bootstrap_clock is not None:migration['bootstrap_clock']=bootstrap_clock
        encoded=wire(migration)
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            prior=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if prior:
                if prior[0]!=encoded:raise ValueError('request ID conflict')
                return json.loads(prior[1])
            row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version:raise ValueError('stale migration battle')
            archive=json.loads(row[2]);view=json.loads(row[3]);native=json.loads(row[4]) if row[4] else {}
            if archive.get('format')!='tome-native-session-v1' or archive.get('build')!=trusted_scope['build'] or not loadout_boundary({'state':row[1],'view':view,'native':native}):
                raise ValueError('safe trusted native migration required')
            script=self._partition_frozen_host('tome_partition_migrate.mjs',trusted_scope['build'])
            response={};failure=None
            try:
                with tempfile.TemporaryDirectory(dir=self.path.parent) as work:
                    source=Path(work)/'in.json';output=Path(work)/'out.json'
                    payload={'archive':archive,'scope':trusted_scope,'version':version}
                    if bootstrap_clock is not None:payload['bootstrap_clock']=bootstrap_clock
                    source.write_text(wire(payload),encoding='utf8')
                    result=subprocess.run(['node',str(script),str(self.public_root),str(source),str(output)],cwd=ROOT,
                        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=180,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
                    response=json.loads(output.read_text(encoding='utf8')) if output.is_file() else {}
                    if result.returncode or not isinstance(response,dict) or response.get('ok') is not True:
                        failure='trusted partition migration rejected or exited without a valid result'
            except (OSError,subprocess.SubprocessError,ValueError) as exc:
                failure=type(exc).__name__+': '+str(exc)[:1000]
            if failure:
                evidence=self._partition_failure_evidence(battle_id,version,{'kind':'migration','baseline_sha256':hashlib.sha256(row[2].encode('utf8')).hexdigest()},None,[],response,failure,request_id)
                raise ValueError('trusted partition migration failed; evidence '+str(evidence))
            candidate=response['candidate'];manifest=candidate['manifest'];new_archive=candidate['archive']
            if (any(manifest.get(k)!=v for k,v in trusted_scope.items()) or new_archive.get('format')!='tome-partition-session-v1' or
                new_archive.get('build')!=trusted_scope['build'] or new_archive.get('seed')!=archive.get('seed') or
                new_archive.get('base',{}).get('version')!=version+1 or not isinstance(new_archive.get('base',{}).get('manifest_sha256'),str)):
                raise ValueError('partition migration candidate mismatch')
            new_version=self._partition_stage_tx(db,battle_id,version,request_id,candidate)
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',(new_version,wire(new_archive),wire(candidate['view']),wire(candidate['native']),battle_id))
            if row[1]=='suspended':
                pending=db.execute("SELECT id,version,receipt FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
                if len(pending)!=1 or pending[0][1]!=version:raise ValueError('pending handover mismatch')
                handover=json.loads(pending[0][2]);handover['receipt']['version']=new_version;handover['view']=candidate['view']
                db.execute('UPDATE handovers SET version=?,receipt=? WHERE id=?',(new_version,wire(handover),pending[0][0]))
            receipt={'verified':True,'battle_id':battle_id,'version':new_version,'partition_migration':True}
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(receipt)))
            return receipt

    def partition_checkpoint(self,battle_id, *, character=False, expected_version=None):
        """Return only the server-selected current strong closure for browser restore."""
        from . import native_partition_store as parts
        if not self._partition_experimental:raise ValueError('partition sessions unavailable')
        with self.lock,self.connect() as db:
            db.execute('BEGIN')
            row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row:raise ValueError('active partition battle required')
            version=row[0]
            if character:
                if expected_version != version or not loadout_boundary({'state':row[1],'view':json.loads(row[3]),'native':json.loads(row[4]) if row[4] else {}}):raise ValueError('character checkpoint boundary mismatch')
                if row[1]=='suspended':
                    handovers=db.execute("SELECT version FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
                    if len(handovers)!=1 or handovers[0][0]!=version:raise ValueError('pending handover mismatch')
            elif row[1]!='active':raise ValueError('active partition battle required')
            archive=json.loads(row[2])
            if archive.get('format')!='tome-partition-session-v1':raise ValueError('partition session required')
            manifest,_=parts.read(db,battle_id=battle_id,version=version,partition_ids=[])
            if archive.get('base',{}).get('version')!=version or archive['base'].get('manifest_sha256')!=hashlib.sha256(wire(manifest).encode('utf8')).hexdigest():
                raise ValueError('partition archive binding mismatch')
            entries={'hot':manifest['hot_root'],**{p['partition_id']:p for p in manifest['partitions']}}
            ids={'hot'};todo=['hot']
            while todo:
                for ref in entries[todo.pop()]['strong_refs']:
                    owner=manifest['objects'][ref]['owner']
                    if owner not in ids:ids.add(owner);todo.append(owner)
            blobs=parts._read_selected(db,manifest,sorted(ids))
            return {'version':version,'manifest':manifest,'blobs':blobs}

    def _partition_failure_evidence(self,battle_id,version,selection,manifest,ids,response,reason,request_id=None):
        """Save bounded failure diagnostics, without storing a checkpoint or blob."""
        folder=ROOT/'artifacts'/'evidence'/'native-partition-failures'/uuid.uuid4().hex
        folder.mkdir(parents=True,exist_ok=False)
        entries=({'hot':manifest['hot_root'],**{p['partition_id']:p for p in manifest['partitions']}} if manifest else {})
        logs=response.get('logs',[]) if isinstance(response,dict) else []
        if not isinstance(logs,list):logs=[]
        evidence={'battle_id':battle_id,'version':version,'request_id':request_id,'selection':selection,
                  'manifest_sha256':hashlib.sha256(wire(manifest).encode('utf8')).hexdigest() if manifest else None,
                  'dependencies':[{'partition_id':pid,'sha256':entries[pid]['blob_digest']} for pid in ids],
                  'reason':str(reason)[:2000],
                  'error':str(response.get('error',''))[:4000] if isinstance(response,dict) else '',
                  'logs':[str(line)[:800] for line in logs[-30:]]}
        path=folder/'failure.json';path.write_text(wire(evidence),encoding='utf8')
        return path

    def _partition_try_hot_tx(self,db,battle_id,version,archive,operations,selection,delta_events,expected_world,expected_final,request_id,resident,pending_ref,row):
        """Use a confirmed private byte cache only for an exact live VM generation."""
        from . import native_partition_hot as hot
        cache=getattr(resident,'partition_cache',None);process=getattr(resident,'process',None)
        if (not isinstance(cache,hot.HotBaseline) or process is None or process.poll() is not None or
            getattr(resident,'partition_cache_pid',None)!=process.pid or time.monotonic()-resident.last_used>resident.idle_seconds):
            if cache is not None:resident.discard()
            return None
        if cache.canonical!=row[1].encode('utf8'):
            resident.discard();return None
        if selection!={'kind':'loadout'} or delta_events or len(operations)!=2 or operations[0].get('operation')!='campaign_items' or operations[0].get('request',{}).get('operation') not in ('equip','unequip','switch_set','progression','prepare_sustain','transmogrify') or operations[1].get('operation')!='campaign_reconcile':
            resident.discard();return None
        fields=dict(cache.fields);scope={k:json.loads(fields[k]) for k in ('build','world_id','campaign_id')};base=archive.get('base') or {};old_hot=json.loads(cache.hot_descriptor)['blob_digest']
        if (expected_world is not None and expected_world!=scope['world_id'] or archive.get('format')!='tome-partition-session-v1' or archive.get('build')!=scope['build'] or
            base.get('version')!=version or base.get('manifest_sha256')!=hashlib.sha256(cache.canonical).hexdigest() or
            (base.get('envelope') or {}).get('native_boundary')!='campaign_admin'):
            resident.discard();return None
        current=db.execute('SELECT state,view,native FROM battles WHERE id=? AND version=?',(battle_id,version)).fetchone()
        view=json.loads(current[1]) if current else {};native=json.loads(current[2]) if current and current[2] else {}
        if (not current or not loadout_boundary({'state':current[0],'view':view,'native':native}) or (native.get('local_areas') or {}).get('outside') is not True or
            view.get('area_outside') is not True or view.get('map_available') is not False or view.get('input_request') is not None or
            view.get('ai_status') not in ('idle','stopped') or (view.get('navigation') or {}).get('status')=='running' or not _partition_no_active_capabilities(view.get('capabilities'))):
            resident.discard();return None
        self._partition_frozen_host('tome_partition_resident.mjs',scope['build'])
        identity=json.loads((self.public_root.parent/'identity.json').read_text(encoding='utf8'))
        if 'host/partition_hot_codec.mjs' not in identity['inputs']['host_scripts']:return None
        db_identity=self._partition_db_identity_tx(db);frozen=hashlib.sha256((self.public_root.parent/'identity.json').read_bytes()).hexdigest();env_sha=hashlib.sha256(wire(base['envelope']).encode('utf8')).hexdigest()
        binding=(wire(db_identity),battle_id,wire(scope),version,base['manifest_sha256'],old_hot,env_sha,frozen)
        if resident.partition_binding!=binding:resident.discard();return None
        blob=db.execute('SELECT data FROM native_partition_blobs WHERE digest=?',(old_hot,)).fetchone()
        if not blob or hashlib.sha256(blob[0]).hexdigest()!=old_hot:raise ValueError('missing or corrupt hot partition')
        request={'kind':'prepare_hot','binding':{'scope':{'battle_id':battle_id,**scope},'db_identity':db_identity,'frozen_identity':frozen,'version':version,'manifest_sha256':base['manifest_sha256'],'hot_sha256':old_hot,'envelope_sha256':env_sha},'archive':archive,'operations':operations,'request_id':request_id}
        if expected_final is not None:request['expected_final']=expected_final
        response=resident.request(request)
        if isinstance(response,dict) and response.get('ok') is True:pending_ref[0]=response.get('lease')
        if not isinstance(response,dict) or response.get('ok') is not True or response.get('warm_hit') is not True:
            raise ValueError('trusted hot resident candidate failed')
        candidate=response.get('candidate') or {};new_archive=candidate.get('archive') or {};lease=response.get('lease')
        if (new_archive.get('format')!='tome-partition-session-v1' or new_archive.get('build')!=scope['build'] or
            new_archive.get('base',{}).get('version')!=version+1):raise ValueError('invalid hot candidate archive')
        prepared=hot.rebuild(cache,candidate.get('objects_delta'),candidate.get('descriptor'),candidate.get('blob'),candidate.get('next_ref'),candidate.get('next_uid'),new_archive.get('base',{}).get('manifest_sha256'))
        expected={'scope':{'battle_id':battle_id,**scope},'parent_version':version,'parent_manifest_sha256':base['manifest_sha256'],'parent_hot_sha256':old_hot,'parent_envelope_sha256':env_sha,'new_version':version+1,'new_manifest_sha256':prepared.digest,'hot_sha256':prepared.blob_digest,'new_envelope_sha256':hashlib.sha256(wire(new_archive['base']['envelope']).encode('utf8')).hexdigest(),'frozen_identity':frozen,'db_identity':db_identity,'request_id':request_id}
        if not isinstance(lease,dict) or any(lease.get(k)!=v for k,v in expected.items()) or not isinstance(lease.get('pending_token'),str) or not lease['pending_token']:
            raise ValueError('hot resident lease mismatch')
        return {'candidate':{'archive':new_archive,'view':candidate.get('view'),'native':candidate.get('native'),'_hot_parent':cache,'_hot_prepared':prepared},'results':response.get('results',[]),'lease':lease,'_trusted_parent':(row[1],old_hot,scope['build'],scope['world_id'],scope['campaign_id'])}

    def _partition_validate_tx(self, db, battle_id, version, archive, operations, selection, *, delta_events=None, expected_world=None, expected_final=None, request_id=None, resident=None, pending_ref=None):
        # Browser checkpoint validation may include untrusted delta and final state.
        return self._partition_execute_tx(db,battle_id,version,archive,operations,selection,delta_events=delta_events,expected_world=expected_world,expected_final=expected_final,request_id=request_id,resident=resident,pending_ref=pending_ref)

    def _partition_loadout_tx(self,db,battle_id,version,archive,world_id,request,world_location,observation_id,request_id,resident,pending_ref):
        # Server-created operations only: no client archive, delta or expected final.
        operations=[{'operation':'campaign_items','world_id':world_id,'request':request},
                    {'operation':'campaign_reconcile','world_id':world_id,'world_location':world_location,'observation_id':observation_id}]
        return self._partition_execute_tx(db,battle_id,version,archive,operations,{'kind':'loadout'},expected_world=world_id,request_id=request_id,resident=resident,pending_ref=pending_ref)

    def _partition_execute_tx(self, db, battle_id, version, archive, operations, selection, *, delta_events=None, expected_world=None, expected_final=None, request_id=None, resident=None, pending_ref=None):
        """Restore an authorized version in a disposable server VM inside the write lock."""
        from . import native_partition_store as parts
        if not self._partition_experimental: raise ValueError('partition sessions unavailable')
        if not db.in_transaction:raise ValueError('partition validation transaction required')
        row=db.execute('SELECT version,manifest FROM native_partition_versions WHERE battle_id=? ORDER BY version DESC LIMIT 1',(battle_id,)).fetchone()
        if not row or row[0]!=version: raise ValueError('partition manifest unavailable or stale')
        if resident is not None:
            compact=self._partition_try_hot_tx(db,battle_id,version,archive,operations,selection,delta_events,expected_world,expected_final,request_id,resident,pending_ref,row)
            if compact is not None:return compact
        manifest=json.loads(row[1]);canonical=parts.validate_manifest(manifest)
        scope={k:manifest[k] for k in ('build','world_id','campaign_id')}
        if expected_world is not None and expected_world!=scope['world_id']: raise ValueError('partition world mismatch')
        base=archive.get('base') or {}
        if (archive.get('format')!='tome-partition-session-v1' or archive.get('build')!=scope['build'] or
            base.get('version')!=version or base.get('manifest_sha256')!=hashlib.sha256(canonical.encode('utf8')).hexdigest()):
            raise ValueError('partition archive binding mismatch')
        entries={'hot':manifest['hot_root'],**{p['partition_id']:p for p in manifest['partitions']}}
        selected={'hot'}
        if selection.get('kind')=='area':
            area=selection.get('area_id');floor=selection.get('floor')
            zones=[p for p in manifest['partitions'] if p['area_id']==area and p['kind']=='zone']
            levels=[p for p in manifest['partitions'] if p['area_id']==area and p['kind']=='level' and p['floor']==floor]
            if len(zones)>1 or len(levels)>1 or levels and not zones:raise ValueError('invalid target area partition')
            native_row=db.execute('SELECT native FROM battles WHERE id=? AND version=?',(battle_id,version)).fetchone()
            native=json.loads(native_row[0]) if native_row and native_row[0] else {}
            known=((native.get('local_areas') or {}).get('areas') or {}).get(area)
            if (known is not None) != bool(zones):raise ValueError('area directory and partition mismatch')
            if known is not None:
                floors=known.get('floors') or {};visited=(floors.get(str(floor)) or {}).get('visited') is True
                if visited!=bool(levels):raise ValueError('floor directory and partition mismatch')
            selected.update(p['partition_id'] for p in zones+levels)
        elif selection!={'kind':'loadout'}:raise ValueError('invalid partition selection')
        sources=selection.get('sources',[])
        if not isinstance(sources,list)or len(sources)>5:raise ValueError('invalid native person sources')
        for source in sources:
            if (not isinstance(source,dict)or set(source)!={'area_id','floor'}or not isinstance(source['area_id'],str)
                    or type(source['floor'])is not int or not 1<=source['floor']<=20):raise ValueError('invalid native person source')
            zone=[p for p in manifest['partitions']if p['kind']=='zone'and p['area_id']==source['area_id']]
            level=[p for p in manifest['partitions']if p['kind']=='level'and p['area_id']==source['area_id']and p['floor']==source['floor']]
            if len(zone)!=1 or len(level)!=1:raise ValueError('native person source is not committed')
            selected.update(p['partition_id']for p in zone+level)
        todo=list(selected)
        while todo:
            for ref in entries[todo.pop()]['strong_refs']:
                owner=manifest['objects'][ref]['owner']
                if owner not in selected:selected.add(owner);todo.append(owner)
        ids=sorted(selected)
        blobs=parts._read_selected(db,manifest,ids)
        script=self._partition_frozen_host('tome_partition_host.mjs',scope['build'])
        payload={'scope':scope,'version':version,'archive':archive,'manifest':manifest,'blobs':blobs,
                 'selection':selection,'operations':operations,'delta_events':delta_events or []}
        if expected_final is not None:payload['expected_final']=expected_final
        response={};failure=None;warm=False;db_identity=None
        if resident is not None:
            current=db.execute('SELECT state,view,native FROM battles WHERE id=? AND version=?',(battle_id,version)).fetchone()
            v=json.loads(current[1]) if current else {};n=json.loads(current[2]) if current and current[2] else {}
            warm=(ids==['hot'] and not delta_events and selection=={'kind':'loadout'} and len(operations)==2 and
                  operations[0].get('operation')=='campaign_items' and operations[0].get('request',{}).get('operation') in ('equip','unequip','switch_set','progression','prepare_sustain','transmogrify') and
                  operations[1].get('operation')=='campaign_reconcile' and archive.get('base',{}).get('envelope',{}).get('native_boundary')=='campaign_admin' and
                  current is not None and loadout_boundary({'state':current[0],'view':v,'native':n}) and
                  (n.get('local_areas') or {}).get('outside') is True and v.get('area_outside') is True and v.get('map_available') is False and
                  v.get('input_request') is None and v.get('ai_status') in ('idle','stopped') and (v.get('navigation') or {}).get('status')!='running' and
                  _partition_no_active_capabilities(v.get('capabilities')))
            if warm:
                self._partition_frozen_host('tome_partition_resident.mjs',scope['build'])
                db_identity=self._partition_db_identity_tx(db)
                frozen=hashlib.sha256((self.public_root.parent/'identity.json').read_bytes()).hexdigest()
                binding=(wire(db_identity),battle_id,wire(scope),version,base['manifest_sha256'],manifest['hot_root']['blob_digest'],hashlib.sha256(wire(base['envelope']).encode('utf8')).hexdigest(),frozen)
                if resident.partition_binding is not None and resident.partition_binding!=binding:resident.discard()
                payload.update({'kind':'prepare','battle_id':battle_id,'request_id':request_id,'db_identity':db_identity})
            else:resident.discard()
        try:
            if warm:
                response=resident.request(payload)
                if isinstance(response,dict) and response.get('ok') is True and pending_ref is not None:pending_ref[0]=response.get('lease')
                if not isinstance(response,dict) or response.get('ok') is not True:failure='trusted resident partition VM rejected'
            else:
                with tempfile.TemporaryDirectory(dir=self.path.parent) as work:
                    source=Path(work)/'in.json';output=Path(work)/'out.json'
                    source.write_text(wire(payload),encoding='utf8')
                    result=subprocess.run(['node',str(script),str(self.public_root),str(source),str(output)],cwd=ROOT,
                        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=180,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
                    response=json.loads(output.read_text(encoding='utf8')) if output.is_file() else {}
                    if result.returncode or not isinstance(response,dict) or response.get('ok') is not True:
                        failure='trusted partition VM rejected or exited without a valid result'
        except Exception as exc:
            failure=type(exc).__name__+': '+str(exc)[:1000]
        if failure:
            evidence=self._partition_failure_evidence(battle_id,version,selection,manifest,ids,response,failure,request_id)
            raise ValueError('trusted partition VM failed; evidence '+str(evidence))
        if operations and all(op.get('operation')=='scene_query' for op in operations):
            results=response.get('query_results')
            if not isinstance(results,list)or len(results)!=len(operations)or response.get('candidate')is not None:raise ValueError('invalid read-only partition query response')
            return {'results':results}
        candidate=response.get('candidate') or {};new_manifest=candidate.get('manifest') or {};new_archive=candidate.get('archive') or {}
        if (any(new_manifest.get(k)!=v for k,v in scope.items()) or new_archive.get('format')!='tome-partition-session-v1' or
            new_archive.get('build')!=scope['build'] or new_archive.get('base',{}).get('version')!=version+1 or
            not isinstance(new_archive.get('base',{}).get('manifest_sha256'),str)):
            evidence=self._partition_failure_evidence(battle_id,version,selection,manifest,ids,response,'candidate binding mismatch',request_id)
            raise ValueError('partition candidate binding mismatch; evidence '+str(evidence))
        if warm:
            lease=response.get('lease');expected_scope={'battle_id':battle_id,**scope}
            expected={'scope':expected_scope,'parent_version':version,'parent_manifest_sha256':base['manifest_sha256'],
                      'parent_hot_sha256':manifest['hot_root']['blob_digest'],
                      'parent_envelope_sha256':hashlib.sha256(wire(base['envelope']).encode('utf8')).hexdigest(),
                      'new_version':version+1,'new_manifest_sha256':new_archive['base']['manifest_sha256'],
                      'hot_sha256':new_manifest['hot_root']['blob_digest'],
                      'new_envelope_sha256':hashlib.sha256(wire(new_archive['base']['envelope']).encode('utf8')).hexdigest(),
                      'frozen_identity':frozen,'db_identity':db_identity,'request_id':request_id}
            mismatches=([k for k,v in expected.items() if lease.get(k)!=v] if isinstance(lease,dict) else ['missing'])
            if mismatches or not isinstance(lease.get('pending_token'),str) or not lease['pending_token']:
                evidence=self._partition_failure_evidence(battle_id,version,selection,manifest,ids,response,'resident lease mismatch: '+','.join(mismatches),request_id)
                raise ValueError('partition resident lease mismatch; evidence '+str(evidence))
        if warm:response['_trusted_parent']=(canonical,manifest['hot_root']['blob_digest'],scope['build'],scope['world_id'],scope['campaign_id'])
        return response

    def _partition_or_legacy_tx(self,db,battle_id,version,archive,operations,*,expected_world=None,expected_campaign=None,selection=None,request_id=None):
        if archive.get('format')!='tome-partition-session-v1':return self._legacy_validate(archive,operations),False
        checked=self._partition_validate_tx(db,battle_id,version,archive,operations,selection or {'kind':'loadout'},expected_world=expected_world,request_id=request_id)
        candidate=checked['candidate']
        if expected_campaign is not None and candidate['manifest'].get('campaign_id')!=expected_campaign:raise ValueError('partition campaign mismatch')
        return {**candidate,'results':checked.get('results',[]),'ok':True},True

    def _partition_stage_tx(self,db,battle_id,version,request_id,candidate):
        """Stage validated VM output alongside the caller's battle update."""
        from . import native_partition_store as parts
        row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
        if not row or row[0]!=version:raise ValueError('stale partition battle')
        previous_native=json.loads(row[4])if row[4]else{}
        if (isinstance(candidate.get('native'),dict) and 'combat_facts'not in candidate['native']
                and previous_native.get('combat_facts') and candidate.get('view',{}).get('generation')==json.loads(row[3]).get('generation')):
            candidate['native']['combat_facts']=previous_native['combat_facts']
        parts.initialize(db)
        db.execute('CREATE TABLE IF NOT EXISTS native_partition_battle_history (battle_id TEXT NOT NULL, version INTEGER NOT NULL, state TEXT NOT NULL, archive TEXT NOT NULL, view TEXT NOT NULL, native TEXT, PRIMARY KEY(battle_id,version))')
        db.execute('CREATE TABLE IF NOT EXISTS native_partition_handover_history (battle_id TEXT NOT NULL, version INTEGER NOT NULL, handover_id TEXT NOT NULL, receipt TEXT NOT NULL, PRIMARY KEY(battle_id,version))')
        expected_sha=candidate.get('archive',{}).get('base',{}).get('manifest_sha256')
        if not isinstance(expected_sha,str) or not parts.DIGEST.fullmatch(expected_sha):
            raise ValueError('partition candidate manifest digest required')
        if '_hot_prepared' in candidate:
            from . import native_partition_hot as hot
            prepared=candidate['_hot_prepared']
            if prepared.digest!=expected_sha:raise ValueError('hot candidate digest mismatch')
            next_version=hot.commit_hot(db,battle_id=battle_id,expected_version=version,request_id=request_id,parent=candidate['_hot_parent'],prepared=prepared)
        else:
            next_version=parts.commit(db,battle_id=battle_id,expected_version=version,request_id=request_id,manifest=candidate['manifest'],blobs=candidate['blobs'],expected_manifest_sha256=expected_sha)
        db.execute('INSERT INTO native_partition_battle_history VALUES (?,?,?,?,?,?)',(battle_id,*row))
        if row[1]=='suspended':
            handovers=db.execute("SELECT id,version,receipt FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
            if len(handovers)!=1 or handovers[0][1]!=version:raise ValueError('pending handover mismatch')
            db.execute('INSERT INTO native_partition_handover_history VALUES (?,?,?,?)',(battle_id,version,handovers[0][0],handovers[0][2]))
        return next_version

    def apply_area(self,battle_id,version,request_id,operation,area,*,loot=None):
        """Host-only area transition. Commit a verified candidate or keep disk intact."""
        if (not self.native_checkpoints or operation not in ('area_enter','area_depart')
                or type(version)is not int or not isinstance(request_id,str) or not 1<=len(request_id)<=100
                or not isinstance(area,dict)):
            raise ValueError('native area operation unavailable or invalid')
        from dm_mvp.local_area import elapsed_days
        clock=area.get('world_clock')
        elapsed_days(clock,clock)
        if operation=='area_enter':
            if (set(area)-{'area_id','floor','floor_count','world_clock','config','reference_level','loot_reference_level','tile_id'}
                    or ('loot_reference_level' in area and
                        (type(area['loot_reference_level']) is not int or not 1<=area['loot_reference_level']<=150))
                    or not isinstance(area.get('area_id'),str) or not area['area_id'].startswith('area:')
                    or type(area.get('floor'))is not int or type(area.get('floor_count'))is not int
                    or not 1<=area['floor']<=area['floor_count']<=20):
                raise ValueError('invalid native area binding')
        elif set(area)!={'world_clock'}:
            raise ValueError('invalid area departure')
        operations=[{'operation':operation,'operation_id':request_id,'area':area}]
        expected_world=None
        encoded_request={'battle_id':battle_id,'version':version,'operation':operation,'area':area}
        if loot is not None:
            if (operation!='area_depart' or not isinstance(loot,dict)
                    or set(loot)!={'world_id','location','choices'}
                    or not all(isinstance(loot[k],str) and loot[k] for k in ('world_id','location'))
                    or not isinstance(loot['choices'],list)):
                raise ValueError('invalid departure loot settlement')
            validate_loot_choices(loot['choices'])
            expected_world=loot['world_id']
            operations.insert(0,{'operation':'campaign_items','world_id':expected_world,
                'request':{'operation':'loot_settle','action_id':request_id,'location':loot['location'],
                           'choices':loot['choices']}})
            encoded_request['loot']=loot
        encoded=wire(encoded_request)
        with self.lock,self.connect()as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=encoded:raise ValueError('request ID conflict')
                return json.loads(old[1])
            row=db.execute('SELECT version,state,archive,view FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version or row[1]not in('active','suspended'):raise ValueError('active native checkpoint required')
            if row[1]=='suspended':
                handovers=db.execute("SELECT id,version FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
                if len(handovers)!=1 or handovers[0][1]!=version:raise ValueError('verified handover required for area transition')
            if loot is not None and row[1]!='suspended':
                raise ValueError('confirmed player handover required for loot')
            view=json.loads(row[3])
            if view.get('status')=='defeat' and not (operation=='area_enter' and view.get('campaign_withdrawn') is True):
                raise ValueError('defeat settlement required')
            saved_archive=json.loads(row[2]);partitioned=saved_archive.get('format')=='tome-partition-session-v1'
            if partitioned:
                selection=({'kind':'area','area_id':area['area_id'],'floor':area['floor']} if operation=='area_enter' else {'kind':'loadout'})
                checked=self._partition_validate_tx(db,battle_id,version,saved_archive,operations,selection,
                                                    **({'expected_world':expected_world} if expected_world else {}),
                                                    request_id=request_id)
                verified={**checked['candidate'],'results':checked.get('results',[]),'ok':True}
            else: verified=self._legacy_validate(saved_archive,operations)
            results=verified.get('results',[])
            if (not verified.get('ok') or len(results)!=len(operations)
                    or any(r.get('accepted') is not True or not isinstance(r.get('transition'),dict) for r in results)
                    or verified.get('archive',{}).get('format')!=('tome-partition-session-v1' if partitioned else 'tome-native-session-v1')
                    or operation=='area_depart' and verified.get('view',{}).get('turn')!=view.get('turn')
                    or verified.get('view',{}).get('turn',-1)<view.get('turn',0)):
                raise ValueError('native area candidate not confirmed')
            if loot is not None:
                settlement=results[0]['transition']
                if (settlement.get('operation')!='loot_settle' or settlement.get('action_id')!=request_id
                        or settlement.get('location')!=loot['location'] or results[-1]['transition'].get('departed') is not True):
                    raise ValueError('loot departure receipt mismatch')
            if partitioned:self._partition_stage_tx(db,battle_id,version,request_id,verified)
            receipt={'verified':True,'battle_id':battle_id,'version':version+1,
                     'archive_id':battle_id+':'+str(version+1),'receipt':results[-1]['transition']}
            if loot is not None:receipt['loot']=settlement
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',
                       (version+1,wire(verified['archive']),wire(verified['view']),wire(verified['native']),battle_id))
            if row[1]=='suspended' and operation=='area_enter':
                db.execute("UPDATE battles SET state='active' WHERE id=?",(battle_id,))
                db.execute("UPDATE handovers SET state='resolved' WHERE id=?",(handovers[0][0],))
            elif row[1]=='suspended':
                for hid,raw in db.execute("SELECT id,receipt FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall():
                    body=json.loads(raw);body['receipt']['version']=version+1;body['view']=verified['view']
                    db.execute('UPDATE handovers SET version=?,receipt=? WHERE id=?',(version+1,wire(body),hid))
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(receipt)))
            return receipt

    def apply_inventory(self,battle_id,version,request_id,world_id,request):
        if type(version) is not int or not isinstance(request_id,str) or not 1<=len(request_id)<=100 or not isinstance(world_id,str) or not isinstance(request,dict):raise ValueError('invalid inventory request')
        encoded=wire({'battle_id':battle_id,'version':version,'world_id':world_id,'request':request})
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=encoded:raise ValueError('request ID conflict')
                return json.loads(old[1])
            row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
            view=json.loads(row[3]) if row else {}
            native_before=json.loads(row[4]) if row and row[4] else {}
            partitioned_before=bool(row and json.loads(row[2]).get('format')=='tome-partition-session-v1')
            allowed_old=bool(row and row[1]=='active' and (view.get('status') in ('victory','defeat') or view.get('campaign_bootstrap') is True))
            allowed_partition=bool(partitioned_before and loadout_boundary({'state':row[1],'view':view,'native':native_before}))
            if not row or row[0]!=version or not (allowed_old or allowed_partition):
                raise ValueError('saved terminal or departed partition state required')
            if db.execute('SELECT 1 FROM defeat_snapshots WHERE battle_id=? AND version=?',(battle_id,version)).fetchone():raise ValueError('defeat settlement frozen')
            selection=None
            if partitioned_before and request.get('operation')=='add' and request.get('source_location') is not None:
                ground=(native_before.get('ground_items') or {}).get(request.get('item_id'))
                if (not isinstance(ground,dict) or ground.get('location')!=request['source_location'] or
                    type(ground.get('uid')) is not int or ground['uid']<1):
                    raise ValueError('trusted ground item location unavailable')
                if ground.get('location_only') is True:
                    # The native inspector attests the original object and its
                    # world-location holder. Missing floor data alone is not proof.
                    if any(ground.get(k) is not None for k in ('area_id','floor','ref','x','y')):
                        raise ValueError('invalid location-only ground identity')
                    selection={'kind':'loadout'}
                elif ground.get('location_only') is False:
                    if (not isinstance(ground.get('area_id'),str) or not ground['area_id'] or
                        type(ground.get('floor')) is not int or ground['floor']<1 or
                        type(ground.get('x')) is not int or type(ground.get('y')) is not int):
                        raise ValueError('invalid mapped ground identity')
                    if ground.get('ref') is not None and ground['ref']!='e:'+str(ground['uid']):
                        raise ValueError('ground reference identity mismatch')
                    selection={'kind':'area','area_id':ground['area_id'],'floor':ground['floor']}
                else:
                    raise ValueError('ground location kind unavailable')
            elif partitioned_before and request.get('operation')=='add' and request.get('item_spec') is not None:
                areas=native_before.get('local_areas') or {}
                if areas.get('outside') is True:
                    area=areas.get('current_area');floor=areas.get('current_floor')
                    if not isinstance(area,str) or not area or type(floor) is not int or floor<1:
                        raise ValueError('trusted item factory context unavailable')
                    selection={'kind':'area','area_id':area,'floor':floor}
            verified,partitioned=self._partition_or_legacy_tx(db,battle_id,version,json.loads(row[2]),[{'operation':'campaign_items','world_id':world_id,'request':request}],expected_world=world_id,selection=selection,request_id=request_id)
            if len(verified.get('results',[]))!=1:raise ValueError('native inventory receipt unavailable')
            new_version=self._partition_stage_tx(db,battle_id,version,request_id,verified) if partitioned else version+1
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',(new_version,wire(verified['archive']),wire(verified['view']),wire(verified['native']) if verified.get('native') else None,battle_id))
            if partitioned and row[1]=='suspended':
                pending=db.execute("SELECT id,version,receipt FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
                if len(pending)!=1 or pending[0][1]!=version:raise ValueError('pending handover mismatch')
                handover=json.loads(pending[0][2]);handover['receipt']['version']=new_version;handover['view']=verified['view']
                db.execute('UPDATE handovers SET version=?,receipt=? WHERE id=?',(new_version,wire(handover),pending[0][0]))
            native=verified['results'][0]
            if native.get('accepted') is not True or not isinstance(native.get('transition'),dict):raise ValueError('invalid native inventory receipt')
            receipt={'verified':True,'battle_id':battle_id,'version':new_version,'archive_id':battle_id+':'+str(new_version),'receipt':native['transition']}
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(receipt)))
            return receipt

    def apply_loadout(self,battle_id,version,request_id,world_id,request,world_location,observation_id):
        return self._execute_loadout(battle_id,version,request_id,world_id,request,world_location,observation_id,server_only=False)

    def execute_loadout(self,battle_id,version,request_id,world_id,request,world_location,observation_id):
        """Execute server-owned equipment and custody operations without client battle input."""
        return self._execute_loadout(battle_id,version,request_id,world_id,request,world_location,observation_id,server_only=True)

    def _execute_loadout(self,battle_id,version,request_id,world_id,request,world_location,observation_id,*,server_only):
        args=(battle_id,version,request_id,world_id,request,world_location,observation_id)
        if not self._partition_resident:return self._apply_loadout_impl(*args,server_only=server_only)
        if not self._partition_experimental:raise ValueError('partition sessions unavailable')
        doc=self.get(battle_id);archive=doc['archive']
        if archive.get('format')!='tome-partition-session-v1':return self._apply_loadout_impl(*args,server_only=server_only)
        script=self._partition_frozen_host('tome_partition_resident.mjs',archive.get('build'))
        from .resident_validator import partition_validator_lease,ResidentCapacityError
        try:
            with partition_validator_lease(self.path,self.public_root,script) as resident:
                pending=[None];proof=[None,None]
                try:
                    # _apply_loadout_impl returns only after its transaction context
                    # has completed the real SQLite COMMIT.
                    receipt=self._apply_loadout_impl(*args,resident=resident,pending_ref=pending,proof_ref=proof,server_only=server_only)
                    if pending[0] is not None:
                        outcome=self._partition_confirm_committed(pending[0],resident,proof[0])
                        if outcome['receipt']!=receipt:raise ValueError('partition committed receipt changed')
                        if outcome['confirmed']:
                            l=pending[0];resident.partition_binding=(wire(l['db_identity']),battle_id,wire({k:l['scope'][k] for k in ('build','world_id','campaign_id')}),l['new_version'],l['new_manifest_sha256'],l['hot_sha256'],l['new_envelope_sha256'],l['frozen_identity'])
                            identity=json.loads((self.public_root.parent/'identity.json').read_text(encoding='utf8'))
                            if 'host/partition_hot_codec.mjs' in identity['inputs']['host_scripts']:
                                from . import native_partition_hot as hot
                                try:
                                    resident.partition_cache=proof[1] or hot.baseline(proof[0][1].encode('utf8'))
                                    resident.partition_cache_pid=resident.process.pid if resident.process is not None else None
                                except Exception:
                                    # The action is already committed. A cache build
                                    # failure must not replay it or claim reuse.
                                    resident.discard()
                    return receipt
                except BaseException:
                    self._partition_abort_resident(resident,pending[0].get('pending_token') if isinstance(pending[0],dict) else None)
                    raise
        except ResidentCapacityError:
            # No VM was borrowed or modified. The ordinary disposable path is safe.
            return self._apply_loadout_impl(*args,server_only=server_only)

    def apply_company(self,battle_id,version,request_id,world_id,request,world_location,observation_id):
        return self._apply_loadout_impl(battle_id,version,request_id,world_id,request,world_location,observation_id,company=True)

    def _apply_loadout_impl(self,battle_id,version,request_id,world_id,request,world_location,observation_id,*,resident=None,pending_ref=None,proof_ref=None,server_only=False,company=False):
        """One native replay and atomic commit for equipment plus custody check."""
        allowed = ('company_join','company_squad_add','company_squad_remove','company_release') if company else ('equip','unequip','switch_set','progression','prepare_sustain','transmogrify','prepare_craft')
        if (type(version)is not int or not all(isinstance(x,str)and 1<=len(x)<=100 for x in (request_id,world_id,world_location,observation_id))
                or not isinstance(request,dict)or request.get('operation')not in allowed):
            raise ValueError('invalid loadout request')
        encoded=wire({'operation':'loadout_reconcile','battle_id':battle_id,'version':version,'world_id':world_id,
                      'request':request,'world_location':world_location,'observation_id':observation_id})
        with self.lock,self.connect()as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=encoded:raise ValueError('request ID conflict')
                return json.loads(old[1])
            row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
            view=json.loads(row[3])if row else{}
            native=json.loads(row[4])if row and row[4]else{}
            if not row or row[0]!=version or not loadout_boundary({'state':row[1],'view':view,'native':native}):
                raise ValueError('safe active campaign state required')
            pending=[]
            if row[1]=='suspended':
                pending=db.execute("SELECT id,version,receipt FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
                if len(pending)!=1 or pending[0][1]!=version:raise ValueError('pending handover mismatch')
            if db.execute('SELECT 1 FROM defeat_snapshots WHERE battle_id=? AND version=?',(battle_id,version)).fetchone():raise ValueError('defeat settlement frozen')
            operations=[{'operation':'campaign_items','world_id':world_id,'request':request},
                        {'operation':'campaign_reconcile','world_id':world_id,'world_location':world_location,'observation_id':observation_id}]
            saved_archive=json.loads(row[2]);partitioned=saved_archive.get('format')=='tome-partition-session-v1'
            if company or request['operation']=='prepare_craft':
                areas=native.get('local_areas') or {}
                current=areas.get('current_area')
                if not partitioned or areas.get('outside') is not True or current not in areas.get('areas',{}):
                    raise ValueError('a committed outside battlefield is required')
                selection={'kind':'loadout'}
                if request['operation'] in ('company_join','prepare_craft'):
                    selection={'kind':'area','area_id':current,'floor':areas['current_floor']}
                    person=(native.get('world_people') or {}).get(request['actor_id']) or {}
                    if person.get('area_id'):
                        selection['sources']=[{'area_id':person['area_id'],'floor':person['floor']}]
                checked=self._partition_validate_tx(db,battle_id,version,saved_archive,operations,selection,
                                                    expected_world=world_id,request_id=request_id)
                verified={**checked['candidate'],'results':checked.get('results',[])}
            elif partitioned:
                checked=(self._partition_loadout_tx(db,battle_id,version,saved_archive,world_id,request,world_location,observation_id,request_id,resident,pending_ref) if server_only else self._partition_validate_tx(db,battle_id,version,saved_archive,operations,{'kind':'loadout'},expected_world=world_id,request_id=request_id,resident=resident,pending_ref=pending_ref))
                verified={**checked['candidate'],'results':checked.get('results',[])}
            else: verified=self._legacy_validate(saved_archive,operations)
            results=verified.get('results',[])
            if (len(results)!=2 or any(x.get('accepted')is not True for x in results)
                    or not isinstance(results[0].get('transition'),dict)or not isinstance(results[1].get('transition'),list)):
                raise ValueError('native loadout/reconciliation receipt unavailable')
            if verified['view']['turn']!=view['turn']:raise ValueError('camp loadout advanced combat time')
            new_version=self._partition_stage_tx(db,battle_id,version,request_id,verified) if partitioned else version+1
            receipt={'verified':True,'battle_id':battle_id,'version':new_version,'archive_id':battle_id+':'+str(new_version),
                     'receipt':results[0]['transition'],'changes':results[1]['transition'],'observation_id':observation_id}
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',
                       (new_version,wire(verified['archive']),wire(verified['view']),wire(verified['native']),battle_id))
            if pending:
                handover=json.loads(pending[0][2]);handover['receipt']['version']=new_version;handover['view']=verified['view']
                db.execute('UPDATE handovers SET version=?,receipt=? WHERE id=?',(new_version,wire(handover),pending[0][0]))
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(receipt)))
            if pending_ref is not None and pending_ref[0] is not None:
                prior,old_hot,build,world,campaign=checked['_trusted_parent']
                current=db.execute('SELECT manifest FROM native_partition_versions WHERE battle_id=? AND version=?',(battle_id,new_version)).fetchone()[0]
                prepared=verified.get('_hot_prepared')
                new_hot=prepared.blob_digest if prepared is not None else verified['manifest']['hot_root']['blob_digest']
                proof_ref[0]=(prior,current,old_hot,new_hot,build,world,campaign)
                if prepared is not None:proof_ref[1]=prepared.next_baseline
            return receipt

    def grant_experience(self,battle_id,version,request_id,request):
        if (type(version)is not int or type(request_id)is not str or not 1<=len(request_id)<=100
            or type(request)is not dict or set(request)!={'operation_id','awards'} or request['operation_id']!=request_id):
            raise ValueError('invalid XP command')
        awards=request['awards']
        import math
        if (type(awards)is not list or len(awards)>100 or any(type(a)is not dict or set(a)!={'person_id','amount'}
            or type(a['person_id'])is not str or type(a['amount'])not in (int,float)
            or not math.isfinite(a['amount'])or not 0<=a['amount']<=1_000_000_000 for a in awards)
            or len({a['person_id']for a in awards})!=len(awards)):raise ValueError('invalid XP recipients')
        encoded=wire({'battle_id':battle_id,'request':request})
        with self.lock,self.connect()as db:
            db.execute('BEGIN IMMEDIATE')
            prior=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if prior:
                if prior[0]!=encoded:raise ValueError('XP identity conflict')
                return json.loads(prior[1])
            row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version or row[1]not in ('active','suspended'):raise ValueError('saved native state required')
            view=json.loads(row[3])
            outside_partition=(json.loads(row[2]).get('format')=='tome-partition-session-v1' and
                loadout_boundary({'state':row[1],'view':view,'native':json.loads(row[4]) if row[4] else {}}))
            if not(view.get('campaign_bootstrap')or view.get('campaign_withdrawn')or view.get('status')=='victory' or outside_partition):
                raise ValueError('XP delivery awaits safe campaign boundary')
            verified,partitioned=self._partition_or_legacy_tx(db,battle_id,version,json.loads(row[2]),[{'operation':'grant_experience',**request}],request_id=request_id)
            results=verified.get('results',[])
            if len(results)!=1 or results[0].get('accepted')is not True:raise ValueError('native XP not acknowledged')
            native=results[0].get('transition',{})
            if native.get('operation_id')!=request_id or [(a.get('person_id'),a.get('amount'))for a in native.get('awards',[])]!=[(a['person_id'],a['amount'])for a in awards]:raise ValueError('native XP receipt mismatch')
            if verified['view']['turn']!=view['turn']:raise ValueError('XP advanced combat time')
            new_version=self._partition_stage_tx(db,battle_id,version,request_id,verified) if partitioned else version+1
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',(new_version,wire(verified['archive']),wire(verified['view']),wire(verified['native']),battle_id))
            if row[1]=='suspended':
                pending=db.execute("SELECT id,receipt FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
                if len(pending)!=1:raise ValueError('pending handover mismatch')
                handover=json.loads(pending[0][1]);handover['receipt']['version']=new_version;handover['view']=verified['view']
                db.execute('UPDATE handovers SET version=?,receipt=? WHERE id=?',(new_version,wire(handover),pending[0][0]))
            result={'verified':True,'operation_id':request_id,'battle_id':battle_id,'version':new_version,'receipt':native}
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(result)))
            return result

    def settle_terminal(self,battle_id,version,request_id):
        if type(version) is not int or not isinstance(request_id,str) or not 1<=len(request_id)<=100:raise ValueError('invalid settlement request')
        encoded=wire({'operation':'settle','battle_id':battle_id,'version':version})
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=encoded:raise ValueError('request ID conflict')
                return json.loads(old[1])
            row=db.execute('SELECT version,state,archive,view FROM battles WHERE id=?',(battle_id,)).fetchone()
            view=json.loads(row[3]) if row else {}
            if not row or row[0]!=version or row[1]!='active' or (view.get('status')!='victory' and view.get('campaign_bootstrap') is not True):raise ValueError('verified victory or trusted bootstrap required')
            verified,partitioned=self._partition_or_legacy_tx(db,battle_id,version,json.loads(row[2]),[{'operation':'campaign_settle'}],request_id=request_id)
            if len(verified.get('results',[]))!=1:raise ValueError('native settlement receipt unavailable')
            new_version=self._partition_stage_tx(db,battle_id,version,request_id,verified) if partitioned else version+1
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',(new_version,wire(verified['archive']),wire(verified['view']),wire(verified['native']) if verified.get('native') else None,battle_id))
            native=verified['results'][0]
            remaining=native.get('transition',{}).get('remaining')
            if native.get('accepted') is not True or type(remaining) is not bool:raise ValueError('invalid native settlement receipt')
            receipt={'verified':True,'battle_id':battle_id,'version':new_version,'status':verified['view']['status'],'remaining':remaining}
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(receipt)))
            return receipt

    def reconcile_inventory(self,battle_id,version,request_id,world_id,world_location,world_clock=None):
        if type(version) is not int or not all(isinstance(v,str) and 1<=len(v)<=100 for v in (request_id,world_id,world_location)):raise ValueError('invalid reconciliation request')
        if world_clock is not None:
            if not self.native_checkpoints:raise ValueError('native area departure unavailable')
            from dm_mvp.local_area import elapsed_days
            elapsed_days(world_clock,world_clock)
        encoded=wire({'operation':'reconcile','battle_id':battle_id,'version':version,'world_id':world_id,'world_location':world_location,
                      **({'world_clock':world_clock}if world_clock is not None else{})})
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=encoded:raise ValueError('request ID conflict')
                return json.loads(old[1])
            row=db.execute('SELECT version,state,archive FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version or row[1] not in ('active','suspended'):raise ValueError('saved checkpoint required')
            if db.execute('SELECT 1 FROM defeat_snapshots WHERE battle_id=? AND version=?',(battle_id,version)).fetchone():raise ValueError('defeat settlement frozen')
            operations=[{'operation':'campaign_reconcile','world_id':world_id,'world_location':world_location,'observation_id':request_id}]
            if world_clock is not None:operations.append({'operation':'area_depart','operation_id':request_id,'area':{'world_clock':world_clock}})
            verified,partitioned=self._partition_or_legacy_tx(db,battle_id,version,json.loads(row[2]),operations,expected_world=world_id,request_id=request_id)
            if len(verified.get('results',[]))!=len(operations) or any(r.get('accepted')is not True for r in verified.get('results',[])):raise ValueError('native reconciliation receipt unavailable')
            result=verified['results'][0];changes=result.get('transition')
            if result.get('accepted') is not True or not isinstance(changes,list):raise ValueError('invalid native reconciliation receipt')
            new_version=self._partition_stage_tx(db,battle_id,version,request_id,verified) if partitioned else version+1
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',(new_version,wire(verified['archive']),wire(verified['view']),wire(verified['native']) if verified.get('native') else None,battle_id))
            if row[1]=='suspended':
                handover=db.execute("SELECT id,receipt FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
                if len(handover)!=1:raise ValueError('suspended handover mismatch')
                data=json.loads(handover[0][1]);data['receipt']['version']=new_version;data['view']=verified['view']
                db.execute('UPDATE handovers SET version=?,receipt=? WHERE id=?',(new_version,wire(data),handover[0][0]))
            receipt={'verified':True,'battle_id':battle_id,'version':new_version,'archive_id':battle_id+':'+str(new_version),'observation_id':request_id,'changes':changes}
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(receipt)))
            return receipt

    def adopt_inventory(self,battle_id,version,request_id,world_id,campaign_id):
        if type(version) is not int or not all(isinstance(v,str) and 1<=len(v)<=100 for v in (request_id,world_id,campaign_id)):raise ValueError('invalid adoption request')
        encoded=wire({'operation':'adopt','battle_id':battle_id,'version':version,'world_id':world_id,'campaign_id':campaign_id})
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=encoded:raise ValueError('request ID conflict')
                return json.loads(old[1])
            row=db.execute('SELECT version,state,archive FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version or row[1]!='active':raise ValueError('active initial checkpoint required')
            verified,partitioned=self._partition_or_legacy_tx(db,battle_id,version,json.loads(row[2]),[{'operation':'campaign_adopt','world_id':world_id,'campaign_id':campaign_id}],expected_world=world_id,expected_campaign=campaign_id,request_id=request_id)
            if len(verified.get('results',[]))!=1:raise ValueError('native adoption receipt unavailable')
            result=verified['results'][0];items=result.get('transition')
            if result.get('accepted') is not True or not isinstance(items,list):raise ValueError('invalid native adoption receipt')
            new_version=self._partition_stage_tx(db,battle_id,version,request_id,verified) if partitioned else version+1
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',(new_version,wire(verified['archive']),wire(verified['view']),wire(verified['native']) if verified.get('native') else None,battle_id))
            receipt={'verified':True,'battle_id':battle_id,'version':new_version,'archive_id':battle_id+':'+str(new_version),'items':items}
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(receipt)))
            return receipt

    def inspect_scene(self,battle_id,query):
        from tome_mvp.placement import validate_scene_query
        query=validate_scene_query(query)
        with self.lock,self.connect()as db:
            db.execute('BEGIN')
            saved=self.get(battle_id)
            operations=[{'operation':'scene_query','query':query}]
            if saved['archive'].get('format')=='tome-partition-session-v1':
                result=self._partition_validate_tx(db,battle_id,saved['version'],saved['archive'],operations,{'kind':'loadout'})
            else:result=self._legacy_validate(saved['archive'],operations)
            if len(result.get('results',[]))!=1:raise ValueError('scene query receipt missing')
            return result['results'][0]

    def prepare_enemies(self,battle_id,version,request_id,enemies,*,base_reference_level):
        """Commit the whole requested roster from one disposable native candidate."""
        from dm_mvp.battle_entry import difficulty_level,normalize_specified_enemies
        from tome_mvp.placement import validate_spawn
        public=[{k:v for k,v in e.items()if k not in ('person_name','person_birth')} for e in enemies]
        normalized=normalize_specified_enemies(public)
        if not normalized:raise ValueError('specified enemies required')
        if type(base_reference_level)is not int or not 1<=base_reference_level<=150:raise ValueError('invalid base reference level')
        if not isinstance(request_id,str)or not 1<=len(request_id)<=100:raise ValueError('invalid preparation identity')
        encoded=wire({'battle_id':battle_id,'enemies':enemies,'base_reference_level':base_reference_level})
        with self.lock,self.connect()as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=encoded:raise ValueError('enemy preparation identity conflict')
                return json.loads(old[1])
            row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version or row[1]not in ('active','suspended'):raise ValueError('saved battle required')
            view=json.loads(row[3]);native=json.loads(row[4])if row[4]else{}
            cleared_area=(view.get('status')=='victory' and view.get('map_available')is True and (native.get('local_areas')or{}).get('current_area')is not None)
            if view.get('status')=='defeat'or (view.get('status')=='victory'and not cleared_area)or (view.get('mission_complete')and not cleared_area):raise ValueError('battle already terminal')
            people=native.get('world_people')or{};areas=native.get('local_areas')or{}
            sources=[];operations=[]
            for i,e in enumerate(normalized):
                pid=e.get('person_id');binding=people.get(pid)if pid else None
                if binding and binding.get('status')not in ('alive','surrendered','released'):raise ValueError('world person is not an available living enemy')
                if binding is None and not (e.get('enemy_id') or enemies[i].get('person_birth')):raise ValueError('first world person creation requires a native profile')
                for j in range(e['count']):
                    op={'operation':'spawn_enemy','operation_id':'roster:'+hashlib.sha256((request_id+':'+str(i)+':'+str(j)).encode()).hexdigest(),
                        'placement':'same_room'if e['same_room']else'other_room'}
                    if e.get('enemy_id'):op['enemy_id']=e['enemy_id']
                    if pid:
                        name=enemies[i].get('person_name')
                        if not isinstance(name,str)or not name:raise ValueError('trusted world person name required')
                        op.update(person_id=pid,person_name=name)
                        if enemies[i].get('person_birth') and not binding:
                            op['person_birth']=enemies[i]['person_birth']
                    if binding:
                        source={'area_id':binding['area_id'],'floor':binding['floor']}
                        if source not in sources:sources.append(source)
                        op.update(source_area=source['area_id'],source_floor=source['floor'])
                    elif not binding:op['reference_level']=difficulty_level(base_reference_level,e['difficulty'])
                    operations.append(validate_spawn(op))
            selection={'kind':'area','area_id':areas.get('current_area'),'floor':areas.get('current_floor'),'sources':sources}
            if not isinstance(selection['area_id'],str):selection={'kind':'loadout'}
            verified,partitioned=self._partition_or_legacy_tx(db,battle_id,version,json.loads(row[2]),operations,selection=selection,request_id=request_id)
            results=verified.get('results')
            if not isinstance(results,list)or len(results)!=len(operations):raise ValueError('incomplete enemy preparation receipts')
            roster=[];seen=set()
            for op,result in zip(operations,results):
                receipt=result.get('transition')if isinstance(result,dict)else None
                if not isinstance(result,dict)or result.get('accepted')is not True or not isinstance(receipt,dict)or receipt.get('status')!='applied':raise ValueError('enemy preparation rejected')
                uid=receipt.get('actor_id')
                if type(uid)is not int or uid in seen or type(receipt.get('level'))is not int or not 1<=receipt['level']<=200:raise ValueError('invalid native enemy identity or level')
                if any(type(receipt.get(k))is not int or not 0<=receipt[k]<64 for k in ('x','y')):raise ValueError('invalid native enemy position')
                if receipt.get('placement')!=op['placement']or op.get('person_id')!=receipt.get('person_id'):raise ValueError('enemy preparation scope mismatch')
                if op.get('enemy_id') and not op.get('person_birth') and receipt.get('enemy_id')!=op['enemy_id']:raise ValueError('enemy type mismatch')
                seen.add(uid);roster.append(receipt)
            if verified['view']['turn']!=view['turn']:raise ValueError('enemy preparation advanced game time')
            new_version=self._partition_stage_tx(db,battle_id,version,request_id,verified)if partitioned else version+1
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',(new_version,wire(verified['archive']),wire(verified['view']),wire(verified.get('native')),battle_id))
            if row[1]=='suspended':
                pending=db.execute("SELECT id,receipt FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
                if len(pending)!=1:raise ValueError('suspended handover mismatch')
                payload=json.loads(pending[0][1]);payload['receipt']['version']=new_version;payload['view']=verified['view']
                db.execute('UPDATE handovers SET version=?,receipt=? WHERE id=?',(new_version,wire(payload),pending[0][0]))
            receipt={'verified':True,'status':'applied','battle_id':battle_id,'version':new_version,'enemies':roster}
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(receipt)))
            return receipt

    def place_enemy(self,battle_id,version,request_id,operation):
        from tome_mvp.placement import validate_spawn
        operation=validate_spawn(operation)
        if type(version)is not int or not isinstance(request_id,str)or not 1<=len(request_id)<=100:raise ValueError('invalid placement request')
        encoded=wire({'battle_id':battle_id,'operation':operation})
        with self.lock,self.connect()as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=encoded:raise ValueError('placement identity conflict')
                return json.loads(old[1])
            row=db.execute('SELECT version,state,archive,view FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version or row[1]not in ('active','suspended'):raise ValueError('saved battle required')
            view=json.loads(row[3])
            if view.get('status')in ('victory','defeat')or view.get('mission_complete'):raise ValueError('battle already terminal')
            verified,partitioned=self._partition_or_legacy_tx(db,battle_id,version,json.loads(row[2]),[operation],request_id=request_id)
            results=verified.get('results')
            if not isinstance(results,list)or len(results)!=1 or not isinstance(results[0],dict):raise ValueError('invalid placement receipt')
            result=results[0];placement=result.get('transition')
            if not isinstance(placement,dict)or placement.get('status')not in ('applied','rejected'):raise ValueError('invalid placement result')
            if result.get('accepted')is not True:raise ValueError('placement not acknowledged')
            if placement.get('status')!='applied':return {'verified':True,'battle_id':battle_id,'version':version,**placement}
            if verified['view']['turn']!=view['turn']:raise ValueError('placement advanced game time')
            new_version=self._partition_stage_tx(db,battle_id,version,request_id,verified) if partitioned else version+1
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=?',(new_version,wire(verified['archive']),wire(verified['view']),wire(verified.get('native')),battle_id))
            if row[1]=='suspended':
                pending=db.execute("SELECT id,receipt FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
                if len(pending)!=1:raise ValueError('suspended handover mismatch')
                payload=json.loads(pending[0][1]);payload['receipt']['version']=new_version;payload['view']=verified['view']
                db.execute('UPDATE handovers SET version=?,receipt=? WHERE id=?',(new_version,wire(payload),pending[0][0]))
            receipt={'verified':True,'status':'applied','battle_id':battle_id,'version':new_version,'archive_id':battle_id+':'+str(new_version),'placement':placement}
            db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,encoded,wire(receipt)))
            return receipt

    def resolve(self,handover_id,request_id,operations,*,trusted_area=None):
        if not isinstance(request_id,str) or not request_id or not isinstance(operations,list) or len(operations)>16:raise ValueError('invalid DM resolution')
        for op in operations:
            if isinstance(op,dict)and op.get('operation')=='spawn_enemy':
                if set(op)&{'person_id','person_name','person_birth','reference_level','source_area','source_floor'}:raise ValueError('named enemies require the unified trusted entry')
                from tome_mvp.placement import validate_spawn
                validate_spawn(op);continue
            if not isinstance(op,dict) or set(op)-{'operation','target','operation_id'} or op.get('operation') not in ('recruit','surrender') or not isinstance(op.get('operation_id'),str) or not str(op.get('target','')).isdigit():raise ValueError('invalid DM operation')
        if trusted_area is not None:
            if not self.native_checkpoints or not isinstance(trusted_area,dict):raise ValueError('native area reentry unavailable')
            from dm_mvp.local_area import elapsed_days
            elapsed_days(trusted_area.get('world_clock'),trusted_area.get('world_clock'))
        request=wire({'handover':handover_id,'operations':operations,**({'trusted_area':trusted_area}if trusted_area is not None else{})})
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old=db.execute('SELECT request,receipt FROM receipts WHERE request_id=?',(request_id,)).fetchone()
            if old:
                if old[0]!=request:raise ValueError('request ID conflict')
                return json.loads(old[1])
            row=db.execute('SELECT battle_id,version,state FROM handovers WHERE id=?',(handover_id,)).fetchone()
            if not row or row[2]!='pending':raise ValueError('handover already resolved or missing')
            bid,version,_=row;current=self.get(bid)
            if current['version']!=version or current['state']!='suspended':raise ValueError('stale handover')
            effective=([{'operation':'area_enter','operation_id':request_id,'area':trusted_area}]if trusted_area is not None else[])+operations
            partitioned=current['archive'].get('format')=='tome-partition-session-v1'
            if partitioned:
                selection=({'kind':'area','area_id':trusted_area['area_id'],'floor':trusted_area['floor']} if trusted_area is not None else {'kind':'loadout'})
                checked=self._partition_validate_tx(db,bid,version,current['archive'],effective,selection,request_id=request_id)
                verified={**checked['candidate'],'results':checked.get('results',[])}
            else: verified=self._legacy_validate(current['archive'],effective)
            if trusted_area is not None and (not verified.get('results') or verified['results'][0].get('accepted')is not True):raise ValueError('area reentry not confirmed')
            results=verified.get('results',[])[1:]if trusted_area is not None else verified.get('results',[])
            for op,result in zip(operations,results):
                if op['operation']=='spawn_enemy' and (result.get('accepted')is not True or result.get('transition',{}).get('status')!='applied'):
                    raise ValueError('enemy placement was rejected')
            if any(op['operation']=='spawn_enemy' for op in operations) and len(results)!=len(operations):
                raise ValueError('missing placement receipt')
            if trusted_area is None and operations and all(op['operation']=='spawn_enemy' for op in operations) and verified['view']['turn']!=current['view']['turn']:
                raise ValueError('placement advanced game time')
            if partitioned:self._partition_stage_tx(db,bid,version,request_id,verified)
            version+=1
            db.execute('UPDATE battles SET version=?,state=?,archive=?,view=?,native=? WHERE id=?',(version,'active',wire(verified['archive']),wire(verified['view']),wire(verified['native']) if verified.get('native') else None,bid))
            receipt={'format':'tome-resume-receipt-v1','battle_id':bid,'version':version,'state':'active','turn':verified['view']['turn'],'verified':True}
            db.execute("UPDATE handovers SET state='resolved' WHERE id=?",(handover_id,));db.execute('INSERT INTO receipts VALUES(?,?,?)',(request_id,request,wire(receipt)))
            return receipt

    def _commit_partition_candidate(self, battle_id, version, request_id, trusted_scope, candidate):
        """Experimental internal transaction seam; no HTTP or browser entry.

        Only a future trusted validator adapter may call this. The candidate is
        not itself evidence of VM validation. The caller is responsible for
        deriving trusted_scope from the authoritative battle/world binding.
        """
        if not getattr(self, '_partition_experimental', False):
            raise ValueError('partition persistence unavailable')
        if (not isinstance(battle_id,str) or not 1<=len(battle_id)<=100 or
            type(version) is not int or version<0 or not isinstance(request_id,str) or
            not 1<=len(request_id)<=100 or not isinstance(trusted_scope,dict) or
            set(trusted_scope)!={'build','world_id','campaign_id'} or
            not isinstance(candidate,dict) or set(candidate)!={'manifest','blobs','archive','view','native'}):
            raise ValueError('invalid partition candidate')
        from . import native_partition_store as partitions
        manifest=candidate['manifest']
        if not isinstance(manifest,dict) or any(manifest.get(k)!=v for k,v in trusted_scope.items()):
            raise ValueError('partition candidate scope mismatch')
        if not isinstance(candidate['archive'],dict) or not isinstance(candidate['view'],dict) or not isinstance(candidate['native'],dict):
            raise ValueError('invalid partition candidate projection')
        if candidate['archive'].get('build') != trusted_scope['build']:
            raise ValueError('partition archive build mismatch')
        partitions.validate_manifest(manifest)
        payload=candidate['blobs']
        if (not isinstance(payload,dict) or len(payload)>partitions.MAX_PARTITIONS+1 or
            any(not isinstance(v,str) for v in payload.values()) or
            sum(len(v) for v in payload.values())>partitions.MAX_PAYLOAD*4//3+4):
            raise ValueError('partition candidate payload capacity exceeded')
        # This digest binds the complete trusted candidate, not only its manifest.
        candidate_digest=hashlib.sha256(wire({'version':version,'scope':trusted_scope,'candidate':candidate}).encode('utf8')).hexdigest()
        with self.lock,self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            partitions.initialize(db)
            db.execute('CREATE TABLE IF NOT EXISTS native_partition_session_receipts (battle_id TEXT NOT NULL, request_id TEXT NOT NULL, candidate_hash TEXT NOT NULL, receipt TEXT NOT NULL, PRIMARY KEY(battle_id,request_id))')
            db.execute('CREATE TABLE IF NOT EXISTS native_partition_battle_history (battle_id TEXT NOT NULL, version INTEGER NOT NULL, state TEXT NOT NULL, archive TEXT NOT NULL, view TEXT NOT NULL, native TEXT, PRIMARY KEY(battle_id,version))')
            db.execute('CREATE TABLE IF NOT EXISTS native_partition_handover_history (battle_id TEXT NOT NULL, version INTEGER NOT NULL, handover_id TEXT NOT NULL, receipt TEXT NOT NULL, PRIMARY KEY(battle_id,version))')
            prior=db.execute('SELECT candidate_hash,receipt FROM native_partition_session_receipts WHERE battle_id=? AND request_id=?',(battle_id,request_id)).fetchone()
            if prior:
                if prior[0]!=candidate_digest: raise ValueError('partition request ID conflict')
                return json.loads(prior[1])
            row=db.execute('SELECT version,state,archive,view,native FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version or row[1] not in ('active','suspended'):
                raise ValueError('stale or inactive partition battle')
            pending=[]
            if row[1]=='suspended':
                saved={'state':row[1],'view':json.loads(row[3]),'native':json.loads(row[4]) if row[4] else {}}
                updated={'state':row[1],'view':candidate['view'],'native':candidate['native']}
                if not loadout_boundary(saved) or not loadout_boundary(updated):
                    raise ValueError('safe departed partition battle required')
                pending=db.execute("SELECT id,version,receipt FROM handovers WHERE battle_id=? AND state='pending'",(battle_id,)).fetchall()
                if len(pending)!=1 or pending[0][1]!=version: raise ValueError('pending handover mismatch')
            old_archive=json.loads(row[2])
            if old_archive.get('build')!=trusted_scope['build']: raise ValueError('partition base build mismatch')
            new_version=partitions.commit(db,battle_id=battle_id,expected_version=version,request_id=request_id,manifest=manifest,blobs=candidate['blobs'])
            db.execute('INSERT INTO native_partition_battle_history VALUES (?,?,?,?,?,?)',(battle_id,*row))
            db.execute('UPDATE battles SET version=?,archive=?,view=?,native=? WHERE id=? AND version=?',
                       (new_version,wire(candidate['archive']),wire(candidate['view']),wire(candidate['native']),battle_id,version))
            if db.execute('SELECT changes()').fetchone()[0]!=1: raise ValueError('partition battle update conflict')
            if pending:
                db.execute('INSERT INTO native_partition_handover_history VALUES (?,?,?,?)',(battle_id,version,pending[0][0],pending[0][2]))
                handover=json.loads(pending[0][2]);handover['receipt']['version']=new_version;handover['view']=candidate['view']
                db.execute('UPDATE handovers SET version=?,receipt=? WHERE id=? AND version=?',
                           (new_version,wire(handover),pending[0][0],version))
                if db.execute('SELECT changes()').fetchone()[0]!=1: raise ValueError('partition handover update conflict')
            receipt={'battle_id':battle_id,'version':new_version,'partition_candidate':True}
            db.execute('INSERT INTO native_partition_session_receipts VALUES (?,?,?,?)',(battle_id,request_id,candidate_digest,wire(receipt)))
            return receipt

    def _read_partition_candidate(self, battle_id, version, partition_ids):
        """Fetch named blobs only from the current trusted battle version."""
        if not getattr(self, '_partition_experimental', False): raise ValueError('partition persistence unavailable')
        from . import native_partition_store as partitions
        with self.lock,self.connect() as db:
            db.execute('BEGIN')
            row=db.execute('SELECT version,state FROM battles WHERE id=?',(battle_id,)).fetchone()
            if not row or row[0]!=version or row[1] not in ('active','suspended'):
                raise ValueError('stale or inactive partition battle')
            if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='native_partition_versions'").fetchone():
                raise ValueError('partition checkpoint unavailable')
            return partitions.read(db,battle_id=battle_id,version=version,partition_ids=partition_ids)
