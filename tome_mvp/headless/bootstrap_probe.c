/* Source-portability experiment. This process can read only prepared Lua files. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "physfs.h"

static const char **roots;
static int root_count;
static FILE *audit;
extern int luaopen_fov(lua_State *L), luaopen_lpeg(lua_State *L), luaopen_bit(lua_State *L);
extern int open_pure(lua_State *L);

PHYSFS_File *PHYSFS_openRead(const char *name) {
    char full[4096];
    const char *dot;
    int i;
    if (!name) return NULL;
    while (*name == '/') name++;
    dot = strrchr(name, '.');
    if (!dot || strcmp(dot, ".lua") || strstr(name, "..") || strchr(name, ':') || strchr(name, '\\')) return NULL;
    for (i=0; i<root_count; ++i) {
        FILE *f;
        if (snprintf(full, sizeof(full), "%s/%s", roots[i], name) >= (int)sizeof(full)) continue;
        f = fopen(full, "rb");
        if (f) {
            fprintf(audit, "%d /%s\n", i, name);
            return (PHYSFS_File *)f;
        }
    }
    return NULL;
}
int PHYSFS_eof(PHYSFS_File *f) { return feof((FILE *)f); }
int PHYSFS_close(PHYSFS_File *f) { return !fclose((FILE *)f); }
PHYSFS_sint64 PHYSFS_read(PHYSFS_File *f, void *data, PHYSFS_uint32 size, PHYSFS_uint32 count) {
    return fread(data, size, count, (FILE *)f);
}
int main(int argc, char **argv) {
    lua_State *L;
    int rc;
    if (argc<4) return 2;
    audit = fopen(argv[1], "wb");
    if (!audit) return 3;
    roots = (const char **)(argv + 3);
    root_count = argc-3;
    L=luaL_newstate();
    if (!L) return 4;
    luaL_openlibs(L);
    open_pure(L);
    luaopen_fov(L); lua_settop(L,0);
    luaopen_bit(L); lua_settop(L,0);
    luaopen_lpeg(L); lua_settop(L,0);
    rc=luaL_dofile(L,argv[2]);
    if (rc) fprintf(stderr,"%s\n",lua_tostring(L,-1));
    lua_close(L); fclose(audit);
    return rc!=0;
}
