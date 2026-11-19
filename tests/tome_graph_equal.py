"""Exact isomorphism for valid rooted headless-graph-v1 Lua table documents."""
import collections
import json
from pathlib import Path


class Mismatch(Exception):
    pass


def atom(token):
    if token is None:
        return ('null',)
    tag,value=token
    if tag=='v':
        return ('v','bool' if isinstance(value,bool) else 'string' if isinstance(value,str) else 'number',value)
    if tag=='r':
        return ('r',value)
    if tag=='a':
        return ('a',value)
    raise ValueError(token)


def parse(doc):
    if doc.get('format')!='headless-graph-v1': raise ValueError('unknown format')
    nodes=[None]
    for n in doc['nodes']:
        entries={atom(k):atom(v) for k,v in n['entries']}
        if len(entries)!=len(n['entries']): raise ValueError('duplicate entry key')
        nodes.append((atom(n['meta']),entries))
    root=atom(doc['root'])
    for tok in [root]+[d for mt,entries in nodes[1:] for d in (mt,*entries,*entries.values())]:
        if tok[0]=='r' and not 1<=tok[1]<len(nodes): raise ValueError('invalid node reference')
    return nodes,root


def check(left_doc,right_doc):
    left,root=parse(left_doc); right,other=parse(right_doc)
    if len(left)!=len(right): raise Mismatch(f'node count {len(left)-1} vs {len(right)-1}')
    explored=[0]

    def solve(forward,backward,pending,paths):
        def bind(a,b,path):
            if a[0]!='r' or b[0]!='r':
                if a!=b: raise Mismatch(f'{path}: {a!r} vs {b!r}')
                return
            x,y=a[1],b[1]
            if x in forward:
                if forward[x]!=y: raise Mismatch(f'{path}: alias diverged from {paths[x]}')
                return
            if y in backward: raise Mismatch(f'{path}: separate nodes collapsed into {paths[backward[y]]}')
            forward[x]=y; backward[y]=x; paths[x]=path; pending.append(x)

        if not forward and not pending: bind(root,other,'$')
        while True:
            while pending:
                x=pending.popleft(); y=forward[x]; path=paths[x]
                ma,ka=left[x]; mb,kb=right[y]
                bind(ma,mb,path+'.<meta>')
                aa={k for k in ka if k[0]!='r'}; ab={k for k in kb if k[0]!='r'}
                if len(ka)!=len(kb) or aa!=ab:
                    raise Mismatch(f'{path}: entries {len(ka)}/{len(kb)}, removed {aa-ab}, added {ab-aa}')
                for key in sorted(aa,key=repr): bind(ka[key],kb[key],f'{path}[{key[-1]!r}]')

            best=None
            did_bind=False
            for x,y in tuple(forward.items()):
                va,vb=left[x][1],right[y][1]
                for key,val in va.items():
                    if key[0]!='r': continue
                    k=key[1]
                    if k in forward:
                        dst=('r',forward[k])
                        if dst not in vb: raise Mismatch(f'{paths[x]}: missing table key {paths[k]}')
                        bind(val,vb[dst],f'{paths[x]}[key={paths[k]}]')
                        if pending: did_bind=True; break
                    else:
                        choices=[]
                        for dst,value in vb.items():
                            if dst[0]!='r' or dst[1] in backward: continue
                            if (val[0]!='r' or value[0]!='r') and val!=value: continue
                            if val[0]=='r' and val[1] in forward and value!=('r',forward[val[1]]): continue
                            k1=left[k][1]; k2=right[dst[1]][1]
                            if len(k1)!=len(k2): continue
                            if any((kk not in k2 or (vv[0]!='r' and vv!=k2[kk])) for kk,vv in k1.items() if kk[0]!='r'): continue
                            choices.append(dst)
                        if not choices: raise Mismatch(f'{paths[x]}: no matching reference key')
                        if best is None or len(choices)<len(best[-1]): best=(x,key,val,choices)
                if did_bind: break
            if did_bind: continue
            if best is None: break
            x,k,val,choices=best; target=forward[x]; path=paths[x]+'.<table-key>'
            if len(choices)==1:
                bind(k,choices[0],path)
                bind(val,right[target][1][choices[0]],path+'.<value>')
                continue
            explored[0]+=1
            if explored[0]>10000: raise RuntimeError('inconclusive: search limit exceeded')
            failures=[]
            for choice in choices:
                f,b,q,p=forward.copy(),backward.copy(),collections.deque(),paths.copy()
                f[k[1]]=choice[1]; b[choice[1]]=k[1]; p[k[1]]=path; q.append(k[1])
                try: return solve(f,b,q,p)
                except Mismatch as err: failures.append(str(err))
            raise Mismatch(f'{path}: all {len(choices)} candidates failed, first {failures[0]}')

        if len(forward)!=len(left)-1: raise ValueError('unreachable encoded table')
        def mapped(token): return ('r',forward[token[1]]) if token[0]=='r' else token
        if mapped(root)!=other: raise Mismatch('root mismatch')
        for x,y in forward.items():
            ma,ka=left[x]; mb,kb=right[y]
            if mapped(ma)!=mb or {mapped(k):mapped(v) for k,v in ka.items()}!=kb:
                raise Mismatch(f'{paths[x]}: complete correspondence verification failed')
        return len(forward),explored[0]

    return solve({},{},collections.deque(),{})


if __name__=='__main__':
    out=Path(__file__).resolve().parent
    docs={k:json.loads((out/('graph-'+k+'.json')).read_text(encoding='utf-8')) for k in ('before','adjacent','after')}
    for first,second in [('before','adjacent'),('adjacent','after'),('before','after')]:
        a,b=docs[first],docs[second]
        validate=[]
        for field in a:
            if field not in ('snapshot','provider_state') and a[field]!=b[field]: validate.append(field)
        for field in a['snapshot']:
            if field!='graph' and a['snapshot'][field]!=b['snapshot'][field]: validate.append('snapshot.'+field)
        if validate: print(first,second,'NON_GRAPH_DIFFERENCES',validate)
        try:
            print(first,second,'world',check(a['snapshot']['graph'],b['snapshot']['graph']),'provider',check(a['provider_state'],b['provider_state']),'raw_graph_equal',a['snapshot']['graph']==b['snapshot']['graph'])
        except Mismatch as err: print(first,second,'MISMATCH',err)
