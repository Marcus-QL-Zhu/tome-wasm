-- Replace desktop widgets, not native dialog filters, choices, or callbacks.
local M={}
local function noop()end
local font={size=function(_,text)return #tostring(text or ''),16 end,lineSkip=function()return 16 end}
local function key()
 return {binds={},commands={},setCurrent=noop,unicodeInput=noop,
  reset=function(self)self.binds={};self.commands={} end,addBind=function(self,k,v)self.binds[k]=v end,addCommand=function(self,k,v)self.commands[k]=v end,
  triggerVirtual=function(self,k)if self.binds[k] then return self.binds[k]() end end,
  addBinds=function(self,t)for k,v in pairs(t)do self.binds[k]=v end end,
  addCommands=function(self,t)for k,v in pairs(t)do self.commands[k]=v end end}
end
local widget={}
function widget:setList(list)self.list=list;self.sel=1 end
function widget:setTree(tree)self.tree=tree;self.sel=1 end
function widget:setText(text)self.text=text end
function widget:getText()return self.text end
function widget:switchItem(item,desc)self.item=item;self.text=desc end
function widget:drawItem()end
function widget:generate()end
function widget:onSelect()end
function widget:setFocus()end
function widget:generateList()end
function widget:redrawAllItems()end
function widget:updateTooltip()end
function widget:onExpand(item,inc)if self.on_expand then self.on_expand(item,inc) end end
function widget:setTextColor(text)self.text=text end
local function new_widget(opts)
 opts=opts or {};opts.w=opts.width or opts.size or 1;opts.h=opts.height or 16;opts.sel=1;opts.font=font;opts.font_h=16
 return setmetatable(opts,{__index=widget})
end
local function dialog_choices(d)
 local choices={}
 local function add(list,ui,prefix)
  for index,row in ipairs(list or {}) do
   if row.nodes then add(row.nodes,ui,prefix)
   else choices[#choices+1]={object=row.object,label=(prefix or '')..tostring(row.name or row.title or row.text or row.id or ''),run=function()
    if row.fct then
     if ui.__native_kind=='TreeList' then return row.fct(row,index,'left')
     elseif ui.__native_kind=='VariableList' then return row:fct('left','key')
     else return row:fct(row,index,'left') end
    end
    if ui.fct then return ui.fct(row,index,'left',ui.__native_kind=='VariableList' and 'key' or nil) end
    error('native dialog has no choice callback')
   end} end
  end
 end
 for _,entry in ipairs(d.uis or {}) do
  local ui=entry.ui
  if entry.hidden then
   -- Preserve the native dialog's hidden UI state.
  elseif ui and ui.__native_kind=='Tab' then
   choices[#choices+1]={label=tostring(ui.title or ui.text or ''),run=function()ui.selected=true;if ui.on_change then return ui.on_change(true) end end}
  elseif ui and ui.__native_kind=='EquipDoll' then
   for _,entry in ipairs(ui.uis or {}) do local frame=entry.ui;local o=frame:getItem()
    if o then choices[#choices+1]={label=tostring(frame.inven.name)..': '..tostring(o:getName()),run=function()return frame.fct('left','key') end} end
   end
  elseif ui and ui.__native_kind=='TalentTrees' then
   local function add_tree(list)
    for _,row in ipairs(list or {}) do
     if row.type or row.stat or row.talent then
      local value=row.rawname or row.name or row.type or ''; if type(value)=='function' then value=value(row) end
      local label=tostring(value)
      for _,inc in ipairs({true,false}) do choices[#choices+1]={label=(inc and '+ ' or '- ')..label,run=function()return ui.on_use(row,inc) end} end
     end
     if row.nodes then add_tree(row.nodes) end
    end
   end
   add_tree(ui.tree)
  elseif ui and ui.fct and ui.can_focus~=false and not ui.only_display and not ui.disabled then
   if ui.tree or ui.list then add(ui.tree or ui.list,ui)
   elseif ui.text then choices[#choices+1]={label=tostring(ui.text),run=ui.fct} end
  end
 end
 if d.__CLASSNAME=='mod.dialogs.ShowEquipInven' or d.__CLASSNAME=='mod.dialogs.ShowInventory' then choices[#choices+1]={label='Close',run=function()return d.key:triggerVirtual('EXIT') end} end
 if d.__CLASSNAME=='mod.dialogs.LevelupDialog' then choices[#choices+1]={label='Finish / close',run=function()return d.key:triggerVirtual('EXIT') end} end
 return choices
end
function M.install(Game,inputs)
 if M.installed then return end;M.installed=true
 local Dialog=require 'engine.ui.Dialog'
 local Entity=require 'engine.Entity';local mapObjects=Entity.getMapObjects
 Entity.getMapObjects=function(self,tiles,...)if tiles and tiles.__headless_dialog then return {} end return mapObjects(self,tiles,...)end
 Dialog.init=function(self,title,w,h)
  self.title=title;self.w=w;self.h=h;self.iw=w;self.ih=h;self.ix=0;self.iy=0;self.font=font;self.font_bold=font;self.font_h=16;self.key=key();self.uis={}
 end
 Dialog.font=font;Dialog.font_bold=font;Dialog.font_h=16
 Dialog.generate=noop;Dialog.updateTitle=function(self,title)self.title=title end;Dialog.toggleDisplay=function(self,ui,show)for _,entry in ipairs(self.uis or {}) do if entry.ui==ui then entry.hidden=not show end end end
 Dialog.loadUI=function(self,t)if t.no_reset then for _,v in ipairs(t)do self.uis[#self.uis+1]=v end else self.uis=t end end
 Dialog.setupUI=noop;Dialog.setFocus=function(self,ui)self.focus=ui end;Dialog.cleanup=noop
 for _,name in ipairs({'TreeList','ListColumns','VariableList','Textzone','TextzoneList','Separator','List','Button','Checkbox','Textbox','Numberbox','Empty','UIContainer','Tab'}) do
  local kind=name
  local constructor=function(opts)local w=new_widget(opts);w.__native_kind=kind;return w end
  local loaded=package.loaded['engine.ui.'..name]
  if type(loaded)=='table' then loaded.new=constructor else package.loaded['engine.ui.'..name]={new=constructor} end
 end
 for _,entry in ipairs({{'mod.dialogs.elements.TalentTrees','TalentTrees'},{'mod.dialogs.elements.StatusBox','StatusBox'}}) do
  local cls=require(entry[1]); local kind=entry[2]
  cls.new=function(opts)local w=new_widget(opts);w.__native_kind=kind;return w end
 end
 local Frame=require 'engine.ui.EquipDollFrame'
 Frame.new=function(opts)opts.mouse={};return setmetatable(opts,{__index=Frame}) end
 local EquipDoll=require 'engine.ui.EquipDoll'
 EquipDoll.new=function(opts)
  local w=new_widget(opts);w.__native_kind='EquipDoll';w.base_doll_y=0
  local doll=opts.equipdoll or opts.actor.equipdoll or 'default';if type(doll)=='string' then doll=opts.actor.equipdolls[doll] end
  w.equipdoll=assert(doll,'missing native equipdoll');w.makeKeyChar=EquipDoll.makeKeyChar;w.setFocus=noop
  EquipDoll.generateEquipDollFrames(w);return w
 end
 local ShowEquip=require 'mod.dialogs.ShowEquipInven'
 local initShow=ShowEquip.init
 ShowEquip.init=function(self,...)game.tooltip=game.tooltip or {empty=true,locked=false,max=0};return initShow(self,...)end
 local Inventory=require 'engine.ui.Inventory'
 local generateInventory=Inventory.generateList
 Inventory.init=function(self,t)
  for k,v in pairs(t)do self[k]=v end
  self.w=t.width;self.h=t.height;self.font=font;self.font_bold=font;self.font_h=16;self.key=key();self.uis={}
  self.c_inven=new_widget{fct=t.fct};self:generateList()
 end
 Inventory.generateList=function(self,...)
  generateInventory(self,...);self.list=self.inven_list
 end
 local dialogs={}
 local function show(d)
  if d.__CLASSNAME=='engine.dialogs.GetQuantity' then
   inputs.request('quantity',{prompt=d.title,min=d.c_box.min,max=d.c_box.max,default=d.c_box.number,dialog=d},function(answer)
    if answer.cancel then d.key:triggerVirtual('EXIT') else d.c_box.number=answer.value;d:okclick() end
   end);return
  end
  local choices=dialog_choices(d);assert(#choices>0,'unsupported_native_dialog:'..tostring(d.__CLASSNAME))
  local public={};for i,c in ipairs(choices) do public[i]={id=i,label=c.label,object=c.object} end
  inputs.request('choice',{prompt=d.title,options=public,dialog=d},function(answer)
   if answer.cancel then
    if d.key and d.key.binds.EXIT then d.key.binds.EXIT() else game:unregisterDialog(d) end
   else choices[answer.choice].run() end
   if not inputs.has_pending() then
    local top=dialogs[#dialogs]
    if top and game:hasDialog(top) then show(top) end
   end
  end)
 end
 local register,unregister,replace=Game.registerDialog,Game.unregisterDialog,Game.replaceDialog
 Game.registerDialog=function(self,d)
  self.tooltip=self.tooltip or {empty=true,locked=false,max=0}
  register(self,d);dialogs[#dialogs+1]=d;show(d)
 end
 Game.replaceDialog=function(self,src,dest)
  local index;for i=#dialogs,1,-1 do if dialogs[i]==src then index=i;break end end
  assert(index,'native dialog replacement source not tracked')
  local result=replace(self,src,dest);dialogs[index]=dest;return result
 end
 Game.unregisterDialog=function(self,d)
  inputs.clear_dialog(d);for i=#dialogs,1,-1 do if dialogs[i]==d then table.remove(dialogs,i);break end end;return unregister(self,d)
 end

end
return M
