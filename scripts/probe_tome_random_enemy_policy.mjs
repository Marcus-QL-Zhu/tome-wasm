// Real Wasm. The fault fixture exists only in the test VM's memory.
import assert from 'node:assert/strict';
import {readFile, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const [rootArg, outArg] = process.argv.slice(2);
if (!rootArg || !outArg) throw Error('usage: node probe_tome_random_enemy_policy.mjs <public> <report.json> [--source]');
const root = resolve(rootArg);
const sourceOverlay = process.argv.includes('--source');
const fromPackage = name => import(pathToFileURL(resolve(root, name)));
const {createKernel} = await fromPackage('kernel_runtime.mjs');
const {installEncounter} = await fromPackage('encounter_overlay.mjs');
const {default: createTome} = await fromPackage('tome.js');
const wasmBinary = await readFile(resolve(root, 'tome.wasm'));
const data = await readFile(resolve(root, 'tome.data'));
const identity = JSON.parse(await readFile(resolve(root, '../identity.json'), 'utf8'));
const ruleSources = new Map();
if (sourceOverlay) {
 for (const name of ['content_policy.lua', 'native_zone.lua', 'formal_factory.lua']) {
  ruleSources.set(name, await readFile(new URL('../tome_mvp/headless/' + name, import.meta.url), 'utf8'));
 }
}

const treeReason = 'content policy rejects talent tree: chronomancy/timetravel';
const cases = [
 {name: 'ecology', zone: true, fault: 'tree'},
 {name: 'ecology_late_levelup', zone: true, fault: 'late'},
 {name: 'ecology_refresh', zone: true, refresh: true, fault: 'late'},
 {name: 'ecology_skip', zone: true, denials: 8, fault: 'tree'},
 {name: 'free_rare', fault: 'talent'},
 {name: 'free_rare_fallback', denials: 8, fault: 'tree'},
 {name: 'explicit_prototype', kind: 'native', fault: 'tree', reason: treeReason, attempts: 1},
 {name: 'explicit_class', career: 'Bulwark', fault: 'tree'},
 {name: 'explicit_class_limit', career: 'Bulwark', fault: 'always', reason: 'random enemy draws exhausted: ' + treeReason, attempts: 8},
 {name: 'forbidden_class', career: 'Temporal Warden', fault: 'none', reason: 'content policy rejects class: Temporal Warden', attempts: 0},
 {name: 'forbidden_talent', talents: [{id: 'T_PROJECTION', rank: 1}], fault: 'none', reason: 'content policy rejects talent: T_PROJECTION', attempts: 0},
 {name: 'other_error', fault: 'other', reason: 'fixture error containing content policy rejects talent', attempts: 1},
 {name: 'unknown_talent', fault: 'unknown', reason: 'unknown native talent: T_POLICY_DRAW_PROBE_UNKNOWN', attempts: 1},
 {name: 'draw_limit', fault: 'always', reason: 'random enemy draws exhausted: ' + treeReason, attempts: 9},
];

function installFixture(mod, fixture) {
 const worker = '/bundle/headless/worker.lua';
 const source = mod.FS.readFile(worker, {encoding: 'utf8'});
 const anchor = '    return create_scene(...)';
 assert.equal(source.split(anchor).length, 2, 'unexpected worker create boundary');
 const probe = `
    local fault=${JSON.stringify(fixture.fault)}
    local denials=${fixture.denials ?? 1}
    local refreshing=${Boolean(fixture.refresh)}
    local requested_class=${fixture.career ? JSON.stringify(fixture.career) : 'nil'}
    local factory=require 'formal_factory'
    local new_zone=factory.new_zone
    local calls,settled,late=0,0,0
    local armed=not refreshing
    local rejected,accepted
    local draw_key='mod.class.Object/__policy_draw_probe_unique'
    local tick_key='policy_draw_probe_tick'
    factory.new_zone=function(...)
        local zone=new_zone(...)
        local make=zone.makeEntity
        zone.makeEntity=function(z,level,kind,filter,force_level,prob_filter)
            if kind~='actor' or not armed then return make(z,level,kind,filter,force_level,prob_filter) end
            calls=calls+1
            local actor=make(z,level,kind,filter,force_level,prob_filter)
            print('POLICY_DRAW_ATTEMPT',calls,actor and actor.uid or 0)
            if calls<=denials or fault=='always' then
                actor=assert(actor,'fixture needs a native candidate')
                local drop=require('mod.class.Object').new{name='Policy draw probe',unique='__policy_draw_probe_unique'}
                assert(not game.uniques[draw_key], 'rejected candidate left a unique item registration')
                z:addEntity(level,drop,'object')
                assert(game.uniques[draw_key]==1)
                game:onTickEnd(function()error('rejected candidate callback was retained')end,tick_key)
                rejected=actor
                if fault=='other' then
                    error('fixture error containing content policy rejects talent')
                elseif fault=='unknown' then
                    actor:learnTalent('T_POLICY_DRAW_PROBE_UNKNOWN',true,1)
                elseif fault=='talent' then
                    assert(actor:getTalentFromId('T_PROJECTION'),'missing installed forbidden talent')
                    actor:learnTalent('T_PROJECTION',true,1)
                elseif fault=='late' then
                    local force_levelup=actor.forceLevelup
                    actor.forceLevelup=function(self,...)
                        self.forceLevelup=nil
                        force_levelup(self,...)
                        assert(level:hasEntity(self)==self and level.map(self.x,self.y,require('engine.Map').ACTOR)==self)
                        late=late+1
                        self:learnTalent('T_PROJECTION',true,1)
                    end
                elseif fault=='tree' or fault=='always' then
                    actor:learnTalentType('chronomancy/timetravel',true)
                else
                    error('explicit rejection must happen before a draw')
                end
            elseif not accepted then
                accepted=assert(actor,'fixture needs a second native candidate')
                assert(not game.uniques[draw_key], 'rejected candidate left a unique item registration')
                assert(not game:onTickEndGet(tick_key),'rejected candidate left a callback')
                if not refreshing then game:onTickEnd(function()settled=settled+1 end,tick_key) end
            end
            return actor
        end
        return zone
    end
    local state=create_scene(...)
    factory.new_zone=new_zone
    if refreshing then
        local area=require 'local_area'
        area.bind(state,{area_id='area:policy-draw-probe',floor_count=1})
        local retained=assert(state.enemies[1])
        retained._dm_named=true
        local old_uid,x,y=retained.uid,retained.x,retained.y
        armed=true
        local refresh=area.refresh_active(state,{reference_level=14})
        assert(refresh.removed>0 and game.level:hasEntity(retained)==retained and retained.uid==old_uid)
        assert(game.level.map(x,y,require('engine.Map').ACTOR)==retained)
        print('POLICY_DRAW_RETAINED',old_uid,refresh.removed)
    end
    assert(game.level:hasEntity(accepted)==accepted and not game.level:hasEntity(rejected))
    assert(not game:hasEntity(rejected))
    if rejected.x then assert(game.level.map(rejected.x,rejected.y,require('engine.Map').ACTOR)~=rejected) end
    assert(accepted~=rejected and not game.uniques[draw_key] and settled==(refreshing and 0 or 1))
    for _,actor in ipairs(state.enemies) do require('content_policy').check_actor(actor) end
    local career=accepted.descriptor and accepted.descriptor.classes and accepted.descriptor.classes[1]
    assert(not requested_class or career==requested_class)
    if denials==8 and accepted.randboss and not ${Boolean(fixture.zone)} then assert(career,'fallback omitted the native career') end
    print('POLICY_DRAW_ACCEPTED',rejected.uid,accepted.uid,#state.enemies,settled,late)
    if career then print('POLICY_DRAW_CAREER',career) end
    return state`;
 mod.FS.writeFile(worker, source.replace(anchor, () => probe));
}

const report = {
 runtime: 'real Wasm',
 build: identity.build_id,
 installed_dlc: Object.keys(identity.inputs.installed_dlc ?? {}),
 source_overlay: sourceOverlay,
 cases: [],
};
for (const fixture of cases) {
 const seed = fixture.zone ? 41 : 23;
 const enemy = {prototype: 'orc warrior', kind: fixture.kind ?? 'rare', level: 16};
 if (fixture.career) enemy.class = fixture.career;
 if (fixture.talents) enemy.talents = fixture.talents;
 const manifest = {
  format: 'tome-encounter-v1', seed,
  map: fixture.zone ? {kind: 'forest', size: 64} : {kind: 'rooms', size: 20},
  party: ['184917', '159442', '425367'].map(template => ({template})),
  enemies: [enemy],
 };
 if (fixture.zone) manifest.zone = {template: 'old-forest', reference_level: 14, floor_count: 1};
 const attempts = [], diagnostics = [];
 const result = {name: fixture.name, seed, attempts, passed: false};
 let kernel, accepted;
 try {
  kernel = await createKernel(createTome, {
   wasmBinary, getPreloadedPackage: () => data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength),
  }, {
   prepare(mod) {
    for (const [name, value] of ruleSources) mod.FS.writeFile('/bundle/headless/' + name, value);
    installEncounter(mod, manifest);
    installFixture(mod, fixture);
   },
   log(...parts) {
    const line = parts.map(String).join(' ');
    const match = /^POLICY_DRAW_ATTEMPT\s+(\d+)\s+(\d+)$/.exec(line);
    if (match) attempts.push(Number(match[2]));
    if (line.startsWith('POLICY_DRAW_ACCEPTED')) accepted = line.split(/\s+/).slice(1).map(Number);
    if (line.startsWith('POLICY_DRAW_RETAINED')) [result.retained_uid, result.retired_enemies] = line.split(/\s+/).slice(1).map(Number);
    if (line.startsWith('POLICY_DRAW_CAREER')) result.career = line.slice('POLICY_DRAW_CAREER'.length).trim();
    if (/rejects|exhausted|unknown native talent|fixture|stack traceback/.test(line)) diagnostics.push(line);
   },
  });
  const created = await kernel.rpc('create', {seed, fixture: 'formal'});
  assert.equal(created.accepted, true);
  const view = await kernel.rpc('observe', {}, created.generation);
  result.created = true;
  result.turn = view.turn;
 } catch (error) {
  result.created = false;
  result.error = String(error);
 } finally {
  kernel?.dispose();
 }
 if (fixture.reason) {
  result.passed = result.created === false && diagnostics.some(line => line.includes(fixture.reason))
   && attempts.length === fixture.attempts;
 } else if (result.created && accepted) {
  const [rejected, chosen, enemyCount, callbacks, late] = accepted;
  const denials = fixture.denials ?? 1;
  result.rejected_uid = rejected;
  result.chosen_uid = chosen;
  result.enemy_count = enemyCount;
  result.accepted_callbacks = callbacks;
  result.denied_on_levelup = late;
  result.passed = result.turn === 0 && attempts[denials - 1] === rejected && attempts[denials] === chosen && rejected !== chosen
   && callbacks === (fixture.refresh ? 0 : 1) && late === (fixture.fault === 'late' ? 1 : 0)
   && (fixture.zone ? enemyCount > 1 : enemyCount === 1)
   && (!fixture.refresh || result.retained_uid > 0);
 }
 if (diagnostics.length) result.diagnostics = diagnostics.slice(-8);
 report.cases.push(result);
}

report.passed = report.cases.every(result => result.passed);
await writeFile(resolve(outArg), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({passed: report.passed, cases: report.cases.map(({name, passed}) => ({name, passed}))}));
if (!report.passed) process.exitCode = 1;
