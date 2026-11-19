"""Copy the verified original Player AIoo source for isolated headless research."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'artifacts/tome-feasibility-20261109/addon/source/superload/mod/class/Player.lua'
DEST = ROOT / 'artifacts/tome-control-expansion-20261109/player_aioo_original.lua'
SHA256 = '97c501f50a730b08e18f680e548191559ece9d65f1aa246668b27ba66fb8aa97'

def main():
    raw = SOURCE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SHA256:
        raise ValueError('AIoo source hash mismatch')
    DEST.parent.mkdir(parents=True, exist_ok=True)
    DEST.write_bytes(raw)
    print(DEST)

if __name__ == '__main__':
    main()
