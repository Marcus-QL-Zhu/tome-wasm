# 兼容宿主与本地开发入口

## Use from the server DM

Use the registered `mercenary_game` tool. Send its `operation` and a strict JSON object string in `parameters_json`. Do not send campaign, owner, world, executable paths or party builds. The trusted host reads the actual party and its registered origin. A later battle continues saved native actors; it must not replace them with full-health templates.

- `select_enemies`: read-only selection. Provide `enemy_count` (1–5), `target_win_probability` (0.01–0.99) and optional `map`. The host reads three living members' levels and worn equipment scores from verified native checkpoints. Do not provide party builds or estimate their scores yourself. Missing checkpoint scores require a scene-capable kernel; do not reset saved actors. The reply contains enemy specifications, a predicted probability, the nearest tested numeric party reference and the available range. It does not start a battle. The current selector uses monotone native win-rate curves with the same inputs; it prefers HP×1 while that baseline can cover the target. This is a coarse full-state open-room reference, not a precise chance for arbitrary classes or terrain. Check the reference and range warning before using the result.
- `start_battle`: after deciding the encounter, provide a stable `action_id`, `seed`, permitted `enemies` and `map` from the encounter contract. This executes scene preparation; it is not a proposal or a difficulty query. A `preparing` receipt is not a playable battle. Read `battle_status` with the returned `job_id` until preparation completes. The hosted tools return native state, not a player URL. Use `open_game` to obtain the player's one-use game link; the game page offers the prepared battle.
- `battle_handover` and `battle_finish`: provide `job_id`. A handover requires the player's saved suspension; a finish requires a saved native terminal result. The host verifies the replay and synchronizes native inventory before confirming either result. `sync_pending` is not a completed handover.
- `battle_resume`: provide `job_id`, `handover_id`, a stable `action_id`, and supported `operations`. An empty list resumes unchanged. After confirmation, use the game page to reopen the same frozen battle. Obtain a fresh game link with `open_game` if needed.

The server stores complete replay snapshots at interruption and terminal results. Read the verified current state before narration or a check. Native rest can restore resources, but ending combat does not grant an implicit rest. Preserve HP, effects, cooldowns, equipment and inventory. Do not describe permanent death or recovery merely from a save receipt; campaign settlement needs its own supported authority operation.

For a supported campaign wipeout, wait for a completed `wipeout` result in the synchronized terminal receipt. Only a verified all-core-party-down defeat triggers this settlement. The same leader withdraws at 1 HP; ordinary participating members die permanently, and their identified items stay at the recorded battle location. A paused battle or one downed member does not trigger it. An incomplete settlement blocks dependent changes. The host can continue a settled campaign with its surviving leader; do not create replacement actors or restore dead members. Extra recruited allies and auxiliary bodies need separate support and can block this settlement.

Frozen builds remain attached to their saves. A newer implementation does not prove that an older campaign can be migrated. Bound campaign pages must not offer a fresh-game reset as a way to recover from defeat.

The local developer launcher below is a separate entry for trusted tooling. It is not a shell capability granted to the DM. If bound tools are unavailable, report that limitation instead of inventing a tool or a completed scene.

## Prepare the encounter

1. Read [the encounter contract](encounter-contract.md). Use [the tested example](encounter.example.json) as a starting point.
2. Use the campaign's authorized party records. This launcher creates a test scene; it does not validate ownership or convert world characters into ToME builds.
3. Write a `tome-encounter-v1` JSON under the project `artifacts/`. Specify seed, exactly three party members, one to ten native or Rare enemies, and a supported map. Difficulty selection covers at most five simultaneous enemies.
4. Choose each member’s template or native birth descriptors. Follow the active content catalog and the encounter contract for classes, talents and equipment. Keep native birth, skill and wear checks enabled.
5. For a supplied portrait, use `data/gfx/encounter/ALIAS.png` and give the host `--portrait-file ALIAS=PATH.png`. Use only a file supplied or authorized for this encounter. Existing admitted native PNG paths also work. Do not fetch a remote image or accept Lua code.

## Validate and launch

Use the host's approved local executor from the project root. The exact entry is:

```text
python skills/tome-browser-battle/scripts/launch.py --manifest artifacts/ENCOUNTER.json --check
python skills/tome-browser-battle/scripts/launch.py --manifest artifacts/ENCOUNTER.json
```

Add `--port PORT` only when a fixed port is needed. The default chooses an unused loopback port. Add one `--portrait-file ALIAS=PATH.png` argument for each supplied PNG.

`--check` proves schema validity only. The full launch builds an immutable package, performs real Wasm construction and reset checks, starts a hidden loopback service with durable checkpoints and nonterminal handovers, and returns a JSON receipt with `url`, `pid`, `root` and `native_construction_verified`.

Open the returned URL for the player. Preserve existing battle pages. Do not reuse or overwrite another run directory. If launch fails, read the bounded build or verification log under the new run root; do not say a playable encounter exists.

If the DM host has no approved executor for this entry, report that the host binding is missing. Do not invent a `game_start_battle` tool, and do not request a broad shell permission for the DM.

## Respect capability limits

Read `verification.catalog.json` in the run directory for installed native birth descriptors and skill definitions. A loaded skill is not proof that its manual interface works. Other learned active skills use native coroutine input. Target, multi-stage, menu, inventory and quantity inputs have native examples. Summons are observed separately from mission targets. The catalog retains unverified coverage and known rule-callback limits; do not infer universal support. Never replace a missing native effect with a narrative effect.

Use the current run's content-policy fields to determine availability. The static birth catalog describes installed definitions; it is not an allowlist. Random Rare generation and native skill and item execution enforce the same project restrictions. Explicit forbidden requests fail; do not silently substitute another build. Ordinary temporal damage and slow effects remain eligible.

Native auxiliary bodies use Party control permissions. Golem, Projection and Over Mind have tested control and replay examples. This does not permit direct control of healthy ordinary companions. A control change revokes the old AI authorization. Core-party downing and rescue remain separate from auxiliary-body death or expiry.

Complex-menu examples cover rogue tools, traps, Empower, golem stat and talent allocation, confirmation and rollback, equipment transfer, nested cancellation and Chat page changes. Preserve the original choices, filters, costs and callbacks. Do not choose the first option automatically. A pending choice can be saved and reconstructed; resume the same frozen battle before answering. Other menus, items, control bodies and DLC still require acceptance. Current scope and evidence are in [the integration record](../../../implementation/TOME_CONTENT_BOUNDARY_INTEGRATION_20261112.md).

Choose `map.kind` from `dungeon`, `forest`, `cave`, `town`, `tavern`, or the legacy alias `rooms`. Set `map.size` to an integer from 10 to 64; width and height are equal. The default size is 20. Use 10×10 for a small tavern and up to 64×64 for one Zone, not 192×192 for all nine Zones at once. Only dungeon/rooms accept optional `room_count` (4–8). A scene-capable frozen kernel is required; old builds must not silently ignore the requested map. A seed selects a generated layout. This does not import an arbitrary saved ToME zone. A fresh launch requires three members. Verified campaign continuation can retain one to three surviving core members. Do not replace this continuation with a new launch or fill empty party slots.

## Save or hand over a battle

Read [the session contract](session-contract.md) when resuming or negotiating during battle. The player can save or choose “转为跑团” at a confirmed state. The server verifies the complete replay and returns a durable battle ID. The handover page does not run the battle Worker.

Only the trusted host can resolve a handover. Supported data changes include `recruit`, `surrender` and the host placement operation `spawn_enemy`; an empty operation list resumes unchanged. For ordinary DM placement, use the dedicated single-enemy tools in [the placement guide](enemy-placement.md). Recruitment reconstructs the enemy as an ally at the same position with the same HP, stats, equipment and effects. The standalone session API returns a resume URL; the hosted DM uses `open_game` and the prepared battle on the game page. Do not launch a new encounter to resume an old battle.

A local receipt does not settle world rewards, ownership or persistent injuries. A live DM host needs its own bound tools and campaign identity. Report that binding as missing if it is absent. Do not give the DM arbitrary shell access or browser access to the host token.

## Local native-Zone calibration

The local encounter contract also accepts `zone: {template, reference_level}` with a 64×64 forest, dungeon or cave and an empty explicit `enemies` list. Supported ecologies are `old-forest`, `ruins-kor-pul` and `trollmire`. A current scene-overlay build is required. Native fixed guardians are disabled. Nightmare supplies native levels, talent scaling and Rare rolls once; do not multiply them again. This mode reuses native population generation with the project terrain layout, not the complete upstream quest or final-floor scripts.

The calibration target is 75%–90% whole-Zone automated clearance, centered on 82.5%. Report unfinished runs and technical errors. The special-encounter `select_enemies` estimate is not that probability. The native-Zone contract is a local developer entry; it does not mean a live DM tool accepts it or that an active campaign has been upgraded. Explicit story Boss additions remain a separate integration task.
