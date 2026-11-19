"use strict";
// Uses a real browser DOM and the shipped HTML and script. Set NODE_PATH to the
// workspace Playwright package and TOME_TEST_BROWSER to a Chromium executable.
const {test} = require("node:test"), assert = require("node:assert/strict");
const fs = require("node:fs");
const {chromium} = require("playwright");
const html=fs.readFileSync("tome_mvp/web/index.html","utf8");
const script=fs.readFileSync("tome_mvp/web/app.js","utf8");
const style=fs.readFileSync("tome_mvp/web/style.css","utf8");
test("equipment and unknown resource maximum survive repeated display", async()=>{
  const browser=await chromium.launch({headless:true,executablePath:process.env.TOME_TEST_BROWSER});
  try {
    const page=await browser.newPage({viewport:{width:1280,height:800}});
    const state={online:true,revision:1,generation:1,turn:0,status:"active",capabilities:{talent:true},
      control_actor_id:1,leader_id:1,map:["@..","...","..."],visible_map:["100","000","000"],enemies:[{id:4,x:2,y:2,visual:{image:"data/gfx/shockbolt/npc/humanoid_orc_orc_warrior.png",kind:"native"}}],events:[],
      terrain_visuals:[[{image:"data/gfx/shockbolt/terrain/marble_floor.png",seen:true},null,null],[null,null,null],[null,null,null]],
      talents:[{id:"T_RUSH",name:"Rush",description:"#{bold}#伤害 #B4B4B4#12#LAST#\n第二行 3",target:"hostile",available:true,icon:"data/gfx/talents/rush.png"}],
      party:[
        {id:1,name:"甲",x:0,y:0,visual:{image:"data/gfx/shockbolt/player/dwarf_male.png",kind:"representative"},hp:10,max_hp:20,resources:[{name:"失衡",value:12,min:0,max:null}],equipment:[{slot:"主手",name:"原生斧",source_name:"来源斧"}],effects:[{id:"EFF_MERCENARY_DOWN",name:"晕倒",status:"detrimental",dur:1000000000},{id:"EFF_STUNNED",name:"眩晕",icon:"data/gfx/effects/stunned.png",status:"detrimental",dur:3},{id:"EFF_OTHER",name:"其他",status:"detrimental"}]},
        {id:2,name:"乙",x:1,y:0,hp:9,max_hp:20,equipment:[{slot:"身体",name:"原生甲",status:"可用"}]},
        {id:3,name:"丙",x:2,y:0,hp:8,max_hp:20,equipment:[{slot:"副手",name:"原生盾"}]}
      ]};
    const assets=JSON.parse(fs.readFileSync("artifacts/tome-formal-squad-20261111/assets/manifest.json","utf8")).assets;
    await page.addInitScript(()=>{const orig=CanvasRenderingContext2D.prototype.drawImage;window.drawnAssets=[];CanvasRenderingContext2D.prototype.drawImage=function(image,...args){window.drawnAssets.push(image.src);return orig.call(this,image,...args);};});
    await page.route("**/*",route=>{
      const url=route.request().url();
      if(url.endsWith("/api/state")) return route.fulfill({json:state});
      if(url.endsWith("/app.js")) return route.fulfill({contentType:"text/javascript",body:script});
      if(url.endsWith("/style.css")) return route.fulfill({contentType:"text/css",body:style});
      const pathname=decodeURIComponent(new URL(url).pathname);
      if(pathname.startsWith("/assets/")){
        const name=pathname.slice("/assets/".length);
        if(assets[name]) return route.fulfill({contentType:"image/png",body:fs.readFileSync("artifacts/tome-formal-squad-20261111/assets/"+name)});
        return route.fulfill({status:404,body:"missing"});
      }
      return route.fulfill({contentType:"text/html",body:html});
    });
    await page.goto("http://tome.test/");
    await page.waitForFunction(()=>document.querySelector("#equipment_list").textContent.includes("原生斧"));
    await page.evaluate(s=>{display(s);display(s);},state);
    await page.locator(".equipment summary").click();
    const equipment=await page.locator("#equipment_list").innerText();
    for(const text of ["甲","乙","丙","主手","原生斧","来源斧","原生甲","可用","原生盾","状态 未知"]) assert.ok(equipment.includes(text),text);
    const hero=await page.locator("#hero_summary").innerText();
    assert.match(hero,/失衡 12\.0 \/ 未知/);
    assert.equal(await page.locator("#hero_summary .resource").nth(1).locator("i").evaluate(e=>e.style.width),"");
    const debuffs=await page.locator("#debuffs").innerText();
    assert.match(debuffs,/晕倒（等待救援）/);
    assert.doesNotMatch(debuffs,/1000000000/);
    assert.match(debuffs,/眩晕 · 3/);
    assert.match(debuffs,/其他 · 未知/);
    await page.waitForFunction(()=>window.drawnAssets.some(x=>x.includes("marble_floor.png"))&&window.drawnAssets.some(x=>x.includes("dwarf_male.png")));
    assert.equal(await page.evaluate(()=>window.drawnAssets.some(x=>x.includes("humanoid_orc_orc_warrior.png"))),false);
    assert.equal(await page.evaluate(()=>{const a=nativeImage("data/gfx/talents/rush.png"),b=nativeImage("data/gfx/talents/rush.png");return a===b;}),true);
    assert.equal(await page.evaluate(()=>assetURL("data/gfx/../secret.png")),null);
    assert.match(await page.locator(".skill-icon").evaluate(e=>e.style.backgroundImage),/rush\.png/);
    assert.match(await page.locator(".effect-icon").evaluate(e=>e.style.backgroundImage),/stunned\.png/);
    assert.match(hero,/同族代表形象/);
    assert.match(await page.locator(".skill").first().getAttribute("title"),/伤害 12\n第二行 3/);
    assert.doesNotMatch(await page.locator(".skill").first().getAttribute("title"),/#{bold}#|#B4B4B4#/);
    await page.evaluate(s=>display({...s,enemies:[],events:["#{bold}#受伤 #B4B4B4#12#LAST#\n下一行 3"]}),state);
    assert.equal(await page.locator("#melee").getAttribute("title"),"无可见目标");
    assert.equal(await page.locator("#events").innerText(),"受伤 12\n下一行 3");
    assert.equal(await page.locator(".equipment").evaluate(e=>e.open),true);
    for(const size of [{width:1280,height:800},{width:1920,height:1080}]){
      await page.setViewportSize(size);
      const geometry=await page.evaluate(()=>{
        const map=document.querySelector(".battlefield").getBoundingClientRect();
        const bar=document.querySelector(".bottom").getBoundingClientRect();
        const equip=document.querySelector(".equipment").getBoundingClientRect();
        return {mapBottom:map.bottom,barTop:bar.top,barBottom:bar.bottom,equipTop:equip.top,equipBottom:equip.bottom,viewport:innerHeight};
      });
      assert.ok(geometry.mapBottom<=geometry.barTop+1);
      assert.ok(geometry.barBottom<=geometry.equipTop+1);
      assert.ok(geometry.equipBottom<=geometry.viewport+1);
    }
  } finally {await browser.close();}
});
test("formal initial observer images load from the local asset manifest", async()=>{
  const state=JSON.parse(fs.readFileSync("artifacts/tome-formal-squad-20261111/formal-initial-visual-state.json","utf8"));
  const assets=JSON.parse(fs.readFileSync("artifacts/tome-formal-squad-20261111/assets/manifest.json","utf8")).assets;
  const browser=await chromium.launch({headless:true,executablePath:process.env.TOME_TEST_BROWSER});
  try {
    const page=await browser.newPage({viewport:{width:1280,height:800}}), missing=[];
    await page.route("**/*",route=>{
      const url=route.request().url();
      if(url.endsWith("/api/state"))return route.fulfill({json:state});
      if(url.endsWith("/app.js"))return route.fulfill({contentType:"text/javascript",body:script});
      if(url.endsWith("/style.css"))return route.fulfill({contentType:"text/css",body:style});
      const name=decodeURIComponent(new URL(url).pathname).replace(/^\/assets\//,"");
      if(url.includes("/assets/")){
        if(assets[name])return route.fulfill({contentType:"image/png",body:fs.readFileSync("artifacts/tome-formal-squad-20261111/assets/"+name)});
        missing.push(name);return route.fulfill({status:404,body:"missing"});
      }
      return route.fulfill({contentType:"text/html",body:html});
    });
    await page.goto("http://tome.test/");
    await page.waitForFunction(()=>document.querySelector("#hero_summary").textContent.includes("Akud"));
    await page.waitForFunction(()=>[...imageCache.values()].every(i=>i.complete));
    assert.deepEqual(missing,[]);
    assert.equal(await page.evaluate(()=>[...imageCache.values()].every(i=>i.naturalWidth>0)),true);
    assert.match(await page.locator("#hero_summary").innerText(),/同族代表形象/);
    assert.equal(state.party.length,3);
    fs.mkdirSync("artifacts/tome-ui-layout-20261111",{recursive:true});
    for(const [width,height] of [[1280,800],[1920,1080]]){
      await page.setViewportSize({width,height});
      assert.notEqual(await page.locator(".skill > span:not(.skill-icon)").first().evaluate(e=>getComputedStyle(e).display),"none");
      await page.screenshot({path:`artifacts/tome-ui-layout-20261111/formal-initial-${width}x${height}.png`});
    }
    await page.setViewportSize({width:672,height:768});
    const narrow=await page.locator("#hotbar").evaluate(el=>({
      width:el.clientWidth,scrollWidth:el.scrollWidth,
      rows:[...new Set([...el.children].map(button=>Math.round(button.getBoundingClientRect().top)))],
      skills:[...el.children].map(button=>({label:button.getAttribute("aria-label"),title:button.title,key:button.getAttribute("aria-keyshortcuts")}))
    }));
    assert.ok(narrow.skills.length>20);
    assert.ok(narrow.scrollWidth<=narrow.width);
    assert.equal(narrow.rows.length,2);
    assert.ok(narrow.skills.every(item=>item.label && item.title));
    assert.equal(narrow.skills[0].key,"1");
    assert.equal(narrow.skills[10].key,"Shift+1");
    await page.screenshot({path:"artifacts/tome-ui-layout-20261111/formal-initial-672x768.png"});
  } finally {await browser.close();}
});
