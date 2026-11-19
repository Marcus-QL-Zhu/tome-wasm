import os
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def location(name, fallback):
    return Path(os.environ.get('TOME_' + name.upper(), str(ROOT / fallback))).resolve()
SOURCE = location('source', 'artifacts/tome-headless-build-20261109/source')
RUNTIME = location('runtime', 'artifacts/tome-headless-build-20261109/runtime')
ADDON = location('addon', 'artifacts/tome-feasibility-20261109/addon/source')
SDK = location('sdk', 'artifacts/toolchains/emsdk')
TCC = location('tcc', 'artifacts/tome-headless-consult-20261109/vendor/tccbox/tcc_dist/tcc.exe')
