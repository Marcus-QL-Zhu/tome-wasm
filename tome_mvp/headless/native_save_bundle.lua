-- Opaque transport for one native partition. It encodes original native
-- serialization fragments, never actor fields. SHA-256 is computed by the
-- trusted host over the decoded UTF-8 bytes.
local json=require 'json_validate'
local mime=assert(_G.mime,'native MIME module missing')
local M={}
local LIMIT=64*1024*1024
local function b64(s)assert(type(s)=='string');if s=='' then return '' end;return assert(mime.b64(s,nil))end
local function unb64(s)
 assert(type(s)=='string' and #s<=LIMIT*2,'invalid partition encoding')
 if s=='' then return '' end
 local decoded=assert(mime.unb64(s,nil),'invalid partition base64')
 assert(b64(decoded)==s,'noncanonical partition base64')
 return decoded
end
local function dict(t)
 local o=json.object({});for k,v in pairs(t or {})do assert(type(k)=='string');o[k]=v end;return o
end
local function descriptor(x)
 assert(type(x)=='table','bad weak descriptor')
 if x.ref~=nil then assert(type(x.ref)=='string' and x.value==nil);return json.object({ref=x.ref})end
 local v=x.value;assert(type(v)=='boolean' or type(v)=='number' or type(v)=='string','bad weak value')
 return json.object({value=v})
end
-- Clone only JSON metadata; strings are immutable and may be shared safely.
-- Do not retain the source serialization context or any native object.
local function snapshot_json(value,active,depth)
 local t=type(value)
 if value==json.null then return json.null end
 if t~='table' then assert(t=='string' or t=='number' or t=='boolean','invalid provider metadata');return value end
 assert(depth<=64 and not active[value],'cyclic provider metadata');active[value]=true
 local out
 if json.isarray(value) then out=json.array();for i,v in ipairs(value)do out[i]=snapshot_json(v,active,depth+1)end
 elseif json.isobject(value) then out=json.object();for k,v in pairs(value)do assert(type(k)=='string');out[k]=snapshot_json(v,active,depth+1)end
 else error('non-JSON provider metadata') end
 active[value]=nil;return out
end
local function clone_json(v)return snapshot_json(v,{},0)end
function M.encode(owner,part,function_env,retain_provider)
 assert(type(owner)=='string' and #owner>0 and type(part)=='table' and type(part.root_ref)=='string','invalid partition')
 local fragments=json.object({});for ref,payload in pairs(part.fragments or {})do fragments[ref]=b64(payload)end
 local function anchor(a)return json.object({kind=a.kind,key=a.key,path=a.path,witness=b64(a.witness)})end
 local functions=json.object({});for ref,f in pairs(part.functions or {})do functions[ref]=json.object({code=b64(f.code),env=f.env,anchor=f.anchor and anchor(f.anchor) or nil})end
 local anchors=json.object({});for ref,a in pairs(part.anchors or {})do anchors[ref]=anchor(a)end
 local refs=json.array({});for ref,v in pairs(part.strong_refs or {})do assert(v==true);refs[#refs+1]=ref end;table.sort(refs)
 local weak=json.array({});for _,e in ipairs(part.weak_edges or {})do
  weak[#weak+1]=json.object({parent=e.parent,key=descriptor(e.key),value=descriptor(e.value),key_weak=e.key_weak,value_weak=e.value_weak})
 end
 local body=json.object({format='tome-native-partition-v1',owner=owner,root_ref=part.root_ref,
  fragments=fragments,functions=functions,modes=dict(part.modes),anchors=anchors,orders=part.orders or json.object(),weak_edges=weak,strong_refs=refs})
 if function_env then body.function_env=function_env end
 local bytes=json.encode(body);assert(#bytes<=LIMIT,'native partition exceeds size limit')
 local provider
 if retain_provider then
  local raw_fragments=json.object();for ref,payload in pairs(part.fragments or {})do raw_fragments[ref]=payload end
  local raw_functions=json.object();for ref,f in pairs(part.functions or {})do
   local a=f.anchor and json.object({kind=f.anchor.kind,key=f.anchor.key,path=f.anchor.path,witness=f.anchor.witness}) or nil
   raw_functions[ref]=json.object({code=f.code,env=f.env,anchor=a})
  end
  local raw_anchors=json.object();for ref,a in pairs(part.anchors or {})do raw_anchors[ref]=json.object({kind=a.kind,key=a.key,path=a.path,witness=a.witness})end
  local raw_modes=json.object();for ref,mode in pairs(part.modes or {})do raw_modes[ref]=mode end
  provider=json.object({format='tome-native-partition-v1',owner=owner,root_ref=part.root_ref,
   fragments=raw_fragments,functions=raw_functions,modes=raw_modes,anchors=raw_anchors,
   orders=clone_json(body.orders),weak_edges=clone_json(weak),strong_refs=clone_json(refs)})
  if function_env then provider.function_env=clone_json(function_env) end
 end
 return {partition_id=owner,root_ref=part.root_ref,strong_refs=refs,payload_base64=b64(bytes),bytes=#bytes},provider
end
function M.decode(owner,encoded)
 local bytes=unb64(encoded);assert(#bytes<=LIMIT,'native partition exceeds size limit')
 local d=assert(json.decode(bytes),'invalid native partition')
 assert(json.isobject(d) and d.format=='tome-native-partition-v1' and d.owner==owner and type(d.root_ref)=='string' and json.isobject(d.fragments) and json.isobject(d.functions) and json.isobject(d.modes) and json.isarray(d.weak_edges) and json.isarray(d.strong_refs),'invalid native partition header')
 local seen={}
 for _,ref in ipairs(d.strong_refs)do assert(type(ref)=='string' and not seen[ref],'invalid partition reference');seen[ref]=true end
 for ref,payload in pairs(d.fragments)do assert(type(ref)=='string');d.fragments[ref]=unb64(payload)end
 local function decode_anchor(a)assert(json.isobject(a) and type(a.kind)=='string' and type(a.key)=='string' and type(a.path)=='string');a.witness=unb64(a.witness)end
 d.anchors=d.anchors or json.object();assert(json.isobject(d.anchors),'invalid native catalog anchors')
 d.orders=d.orders or json.object();assert(json.isobject(d.orders),'invalid native source-order manifest')
 for ref,keys in pairs(d.orders)do assert(type(ref)=='string' and json.isarray(keys) and d.fragments[ref]~=nil and not d.anchors[ref],'invalid native source order')end
 for ref,a in pairs(d.anchors)do assert(type(ref)=='string');decode_anchor(a)end
 for ref,f in pairs(d.functions)do assert(type(ref)=='string' and json.isobject(f) and type(f.env)=='number');f.code=unb64(f.code);if f.anchor then decode_anchor(f.anchor)end;assert((f.code=='')==not not f.anchor,'invalid anchored native function')end
 for ref,payload in pairs(d.fragments)do assert((payload=='')==not not d.anchors[ref],'invalid anchored native fragment')end
 for ref in pairs(d.anchors)do assert(d.fragments[ref]=='','orphan native catalog anchor')end
 return d
end
return M
