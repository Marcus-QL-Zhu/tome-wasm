/* Bounded SFMT19937 and Box-Muller state. No world state is implied. */
extern int headless_sfmt_export(uint32_t *, int *);
extern int headless_sfmt_import(const uint32_t *, int, int);
static int rng_state_get(lua_State *L) {
    uint32_t words[624]; int i, index;
    if (headless_sfmt_export(words, &index) != 624) return luaL_error(L,"uninitialized SFMT");
    lua_newtable(L);
    lua_pushliteral(L,"sfmt19937-v1"); lua_setfield(L,-2,"format");
    lua_pushinteger(L,index); lua_setfield(L,-2,"index");
    lua_pushboolean(L,stored); lua_setfield(L,-2,"stored");
    lua_pushnumber(L,z1); lua_setfield(L,-2,"normal_spare");
    lua_createtable(L,624,0);
    for (i=0;i<624;i++) { lua_pushnumber(L,(double)words[i]); lua_rawseti(L,-2,i+1); }
    lua_setfield(L,-2,"words");
    return 1;
}
static int rng_state_set(lua_State *L) {
    uint32_t words[624]; int i, index, spare, nonzero=0; double n, normal;
    luaL_checktype(L,1,LUA_TTABLE);
    lua_getfield(L,1,"format");
    if (!lua_isstring(L,-1) || strcmp(lua_tostring(L,-1),"sfmt19937-v1")) return luaL_error(L,"invalid RNG format");
    lua_pop(L,1);
    lua_getfield(L,1,"index"); n=luaL_checknumber(L,-1);
    if (n<0 || n>624 || n!=floor(n)) return luaL_error(L,"invalid RNG index");
    index=(int)n; lua_pop(L,1);
    lua_getfield(L,1,"stored"); if (!lua_isboolean(L,-1)) return luaL_error(L,"invalid RNG spare flag");
    spare=lua_toboolean(L,-1); lua_pop(L,1);
    lua_getfield(L,1,"normal_spare"); normal=luaL_checknumber(L,-1);
    if (normal!=normal || normal>1e308 || normal< -1e308) return luaL_error(L,"invalid RNG spare");
    lua_pop(L,1);
    lua_getfield(L,1,"words"); luaL_checktype(L,-1,LUA_TTABLE);
    if (lua_objlen(L,-1)!=624) return luaL_error(L,"invalid RNG word count");
    for (i=0;i<624;i++) {
        lua_rawgeti(L,-1,i+1); n=luaL_checknumber(L,-1);
        if (n<0 || n>4294967295.0 || n!=floor(n)) return luaL_error(L,"invalid RNG word");
        words[i]=(uint32_t)n; if (words[i]) nonzero=1; lua_pop(L,1);
    }
    if (!nonzero) return luaL_error(L,"invalid all-zero RNG state");
    if (!headless_sfmt_import(words,624,index)) return luaL_error(L,"invalid SFMT state");
    stored=spare; z1=normal; return 0;
}
