"""Project-local skill wrapper. No installation into global skills is required."""
from pathlib import Path
import sys

sys.path.insert(0,str(Path(__file__).resolve().parents[3]))
from tome_mvp.encounter_launch import main

if __name__ == '__main__': main()
