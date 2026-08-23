# 敌人模拟 A/B 证据协议

敌人模拟实验统一使用 `--enemy-simulation-mode=LEGACY|COMPAT_60|LAYERED_AREA|LAYERED_CONTACT`。未提供参数、参数未知或策略资源缺失时必须回到 `LEGACY`。

正式性能证据需满足：

- 同一提交、同一 Godot 版本、固定种子和相同权威 Tick 数；
- 300 Tick 预热、至少 1800 个采样 Tick，ABBA 顺序且至少三组配对；
- 性能运行关闭详细事件签名，语义运行单独记录事件计数和稳定签名；
- 保存完整命令、Git SHA、工作树状态、原始 JSON、环境信息及 SHA256；
- 主场景总帧时间 p95 相对 `LEGACY` 降低至少 15%，关键场景不得回退超过 3%；
- 退出后核实没有遗留 `--headless` 或 `--check-only` Godot 进程。

`EnemySimulationEvidenceRecorder` 只接受整数 Tick、稳定模拟 ID 和整数负载。位置、生命等浮点状态应在调用方按明确比例量化后记录，禁止把 Dictionary 或本地 `instance_id` 直接混入跨模式签名。
