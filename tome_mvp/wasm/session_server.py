"""Loopback development host for durable Wasm battles and DM handovers."""
import argparse
import hmac
import json
import os
from pathlib import Path
import secrets
from urllib.parse import unquote
from .serve import create_server
from .session_store import SessionStore


class SessionAPI:
    def __init__(self,store,host_token,on_handover=None):
        self.store=store;self.host_token=host_token;self.on_handover=on_handover

    def http(self,h,method,path):
        def send(status,data):
            raw=json.dumps(data,ensure_ascii=False,allow_nan=False).encode('utf-8')
            h.send_response(status);h.send_header('Content-Type','application/json; charset=utf-8');h.send_header('Cache-Control','no-store');h.send_header('Content-Length',str(len(raw)));h.end_headers();h.wfile.write(raw)
        try:
            privileged=path.startswith('/api/dm/')
            if privileged and not hmac.compare_digest(h.headers.get('Authorization',''),'Bearer '+self.host_token):return send(403,{'error':'host authorization required'})
            data=None
            if method=='POST':
                length=int(h.headers.get('Content-Length','0'))
                if length<1 or length>80*1024*1024:raise ValueError('invalid request size')
                data=json.loads(h.rfile.read(length))
                if not isinstance(data,dict):raise ValueError('expected object')
            if method=='GET' and path=='/api/session-capabilities':return send(200,{'persistent_sessions':True,'nonterminal_handover':True,'native_validation':True,'native_checkpoints':self.store.native_checkpoints,'native_partitions':self.store._partition_experimental,'browser_native_snapshots':self.store._partition_experimental})
            if method=='GET' and path=='/api/asset-catalog':return send(200,h.server.asset_store.catalog())
            if method=='GET' and path.startswith('/api/partition-checkpoints/'):
                bid=unquote(path.removeprefix('/api/partition-checkpoints/'))
                if len(bid)!=32 or any(c not in '0123456789abcdef' for c in bid):raise ValueError('invalid battle ID')
                return send(200,self.store.partition_checkpoint(bid))
            if method=='GET' and path.startswith('/api/checkpoints/'):
                bid=unquote(path.removeprefix('/api/checkpoints/'))
                if len(bid)!=32 or any(c not in '0123456789abcdef' for c in bid):raise ValueError('invalid battle ID')
                row=self.store.get(bid);native=row.pop('native',None)or{}
                if isinstance(native.get('combat_facts'),dict):row['combat_facts']=native['combat_facts']
                return send(200,row)
            if method=='GET' and path.startswith('/api/status/'):
                row=self.store.get(path.removeprefix('/api/status/'));row.pop('archive');row.pop('native',None)
                return send(200,row)
            if method=='POST' and path=='/api/checkpoints':
                receipt=self.store.save(data)
                if receipt['state']=='suspended' and self.on_handover:self.on_handover(receipt,self.store.get(receipt['battle_id'])['view'])
                return send(200,receipt)
            if method=='GET' and path=='/api/dm/handovers':return send(200,{'handovers':self.store.pending()})
            if method=='POST' and path=='/api/dm/next-scene':
                if set(data)!={'battle_id','version','request_id','scene'}:raise ValueError('invalid next scene fields')
                receipt=self.store.next_scene(data['battle_id'],data['version'],data['request_id'],data['scene'])
                receipt['resume_url']='/?battle='+receipt['battle_id'];return send(200,receipt)
            if method=='POST' and path=='/api/dm/resolve':
                if set(data)!={'handover_id','request_id','operations'}:raise ValueError('invalid resolution fields')
                receipt=self.store.resolve(data['handover_id'],data['request_id'],data['operations'])
                receipt['resume_url']='/?battle='+receipt['battle_id'];return send(200,receipt)
            return send(404,{'error':'unknown route'})
        except KeyError:return send(404,{'error':'unknown battle'})
        except (ValueError,TypeError,json.JSONDecodeError) as e:return send(400,{'error':str(e)[:800]})
        except Exception:return send(500,{'error':'host operation failed; native battle was not replaced'})


def main():
    p=argparse.ArgumentParser();p.add_argument('--root',required=True,type=Path);p.add_argument('--data',required=True,type=Path);p.add_argument('--port',type=int,default=8927);p.add_argument('--overlay-assets');p.add_argument('--ready-file',type=Path);p.add_argument('--asset-archive',action='append');p.add_argument('--native-checkpoints',action='store_true');p.add_argument('--resident-validation',action='store_true');p.add_argument('--native-partitions',action='store_true');p.add_argument('--native-partition-resident',action='store_true');a=p.parse_args()
    a.data.mkdir(parents=True,exist_ok=True)
    token_file=a.data/'host-token'
    if not token_file.exists():token_file.write_text(secrets.token_urlsafe(32),encoding='utf-8');os.chmod(token_file,0o600)
    api=SessionAPI(SessionStore(a.data/'battles.sqlite',a.root,native_checkpoints=a.native_checkpoints,resident_validation=a.resident_validation,native_partitions=a.native_partitions,native_partition_resident=a.native_partition_resident),token_file.read_text(encoding='utf-8').strip())
    server=create_server(a.root,a.port,overlay_assets=a.overlay_assets,session_api=api,asset_archives=a.asset_archive,runtime_assets=Path(__file__).parent if a.native_partitions else None)
    ready={'pid':os.getpid(),'port':server.server_port,'url':f'http://127.0.0.1:{server.server_port}/','data':str(a.data.resolve()),'host_token_file':str(token_file.resolve())}
    (a.data/'server.json').write_text(json.dumps(ready,indent=2),encoding='utf-8')
    if a.ready_file:a.ready_file.write_text(json.dumps({'pid':os.getpid(),'port':server.server_port}),encoding='utf-8')
    print(json.dumps(ready),flush=True);server.serve_forever()


if __name__=='__main__':main()
