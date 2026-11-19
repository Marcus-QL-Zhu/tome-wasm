# DM开战入口

用途：进入已经确定要游玩的局部区域，或处理确实发生的战斗。不是提案、报价或后台剧本筹备。已有战斗继续使用原job，不再新开。

使用已有 `mercenary_game`，先查询：

```json
{"operation":"look","parameters_json":"{\"kind\":\"local_areas\"}"}
```

实际进入时调用：

```json
{"operation":"start_battle","parameters_json":"{\"scene\":\"forest\",\"area\":{\"local_key\":\"北方森林\",\"floor_count\":1}}"}
```

进入持久区域须提供area。首次提供稳定local_key和floor_count；重访给area_id或相同local_key。floor从1开始，最多20层。先用上述 look 查询当前地块的已登记区域。宿主核对真实位置并计算ID，DM不计算哈希。

当前公开入口只支持forest、dungeon和cave，每层固定64×64，size可省略或填64。城市活动由跑团主持；尚未接通的城镇/酒馆持久地图不在公开schema中。森林只允许一层，地牢与洞窟可多层。

```json
{"operation":"start_battle","parameters_json":"{\"scene\":\"dungeon\",\"area\":{\"local_key\":\"旧城区下水道\",\"floor_count\":2,\"floor\":1}}"}
```

开战可传difficulty为easy、normal、hard，默认normal；specified_enemies为可选列表，每项enemy_id或person_id、count、difficulty、same_room。未给个体难度则继承整场，默认数量1、同房间true。首次世界人物要合法enemy_id和真实person_id；已有绑定人物只需person_id，保持原生等级装备。宿主核对存活和实际地块，全组原生准备后才ready。description仍不支持。已有ready场景追加敌人仍可用快捷工具，不重开地图。

玩家的战术愿望不是已成立事实。“别让敌人包围我们”不能改写成“敌人不许绕后”。可以描述已经确定的初始相对位置，但不能保证后续战果或限制原生AI。

宿主负责小队当前状态、等效参考等级、Nightmare规则、常规人口与种子。固定区域Boss关闭。所有生态共用一套小队强度映射，保留原生生态难度差异。75%～90%只作整体难度参照，不保证每种地图或每场获胜。不能以剧情叙述替代真实状态变更。

新区域直接调用开战工具，不必先查战斗状态。仅当上下文或回执已提供job_id时，才用`battle_status {job_id}`查询；没有job_id不能空查或猜编号。preparing只表示准备中。ready或active后用`open_game {}`取得真实入口。

`battle_status`已能读取交接及终局收据，不需要再选battle_handover或battle_finish。sync_pending表示宿主尚在同步，等待即可，不通过恢复来催促同步。synced且当前原生view为victory或defeat时，按真实结果回到跑团，不恢复终局。

同步中可简短告诉玩家正在保存，然后结束这一轮等待宿主通知，不连续查询目录或人物来催促它完成。终局已同步时，根据已有结果回应；缺少具体伤势就保留未知，不为了收束而编造伤势或发奖。

只有玩家明确继续同一局、当前原生view非终局、并且已经同步的中断，才使用`battle_resume {job_id,handover_id,action_id,operations}`。不改状态则operations为[]，action_id为本次恢复的稳定ID。handover_id单独出现不证明可以恢复。恢复不能新开局，结束不能假定已回血。

持久地点使用已有通用工具，不调用未注册的专用开战工具。原生存档、场景要求、剧情Boss和任意布局仍以宿主实际支持范围为准。普通人口年度刷新由宿主按世界时钟判断，不凭叙述重置现场。

## 按需选敌人与人物

开战前可用look {kind:"battle_enemies"}查原生来源，再用look {kind:"battle_enemies",source:"thieve"}查该来源的enemy_id，不需要job也不生成地点。目录可加载不等于所有内容已验证，执行仍有内容边界。

普通盗匪示例：start_battle {scene:"forest",area:{local_key:"北林",floor_count:1},difficulty:"normal",specified_enemies:[{enemy_id:"thieve:THIEF_BANDIT",count:3,same_room:true}]}。

具体人物首次指定person_id和合法enemy_id；再次战斗只用同一person_id。不能以同名或相同enemy_id代替身份。具名人物的难度不重抽；若宿主报告死亡、位置不符或存档未知，保留实际结果，不换ID绕过。
