"""Make a build-only projection of upstream FOV with graphics headers removed."""
import hashlib
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:])
raw = source.read_bytes()
expected = "d3bdedc4ce28f0c05ff8a9c2ff9ff709a3752f2fe5baced6a323caece9547dbe"
if hashlib.sha256(raw).hexdigest() != expected:
    raise SystemExit("Unexpected upstream fov.c hash; refusing projection")
text = raw.decode("utf-8")
start = text.index('#include "display.h"')
end = text.index('#define SQRT_3', start)
headers = '''#include "fov/fov.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "auxiliar.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define TRUE true
#define FALSE false

'''
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(text[:start] + headers + text[end:], encoding="utf-8", newline="\n")
