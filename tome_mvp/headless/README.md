# ToME 无图形构建

源码提取命令：`python scripts/prepare_tome_headless_source.py`。

官方源码仅保存于 Git 忽略的 `artifacts/tome-headless-build-20261109/source/`。运行 `python scripts/prepare_tome_headless_runtime.py` 生成规则资料。逐文件摘要、范围与限制见 [构建准备记录](../../implementation/TOME_HEADLESS_BUILD_PREPARATION_20261109.md)。

Windows 实验构建使用隔离目录中的 `tccbox==2025.10.27`。若该依赖缺失，可在工作区执行 `python -m pip install --no-deps --target artifacts/tome-headless-consult-20261109/vendor tccbox==2025.10.27`，然后执行 `python scripts/build_tome_headless_windows.py`。构建脚本会核对编译器和上游源码的固定摘要。

当前候选构建先执行 `python -m tome_mvp.prepare_player_aioo`，再执行 `python scripts/build_tome_headless_windows.py --output artifacts/tome-rescue-20261111/candidate`。生成的 `candidate/worker_config.json` 包含当前机器的 worker 命令和资源路径，可作为网页服务的 `--config` 参数。配置只适用于当前工作区位置。

当前工程场景为全亮 64×64、三名友方和五名敌方。支持创建、共享观察、同进程重置、移动、等待、近战、原生弓箭、代表技能及 Player AIoo Custom 的战斗、休息和探索路径。角色、攻击、队友 AI、视野和调度使用 ToME 原生代码；公开观察合并存活队友视野，个人攻击仍使用个人条件。动作按预算推进原生 tick。

存档保留真实对象图、世界记录、调度、SFMT、正态采样缓存和已停止的 AIoo 状态。仅支持已验证的决策边界；在途箭、未处理回调和未知对象明确拒绝。恢复使用新 worker 验证后替换旧 worker；新局重置仍在同一 OS 进程重建 Lua VM。本作晕倒、救援、接管及全队新倒地确认已接入，见[救援整合记录](../../implementation/TOME_RESCUE_INTEGRATION_20261111.md)。当前 v4 build 保留决策阶段、策略、控制身份和待确认事件；旧 v1–v3 明确拒绝。活动救援、未知回调与在途投射物仍可拒存。其他复杂技能与交互、特殊感知、任意时刻存档及长期战局未完成。AI 启动、许可、阶段和停止语义见[当前整合记录](../../implementation/TOME_AIOO_INTEGRATION_20261110.md)。验证与范围见[本轮整合](../../implementation/TOME_EXPANSION_INTEGRATION_20261110.md)及[原生实施](../../implementation/TOME_NATIVE_EXPANSION_20261109.md)。

交付打包、构建路径与分组验收见 [交付说明](../DELIVERY.md)。来源归档采用离线固定摘要；旧的无完整归档摘要记录不能通过新 doctor。
