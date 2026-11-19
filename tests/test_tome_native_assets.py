"""The internal art endpoint serves only manifest-listed PNGs below its root."""
import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from tome_mvp import server


class AssetRouteTest(unittest.TestCase):
    def test_manifest_and_path_boundaries(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'assets'
            folder = root / 'data' / 'gfx' / 'talents'
            folder.mkdir(parents=True)
            (folder / 'rush.png').write_bytes(b'png-test')
            (folder / 'hidden.png').write_bytes(b'not-listed')
            (root / 'manifest.json').write_text(json.dumps({'version': 1, 'assets': {'data/gfx/talents/rush.png': {}}}), encoding='utf-8')
            with patch.object(server, 'NATIVE_ASSETS', root):
                srv = server.create_server(object(), 0)
                thread = threading.Thread(target=srv.serve_forever, daemon=True)
                thread.start()
                try:
                    def get(path):
                        conn = http.client.HTTPConnection('127.0.0.1', srv.server_port, timeout=3)
                        conn.request('GET', path)
                        response = conn.getresponse()
                        body = response.read()
                        conn.close()
                        return response.status, body
                    self.assertEqual(get('/assets/data/gfx/talents/rush.png'), (200, b'png-test'))
                    for path in ('/assets/data/gfx/talents/hidden.png', '/assets/data/gfx/%2e%2e/manifest.json',
                                 '/assets/data/gfx/talents/%5c..%5cmanifest.png', '/assets/manifest.json',
                                 '/assets/data/gfx/talents/rush.png?x=1'):
                        self.assertEqual(get(path)[0], 404, path)
                finally:
                    srv.shutdown()
                    srv.server_close()
                    thread.join(timeout=2)
