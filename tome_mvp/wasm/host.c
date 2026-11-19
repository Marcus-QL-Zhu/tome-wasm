/* Request-driven Lua 5.1 host. One instance per Wasm module. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "physfs.h"
#include "aioo_source.inc"

extern int luaopen_fov(lua_State *L), luaopen_lpeg(lua_State *L), luaopen_bit(lua_State *L);
extern int luaopen_noise(lua_State *L);
extern int open_pure(lua_State *L);
extern int luaopen_native_serial(lua_State *L);
extern int luaopen_md5_core(lua_State *L), luaopen_mime_core(lua_State *L);
static const char *roots[]={"/bundle/headless","/bundle/generated","/bundle/tome","/bundle/engine","/bundle/thirdparty","/bundle/game"};
static lua_State *main_lua, *worker;
static char *result;
static int restart_requested;
static double restart_seed,restart_id,restart_generation;
static char restart_fixture[32];

static void set_result(const char *s, size_t n) {
    char *p=(char *)malloc(n+1);
    if (!p) { free(result); result=NULL; return; }
    memcpy(p,s,n); p[n]='\0'; free(result); result=p;
}
static int source(lua_State *L) { lua_pushlstring(L,(const char *)aioo_source,sizeof(aioo_source)); return 1; }
static int protocol_write(lua_State *L) {
    size_t n; const char *s=luaL_checklstring(L,1,&n);
    if (result) return luaL_error(L,"multiple protocol responses");
    set_result(s,n);
    if (!result) return luaL_error(L,"out of memory");
    return 0;
}
static int protocol_read(lua_State *L) { return lua_yield(L,0); }
static int protocol_restart(lua_State *L) {
    const char *f=luaL_checkstring(L,4);
    if (strcmp(f,"formal") && strcmp(f,"rescue") && strcmp(f,"standard") && strcmp(f,"skill_types") && strcmp(f,"ranged_policy") && strcmp(f,"exploration") && strcmp(f,"recovery") && strcmp(f,"exploration_complete")) return luaL_error(L,"invalid fixture");
    restart_seed=luaL_checknumber(L,1); restart_id=luaL_checknumber(L,2); restart_generation=luaL_checknumber(L,3);
    strcpy(restart_fixture,f); restart_requested=1; return 0;
}
PHYSFS_File *PHYSFS_openRead(const char *name) {
    char full[4096]; const char *dot; size_t i;
    if (!name) return NULL;
    while (*name=='/') name++;
    dot=strrchr(name,'.');
    if (!dot || strcmp(dot,".lua") || strstr(name,"..") || strchr(name,':') || strchr(name,'\\')) return NULL;
    for (i=0;i<sizeof(roots)/sizeof(roots[0]);i++) {
        FILE *f;
        if (snprintf(full,sizeof(full),"%s/%s",roots[i],name)>=(int)sizeof(full)) continue;
        f=fopen(full,"rb"); if (f) return (PHYSFS_File *)f;
    }
    return NULL;
}
int PHYSFS_eof(PHYSFS_File *f) { return feof((FILE *)f); }
int PHYSFS_close(PHYSFS_File *f) { return !fclose((FILE *)f); }
PHYSFS_sint64 PHYSFS_read(PHYSFS_File *f,void *data,PHYSFS_uint32 size,PHYSFS_uint32 count) { return fread(data,size,count,(FILE *)f); }
static int start_worker(int restarting) {
    int rc;
    main_lua=luaL_newstate(); if (!main_lua) return -1;
    luaL_openlibs(main_lua);
    lua_pushcfunction(main_lua,protocol_write); lua_setglobal(main_lua,"protocol_write");
    lua_pushcfunction(main_lua,protocol_read); lua_setglobal(main_lua,"protocol_read");
    lua_pushcfunction(main_lua,protocol_restart); lua_setglobal(main_lua,"protocol_restart");
    lua_pushcfunction(main_lua,source); lua_setglobal(main_lua,"headless_aioo_source");
    lua_pushnumber(main_lua,20); lua_setglobal(main_lua,"TOME_SCENE_SIZE");
    if (restarting) {
        lua_pushnumber(main_lua,restart_seed); lua_setglobal(main_lua,"restart_seed");
        lua_pushnumber(main_lua,restart_id); lua_setglobal(main_lua,"restart_id");
        lua_pushnumber(main_lua,restart_generation); lua_setglobal(main_lua,"restart_generation");
        lua_pushstring(main_lua,restart_fixture); lua_setglobal(main_lua,"restart_fixture");
    }
    open_pure(main_lua); luaopen_native_serial(main_lua); lua_settop(main_lua,0); luaopen_fov(main_lua); lua_settop(main_lua,0);
    luaopen_noise(main_lua); lua_settop(main_lua,0);
    luaopen_bit(main_lua); lua_settop(main_lua,0); luaopen_lpeg(main_lua); lua_settop(main_lua,0);
    luaopen_md5_core(main_lua); lua_settop(main_lua,0); luaopen_mime_core(main_lua); lua_settop(main_lua,0);
    worker=lua_newthread(main_lua); /* anchored on main stack */
    rc=luaL_loadfile(worker,"/worker.lua");
    if (!rc) rc=lua_resume(worker,0);
    if (rc!=LUA_YIELD) {
        const char *err=lua_tostring(worker,-1); if (err) set_result(err,strlen(err));
        return -1;
    }
    return 0;
}
void tome_free(void) { if (main_lua) lua_close(main_lua); main_lua=worker=NULL; free(result); result=NULL; restart_requested=0; }
int tome_init(void) { tome_free(); return start_worker(0); }
const char *tome_result(void) { return result ? result : ""; }
int tome_request(const char *json) {
    int rc; size_t n;
    if (!worker || !json) return -1;
    free(result); result=NULL; n=strlen(json);
    lua_pushlstring(worker,json,n>83886080 ? 83886080 : n); lua_pushboolean(worker,n>83886080);
    rc=lua_resume(worker,2);
    if (rc==0 && restart_requested) {
        lua_close(main_lua); main_lua=worker=NULL; restart_requested=0;
        if (start_worker(1)) return -1;
        return result ? 0 : -1;
    }
    if (rc!=LUA_YIELD) {
        const char *err=lua_tostring(worker,-1); if (err) set_result(err,strlen(err));
        return -1;
    }
    return result ? 0 : -1;
}
