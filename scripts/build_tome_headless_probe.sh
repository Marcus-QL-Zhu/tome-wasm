#!/bin/sh
# Usage: sh scripts/build_tome_headless_probe.sh SOURCE_DIR OUTPUT_FILE
set -eu
src=$1
out=$2
probe=${HEADLESS_PROBE_C:-tome_mvp/headless/dependency_probe.c}
extra=${HEADLESS_EXTRA_C:-}
gcc -O2 -DLUA_USE_LINUX -DPHYSFS_SUPPORTS_ZIP -I"$src" -I"$src/lua" -I"$src/physfs" \
  "$src"/lua/*.c "$src/physfs/physfs.c" "$src/physfs/physfs_byteorder.c" \
  "$src/physfs/physfs_unicode.c" "$src/physfs/archivers/bind_physfs.c" \
  "$src/physfs/archivers/dir.c" "$src/physfs/archivers/zip.c" \
  "$src/physfs/archivers/subzip.c" "$src/physfs/platform/unix.c" \
  "$src/physfs/platform/posix.c" "$src/fov/fov.c" "$src/SFMT.c" \
  "$probe" $extra -lz -lm -ldl -lpthread -o "$out"
