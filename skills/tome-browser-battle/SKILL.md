---
name: tome-browser-battle
description: Create, continue or inspect playable ToME browser battles for the mercenary Dungeon Master. Add specific enemies in the current room, elsewhere, or at an exact tile. Also validate and launch developer encounters. Use native results; not for ordinary narration, world simulation or rewards.
---

# ToME browser battle

使用真实 ToME Wasm 规则。玩家可以手动操作或启用 AIoo。不要用叙述替代实际生成、伤害或结算。

## 进入或继续场景

先看当前可用工具。新场景采用已绑定的开战入口；已有场景沿用原 `job_id`。不要为追加敌人重开地图或重置人物。

开战调用超时或返回结果未知时，不要再次提交新开战。先调用 `mercenary_game` 的 `brief`，从 `browser_battles` 取得实际 `job_id`，再用该 ID 查询 `battle_status`；不猜任务号，不空参查询。`preparing` 包括持久地点创建和原生战场准备，继续查询同一任务即可。`unknown` 或 `access_blocked` 表示尚不可交接，应保留任务并说明阻塞，不能把重试当作新场景。

使用已绑定的 `mercenary_game`。先调用 `operation="look"`，令 `parameters_json` 为 `{"kind":"local_areas"}`，查询当前地块的持久地点。进入地点时调用 `operation="start_battle"`，令 `parameters_json` 包含 `scene` 和 `area`。首次给稳定 `local_key` 与 `floor_count`；重访给已有 `area_id` 或相同 `local_key`，并给目标 `floor`（从1开始）。宿主计算 ID 并核对位置；不要自行计算 ID，也不要以地图类型代替地点身份。剧情要求尚不支持时宿主会拒绝，不能当作已经生成。详细参数见 [DM 入口](references/dm-entry.md)。宿主必须启用同包的原生分区存档；入口不可用时保留实际错误，不改走重建人物或重开旧地点的路径。

当前持久区域固定64×64，只支持森林、地牢和洞窟，森林仅一层。城市活动通过跑团处理。其他地图尺寸属于兼容开发接口，不能传给当前区域开战入口；不要求玩家填写格数。`preparing`只表示准备中。新开战将指定敌人放入同一请求的specified_enemies；全部原生生成并保存后才ready和打开页面。

## 追加剧情敌人

每次调用只追加一名敌人，不替换地图的原生人口。已有受支持的 ready 场景时，优先用快捷入口：

- `mercenary_spawn_enemy_here(job_id, enemy_id)`：与当前操控角色同房间。没有房间时，距该角色10格以内（含10）。
- `mercenary_spawn_enemy_elsewhere(job_id, enemy_id)`：有房间时在其他房间；没有房间时，距全小队每名在场成员均超过10格。不保证几名敌人各占一个不同房间。

普通土匪的原生 ID 为 `thieve:THIEF_BANDIT`。已知 ID 时可直接用快捷方法，不必先查整张地图。其他类型按需查询 `mercenary_battle_map(job_id, source=...)` 的目录，不猜 ID。等级和装备沿用原生工厂。人物没有朝向，“迎面”不代表一套绕背规则。

**例：森林里迎面遇到四名土匪。** 保留标准森林 Zone。在start_battle中加`specified_enemies:[{"enemy_id":"thieve:THIEF_BANDIT","count":4,"same_room":true}]`。宿主统一准备，取得ready与全部敌人回执后交接。

**例：森林里藏着四名土匪，需要逐个搜出。** 在统一开战请求中加`specified_enemies:[{"enemy_id":"thieve:THIEF_BANDIT","count":4,"same_room":false}]`。不要把四名土匪放在出生房间，也不要删除森林本来的敌人。

只有剧情要求精确到格子时，才读 [精确摆放与房间语义](references/enemy-placement.md)。先查询实际地图，再调用 `mercenary_spawn_enemy(job_id, enemy_id, x, y)`。坐标非法、被占用或没有其他房间时，工具明确拒绝。不得把拒绝说成已经生成。

这些工具需要包含摆放模块的冻结内核及匹配的宿主插件。项目文件存在不表示服务器已升级。没有对应工具时，不编造调用或生成结果。

## 交回玩家和跑团

ready 后优先使用宿主返回的 `player_url`，不自行拼接或猜测战局ID；没有该字段时用 `open_game` 获取玩家入口。Web会话将该链接呈现为“进入战斗”按钮，打开并行的战斗标签；飞书仍发送同一个网页链接。玩家点击“返回跑团”并保存交接后，会看到提示，再主动向DM搭话。不要在玩家未发话时自动推进剧情。接到玩家发话后，先读 `battle_status` 的真实中断或终局收据，再继续主持。保留人物 HP、效果、冷却、装备和背包；结束不会由 DM 自动休息回血。详细存读与恢复见 [会话合同](references/session-contract.md)。

只有已核验的全员倒地结算才能宣布团灭。永久死亡、团长 1 HP 撤出和物品遗留以宿主结算为准。继续原局不能重建人物或复活死者。

需要手工配置人物、技能、装备或特殊遭遇估算时，按需读 [遭遇合同](references/encounter-contract.md)，不在普通摆放流程里加载全部工厂参数。
