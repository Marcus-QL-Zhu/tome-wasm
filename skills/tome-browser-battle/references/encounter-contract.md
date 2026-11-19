# Encounter contract

The executable validator is `tome_mvp/encounter.py`. The native scene owns final admission. Unknown fields fail. Do not use executable Lua in any field.

## Project content limits

Exclude Paradox Mage, Temporal Warden, chronomancy trees, world rewind abilities and secondary-body control. Ordinary summons and autonomous golems remain available. Read the active kernel’s policy flags for native talent availability.

Ordinary temporal damage and slow effects remain eligible. `Temporal Fugue` is not excluded merely because it creates actor copies. A permitted definition is still not proof of executed skill coverage. Old frozen battles keep their own content policy; do not import them into a new build.

| Field | Meaning |
|---|---|
| `format` | Exactly `tome-encounter-v1` |
| `seed` | Integer, 0–2147483647 |
| `party` | Exactly three members; the first is controlled |
| `enemies` | One to ten native or Rare enemies |
| `map` | `{"kind":"forest","size":64}`. Kinds: dungeon, forest, cave, town, tavern, rooms. Square size 10–64; default 20. Only dungeon/rooms accept room_count 4–8. |

## Party member

Choose exactly one source:

- `template`: `184917` (Akud/Bulwark), `159442` (Bruce/Berserker), or `425367` (wamble/Cursed). These are source rebuilds, not imported saves.
- `birth`: native `sex`, `race`, `subrace`, `class`, `subclass` names. See the compact [installed birth catalog](native-birth-catalog.json), then confirm against the new run's live content catalog. Native descriptor callbacks and prerequisite checks can still reject construction.

Optional fields: `name`, `level` (1–50), `stats` (`str,dex,con,mag,wil,cun`), `talents`, `equipment`, `portrait`.

The trusted campaign host may additionally set `campaign_identity` with `person_id` and `origin` for all three distinct members. It obtains both from the authoritative campaign and registered build, not from DM-generated claims. Native construction records them on the actors and the launch probe checks the binding. A template creates an initial build; it does not restore a previous character. Existing native state requires verified carry and must never be replaced by a fresh template.

Each talent is `{"id":"T_RUSH","rank":3,"mastery":1.3}`. Rank is 1–5, mastery is 0.1–3. Entries add or replace ranks in the source build. Other source talents remain. A request below a native birth rank is rejected. Do not infer compatibility from the ID alone.

Each item is `{"name":"steel shield","slot":"OFFHAND"}`. Use a native prototype name or `define_as`. Slots are MAINHAND, OFFHAND, BODY, HEAD, HANDS, FEET, LITE, QUIVER, TOOL, FINGER, NECK, BELT or CLOAK. The native body must have that slot, and `canWearObject` must accept the item. Replaced source equipment is preserved in inventory. New native births retain native birth gear; requested items replace only their designated slots.

`portrait` is an admitted `data/gfx/...png` path. An explicit local PNG can be staged with `--portrait-file ALIAS=PATH.png`, then referenced as `data/gfx/encounter/ALIAS.png`. It is an appearance override. It cannot change rules. The initial implementation also uses it for the map sprite.

## Enemy

For difficulty selection, hosted DM calls `select_enemies` with `{"enemy_count":3,"target_win_probability":0.75,"map":{"kind":"dungeon","size":32}}`. The host reads actual party level and worn-tier sums. It returns explicit enemy specifications; pass those into `start_battle` only when ready to prepare an encounter. The selector is read-only and does not advance world time. Its current pool is native orc-warrior Rare roles (Bulwark/Berserker/Archmage), native levels10–50, HP×1/×2. It does not claim to balance every native species or Boss. Targets outside that pool's probability range return the nearest configuration with a warning. Output needs native construction checks; neither a schema pass nor the predicted probability proves balanced gameplay.

Selection uses local monotone win-rate curves for the nearest tested numeric party reference; it does not infer intermediate-level difficulty from one shared power law. It prefers native HP×1 when that range covers the target. The reply identifies the reference and its data support. Integer levels and native build randomness prevent exact target probabilities. The old relative-power formula remains for historical comparison; it is not the current inverse selector. No new party, class, terrain or skill input is required.

Trusted offline tooling can provide numeric party estimates directly:

```text
python -m tome_mvp.encounter_balance --input artifacts/selection-input.json --output artifacts/selection-output.json
```

Input example: `{"party":[{"level":25,"gear_score":29},{"level":24,"gear_score":22},{"level":24,"gear_score":26}],"enemy_count":3,"target_win_probability":0.75,"map":{"kind":"dungeon","size":32}}`. Equipment score means the sum of tiers of currently worn items; empty or untiered items score0. This input does not create or alter the party.

Each enemy has `prototype` and `level`. Optional `source` selects a native `/data/general/npcs/SOURCE.lua` pool; default `orc`. Optional `kind` is `rare` (default) or `native`. `class` filters the native random_elite class and is only valid for `rare`. `hp_multiplier` is 0.1–10, default 2 for Rare or 1 for native. Optional `talents` use the same native rank schema.

Example: `{"source":"skeleton","prototype":"skeleton warrior","class":"Berserker","level":17,"hp_multiplier":1.5}`.

The factory constructs the native entity, optionally with random_elite, then applies requested added talent ranks and maximum-life multiplier. It refuses to lower an already generated talent rank. Missing native prototypes, classes, equipment and spawn positions fail explicitly. It does not invent a weaker fallback.

## Receipt and limits

Launch outputs `tome-local-launch-v1` with URL, PID, artifact root, seed, `native_construction_verified:true`, and `campaign_settlement:false`. Static service health is not proof of browser rendering or universal skill compatibility. Native construction validation includes real Wasm scene creation, creature inspection and reset. It does not play every possible skill.

The catalog has an explicit `all_talents_verified:false`. Manual combat has verified convenience adapters and a generic native coroutine route. Complete replay persistence and nonterminal resumption are available through the session host. All-skills certification, saved-map import, arbitrary initial party size, DLC admission and campaign settlement remain separate acceptance work.

## Native birth and battle allegiance

Use native parent/child descriptor pairs from the catalog. A listed definition is not valid with every race or scenario. Stone Warden requires a native allowed race; Runic Golem uses None rather than a normal human class. Tutorial Adventurer is not admitted by the Normal scenario. Do not bypass native checks.

Wanderer executes the original random-tree initialization before level advancement. Its local shuffle uses a scene-derived seed and restores the world RNG. A successful empty shell is not a complete Wanderer.

All starting party members use the resolved leader's battle faction. Declared enemies share the native enemies faction. The original template faction is retained separately. This does not change their race, body, skills or gear. Native quest notifications go to the battle log; quest state is retained.
