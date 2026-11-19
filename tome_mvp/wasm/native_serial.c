/*
    TE4 - T-Engine 4
    Copyright (C) 2009 - 2018 Nicolas Casalini

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

    Nicolas Casalini "DarkGod"
    darkgod@te4.org
*/
/* Original serial.c table serialization adapted to synchronous in-memory sink.
 * Experimental only: no snapshot RPC or complete restoration is provided. */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include "lua.h"
#include "lauxlib.h"
#include "auxiliar.h"
typedef struct { char *buf; long bufpos, buflen; int fname, fadd, allow, disallow, disallow2, depth; lua_State *L; } serial_type;
static int serial_new(lua_State *L) {
    luaL_checktype(L, 2, LUA_TFUNCTION); luaL_checktype(L, 3, LUA_TFUNCTION);
    if (!lua_isnil(L,4)) luaL_checktype(L,4,LUA_TTABLE);
    if (!lua_isnil(L,5)) luaL_checktype(L,5,LUA_TTABLE);
    if (!lua_isnil(L,6)) luaL_checktype(L,6,LUA_TTABLE);
    int d2=luaL_ref(L,LUA_REGISTRYINDEX), d=luaL_ref(L,LUA_REGISTRYINDEX), a=luaL_ref(L,LUA_REGISTRYINDEX);
    int fadd=luaL_ref(L,LUA_REGISTRYINDEX), fname=luaL_ref(L,LUA_REGISTRYINDEX);
    serial_type *s=(serial_type *)lua_newuserdata(L,sizeof(*s)); memset(s,0,sizeof(*s));
    auxiliar_setclass(L,"core{serial}",-1);
    s->L=L; s->fname=fname; s->fadd=fadd; s->allow=a; s->disallow=d; s->disallow2=d2;
    return 1;
}
static int serial_free(lua_State *L)
{
	serial_type *s = (serial_type*)auxiliar_checkclass(L, "core{serial}", 1);
    free(s->buf); s->buf = NULL;
	luaL_unref(L, LUA_REGISTRYINDEX, s->fname);
	luaL_unref(L, LUA_REGISTRYINDEX, s->fadd);
	luaL_unref(L, LUA_REGISTRYINDEX, s->allow);
	luaL_unref(L, LUA_REGISTRYINDEX, s->disallow);
	luaL_unref(L, LUA_REGISTRYINDEX, s->disallow2);
	lua_pushnumber(L, 1);
	return 1;
}

static const char *get_name(lua_State *L, serial_type *s, int idx)
{
	lua_rawgeti(L, LUA_REGISTRYINDEX, s->fname);
	lua_pushvalue(L, idx - 1);
	lua_call(L, 1, 1);
	const char *name = lua_tostring(L, -1);
	lua_pop(L, 1);
	return name;
}

static void add_process(lua_State *L, serial_type *s, int idx)
{
	lua_rawgeti(L, LUA_REGISTRYINDEX, s->fadd);
	lua_pushvalue(L, idx - 1);
	lua_call(L, 1, 0);
}

static void writeTblFixed(serial_type *s, const char *data, long len) {
    if (len < 0 || len > 67108864L - s->bufpos) luaL_error(s->L, "native serial chunk too large");
	if (len + s->bufpos >= s->buflen) {
        long size = s->buflen;
        while (len + s->bufpos >= size) size *= 2;
        char *newbuf = realloc(s->buf, size);
        if (!newbuf) luaL_error(s->L, "native serial out of memory");
        s->buf = newbuf; s->buflen = size;
    }
	memcpy(s->buf + s->bufpos, data, len);
	s->bufpos += len;
}
#define writeTbl(s, data) { writeTblFixed(s, data, strlen(data)); }

static void tbl_dump_string(serial_type *s, const char *str, size_t l)
{
	while (l--) {
		switch (*str) {
		case '"': case '\\': case '\n': {
			writeTblFixed(s, "\\", 1);
			writeTblFixed(s, str, 1);
			break;
		}
		case '\r': {
			writeTblFixed(s, "\\r", 2);
			break;
		}
		case '\0': {
			writeTblFixed(s, "\\000", 4);
			break;
		}
		default: {
			writeTblFixed(s, str, 1);
			break;
		}
		}
		str++;
	}
}

static int tbl_dump_function(lua_State *L, const void* p, size_t sz, void* ud)
{
	serial_type *s = (serial_type*)ud;
//	fwrite(p, sz, 1, stdout);
//	zipWriteInFileInZip(s->zf, p, sz);
	tbl_dump_string(s, p, sz);
	return 0;
}

static void tbl_basic_serialize(lua_State *L, serial_type *s, int type, int idx)
{
    if (++s->depth > 128) luaL_error(L, "native serial nesting limit or cycle");
	if (type == LUA_TBOOLEAN) {
		if (lua_toboolean(L, idx)) { writeTblFixed(s, "true", 4); }
		else { writeTblFixed(s, "false", 5); }
	} else if (type == LUA_TNUMBER) {
        /* Lua 5.1 tostring rounds doubles; save enough digits to restore the
         * exact native value and keep deterministic post-load trajectories. */
        if (!isfinite((double)lua_tonumber(L, idx))) luaL_error(L, "non-finite saved number");
        char number[64];
        int len = snprintf(number, sizeof(number), "%.17g", (double)lua_tonumber(L, idx));
        if (len <= 0 || len >= (int)sizeof(number)) luaL_error(L, "invalid saved number");
        writeTblFixed(s, number, len);
	} else if (type == LUA_TSTRING) {
		size_t len;
		const char *str = lua_tolstring(L, idx, &len);
		writeTblFixed(s, "\"", 1);
		tbl_dump_string(s, str, len);
		writeTblFixed(s, "\"", 1);
	} else if (type == LUA_TFUNCTION) {
        lua_getglobal(L, "native_serial_classify_function");
        if (lua_isfunction(L, -1)) {
            char suffix[48];
            lua_pushvalue(L, idx - 1);
            lua_call(L, 1, 2);
            lua_Integer env_id=luaL_checkinteger(L, -2);
            lua_Integer function_id=luaL_checkinteger(L, -1);
            lua_pop(L, 2);
            if (env_id < 0 || function_id < 1) luaL_error(L, "invalid native function identity");
            lua_getglobal(L, "native_serial_partition_function_reference");
            int partition_function_ref=lua_toboolean(L,-1);lua_pop(L,1);
            if (partition_function_ref) {
                snprintf(suffix,sizeof(suffix),"loadFunctionRef(%ld)",(long)function_id);
                writeTbl(s,suffix);
            } else {
                writeTblFixed(s, "loadFunction(\"", 14);
                lua_pushvalue(L, idx);
                if (lua_dump(L, tbl_dump_function, s)) luaL_error(L, "cannot dump native function");
                lua_pop(L, 1);
                snprintf(suffix, sizeof(suffix), "\",%ld,%ld)", (long)env_id, (long)function_id);
                writeTbl(s, suffix);
            }
        } else {
            lua_pop(L, 1);
            writeTblFixed(s, "loadstring(\"", 12);
            lua_pushvalue(L, idx);
            if (lua_dump(L, tbl_dump_function, s)) luaL_error(L, "cannot dump native function");
            lua_pop(L, 1);
            writeTblFixed(s, "\")", 2);
        }
	} else if (type == LUA_TTABLE) {
		lua_pushstring(L, "__CLASSNAME");
		lua_rawget(L, idx - 1);
		// This is an object, register for saving later
		if (!lua_isnil(L, -1))
		{
			lua_pop(L, 1);
			writeTblFixed(s, "loadObject('", 12);
			writeTbl(s, get_name(L, s, idx));
			writeTblFixed(s, "')", 2);
			add_process(L, s, idx);
		}
		// This is just a table, save it
		else
		{
            lua_pop(L, 1);
            lua_getglobal(L, "native_serial_plain_reference");
            int reference_plain = lua_toboolean(L, -1);
            lua_pop(L, 1);
            if (reference_plain) {
                writeTblFixed(s, "loadTable('", 11);
                writeTbl(s, get_name(L, s, idx));
                writeTblFixed(s, "')", 2);
                add_process(L, s, idx);
            } else {
            int ktype, etype;

			writeTblFixed(s, "{", 1);
			/* table is in the stack at index 't' */
			lua_pushnil(L);  /* first key */

			while (lua_next(L, idx - 1) != 0)
			{
				ktype = lua_type(L, -2);
				etype = lua_type(L, -1);

				// Only save allowed types
				if (
					((ktype == LUA_TBOOLEAN) || (ktype == LUA_TNUMBER) || (ktype == LUA_TSTRING) || (ktype == LUA_TFUNCTION) || (ktype == LUA_TTABLE)) &&
					((etype == LUA_TBOOLEAN) || (etype == LUA_TNUMBER) || (etype == LUA_TSTRING) || (etype == LUA_TFUNCTION) || (etype == LUA_TTABLE))
					)
				{
					writeTblFixed(s, "[", 1);
					tbl_basic_serialize(L, s, ktype, -2);
					writeTblFixed(s, "]=", 2);
					tbl_basic_serialize(L, s, etype, -1);
					writeTblFixed(s, ",\n", 2);
				}

				/* removes 'value'; keeps 'key' for next iteration */
				lua_pop(L, 1);
			}
			writeTblFixed(s, "}\n", 2);
            }
		}
	} else {
        luaL_error(L, "unsupported native serial type %s", lua_typename(L, type));
	}
    --s->depth;
}

static int serial_tozip(lua_State *L)
{
	serial_type *s = (serial_type*)auxiliar_checkclass(L, "core{serial}", 1);

	int ktype, etype;
	int skip;

	/* Allows & disallows */
	lua_rawgeti(L, LUA_REGISTRYINDEX, s->allow);     // -5
	lua_rawgeti(L, LUA_REGISTRYINDEX, s->disallow);  // -4
	lua_rawgeti(L, LUA_REGISTRYINDEX, s->disallow2); // -3

	/* table is in the stack at index 't' */
	lua_pushvalue(L, 2);  /* table */
	lua_pushnil(L);  /* first key */

	const char *filename = get_name(L, s, -2);

	/* Init the buffer */
	s->buf = malloc(2 * 1024);
	s->buflen = 2 * 1024;
	s->bufpos = 0;

	writeTblFixed(s, "d={}\n", 5);
	writeTblFixed(s, "setLoaded('", 11);
	writeTbl(s, get_name(L, s, -2));
	writeTblFixed(s, "', d)\n", 6);
	while (lua_next(L, -2) != 0)
	{
		skip = 0;
		ktype = lua_type(L, -2);
		etype = lua_type(L, -1);

		if (s->allow != LUA_REFNIL)
		{
			lua_pushvalue(L, -2); lua_rawget(L, -7);
			skip = lua_isnil(L, -1); lua_pop(L, 1);
		}
		else if (s->disallow != LUA_REFNIL)
		{
			lua_pushvalue(L, -2); lua_rawget(L, -6);
			skip = !lua_isnil(L, -1); lua_pop(L, 1);
		}
		if (s->disallow2 != LUA_REFNIL)
		{
			lua_pushvalue(L, -2); lua_rawget(L, -5);
			skip = skip || !lua_isnil(L, -1); lua_pop(L, 1);
		}

        if (!skip) {
            lua_getglobal(L, "native_serial_filter_entry");
            if (lua_isfunction(L, -1)) {
                lua_pushvalue(L, -4); /* containing table */
                lua_pushvalue(L, -4); /* key */
                lua_pushvalue(L, -4); /* value */
                lua_call(L, 3, 1);
                skip = lua_toboolean(L, -1);
                lua_pop(L, 1);
            } else lua_pop(L, 1);
        }
		if (!skip)
		{
			writeTblFixed(s, "d[", 2);
			tbl_basic_serialize(L, s, ktype, -2);
			writeTblFixed(s, "]=", 2);
			tbl_basic_serialize(L, s, etype, -1);
			writeTblFixed(s, "\n", 1);
		}

		/* removes 'value'; keeps 'key' for next iteration */
		lua_pop(L, 1);
	}
	writeTblFixed(s, "\nreturn d", 9);

	lua_getglobal(L, "native_serial_emit");
    if (!lua_isfunction(L, -1)) return luaL_error(L, "native_serial_emit missing");
    lua_pushstring(L, filename);
    lua_pushlstring(L, s->buf, s->bufpos);
    free(s->buf); s->buf = NULL;
    lua_call(L, 2, 0);

	lua_pushboolean(L, 1);
	return 1;
}


static const struct luaL_Reg seriallib[]={{"new",serial_new},{NULL,NULL}};
static const struct luaL_Reg serial_reg[]={{"__gc",serial_free},{"toZip",serial_tozip},{NULL,NULL}};
int luaopen_native_serial(lua_State *L) {
    auxiliar_newclass(L,"core{serial}",serial_reg);
    luaL_openlib(L,"core.serial",seriallib,0); lua_pop(L,1); return 1;
}
