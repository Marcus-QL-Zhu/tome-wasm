"""Render bounded native-Zone calibration evidence without dropping incomplete runs."""
import argparse
from collections import Counter,defaultdict
from html import escape
import json
from pathlib import Path


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--batches',nargs='+',required=True)
    a=p.parse_args()
    records=[]
    for batch in a.batches:
        for line in (a.root/batch/'results.jsonl').read_text(encoding='utf8').splitlines():
            r=json.loads(line);r['_batch']=batch;records.append(r)
    grouped=defaultdict(list)
    for r in records:
        zone=r.get('zone_population') or {}
        grouped[(r['_batch'],r['group'],zone.get('template','error'),zone.get('reference_level',0))].append(r)
    summary=[];rows=[]
    for (batch,group,template,level),items in sorted(grouped.items()):
        status=Counter(r['status']for r in items)
        valid=len(items)-status['error']
        rate=status['victory']/valid if valid else None
        enemies=[len(r['initial_enemies'])for r in items if 'initial_enemies'in r]
        rare=[sum(e.get('rank',0)==3.2 for e in r['initial_enemies'])for r in items if 'initial_enemies'in r]
        reasons=Counter(r.get('incomplete_reason') or 'budget'for r in items if r['status']=='incomplete')
        row=dict(batch=batch,party=group,template=template,reference_level=level,cases=len(items),
                 valid=valid,statuses=dict(status),completion_rate=rate,incomplete_reasons=dict(reasons),
                 mean_population=sum(enemies)/len(enemies)if enemies else None,
                 mean_rares=sum(rare)/len(rare)if rare else None,
                 mean_seconds=sum(r['elapsed_ms']for r in items)/len(items)/1000)
        summary.append(row)
        pct='—'if rate is None else f'{rate:.1%}'
        cls='ok'if rate is not None and .75<=rate<=.85 else ''
        cells=[batch,group,template,level,len(items),status['victory'],status['defeat'],status['incomplete'],status['error'],pct,
               f'{row["mean_population"]:.1f}'if enemies else '—',f'{row["mean_rares"]:.1f}'if rare else '—',f'{row["mean_seconds"]:.2f}s']
        rows.append('<tr class="'+cls+'">'+''.join('<td>'+escape(str(v))+'</td>'for v in cells)+'</tr>')
    traces=[]
    for r in records:
        zone=r.get('zone_population') or {}
        traces.append('<tr>'+''.join('<td>'+escape(str(v))+'</td>'for v in [r['_batch'],r['case_id'],r['seed'],r['status'],
            r.get('incomplete_reason')or r.get('error','').split('\n')[0],len(r.get('initial_enemies',[])),r.get('actions',''),round(r['elapsed_ms']/1000,2)])+'</tr>')
    heads=lambda names:'<tr>'+''.join('<th>'+v+'</th>'for v in names)+'</tr>'
    page='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>原生Zone难度校准</title>
<style>body{font:16px/1.65 system-ui;margin:36px;background:#131923;color:#e4ebf3}h1{font-size:28px}p{max-width:1100px}table{border-collapse:collapse;white-space:nowrap;font-size:14px}th,td{padding:9px 12px;border-bottom:1px solid #344155;text-align:left}th{background:#263348}a{color:#87c8ff}.ok{background:#153b32}.scroll{overflow:auto;margin:20px 0}small{color:#afbdcf}details{margin:20px 0}code{color:#a9d4ff}</style>
<h1>原生Zone难度校准</h1><p>目标：64×64 Zone，Nightmare，固定守关Boss关闭。小队使用AIoo自动探索、战斗及原生休息。完成率目标75%～85%。</p>
<p>完成率＝完整清剿次数÷有效开局数。未结束也在分母内；技术错误单列，不用删掉种子后的比例宣称达标。清剿核验当前区域存活敌对实体，包含分裂和召唤。试验无保护急停，但不强制治疗或复活。</p>
<p>本轮复用原生怪物生态、等级、Rare和难度规则；地形仍用项目既有生成布局。它不等于完整复刻原版Zone剧情、宝库与静态关底地图。小样本结果是实测比例，不是精确概率保证。</p>'''
    page+='<div class="scroll"><table id="summary">'+heads(['阶段','小队','生态','参考等级R','开局','清剿','团灭','未结束','技术错','完成率','平均敌人','平均Rare','均耗时'])+''.join(rows)+'</table></div>'
    page+='<details><summary>逐场结果</summary><div class="scroll"><table>'+heads(['阶段','案例','种子','结果','原因','敌人','行动','秒'])+''.join(traces)+'</table></div></details>'
    page+='<p><a href="summary.json">结构化汇总</a></p><ul>'+''.join('<li><a href="'+escape(b)+'/results.jsonl">'+escape(b)+'：原始结果</a> · <a href="'+escape(b)+'/run.json">运行与输入冻结核验</a></li>'for b in a.batches)+'</ul>'
    (a.root/'index.html').write_text(page+'</html>',encoding='utf8')
    (a.root/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(summary,ensure_ascii=False))


if __name__=='__main__':main()
