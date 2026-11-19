"use strict";
const {test}=require("node:test"), assert=require("node:assert/strict"), fs=require("node:fs"), {chromium}=require("playwright");
test("map clicks separate movement, visible enemy, grid aiming and unknown cells",async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.TOME_TEST_BROWSER});
 try {
  const page=await browser.newPage({viewport:{width:1280,height:800}}), calls=[];
  const state={revision:1,control_epoch:1,online:true,status:"active",capabilities:{navigate_start:true,navigate_step:false,move:true,talent:true,pause:true},navigation:{status:"idle"},map:["@.e ","...."],explored_map:["@.e ","...."],visible_map:["1110","1111"],party:[{id:1,x:0,y:0}],control_actor_id:1,enemies:[{id:2,x:2,y:0}],talents:[{id:"grid",target:"grid",available:true}],events:[]};
  await page.route("**/*",route=>{const url=route.request().url();
   if(url.endsWith("/api/state"))return route.fulfill({json:state});
   if(url.endsWith("/api/command")){const body=route.request().postDataJSON();calls.push(body);return route.fulfill({json:{...state,revision:2,navigation:{status:"stopped",x:body.x,y:body.y,stop_reason:"arrived"}}});}
   if(url.endsWith("/app.js"))return route.fulfill({contentType:"text/javascript",body:fs.readFileSync("tome_mvp/web/app.js")});
   if(url.endsWith("/style.css"))return route.fulfill({contentType:"text/css",body:fs.readFileSync("tome_mvp/web/style.css")});
   if(url.includes("/assets/"))return route.fulfill({status:404});
   return route.fulfill({contentType:"text/html",body:fs.readFileSync("tome_mvp/web/index.html")});
  });
  await page.goto("http://tome.test/"); await page.waitForFunction(()=>state!==null && camera!==null);
  async function click(x,y){await page.evaluate(([x,y])=>{const c=document.getElementById("battle_map"),r=c.getBoundingClientRect();c.dispatchEvent(new MouseEvent("click",{clientX:r.left+(x-camera.left+.5)*camera.size,clientY:r.top+(y-camera.top+.5)*camera.size,bubbles:true}));},[x,y]);}
  await click(1,0);await page.waitForFunction(()=>state?.revision===2);assert.equal(calls[0].type,"move");assert.deepEqual([calls[0].dx,calls[0].dy],[1,0]);
  await click(2,0);assert.equal(await page.locator("#target").inputValue(),"2");assert.equal(calls.length,1);
  await click(3,0);assert.equal(calls.length,1);
  await page.locator("#talent").dispatchEvent("change");await click(1,1);assert.equal(await page.locator("#grid_x").inputValue(),"1");assert.equal(await page.locator("#grid_y").inputValue(),"1");assert.equal(calls.length,1);
  await page.locator("#cancel_grid_target").click();await click(1,1);await page.waitForTimeout(30);assert.equal(calls.length,2);
 } finally {await browser.close();}
});
