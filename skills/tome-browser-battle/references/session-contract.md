# Battle session contract

The local launch receipt identifies the frozen build and service. Keep that package for the lifetime of its saves. Never replace its Wasm, Lua, JavaScript or encounter configuration with a later build.

## Player routes

- `GET /api/session-capabilities`: confirms persistent sessions.
- `POST /api/checkpoints`: `request_id`, integer `version`, complete `archive`, boolean `handover`; add `battle_id` after the first save. The browser builds the archive. A model must not invent one.
- `GET /api/checkpoints/BATTLE_ID`: canonical archive, public view, version and state.
- `GET /api/status/BATTLE_ID`: public saved view and state without the replay body.
- `/?battle=BATTLE_ID`: restore the existing battle. A suspended battle redirects to the handover page.
- `/dm.html?battle=BATTLE_ID`: wait for host resolution and offer the verified resume link.

Saving does not answer or cancel an unfinished native skill. The same pending request returns after restoration. A native unknown result cannot become a valid save. The client requests a verified checkpoint when a command reaches victory or defeat; failure stays visible and can be retried. Other dirty states require explicit saving. Closing a dirty page is not a confirmed checkpoint.

Saving also does not advance a pending native action or fire rule callbacks. If the action is still settling, wait for an explicit continuation to reach a confirmed boundary. One-shot rendering rule callbacks run as kernel events before the next actor action. Replay reconstructs their original closures. Periodic rendering rule callbacks remain unsupported and fail explicitly.

## Trusted host routes

Keep the token in the host-only `host_token_file` returned by launch. Send it only as `Authorization: Bearer TOKEN` to this loopback host. It is not a MiniMax key and must not appear in a player URL, tool response or page.

`GET /api/dm/handovers` returns pending receipts and their public native views. Use the handover ID as the stable delivery identity. A production adapter must bind this queue to its own authorized campaign and player session.

`POST /api/dm/resolve` accepts exactly:

```json
{
  "handover_id":"SERVER_ID",
  "request_id":"STABLE_HOST_REQUEST_ID",
  "operations":[
    {"operation":"recruit","operation_id":"STABLE_OPERATION_ID","target":"NATIVE_ACTOR_ID"}
  ]
}
```

Recruitment and surrender operations use `recruit` or `surrender`. `[]` resumes without a change. A recruitment or surrender target must be a living, currently visible mission enemy. Complete an outstanding skill choice in the resumed battle before requesting a state-changing resolution. A duplicate identical request returns the same receipt. A conflicting request, old version, unauthorized client DM event, missing target or divergent replay fails.

Current placement-enabled kernels also support host `spawn_enemy` operations. Prefer the dedicated same-room, other-room and exact-coordinate tools described in [enemy placement](enemy-placement.md). Placement preserves the pending handover, updates its checkpoint version and adds a native replay event without advancing a turn. A failed placement does not resolve the handover. A placement-only resolution batch must preserve the turn; ordinary recruitment keeps its native rules.

Recruitment removes the old enemy and reconstructs a new ally, without death loot or XP. The native resolution includes `source_uid` and `ally_uid`. Keep that link when binding a world character. The result retains the same `battle_id`, increments `version`, and supplies `resume_url`. Resume only after this receipt.

These routes are implemented for internal loopback testing. They are not a live OpenClaw tool registration or a shared-world settlement authority.

## Server art

Use the installed native archives through `TOME_NATIVE_INSTALL`, or pass one `--asset-archive PATH` per archive to the session host. Explicit portrait overlays use the launch allowlist. `/api/asset-catalog` reports available and missing archives. The browser requests individual safe PNG paths under `/assets/data/gfx/`; rules stay in Wasm.
