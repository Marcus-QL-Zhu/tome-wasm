"""Recompile the native Wasm binary for the plane-capable release."""
from argparse import ArgumentParser
import json
import os
from pathlib import Path
import subprocess
import sys

parser = ArgumentParser(description=__doc__)
parser.add_argument('--base', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
base, out = args.base.resolve(), args.output.resolve()
if out.exists() or out.is_relative_to(base):
    parser.error('--output must be a new directory outside the input kernel')
out.mkdir(parents=True)
build = json.loads((base / 'build.json').read_bytes())
cmd = build['command']
sdk = Path(cmd[1]).parents[2]
src = next(Path(arg[2:]).parent for arg in cmd if arg.startswith('-I') and Path(arg[2:]).name == 'lua')
os.environ.update(TOME_SOURCE=str(src.parent), EM_CONFIG=str(sdk/'.emscripten'),
                  EMSDK_PYTHON=sys.executable, BINARYEN_CORES='2', EMCC_CORES='2')
sys.path.insert(0, str(root / 'scripts'))
from build_tome_wasm import prepare_noise
prepare_noise(out)
cmd[0] = sys.executable
for i, arg in enumerate(cmd):
    if Path(arg).name in ('host.c', 'native_serial.c') and '/tome_mvp/wasm/' in arg.replace(chr(92), '/'):
        cmd[i] = str(root/'tome_mvp/wasm'/Path(arg).name)
cmd[cmd.index('--no-entry'):cmd.index('--no-entry')] = [
    '-I'+str(src/'libtcod_import'), str(src/'libtcod_import/noise_c.c'), str(out/'pure_noise.c')]
cmd[-1] = str(out/'tome.js')
(out/'rebuild-command.json').write_text(json.dumps(cmd))
with (out/'compile.log').open('w',encoding='utf8') as log:
    subprocess.run([*cmd[:2], '-v', *cmd[2:]], check=True, stdout=log, stderr=log, timeout=300)
print(json.dumps({name:(out/name).stat().st_size for name in ('tome.js','tome.wasm','tome.data')}))
