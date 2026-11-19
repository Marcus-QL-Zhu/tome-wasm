"""Check navigation is locked by pending down confirmation on real HTTP."""
import http.client
import json
import os
import threading
from tome_mvp.headless_bridge import HeadlessBridge, load_config
from tome_mvp.server import create_server
from tome_mvp.service import ServiceAdapter

bridge=HeadlessBridge(*load_config(os.environ['TOME_E2E_WORKER_CONFIG']))
server=None
try:
    bridge.start(seed=11, fixture='rescue')
    server=create_server(ServiceAdapter(bridge),0)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    def call(data=None):
        conn=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=60)
        headers={'Origin':f'http://127.0.0.1:{server.server_port}','Content-Type':'application/json'} if data else {}
        conn.request('POST' if data else 'GET','/api/command' if data else '/api/state',json.dumps(data) if data else None,headers)
        response=conn.getresponse();result=(response.status,json.loads(response.read()));conn.close();return result
    _,initial=call();assert initial['down_events']; before=initial['turn']
    for payload in ({'type':'navigate_start','x':3,'y':3},{'type':'navigate_step','control_epoch':initial['control_epoch']}):
        code,body=call({**payload,'revision':initial['revision']}); assert code != 200,(code,body)
        _,state=call();assert state['turn']==before and state['down_events']==initial['down_events']
    code,ack=call({'type':'confirm_down','event_id':initial['down_events'][0]['id'],'generation':initial['generation'],'revision':initial['revision']});assert code==200,(code,ack)
    code,stale=call({'type':'navigate_step','control_epoch':initial['control_epoch'],'revision':ack['revision']});assert code==409,(code,stale)
    _,after=call();assert after['turn']==before
    print(json.dumps({'result':'passed','pending_start_and_step':'rejected','post_ack_old_step':code,'turn':before},ensure_ascii=False))
finally:
    if server: server.shutdown();server.server_close();thread.join()
    bridge.close()
