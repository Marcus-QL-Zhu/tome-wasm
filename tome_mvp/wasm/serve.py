"""Loopback-only static preview; no battle endpoint or worker process."""
import argparse
import json
import mimetypes
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

ASSETS = Path(__file__).resolve().parents[2] / 'artifacts/tome-formal-squad-20261111/assets'
ALLOWED = {'index.html', 'app.js', 'style.css', 'client.js', 'browser_worker.mjs', 'browser_checkpoint.mjs', 'character_worker.mjs', 'engine_bridge.mjs', 'diagnostics.mjs', 'kernel_runtime.mjs', 'battle_session.mjs', 'partition_session.mjs', 'partition_transport.mjs', 'encounter_overlay.mjs', 'document_overlay.mjs', 'loadout_overlay.mjs', 'scene_overlay.mjs', 'native_zone_overlay.mjs', 'experience_overlay.mjs', 'encounter.json', 'dm.html', 'tome.js', 'tome.wasm', 'tome.data'}

def create_server(root, port=8920, assets=ASSETS, overlay_assets=None, asset_archives=None, session_api=None, runtime_assets=None):
    root, assets = Path(root).resolve(), Path(assets).resolve()
    overlay_assets = Path(overlay_assets).resolve() if overlay_assets else None
    # UI transport follows the application release. Native rules, bridges and
    # Wasm bytes stay pinned to the verified package; never rewrite that package.
    transport={}
    if runtime_assets is not None:
        runtime_assets=Path(runtime_assets)
        identity=json.loads((root.parent/'identity.json').read_text(encoding='utf8'))
        frozen_worker=(root/'browser_worker.mjs').read_text(encoding='utf8')
        seed=re.search(r'new BattleSession\(kernel\.rpc,recorder\.build,(\d+)\)',frozen_worker)
        if not seed:raise ValueError('frozen browser seed unavailable')
        for name in ('client.js','browser_worker.mjs','browser_checkpoint.mjs'):
            source=(runtime_assets/name).read_text(encoding='utf8')
            source=source.replace('__TOME_BUILD_ID__',identity['build_id']).replace('__TOME_ENCOUNTER_SEED__',seed[1]).replace('__TOME_ENCOUNTER_OVERLAY__','enabled' if identity.get('encounter_overlay') else 'disabled')
            transport[name]=source.encode('utf8')
    from .asset_store import AssetStore, DEFAULT_INSTALL, ARCHIVES
    images=AssetStore(assets,overlay_assets,asset_archives if asset_archives is not None else [DEFAULT_INSTALL/p for p in ARCHIVES])
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            u = urlsplit(self.path)
            if self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}' or (u.query and u.path not in ('/','/dm.html')) or u.fragment:
                return self.send_error(404)
            if session_api and u.path.startswith('/api/'):
                return session_api.http(self,'GET',u.path)
            try:
                name = unquote(u.path, encoding='utf-8', errors='strict')
                if name.startswith('/assets/'):
                    rel = name[len('/assets/'):]
                    parts = rel.split('/')
                    if not rel.startswith('data/gfx/') or not rel.endswith('.png') or any(not p or p in ('.', '..') or any(c in p for c in ('\\', ':', '%', '\x00')) for p in parts): raise ValueError()
                    data,etag=images.read(rel)
                    if self.headers.get('If-None-Match')=='"'+etag+'"':
                        self.send_response(304);self.send_header('ETag','"'+etag+'"');self.end_headers();return
                    self.send_response(200);self.send_header('Content-Type','image/png');self.send_header('Content-Length',str(len(data)));self.send_header('ETag','"'+etag+'"');self.send_header('Cache-Control','private, max-age=3600');self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(data);return
                else:
                    rel = 'index.html' if name == '/' else name.removeprefix('/')
                    if rel not in ALLOWED|set(transport) or name not in ('/', '/' + rel): raise ValueError()
                    if rel in transport:
                        path=Path(rel);data=transport[rel]
                    else:
                        path = (root / rel).resolve(strict=True); path.relative_to(root);data=path.read_bytes()
            except (OSError, ValueError, UnicodeError, json.JSONDecodeError): return self.send_error(404)
            kind = {'.mjs':'text/javascript', '.js':'text/javascript', '.wasm':'application/wasm', '.data':'application/octet-stream'}.get(path.suffix, mimetypes.guess_type(path.name)[0] or 'application/octet-stream')
            self.send_response(200); self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(data))); self.send_header('Cache-Control', 'no-store'); self.send_header('X-Content-Type-Options', 'nosniff'); self.end_headers(); self.wfile.write(data)
        def do_POST(self):
            if session_api and self.headers.get('Host')==f'127.0.0.1:{self.server.server_port}' and self.headers.get('Origin') in (None,f'http://127.0.0.1:{self.server.server_port}'):
                return session_api.http(self,'POST',urlsplit(self.path).path)
            self.send_error(405)
    Handler.asset_store=images
    server=ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.asset_store=images;original_close=server.server_close
    def close():
        images.close();original_close()
    server.server_close=close
    return server

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--root', required=True); p.add_argument('--port', type=int, default=8920); p.add_argument('--overlay-assets'); p.add_argument('--ready-file'); a = p.parse_args()
    server=create_server(a.root, a.port, overlay_assets=a.overlay_assets)
    if a.ready_file:
        ready=Path(a.ready_file);temporary=ready.with_suffix('.tmp')
        temporary.write_text(json.dumps({'pid':os.getpid(),'port':server.server_port}),encoding='utf-8');temporary.replace(ready)
    server.serve_forever()
