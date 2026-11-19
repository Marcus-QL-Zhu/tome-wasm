-- Strict JSON decoder for the private line protocol. Never evaluates input as code.
local M = {}
local null = {}
local object_mt, array_mt = {}, {}
M.null = null
function M.isobject(value) return type(value)=='table' and getmetatable(value)==object_mt end
function M.isarray(value) return type(value)=='table' and getmetatable(value)==array_mt end
function M.object(value) return setmetatable(value or {}, object_mt) end
function M.array(value) return setmetatable(value or {}, array_mt) end

function M.encode(value)
    local visiting = {}
    local chunks = {}
    local function emit(s) chunks[#chunks+1]=s end
    local function quote(s)
        return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
            local special = {['"']='\\"',['\\']='\\\\',['\b']='\\b',['\f']='\\f',['\n']='\\n',['\r']='\\r',['\t']='\\t'}
            return special[c] or string.format('\\u%04x', c:byte())
        end) .. '"'
    end
    local function enc(v, depth)
        if depth>64 then error('JSON nesting limit') end
        local t=type(v)
        if v==null then emit('null');return
        elseif t=='boolean' then emit(v and 'true' or 'false');return
        elseif t=='number' then
            if v~=v or v==math.huge or v==-math.huge then error('non-finite number') end
            emit(string.format('%.17g',v));return
        elseif t=='string' then
            if not v:find('[%z\1-\31\\"]') and not v:find('[\128-\255]') then
                if #v+2>83886080 then error('invalid UTF-8') end
                emit('"');emit(v);emit('"');return
            end
            local q=quote(v)
            if #q>83886080 or (v:find('[\128-\255]') and not M.decode(q)) then error('invalid UTF-8') end
            emit(q);return
        elseif t~='table' then error('unsupported JSON value') end
        if visiting[v] then error('cyclic JSON value') end
        visiting[v]=true
        if M.isarray(v) then
            local n=#v
            for k in pairs(v) do if type(k)~='number' or k~=math.floor(k) or k<1 or k>n then error('invalid array key') end end
            emit('[')
            for i=1,n do if v[i]==nil then error('sparse array') end; if i>1 then emit(',') end; enc(v[i],depth+1) end
            emit(']');visiting[v]=nil;return
        elseif M.isobject(v) then
            local keys={}; for k in pairs(v) do if type(k)~='string' then error('invalid object key') end; keys[#keys+1]=k end
            table.sort(keys)
            emit('{')
            for i,k in ipairs(keys) do if i>1 then emit(',') end;enc(k,depth+1);emit(':');enc(v[k],depth+1) end
            emit('}');visiting[v]=nil;return
        end
        error('JSON table requires explicit object or array')
    end
    enc(value,0)
    return table.concat(chunks)
end

function M.decode(s)
    local i, n, depth = 1, #s, 0
    if n > 83886080 then return nil, 'JSON exceeds size limit' end
    local k=1
    while k<=n do
        local b=s:byte(k); local width=1
        if b>=0x80 then
            if b>=0xc2 and b<=0xdf then width=2
            elseif b>=0xe0 and b<=0xef then width=3
            elseif b>=0xf0 and b<=0xf4 then width=4
            else return nil, 'invalid UTF-8' end
            local b2=s:byte(k+1)
            if not b2 or b2<0x80 or b2>0xbf or (b==0xe0 and b2<0xa0) or (b==0xed and b2>=0xa0) or (b==0xf0 and b2<0x90) or (b==0xf4 and b2>=0x90) then return nil, 'invalid UTF-8' end
            for j=2,width-1 do local x=s:byte(k+j); if not x or x<0x80 or x>0xbf then return nil, 'invalid UTF-8' end end
        end
        k=k+width
    end
    local function ws() while i <= n and s:sub(i,i):match('[ \t\r\n]') do i = i + 1 end end
    local function fail() error('invalid JSON', 0) end
    local function utf8(cp)
        if cp < 128 then return string.char(cp) end
        if cp < 2048 then return string.char(192+math.floor(cp/64),128+cp%64) end
        if cp < 65536 then return string.char(224+math.floor(cp/4096),128+math.floor(cp/64)%64,128+cp%64) end
        return string.char(240+math.floor(cp/262144),128+math.floor(cp/4096)%64,128+math.floor(cp/64)%64,128+cp%64)
    end
    local function str()
        if s:sub(i,i) ~= '"' then fail() end
        i=i+1
        local start=i;local out=nil
        while i<=n do
            local p=s:find('["\\%z\1-\31]',i)
            if not p then fail() end
            local c=s:sub(p,p)
            if c=='"' then
                local tail=s:sub(start,p-1);i=p+1
                if not out then return tail end
                out[#out+1]=tail;return table.concat(out)
            end
            if c~='\\' then fail() end
            if not out then out={} end
            out[#out+1]=s:sub(start,p-1)
            i=p+1;c=s:sub(i,i);i=i+1
            local simple = {['"']='"',['\\']='\\',['/']='/',b='\b',f='\f',n='\n',r='\r',t='\t'}
            if simple[c] then out[#out+1]=simple[c]
            elseif c=='u' then
                local h=s:sub(i,i+3);if #h~=4 or not h:match('^%x%x%x%x$') then fail() end
                i=i+4;local cp=tonumber(h,16)
                if cp>=0xd800 and cp<=0xdbff then
                    if s:sub(i,i+1)~='\\u' then fail() end
                    local lo=s:sub(i+2,i+5);if not lo:match('^%x%x%x%x$') then fail() end
                    lo=tonumber(lo,16);if lo<0xdc00 or lo>0xdfff then fail() end
                    i=i+6;cp=0x10000+(cp-0xd800)*1024+lo-0xdc00
                elseif cp>=0xdc00 and cp<=0xdfff then fail() end
                out[#out+1]=utf8(cp)
            else fail() end
            start=i
        end
        fail()
    end
    local value
    value = function()
        ws(); depth=depth+1; if depth>64 then fail() end
        local c=s:sub(i,i); local result
        if c=='"' then result=str()
        elseif c=='{' then
            i=i+1; ws(); result=setmetatable({}, object_mt); local keys={}
            if s:sub(i,i)~='}' then
                while true do
                    ws(); local k=str(); if keys[k] then fail() end; keys[k]=true
                    ws(); if s:sub(i,i)~=':' then fail() end; i=i+1; result[k]=value(); ws()
                    c=s:sub(i,i); i=i+1; if c=='}' then break elseif c~=',' then fail() end
                end
            else i=i+1 end
        elseif c=='[' then
            i=i+1; ws(); result=setmetatable({}, array_mt)
            if s:sub(i,i)~=']' then
                while true do result[#result+1]=value(); ws(); c=s:sub(i,i); i=i+1; if c==']' then break elseif c~=',' then fail() end end
            else i=i+1 end
        elseif s:sub(i,i+3)=='true' then i=i+4; result=true
        elseif s:sub(i,i+4)=='false' then i=i+5; result=false
        elseif s:sub(i,i+3)=='null' then i=i+4; result=null
        else
            local stop=s:find('[^%d%+%-%.eE]',i) or (n+1);if stop-i>128 then fail() end
            local sub=s:sub(i,stop-1); local num=sub:match('^-?%d+%.%d+[eE][+-]?%d+') or sub:match('^-?%d+[eE][+-]?%d+') or sub:match('^-?%d+%.%d+') or sub:match('^-?%d+')
            if not num or num:match('^-?0%d') then fail() end
            i=i+#num; result=tonumber(num); if not result or result==math.huge or result==-math.huge then fail() end
        end
        depth=depth-1; return result
    end
    local ok, result = pcall(value); if not ok then return nil, result end
    ws(); if i<=n then return nil, 'invalid JSON' end
    return result
end
return M
