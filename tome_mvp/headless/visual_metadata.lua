local json=require 'json_validate'
local M={}
local function path(prefix,value)
 if type(value)~='string' or value=='' or value:find('..',1,true) or value:find('\\',1,true) or value:find(':',1,true) or value:sub(1,1)=='/' or not value:match('%.png$') then return nil end
 return prefix..value
end
function M.icon(value) return path('data/gfx/',value) end
function M.terrain(grid)
 local info={image=path('data/gfx/shockbolt/',grid and grid.image),glyph=grid and grid.display or ' ',layers={}}
 for _,field in ipairs({'add_mos','add_displays'}) do
  for _,layer in ipairs(grid and grid[field] or {}) do
   local image=path('data/gfx/shockbolt/',layer.image)
   if image then
    local row={image=image}
    for _,key in ipairs({'z','display_x','display_y','display_w','display_h'}) do if type(layer[key])=='number' then row[key]=layer[key] end end
    info.layers[#info.layers+1]=row
   end
  end
 end
 return info
end
function M.terrain_json(info,seen)
 local layers=json.array()
 for _,layer in ipairs(info.layers or {}) do layers[#layers+1]=json.object(layer) end
 return json.object({image=info.image or json.null,layers=layers,seen=seen and true or false})
end
function M.actor(actor,is_party)
 local display=actor.replace_display or actor
 local image=path('data/gfx/shockbolt/',display.image)
 local layers=json.array()
 if not actor.encounter_portrait then
  for _,layer in ipairs(display.add_mos or {}) do
   local png=path('data/gfx/shockbolt/',layer.image)
   if png then
    local item={image=png,auto_tall=not not layer.auto_tall}
    for _,key in ipairs({'display_x','display_y','display_w','display_h'}) do if type(layer[key])=='number' then item[key]=layer[key] end end
    layers[#layers+1]=json.object(item)
   end
  end
 end
 local out={image=actor.encounter_portrait or image or json.null,kind=actor.encounter_portrait and 'injected' or 'native',layers=layers,
  moddable_tile=type(display.moddable_tile)=='string' and display.moddable_tile or json.null,sex=actor.female and 'female' or 'male'}
 for _,key in ipairs({'display_x','display_y','display_w','display_h'}) do if type(display[key])=='number' then out[key]=display[key] end end
 return json.object(out)
end
return M
