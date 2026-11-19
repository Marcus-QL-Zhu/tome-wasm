# ToME 战斗内核与网页

本项目正式采用ToME原生战斗规则和AI。此目录与保留的`gameplay_mvp/` CDDA实现分开，当前主线为浏览器Web Worker中的Wasm战斗。持久区域固定64×64，目前支持森林、地牢和洞窟；旧开发配置仍支持10～64边长的独立地图。独立常驻无图形后台保留作参考和其他接合。

DM入口见[项目skill](../skills/tome-browser-battle/SKILL.md)。使用既有mercenary_game的look查询当前地块地点，start_battle带scene和area实际进入。一个地块挂多个区域，每个区域按Level保存；不按固定九宫格展开。新区域和年度普通人口刷新共用[统一小队等级映射](../docs/TOME_ZONE_LEVEL_INTERFACE.md)。旧选怪实验见[历史实测](../implementation/TOME_ENCOUNTER_GENERATOR_20261114.md)，不把离线分类准确率当作难度平衡验收。

人物、装备和局部现场复用ToME原生对象存读。服务器保留权威热人物片及冷Zone/Level片，营地换装不重放全部历史。旧日志档只在迁移时重演一次。设计见[存档与区域计划](../plans/ToME原生存档与区域持久化实施计划.md)，实际交付和限制见[部署记录](../implementation/NATIVE_SAVE_DEPLOY_20261115.md)。

范围与验收：[无图形内核SPEC](../plans/ToME无图形战斗内核SPEC.md)及[实施计划](../plans/ToME无图形战斗内核实施计划.md)。设计依据：[架构调研](../research/ToME后台内核与浏览器运行可行性_20261109.md)。

旧桌面试接能力和浏览器结果见[历史整合记录](../implementation/TOME_INTEGRATION_20261109.md)。该宿主依赖图形上下文，不作为无图形后台验收。未验能力由页面明确列出。

## 浏览器Wasm入口

正式游戏从已授权的WebUI进入，访问说明见[浏览器授权](../docs/BROWSER_ACCESS.md)。历史本机测试入口为 `http://127.0.0.1:8936/`，不保证该进程仍运行。该包限制整局时间线内容，补齐投影、思想体及复杂菜单代表例；支持魔像成长、装备管理和待答存读。见[历史整合](../implementation/TOME_CONTENT_BOUNDARY_INTEGRATION_20261112.md)。玩法范围及尚未认证的内容由各专项记录说明，不把代表例通过称为全量兼容。

Z调用原生探索，R调用原地休息；AIoo连续扫荡接合探索、战斗与恢复。危急时停止，玩家显式继续后不重复确认同一持续条件；新的危急和晕倒仍会停止。模式合同见[自动操作整合](../implementation/TOME_AUTOMATION_INTEGRATION_20261112.md)。

构建、静态服务和验证命令见[Wasm README](wasm/README.md)，目标见[专项SPEC](../plans/ToME浏览器WasmMVP_SPEC.md)。战斗在浏览器执行，持久宿主用匹配的冻结内核验证未确认增量，提交新的原生检查点；完整日志保留作审计，不是正常恢复起点。保存成功后可刷新恢复同局，尚未保存的行动仍会丢失。旧日志格式保留兼容路径；纯静态服务不提供权威保存。

## 运行边界

可配置战斗和原版操作补全见[通用接入SPEC](../plans/ToME通用战斗接入SPEC.md)、[实施计划](../plans/ToME通用战斗接入实施计划.md)和[实施记录](../implementation/TOME_GENERALIZATION_20261112.md)。项目skill已接现有DM通用工具，未新增专用开战工具。全技能和任意剧情要求仍须独立验收。

- 使用本机 ToME 1.7.6 的真实内核；本目录不含自写 Python 战斗公式。
- 内部测试网页暂用本机ToME原生素材；后续替换。提取物只进artifacts，保留来源清单，不修改安装、不进入Git或外网发布。无图形worker仍不加载美术。
- Steam 安装与旧用户存档保持只读。会话文件写入本工作树的 `artifacts/`。
- 当前 Windows worker 不创建窗口，不加载 SDL、OpenGL 或音频库。真实动作和网页联调见[本轮整合记录](../implementation/TOME_EXPANSION_INTEGRATION_20261110.md)。该结论限于已验证的工程场景。
- 页面只启用原生桥明确声明支持的能力。离线页面和协议单测不构成真实场景验收。

## 原生参考服务入口

正式入口从本工作树根目录运行，使用明确配置的 worker 参数数组：

```powershell
python -m tome_mvp.server --backend headless --config artifacts/tome-door-fov-20261111/fov-full/worker_config.json --port 8918 --session fov-preview-20261111 --seed 12 --fixture formal
```

打开 `http://127.0.0.1:8918/`。此入口使用三份官方档案来源化重建的小队、五名原生 Rare 和原生 Rooms 地图。人物与装备差异、内部测试素材及验收边界见[正式配置](../docs/TOME_FORMAL_TEST_CONFIGURATION.md)和[整合记录](../implementation/TOME_FORMAL_INTEGRATION_20261111.md)。新增点击移动、探索自动开门和输入延迟优化见[输入整合](../implementation/TOME_INPUT_INTEGRATION_20261111.md)。手动开门视野刷新和队友便携灯共享修复见[视野整合](../implementation/TOME_DOOR_FOV_INTEGRATION_20261111.md)。旧8916、8917试玩战局保留；旧进程没有热更新。原生素材先按观察清单运行 `scripts/prepare_tome_web_assets.py` 提取到本机 artifacts；配置和提取物不是跨机器安装包。

以上路径来自本机已完成的构建。其他机器先按[构建说明](headless/README.md)准备来源、规则资料和 worker，再使用生成的配置。配置格式见 [example](../config/tome_headless_runtime.example.json)。缺少 worker 会报错，不回退到桌面或 Python 模拟。旧 `artifacts/tome-rescue-20261111/ack-candidate/worker_config.json` 保留作晕倒与救援工程回归，不能当作正式小队配置。

旧桌面试接仅通过显式后端运行：

```powershell
python -m tome_mvp.server --backend desktop --port 8910 --session trial-7 --seed 7
```

打开 `http://127.0.0.1:8910/`。首版接口只绑定本机，写操作要求同源和当前 `revision`。

服务在一局及多次场景重置期间保留同一个 worker 进程。使用网页“新局”按钮重置场景，不需要关闭再启动服务。重置会重建 Lua VM 并重载规则，更新场景代数和控制版本，取消旧自动队列。它不是复用 Lua 状态的热重置。旧桌面入口还要求新的空会话目录，避免覆盖旧证据。

原生场景初始化未完成或桥未就绪时，页面应明确显示离线。不要据此宣称已完成 ToME 接合。

## 来源与运行依赖

本机配置 `artifacts/tome-rescue-20261111/ack-candidate/worker_config.json` 指向构建出的无图形 worker 与规则运行根。它属于本机构建配置；只有重建并核对后才能代表更新后的候选。`artifacts/tome-headless-build-20261109/runtime/` 保存运行所需的 ToME 规则和引擎。`artifacts/tome-feasibility-20261109/addon/source/` 保存 Player AIoo Custom 1.4.3 来源。上述目录是构建和运行依赖，不是可随意删除的旧模拟产物。

准备固定原始插件：

```powershell
python -m tome_mvp.prepare_player_aioo
```

脚本核对 `superload/mod/class/Player.lua` 的 SHA-256 为 `97c501f50a730b08e18f680e548191559ece9d65f1aa246668b27ba66fb8aa97`，再将原字节复制到 `artifacts/tome-control-expansion-20261109/player_aioo_original.lua`。当前候选 worker 构建时校验并嵌入原始插件。该插件来源和版本记录见 [来源记录](../artifacts/tome-feasibility-20261109/addon/origin.json)。复制时校验本身不证明运行时加载字节未被替换；候选构建将核验后嵌入原始字节，运行时使用嵌入版本。该路径须经构建和联调验证。原插件和运行资料可保持 Git 忽略，不复制Steam用户存档。内部网页素材由独立允许清单提取，保持安装只读。

## 测试分类

HTTP 测试使用注入服务，验证版本、能力、暂停排队和请求边界。原生动作必须另有真实进程、场景与结果记录。运行证据放入 `artifacts/`，结论放入 `implementation/`。

当前可用：64×64 全亮工程场景、三友五敌、小队共享当前有效视野、移动及原生换位、等待、近战、弓箭射击、代表技能、AIoo 战斗—休息—探索、暂停和同进程重置。弹药、耐力和冷却来自原生结果。初始可见敌人数不代表总敌人数。局部战斗不接 MiniMax，也不接旧小队指挥层。

“暂停并保存”先显式停止 AI，再保存真实状态；“恢复”先在新 worker 中验证存档，成功才替换当前 worker。固定槽在 `artifacts/tome-control-saves/<session>/slot.json`。普通动作决策点可保存；活动 AI、在途投射物、未处理回调和未知对象会被拒绝。存档不是通用 ToME 战役交换格式。worker 异常退出后，有合法保存槽时仍可显式恢复，不自动重放动作。

正式小队的复杂装备和回调图当前尚未通过存读验收，会明确拒存。工程存档的通过结果不代表正式小队可恢复；当前试玩不要依赖保存保留战局进度。

AIoo 使用固定来源的原插件逻辑。网页显示阶段和停止原因。停止会撤销旧授权，只有玩家再次点击自动托管才会恢复。工程请求预算为 1–500 的整数，与插件自身保护计数分开。网络结果未知时不重放动作；无法确认暂停时明确提示。

网页可编辑原生技能相对权重、稀有敌人和敌人数停止设置，并保存或载入独立策略模板。0 禁止战术选择，1 为默认；手动使用不受影响，插件独立维护操作可能不使用该权重。应用或载入策略会先停止 AI。

代表技能覆盖远程射弹、射线、远程范围、近战范围、锁血、减益、治疗、即时增益、持续开关及 Rush。特殊交互和未验证技能明确拒绝，不按已注册数量宣称支持。当前 v6 build 保存工程场景决策阶段、策略、控制身份、晕倒确认事件及导航通行记忆。旧 build 明确拒绝，旧文件保留。活动导航拒存，正式小队复杂存档的限制保持。

验证见[本轮整合](../implementation/TOME_AIOO_INTEGRATION_20261110.md)。复用真实 worker→HTTP→正式前端脚本测试：设置 `TOME_E2E_WORKER_CONFIG`，并以 `TOME_E2E_RESCUE=1` 开启救援用例后运行 `python -m pytest tests/test_tome_web_real_e2e.py -q`。需 Node；依赖缺失会明确跳过。该测试使用最小 DOM，真实浏览器另行验证。

已接入本作晕倒、救援和接管：三名成员最终致死转晕倒，生命锁0，不行动、不被敌人选为目标。相邻救援持续20个原生角色回合，完成后恢复20%生命。受伤、失能、位移或取消中断。任何成员新晕倒均急停，网页须明确确认后才可推进；确认不自动重启托管。主控晕倒可接管健康队员，团长恢复后可交还。

[本批整合与验收](../implementation/TOME_RESCUE_INTEGRATION_20261111.md)区分原生探针、真实HTTP/正式脚本及浏览器证据。合法边界存读保留控制者和待确认事件；活动救援、在途投射物及未处理回调仍会明确拒存。自然急停若有待执行回调，不会为保存而擅自推进时间。

仍待完成：全部技能和复杂交互、任意时刻存档、动态照明与特殊感知的完整覆盖、长期救援战局和 Wasm。本轮有界验证不等于完整自然自动清图或玩法平衡验收。
