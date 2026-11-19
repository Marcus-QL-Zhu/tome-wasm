-- Data-only object graph codec. Trusted anchors are supplied by the host.
-- This module does not itself declare any game state saveable.
local json = require 'json_validate'
local M = {}
local function scalar(v)
    local t = type(v)
    return t == 'boolean' or t == 'string' or t == 'number'
end
function M.encode(root, anchors, limit, options)
    limit = limit or 30000
    options = options or {}
    local ids, nodes, queue = {}, json.array(), {}
    local function value(v)
        local t = type(v)
        if scalar(v) then
            if t == 'number' and (v~=v or v==math.huge or v==-math.huge) then error('nonfinite') end
            return json.array({'v',v})
        end
        local a = anchors[v]
        if a then return json.array({'a',a}) end
        if t ~= 'table' then
            local d = t=='function' and debug.getinfo(v,'S')
            error('unsupported graph value: '..t..(d and (' '..d.short_src..':'..d.linedefined) or ''))
        end
        local id=ids[v]
        if not id then
            id=#queue+1
            if id>limit then error('graph node limit') end
            ids[v]=id; queue[id]=v
        end
        return json.array({'r',id})
    end
    local start=value(root)
    local i=1
    while i<=#queue do
        local src=queue[i]
        local entries=json.array()
        for k,v in next,src do
            if not options.skip or not options.skip(src,k,v) then
                entries[#entries+1]=json.array({value(k),value(v)})
            end
        end
        local mt=not (options.skipmeta and options.skipmeta(src)) and debug.getmetatable(src)
        nodes[i]=json.object({entries=entries,meta=mt and value(mt) or json.null})
        i=i+1
    end
    return json.object({format='headless-graph-v1',root=start,nodes=nodes})
end
function M.decode(doc, anchors, limit)
    limit=limit or 30000
    if not json.isobject(doc) or doc.format~='headless-graph-v1' or not json.isarray(doc.nodes) or #doc.nodes>limit then error('invalid graph') end
    local tables={}
    for i=1,#doc.nodes do tables[i]={} end
    local function value(v)
        if not json.isarray(v) or #v~=2 then error('invalid graph value') end
        if v[1]=='v' and scalar(v[2]) then return v[2] end
        if v[1]=='r' and type(v[2])=='number' and v[2]==math.floor(v[2]) and tables[v[2]] then return tables[v[2]] end
        if v[1]=='a' and type(v[2])=='string' and anchors[v[2]]~=nil then return anchors[v[2]] end
        error('invalid graph reference')
    end
    for i,node in ipairs(doc.nodes) do
        if not json.isobject(node) or not json.isarray(node.entries) then error('invalid graph node') end
        for _,entry in ipairs(node.entries) do
            if not json.isarray(entry) or #entry~=2 then error('invalid graph entry') end
            local k,v=value(entry[1]),value(entry[2])
            if rawget(tables[i],k)~=nil then error('duplicate graph key') end
            rawset(tables[i],k,v)
        end
    end
    for i,node in ipairs(doc.nodes) do
        if node.meta~=json.null then
            local mt=value(node.meta)
            if type(mt)~='table' then error('invalid metatable') end
            setmetatable(tables[i],mt)
        end
    end
    return value(doc.root), tables
end
return M
