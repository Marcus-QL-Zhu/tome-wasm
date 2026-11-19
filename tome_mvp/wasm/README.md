# ToME 浏览器 Wasm MVP

目标与验收见[专项SPEC](../../plans/ToME浏览器WasmMVP_SPEC.md)。本入口将现有普通Lua运行时、C算法、ToME规则和固定AIoo插件放入浏览器Worker。它不是远程桌面串流，也不将战斗公式重写成JavaScript。

## 原生存档与地点架构

当前重构目标与模块入口见[专项实施计划](../../plans/ToME原生存档与区域持久化实施计划.md)及[联合记录](../../implementation/NATIVE_SAVE_INTEGRATION_20261115.md)。区域按世界地块挂载，分Level保存。正常恢复使用可信原生快照和未确认增量；原生快照构建开关默认关闭，未通过联合验收的测试构建不能替换玩家档。下述旧冻结包的完整日志恢复方式是历史兼容路径。

## 跑团人物页的规则Worker

人物升级与换装的本地生命周期入口为`dm_mvp/web_ui/character-worker.mjs`，由`dm_mvp/web_ui/app.js`调用。它导入已冻结的原生模块，不修改或重编译战斗内核。清洁草稿关窗复用；放弃修改时按原生hot片重置Lua状态，后续请求串序等待基线恢复。

发布前执行`scripts/prepare_character_assets.py --public <冻结public目录> --assets <已核验PNG目录> --cache <browser_db同目录/character-rule-cache> --build <人物存档build>`。缓存只含规则代码和原生图标，不得放入人物热片或世界存档。准备后以实际HTTP服务账号检查目录可读、gzip和304；目录不能继承root独占的临时权限。新原生构建增加模块依赖时更新发布清单。

上线与复测见[加载优化记录](../../implementation/T01_OPTIMIZATION_DEPLOY_20261116.md)。旧冻结包里的`character_worker.mjs`保留兼容入口，不是当前人物页生命周期的修改位置。

## 本机构建

需要已准备的ToME原生源码与规则，按[原生构建入口](../headless/README.md)定位。SDK放在工作区artifacts，不写全局PATH。官方工具来源为 https://github.com/emscripten-core/emsdk ，本批固定Emscripten 4.0.21。

```powershell
git clone --depth 1 https://github.com/emscripten-core/emsdk.git artifacts/toolchains/emsdk
python artifacts/toolchains/emsdk/emsdk.py install 4.0.21
python artifacts/toolchains/emsdk/emsdk.py activate --embedded 4.0.21
python scripts/build_tome_wasm.py --output artifacts/tome-black-screen-fix-20261112/mvp
python -m tome_mvp.wasm.serve --root artifacts/tome-black-screen-fix-20261112/mvp/public --port 8922
```

页面为 `http://127.0.0.1:8922/`。静态服务只加载本机页面、Wasm、Lua资源包和允许清单中的PNG；没有战斗POST接口。战斗由浏览器Worker推进。首次加载需要下载和初始化资源；热行动耗时另看地图提示栏。该读数不包含绘制。旧8921失败对照保留。

Z为原生探索，R为原生原地休息，空格为原生等待一回合。AIoo按钮启动连续扫荡，普通接敌不停止。危急和晕倒保留明确确认。按Esc可暂停。输入控件内的Z/R不触发快捷键。未知结果保留最后已确认的旧画面，操作锁止，可点击导出本地诊断。真实弹道与规则回调未被当作视觉忽略。

构建脚本只生成artifacts内的文件；不修改Steam、其他试玩服务或玩家局。持久服务通过完整输入日志和同一冻结构建重建复杂战局。先点击“保存战局”，再关闭或刷新；未保存行动仍会丢失。静态预览服务不提供存档。原生后端和64×64参考场景保留。

## 验证入口

当前试玩8936使用内容限制及复杂交互冻结包。逆悖法师与整局时间线技能不进入新场景。Projection、Over Mind、盗贼工具/陷阱、魔像成长与装备菜单的代表例已验证，含完整日志重放。入口、证据和未完成项见[本轮整合](../../implementation/TOME_CONTENT_BOUNDARY_INTEGRATION_20261112.md)。旧8935保持原样。

原生魔像控制代表例使用 `scripts/probe_tome_native_control.mjs`。普通健康队员不能直接控制。当前试玩8935及完整测试证据见[控制体记录](../../implementation/TOME_NATIVE_CONTROL_20261112.md)。旧8934及其战局保留，旧档不迁入新构建。

原生正常技能失败、耗时/不耗时、实际Lua错误及待输入的真实Wasm探针为 `scripts/probe_tome_rush_outcomes.mjs`。运行参数和本次浏览器结果见[Rush修复记录](../../implementation/TOME_RUSH_NORMAL_FAILURE_20261112.md)。测试插入只在探针的独立内存文件系统中生效，不添加生产调试开关。

可配置场景可由[项目skill](../../skills/tome-browser-battle/SKILL.md)启动。`--check`只校验数据结构；完整启动先做真实Wasm创建、只读查看和重置检查，再提供独立本地URL。通用目标和未完成项见[通用接入计划](../../plans/ToME通用战斗接入实施计划.md)。原版右键查看及技能优先选目标使用同一浏览器内核，不增加HTTP战斗结算。

```powershell
node --test tests/test_tome_wasm_bridge.mjs
node scripts/probe_tome_wasm.mjs
node scripts/probe_tome_wasm_parity.mjs
node scripts/probe_tome_automation_wasm.mjs artifacts/tome-automation-20261112/mvp/public artifacts/tome-automation-20261112/automation-probe.json
```

第一项是协议替身测试，不能证明ToME战斗。第二项加载真实编译模块并执行有界场景。第三项还需要本批独立20×20原生配置 `mvp/native_config.json`；对照同一控制器、输入和已发布观察，不宣称完整隐藏对象图或图形客户端逐位一致。证据保留在artifacts，实施结论另记。

本批实际验证、投影修复、性能及未完成项见[整合记录](../../implementation/TOME_WASM_INTEGRATION_20261111.md)。

三模式、危急条件与续额验证见[自动操作整合](../../implementation/TOME_AUTOMATION_INTEGRATION_20261112.md)。续额只在同一授权的安全决策点发生，不重新启动原生AI，不确认警报，也不重置反卡死计数。

当前构建、20种子成绩、两个新增真实Wasm探针及限制见[黑屏修复整合](../../implementation/TOME_BLACK_SCREEN_FIX_20261112.md)。

## 持久服务与非终局交接

```powershell
python -m tome_mvp.wasm.session_server --root artifacts/BUILD/public --data artifacts/BUILD/sessions --port 8928
```

即时战斗仍在浏览器Worker执行。服务器保存完整日志，并使用同一冻结包验证。点击“转为跑团”后，网页等待服务器确认，再进入没有Wasm的交接页。宿主可让敌人投降或按原位置、生命、属性、装备和状态重建为队友。返回链接恢复同一战局。具体HTTP合同见[会话合同](../../skills/tome-browser-battle/references/session-contract.md)。本地宿主接口和线上DM绑定分别验收。

通用技能输入通过原生协程暂停和恢复，不重启技能。Lua 5.1 的保护调用适配只用于原版技能入口。待答目标、菜单和数量可经存档恢复。一次性动画结束规则回调使用可重建的内核事件，在下一次角色行动前执行一次。暂停、查看和存档不触发它。周期性视觉规则回调仍明确拒绝，不静默忽略。

美术保留在宿主原生包，按PNG请求读取。Linux宿主设置 `TOME_NATIVE_INSTALL`，或显式传入 `--asset-archive`。素材文件可解码不等于所有组合与着色器已验收。测试与剩余边界见[本次实施记录](../../implementation/TOME_HANDOVER_ASSETS_20261112.md)。

一次性规则事件的实现、构建身份和代表例结果见[事件验收](../../implementation/TOME_RULE_EVENTS_20261112.md)。其余通用兼容缺口按专项计划推进，不把陨石通过视为全量认证。

AI菜单、目标和数值输入会挂起整个AI调度。等待期间可以保存，恢复后继续回答。取消、未生效和新倒地不执行备用动作。成功回答可完成当前调度，再等待玩家重新启动。原生计算预算跨待答保留。代表例、失败和范围见[AI待答与通道记录](../../implementation/TOME_AI_INPUT_FRAME_20261112.md)。
