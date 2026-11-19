/* Bounded upstream dependency probe. This is not a gameplay worker. */
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "fov/fov.h"
#include "SFMT.h"

static bool opaque(void *map, int x, int y) {
    (void)map;
    return x == 1 && y == 0;
}
static void light(void *map, int x, int y, int dx, int dy, int radius, void *src) {
    bool (*seen)[9] = map;
    (void)dx; (void)dy; (void)radius; (void)src;
    if (x >= -4 && x <= 4 && y >= -4 && y <= 4) seen[y + 4][x + 4] = true;
}
int main(void) {
    lua_State *L = luaL_newstate();
    fov_settings_type settings;
    bool seen[9][9] = {{false}};
    unsigned first, second;
    if (!L) return 1;
    luaL_openlibs(L);
    if (luaL_dostring(L, "return 6*7") || lua_tointeger(L, -1) != 42) return 2;
    lua_close(L);
    init_gen_rand(7); first = gen_rand32();
    init_gen_rand(7); second = gen_rand32();
    if (first != second) return 3;
    memset(&settings, 0, sizeof(settings));
    fov_settings_init(&settings);
    fov_settings_set_opacity_test_function(&settings, opaque);
    fov_settings_set_apply_lighting_function(&settings, light);
    fov_circle(&settings, seen, NULL, 0, 0, 4);
    if (!seen[4][5] || seen[4][6] || !seen[5][4]) return 4;
    puts("upstream Lua 5.1, SFMT repeatability and FOV occlusion: PASS");
    return 0;
}
