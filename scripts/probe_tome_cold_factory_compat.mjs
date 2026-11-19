// Exercise the authenticated cold restore path with a synthetic old-build save.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const [oldPath, incompatiblePath, fixedPath, out] = process.argv.slice(2);
if (!out) throw Error('usage: node probe_tome_cold_factory_compat.mjs <old public> <incompatible public> <fixed public> <report.json> [--source]');
const source = process.argv.includes('--source')
 ? await readFile(new URL('../tome_mvp/headless/formal_factory.lua', import.meta.url), 'utf8')
 : null;
const seed = 23;
const area = {area_id: 'area:cold-factory-probe', floor: 1, world_clock: {world_tick: 0, day_in_quarter: 0}};
const manifestConfig = {
 format: 'tome-encounter-v1', seed,
 map: {kind: 'rooms', size: 20},
 party: ['184917', '159442', '425367'].map((template, i) => ({
  template, campaign_identity: {person_id: 'probe-party-' + i, origin: 'isolated-probe'},
 })),
 enemies: [{prototype: 'orc warrior', class: 'Bulwark', level: 16}],
};
const scopeFor = build => ({build, world_id: 'probe-world', campaign_id: 'probe-campaign'});
const fixture = `
    elseif req.method=='fixture_cold_factory' then
        last_id=id
        if req.params.area_id then
            require('local_area').bind(state,{area_id=req.params.area_id,floor_count=1})
            require('campaign_items').adopt(state,'probe-world','probe-campaign')
            -- Ecology zones persist this function as their base filter.
            -- Keep it on this synthetic zone as well to test both prototypes.
            state.game.zone._probe_frozen_post_filter=state.game.zone.post_filter
            state.game.paused=true
            reply(id,{bound=true})
        else
            local zone=assert(state.game.zone)
            local function inspect(fn)
                local info=debug.getinfo(fn,'Su')
                return json.object({source=info.source,first_line=info.linedefined,last_line=info.lastlinedefined,
                    upvalues=info.nups,dump=mime.b64(string.dump(fn),nil)})
            end
            reply(id,json.object({name=zone.short_name,actor_adjust_level=inspect(zone.actor_adjust_level),
                post_filter=inspect(zone._probe_frozen_post_filter)}))
        end
`;

async function open(publicPath, overlay) {
 const root = resolve(publicPath);
 const module = name => import(pathToFileURL(resolve(root, name)));
 const {createKernel} = await module('kernel_runtime.mjs');
 const {installEncounter} = await module('encounter_overlay.mjs');
 const {default: createTome} = await module('tome.js');
 const transport = await module('partition_transport.mjs');
 const build = JSON.parse(await readFile(resolve(root, '../identity.json'), 'utf8')).build_id;
 const wasmBinary = await readFile(resolve(root, 'tome.wasm'));
 const data = await readFile(resolve(root, 'tome.data'));
 const logs = [];
 const kernel = await createKernel(createTome, {
  wasmBinary, getPreloadedPackage: () => data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength),
 }, {
  prepare(mod) {
   installEncounter(mod, manifestConfig);
   if (overlay) mod.FS.writeFile('/bundle/headless/formal_factory.lua', overlay);
   const worker = '/bundle/headless/worker.lua';
   const code = mod.FS.readFile(worker, {encoding: 'utf8'});
   const marker = "    elseif req.method=='capabilities' then";
   assert.equal(code.split(marker).length, 2);
   mod.FS.writeFile(worker, code.replace(marker, fixture + marker));
  },
  log(...parts) {
   const line = parts.join(' ');
   if (/error|native function environment/.test(line)) logs.push(line);
  },
 });
 return {kernel, build, transport, logs};
}

async function restore(env, saved) {
 const scope = scopeFor(env.build);
 const manifest = {...saved.manifest, build: env.build};
 const ids = env.transport.selectPartitions(manifest, scope, {kind: 'area', area_id: area.area_id, floor: 1});
 const entries = {hot: manifest.hot_root, ...Object.fromEntries(manifest.partitions.map(p => [p.partition_id, p]))};
 const selected = Object.fromEntries(ids.map(id => [id, saved.blobs[entries[id].blob_digest]]));
 const blobs = await env.transport.verifyAuthorizedPartitions(manifest, scope, ids, selected);
 const {generation, native_boundary} = await env.kernel.rpc('partition_import', {manifest, blobs});
 assert.equal(native_boundary, 'campaign_admin');
 const parked = await env.kernel.rpc('observe', {}, generation);
 assert.equal(parked.map_available, false);
 const entered = await env.kernel.rpc('dm_transition', {operation: 'area_enter', area}, generation);
 assert.equal(entered.transition.created, false);
 assert.equal(entered.transition.refreshed, false);
 const factory = await env.kernel.rpc('fixture_cold_factory', {}, generation);
 const view = await env.kernel.rpc('dm_inspect', {}, generation);
 const exported = await env.kernel.rpc('partition_export', {protected_by_owner: {}}, generation);
 const candidate = await env.transport.normalizePartitionExport(scope, manifest, exported, generation);
 return {factory, view, ids, candidate};
}

const report = {runtime: 'real Wasm', source_overlay: Boolean(source), passed: false};
let env;
try {
 env = await open(oldPath);
 report.old_build = env.build;
 const {generation} = await env.kernel.rpc('create', {seed, fixture: 'formal'});
 assert.equal((await env.kernel.rpc('fixture_cold_factory', {area_id: area.area_id}, generation)).bound, true);
 assert.equal((await env.kernel.rpc('partition_enable', {}, generation)).accepted, true);
 const departed = await env.kernel.rpc('dm_transition', {operation: 'area_depart', area}, generation);
 assert.equal(departed.transition.departed, true);
 const raw = await env.kernel.rpc('partition_export', {protected_by_owner: {}}, generation);
 const saved = await env.transport.normalizePartitionExport(scopeFor(env.build), null, raw, generation);
 assert.equal(saved.manifest.partitions.length, 2);
 env.kernel.dispose();
 env = await open(oldPath);
 const baseline = await restore(env, saved);
 assert.equal(baseline.factory.name, 'formal-squad');
 assert.equal(baseline.factory.actor_adjust_level.first_line, 70);
 assert.equal(baseline.factory.actor_adjust_level.last_line, 74);
 assert.equal(baseline.factory.post_filter.first_line, 55);
 assert.equal(baseline.factory.post_filter.last_line, 55);
 env.kernel.dispose();

 env = await open(incompatiblePath);
 report.rejected_build = env.build;
 let rejected;
 try {
  await restore(env, saved);
 } catch (error) {
  rejected = [String(error), ...env.logs].find(log => /unknown prototype .*formal_factory.lua:(55|70)/.test(log));
  if (!rejected) throw error;
 }
 assert.ok(rejected, 'old archive must reproduce the shifted prototype failure');
 report.rejection = rejected.split('\n')[0];
 env.kernel.dispose();

 env = await open(fixedPath, source);
 report.fixed_build = env.build;
 const restored = await restore(env, saved);
 assert.deepEqual(restored.factory, baseline.factory);
 assert.deepEqual(restored.ids, baseline.ids);
 for (const key of ['turn', 'rng', 'next_uid', 'control', 'enemies', 'terrain']) {
  assert.deepEqual(restored.view[key], baseline.view[key], key);
 }
 assert.deepEqual(restored.view.party.map(actor => actor.uid), baseline.view.party.map(actor => actor.uid));
 assert.deepEqual(restored.candidate.manifest.objects, baseline.candidate.manifest.objects);
 report.loaded_partitions = restored.ids;
 report.turn = restored.view.turn;
 report.party_uids = restored.view.party.map(actor => actor.uid);
 report.prototypes = Object.fromEntries(['actor_adjust_level', 'post_filter'].map(name => {
  const {dump, ...info} = restored.factory[name];
  return [name, {...info, sha256: createHash('sha256').update(Buffer.from(dump, 'base64')).digest('hex')}];
 }));
 report.passed = true;
} catch (error) {
 report.error = String(error.stack || error);
 report.native_errors = env?.logs.slice(-8);
 process.exitCode = 1;
} finally {
 env?.kernel.dispose();
 await writeFile(resolve(out), JSON.stringify(report, null, 2) + '\n');
 console.log(JSON.stringify({passed: report.passed, error: report.error, native_errors: report.native_errors}));
}
