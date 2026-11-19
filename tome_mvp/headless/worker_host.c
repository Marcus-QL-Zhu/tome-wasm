/* Source-portability experiment. This process can read only prepared Lua files. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <io.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "physfs.h"
#include "aioo_source.inc"

static const char **roots;
static int root_count;
static FILE *audit;
static FILE *protocol_output;
static int restart_requested = 0;
static double restart_seed, restart_id, restart_generation;
static char restart_fixture[32];
extern int luaopen_fov(lua_State *L), luaopen_lpeg(lua_State *L), luaopen_bit(lua_State *L);
extern int open_pure(lua_State *L);

static int headless_aioo_source(lua_State *L) {
    lua_pushlstring(L, (const char *)aioo_source, sizeof(aioo_source));
    return 1;
}

static int protocol_write(lua_State *L) {
    size_t n;
    const char *s = luaL_checklstring(L, 1, &n);
    if (fwrite(s, 1, n, protocol_output) != n || fflush(protocol_output))
        return luaL_error(L, "protocol output failed");
    return 0;
}
static int protocol_read(lua_State *L) {
    static char line[1048577];
    size_t n = 0; int c, overflow = 0;
    while ((c = getchar()) != EOF && c != '\n') {
        if (n < sizeof(line)-1) line[n++] = (char)c; else overflow = 1;
    }
    /* A request exists only after its terminating newline has arrived. */
    if (c == EOF) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, line, n); lua_pushboolean(L, overflow); return 2;
}
static int protocol_restart(lua_State *L) {
    restart_seed=luaL_checknumber(L,1);
    restart_id=luaL_checknumber(L,2);
    restart_generation=luaL_checknumber(L,3);
    { const char *fixture=luaL_checkstring(L,4);
      if (strcmp(fixture,"formal") && strcmp(fixture,"rescue") && strcmp(fixture,"standard") && strcmp(fixture,"skill_types") && strcmp(fixture,"ranged_policy") && strcmp(fixture,"exploration") && strcmp(fixture,"recovery") && strcmp(fixture,"exploration_complete")) return luaL_error(L,"invalid fixture");
      strcpy(restart_fixture,fixture); }
    restart_requested=1;
    return 0;
}

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
    protocol_output = _fdopen(_dup(_fileno(stdout)), "wb");
    if (!protocol_output || _dup2(_fileno(stderr), _fileno(stdout)) != 0) return 3;
    roots = (const char **)(argv + 3);
    root_count = argc-3;
    do {
        int restarting=restart_requested;
        restart_requested=0;
        L=luaL_newstate();
        if (!L) return 4;
        luaL_openlibs(L);
        lua_pushcfunction(L, protocol_write); lua_setglobal(L, "protocol_write");
        lua_pushcfunction(L, headless_aioo_source); lua_setglobal(L, "headless_aioo_source");
        lua_pushcfunction(L, protocol_read); lua_setglobal(L, "protocol_read");
        lua_pushcfunction(L, protocol_restart); lua_setglobal(L, "protocol_restart");
        if (restarting) {
            lua_pushnumber(L,restart_seed); lua_setglobal(L,"restart_seed");
            lua_pushnumber(L,restart_id); lua_setglobal(L,"restart_id");
            lua_pushnumber(L,restart_generation); lua_setglobal(L,"restart_generation");
            lua_pushstring(L,restart_fixture); lua_setglobal(L,"restart_fixture");
        }
        open_pure(L);
        luaopen_fov(L); lua_settop(L,0);
        luaopen_bit(L); lua_settop(L,0);
        luaopen_lpeg(L); lua_settop(L,0);
        rc=luaL_dofile(L,argv[2]);
        if (rc) fprintf(stderr,"%s\n",lua_tostring(L,-1));
        lua_close(L);
    } while (!rc && restart_requested);
    fclose(audit); fclose(protocol_output);
    return rc!=0;
}
