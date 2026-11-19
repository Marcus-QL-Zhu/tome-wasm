"""Check each installed DLC class through the existing HTTP preview and Web Worker."""
import argparse
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from threading import Thread

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tome_mvp.encounter import validate_encounter
from tome_mvp.encounter_launch import package_frozen
from tome_mvp.wasm.serve import create_server

CAREERS = {
    "Defiler": ["Doombringer", "Demonologist"],
    "Tinker": ["Sawbutcher", "Gunslinger", "Psyshot", "Annihilator"],
}


def run(browser, base, parent, career):
    party = [{"birth": {"race": "Human", "subrace": "Cornac", "sex": "Female",
                        "class": parent, "subclass": career}, "name": career, "level": 16},
             {"template": "159442"}, {"template": "425367"}]
    manifest = validate_encounter({"format": "tome-encounter-v1", "seed": 23, "party": party,
                                   "map": {"kind": "rooms", "size": 20},
                                   "enemies": [{"prototype": "orc warrior", "level": 10}]})
    with TemporaryDirectory() as temp:
        bundle = Path(temp) / "encounter"
        build = package_frozen(base, bundle, manifest)
        with create_server(bundle / "public", 0) as server:
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            page = browser.new_page()
            try:
                page.goto(f"http://127.0.0.1:{server.server_port}/encounter.json")
                result = page.evaluate("""() => new Promise((ok,fail) => {
                  const worker=new Worker('/browser_worker.mjs',{type:'module'});
                  const timer=setTimeout(()=>{worker.terminate();fail(Error('worker timed out'));},60000);
                  worker.onerror=e=>{clearTimeout(timer);worker.terminate();fail(Error(e.message));};
                  worker.onmessage=({data:r})=>{
                    if(r.id===2){clearTimeout(timer);worker.terminate();fail(Error(JSON.stringify(r.body).slice(-3800)));return;}
                    if(r.status!==200){worker.postMessage({id:2,path:'/api/diagnostics'});return;}
                    clearTimeout(timer);worker.terminate();
                    ok({build:r.body.build_id,leader:r.body.party[0].name,
                        talents:r.body.talents.map(t=>t.id),mapRows:r.body.map.length,party:r.body.party.length});
                  };
                  worker.postMessage({id:1,path:'/api/bootstrap',body:{}});
                })""")
                if result["build"] != build or result["leader"] != career or result["mapRows"] != 20 or result["party"] != 3 or not result["talents"]:
                    raise AssertionError((career, result))
                return result
            finally:
                page.close()
                server.shutdown()
                thread.join()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("--channel", default="msedge")
    args = parser.parse_args()
    records = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel=args.channel)
        try:
            for parent, careers in CAREERS.items():
                for career in careers:
                    records.append(run(browser, args.base, parent, career))
                    print(career, flush=True)
        finally:
            browser.close()
            args.report.write_text(json.dumps(records, indent=2), encoding="utf8")
