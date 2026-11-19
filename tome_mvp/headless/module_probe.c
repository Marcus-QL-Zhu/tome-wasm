/* Loads trusted upstream Lua through the official PhysFS module loader. */
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "physfs.h"
int luaopen_fov(lua_State *L);
int main(int argc, char **argv) {
    lua_State *L;
    if (argc != 3) { fprintf(stderr, "usage: module_probe ENGINE_ROOT MODULE_ROOT\n"); return 2; }
    if (!PHYSFS_init(argv[0]) || !PHYSFS_mount(argv[1], "/", 1) || !PHYSFS_mount(argv[2], "/", 1)) {
        fprintf(stderr, "PhysFS setup failed\n"); return 3;
    }
    L = luaL_newstate();
    if (!L) return 4;
    luaL_openlibs(L);
    lua_newtable(L); lua_setglobal(L, "core");
    luaopen_fov(L);
    if (luaL_dostring(L, "require 'engine.class'; assert(type(class)=='table'); assert(type(core.fov)=='table'); print('upstream engine.class and core.fov loaded')")) {
        fprintf(stderr, "Lua module: %s\n", lua_tostring(L, -1)); return 5;
    }
    lua_close(L);
    PHYSFS_deinit();
    return 0;
}
