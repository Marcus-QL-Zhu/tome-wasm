# ToME Wasm — Open-source turn-based tactical combat engine

ToME Wasm brings the native combat rules of **Tales of Maj’Eyal (ToME) 1.7.6** to WebAssembly. It runs the T-Engine 4 Lua rules and C runtime in a browser Web Worker and provides a JavaScript bridge for an application to send actions and receive observations. It was developed as the open-source combat component of Pocket Mercenaries, a separate tabletop RPG application.

This repository is a starting point for a browser-based tactical RPG, a roguelike combat prototype, or an application that needs a combat simulator it can inspect and drive. A Node.js probe can run a locally built kernel without opening a browser.

## Capabilities

- Create seeded encounters with a map, party, enemies, and placement rules. Supported content depends on the selected kernel and encounter configuration.
- Advance native turn-based combat through movement, attacks, talents, and item use. Read map and combat observations, action receipts, and pending input requests.
- Save and resume supported battle states with a matching build. The session host supports checkpoint persistence and a battle handover for an external campaign.
- Run battle turns in the browser worker. An integrating application can use the session host for persistence and keep its own campaign state.

## Integration map for developers and coding agents

| Task | Start here |
| --- | --- |
| Find the browser worker and action bridge | [Browser worker](tome_mvp/wasm/browser_worker.mjs), [EngineBridge](tome_mvp/wasm/engine_bridge.mjs), [Wasm loader](tome_mvp/wasm/kernel_runtime.mjs) |
| Inspect the RPC protocol and encounter inputs | [Lua worker for `tome-headless-v1`](tome_mvp/headless/worker.lua), [encounter contract](skills/tome-browser-battle/references/encounter-contract.md), [example encounter](skills/tome-browser-battle/references/encounter.example.json) |
| Persist battles or connect a campaign | [Session server](tome_mvp/wasm/session_server.py), [HTTP session contract](skills/tome-browser-battle/references/session-contract.md) |
| Build and exercise the real runtime | [Build inputs and delivery guide](tome_mvp/DELIVERY.md), [Wasm build guide](tome_mvp/wasm/README.md), [real Wasm probe](scripts/probe_tome_wasm.mjs) |

Start with the encounter example and session contract if you are integrating the engine. Inspect the worker's capabilities for the build you load before enabling actions. Base ToME rules, project adapters, and optional DLC content have different inputs. Treat save compatibility and skill support as properties of the build you actually test.

## First checks

The bridge and transport tests run on Node.js from the checkout. They verify JavaScript contracts using test doubles.

```sh
node --test tests/test_tome_wasm_bridge.mjs tests/test_tome_partition_transport.mjs
```

To exercise native combat, prepare the pinned upstream source, runtime inputs, and Emscripten toolchain using the build guide. Then point the real Wasm probe at your generated public directory.

```sh
node scripts/probe_tome_wasm.mjs path/to/build/public artifacts/real-probe.json
```

The checkout provides porting code, build scripts, integration contracts, and probes. A runnable kernel requires the build inputs above. Original ToME media and complete DLC packages are external inputs. The public repository covers the combat component.

## Upstream and license

Tales of Maj’Eyal and T-Engine 4 are developed by Nicolas Casalini (DarkGod) and upstream contributors. The covered source is distributed under the [GNU GPL v3](LICENSE). Original graphics, audio, and music are subject to their own terms. [ToME official license](https://te4.org/license) · [Upstream source setup](https://te4.org/wiki/Source_Setup)

---

# 中文介绍 · ToME Wasm 开源回合制战斗内核

ToME Wasm 将 **《Tales of Maj’Eyal》（ToME）1.7.6 的原生战斗规则**移植到 WebAssembly。T-Engine 4 的 Lua 规则和 C 运行时在浏览器 Web Worker 中执行。宿主应用通过 JavaScript 桥接发送动作并读取战斗观察。它最初为《口袋佣兵团》开发，适用于浏览器战术 RPG、Roguelike 战斗原型及需要可编程战斗模拟的应用。

## 能力

- 根据种子和配置生成地图、小队、敌人及初始摆放。可用内容由具体构建决定。
- 使用原生规则执行移动、攻击、技能和物品操作，读取地图、战况、动作回执和待答输入。
- 使用匹配的构建保存及恢复受支持的状态。会话宿主可保存检查点，并将战局交接给外部战役。
- 战斗回合在浏览器 Worker 内推进。宿主应用可以接入会话服务保存战局，单独维护自己的战役数据。

## 接入指南

| 任务 | 入口 |
| --- | --- |
| 理解浏览器 Worker 和动作桥接 | [浏览器 Worker](tome_mvp/wasm/browser_worker.mjs)、[EngineBridge](tome_mvp/wasm/engine_bridge.mjs)、[Wasm 加载器](tome_mvp/wasm/kernel_runtime.mjs) |
| 查看 RPC 和遭遇配置 | [Lua Worker](tome_mvp/headless/worker.lua)、[遭遇契约](skills/tome-browser-battle/references/encounter-contract.md)、[示例配置](skills/tome-browser-battle/references/encounter.example.json) |
| 保存战局或接入战役 | [会话服务](tome_mvp/wasm/session_server.py)、[HTTP 会话契约](skills/tome-browser-battle/references/session-contract.md) |
| 构建和验证真实内核 | [构建输入和交付说明](tome_mvp/DELIVERY.md)、[Wasm 构建指南](tome_mvp/wasm/README.md)、[真实 Wasm 探针](scripts/probe_tome_wasm.mjs) |

首次接入时先读示例配置和会话契约。加载内核后读取该构建报告的能力，再开放相应操作。上方 Node.js 测试命令可直接验证桥接与传输契约。验证原生战斗时，按构建指南准备固定版本的上游源码、运行输入和 Emscripten 工具链，再运行真实 Wasm 探针。技能与旧存档兼容范围以实际构建的验证结果为准。

## 上游与许可

ToME 和 T-Engine 4 由 Nicolas Casalini（DarkGod）及上游贡献者开发。适用源码按 [GNU GPL v3](LICENSE) 分发。原版图像、音效和音乐适用各自的条款。原版素材和完整 DLC 包由外部环境提供。 [ToME 官方许可](https://te4.org/license) · [上游源码获取](https://te4.org/wiki/Source_Setup)
