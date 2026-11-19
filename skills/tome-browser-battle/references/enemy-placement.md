# 敌人追加摆放

四个工具均针对已准备好的 `job_id`。每次写入生成一名敌人，不推进回合。插件用工具调用 ID 防止传输重试重复生成；生成下一名敌人应使用下一次正常工具调用。

## 常用快捷方法

```json
{"job_id":"已返回的job_id","enemy_id":"thieve:THIEF_BANDIT"}
```

同房间用 `mercenary_spawn_enemy_here`。非本房间用 `mercenary_spawn_enemy_elsewhere`。需要四名就分别调用四次，不传 count、阵营、等级、血量或虚构朝向字段。

两种方法都保留地图原有的普通怪和 Rare。它们只控制新增敌人的初始位置，不限制后续移动、技能、撤退或包围。

## 房间的含义

优先使用 ToME `room_map[x][y].room` 原生编号。并非所有生成器都提供编号。无编号的室内布局用墙、门分隔的连通区；走廊也可能成为一个分区。门打开前后沿用同一分区。

没有房间时，兼容标识room_mode=outdoor_visibility仍保留，但位置按距离：here距操控角色≤10格，elsewhere距全部在场小队成员均>10格。10格只能属于here。距离取横纵差较大值，不依赖视野或潜行。

室内 elsewhere 只保证房间不同，不保证不可见，也不保证每名敌人在不同的其他房间。单房间酒馆没有其他房间时返回 `no_legal_placement`。角色站在未归属房间的门格时，快捷方法可返回 `player_not_in_room`；此时先查地图，再决定精确位置。

## 精确方法

1. `mercenary_battle_map {"job_id":"实际job","source":"thieve","include_tiles":true}`。
2. 从回执选择真实 enemy_id 和空闲地块。
3. `mercenary_spawn_enemy {"job_id":"实际job","enemy_id":"thieve:THIEF_BANDIT","x":12,"y":8}`。此坐标仅为格式示例，不能照搬到另一张地图。

坐标从 0 开始。原点在左上角，x 向右，y 向下。`tiles[y][x]` 中 `.` 可通行、`#` 阻挡、`@` 已被占用。`room_labels` 按 `x+y*width` 取值，0 表示无房间。visibility 中 p 是操控者视野，s 是其他队员共享视野，`.` 是当前不可见。

不传 source 时只列出可查询的原生 NPC 来源。指定 source 后仅列该来源的具体敌人，不一次加载完整怪物目录。目录查询在可丢弃的重建实例中执行，不写入正式战斗。

精确坐标必须在地图范围内、可通行且无角色占用。失败不会静默挪到邻格。世界地图坐标不能直接用作战斗格子坐标。

## few-shot

情境：森林 Zone 已就绪，返回 job_id=forest_ready_12。四名土匪迎面出现。

```text
mercenary_spawn_enemy_here({"job_id":"forest_ready_12","enemy_id":"thieve:THIEF_BANDIT"})
mercenary_spawn_enemy_here({"job_id":"forest_ready_12","enemy_id":"thieve:THIEF_BANDIT"})
mercenary_spawn_enemy_here({"job_id":"forest_ready_12","enemy_id":"thieve:THIEF_BANDIT"})
mercenary_spawn_enemy_here({"job_id":"forest_ready_12","enemy_id":"thieve:THIEF_BANDIT"})
```

情境：同一片森林里藏着四名土匪，需要搜索。把上面四次调用全部换成 `mercenary_spawn_enemy_elsewhere`。仍使用实际返回的 job。工具回执确认四次生成后，才能说这批敌人已经落地。

情境：剧情要求一名指定敌人位于地牢北侧祭台格。先查该场景的目录和完整格子图，再用精确方法。不要为了满足剧情绕过墙体或占用检查。
