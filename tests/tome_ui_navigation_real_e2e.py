"""Isolated real worker + HTTP + shipped JavaScript navigation test."""
import os
from pathlib import Path
import subprocess
import threading
from tome_mvp.headless_bridge import HeadlessBridge, load_config
from tome_mvp.server import create_server
from tome_mvp.service import ServiceAdapter

root = Path(__file__).resolve().parents[1]
config = os.environ['TOME_E2E_WORKER_CONFIG']
argv, timeout, startup = load_config(config)
bridge = HeadlessBridge(argv, timeout, startup)
service = server = thread = None
out = root / 'artifacts/tome-input-20261111/ui'
out.mkdir(parents=True, exist_ok=True)
try:
    initial = bridge.start(seed=11, fixture='exploration')
    service = ServiceAdapter(bridge)
    server = create_server(service, 0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    result = subprocess.run(['node', str(root/'tests/tome_ui_navigation_real_e2e.js'),
                             f'http://127.0.0.1:{server.server_port}', '3', '3'],
                            cwd=root, capture_output=True, text=True, encoding='utf-8', timeout=180)
    (out/'navigation-real-http.json').write_text(result.stdout, encoding='utf-8')
    (out/'navigation-real-http.stderr.log').write_text(result.stderr, encoding='utf-8')
    print(result.stdout)
    if result.returncode:
        raise RuntimeError(result.stderr)
finally:
    if server is not None:
        server.shutdown()
        server.server_close()
    if service is not None:
        service.close()
    else:
        bridge.close()
    if thread is not None:
        thread.join()
