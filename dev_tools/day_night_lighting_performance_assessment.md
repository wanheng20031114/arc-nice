# 昼夜与局部灯光性能评估

测试日期：2026-07-19
Godot：4.6.3 stable，D3D12 Forward+
GPU：NVIDIA GeForce RTX 3080
固定测试环境：1152×648、VSync 开启、60 FPS 上限

## 结论

- `DayNightController` 和 `NightPointLight2D` 均没有 `_process` 或
  `_physics_process`。稳定白天会把所有昼夜灯设置为 `enabled=false`、
  `energy=0`，因此常驻场景不产生持续脚本更新，也不提交灯光绘制。
- 玩家、红蓝门与确实需要照明的状态格灯节点可以保留在各自 `.tscn` 中，无需
  在昼夜切换时动态实例化或销毁。植被桩已不再包含 `Light2D`，其粒子仅使用
  `UNSHADED` 保持夜间自身可见。
- 100 个可见合成环灯压力夹具在完整 3 秒双向渐变中，Render CPU p95 最高为
  `0.444 ms`、GPU p95 最高为 `0.446 ms`、Wall p95 最高为
  `16.691 ms`；没有观察到渐变更新造成的掉帧。
- 256 个可见合成环灯的额外诊断中，完整渐变的 Render CPU p95 最高为
  `0.984 ms`、GPU p95 最高为 `0.644 ms`、Wall p95 最高为
  `17.051 ms`。256 是当前多人队伍的植物数量上限，并不是单人模式的全局
  硬上限；因此这只能说明当前 100 座压力目标以及多人上限以内无需动态加载。
- 300 盏灯同步更新一次 `night_factor` 的纯主线程广播 CPU p95 为
  `0.221 ms`、最大 `0.325 ms`。此微基准只衡量信号回调及
  `enabled/energy` 属性写入，不代替上述真实渲染渐变数据。
- 光照成本仍主要由屏幕覆盖面积与重叠决定。若未来扩大
  `texture_scale`、开启阴影，或允许单人场景中同时可见超过 256 个局部灯，
  应重新运行探针并考虑可见性/数量预算。

> 2026-07-20 视觉调整后，植被环灯已从运行时场景移除。下列 100/256 灯数据
> 保留为通用局部灯最坏情况压力参考，不再代表植被桩的实际运行时数量。

## 正式 100 灯样本

| 阶段 | 活跃灯 | Wall p95 | Render CPU p95 | GPU p95 | Draw Call p50 |
|---|---:|---:|---:|---:|---:|
| 初始白天 | 0 | 16.697 ms | 0.378 ms | 0.128 ms | 58 |
| 玩家与门夜灯 | 8 | 16.694 ms | 0.477 ms | 0.237 ms | 62 |
| 100 个分散绿环 | 108 | 16.692 ms | 0.486 ms | 0.448 ms | 58 |
| 100 个密集绿环 | 108 | 16.697 ms | 0.464 ms | 0.416 ms | 60 |
| 夜→昼 3 秒渐变 | 动态 | 16.688 ms | 0.444 ms | 0.445 ms | 60 |
| 返回白天 | 0 | 16.688 ms | 0.438 ms | 0.219 ms | 58 |
| 昼→夜 3 秒渐变 | 动态 | 16.691 ms | 0.436 ms | 0.446 ms | 60 |

Wall 时间受 60 Hz VSync 调度约束，因此性能判断以 Render CPU/GPU 增量为主。
返回白天后活跃灯数量归零，Draw Call 回到初始白天值。

## 256 灯多人上限诊断

按当前多人队伍植物数量上限运行缩短稳态采样；两段渐变仍完整运行 3 秒：

| 阶段 | 活跃灯 | Wall p95 | Render CPU p95 | GPU p95 |
|---|---:|---:|---:|---:|
| 256 个分散绿环 | 264 | 16.942 ms | 0.956 ms | 0.202 ms |
| 256 个密集绿环 | 264 | 16.903 ms | 0.956 ms | 0.204 ms |
| 夜→昼 3 秒渐变 | 动态 | 17.051 ms | 0.984 ms | 0.544 ms |
| 返回白天 | 0 | 16.896 ms | 0.743 ms | 0.250 ms |
| 昼→夜 3 秒渐变 | 动态 | 17.044 ms | 0.761 ms | 0.644 ms |

探针会硬性断言 256 个压力灯全部处于相机可见范围，避免离屏灯导致静默低估。

## 复现命令

正式样本必须使用真实渲染驱动，不能添加 `--headless`：

```powershell
& 'C:\Program Files\Godot\Godot_console.exe' `
  --path . `
  --script res://dev_tools/day_night_lighting_performance_probe.gd
```

256 灯上限诊断：

```powershell
& 'C:\Program Files\Godot\Godot_console.exe' `
  --path . `
  --script res://dev_tools/day_night_lighting_performance_probe.gd `
  -- --lights=256 --warmup=20 --samples=60 --micro-samples=100
```

需要人工检查一次分散灯布局时，可在 `--` 后追加 `--screenshot`。截图写入
`user://day_night_lighting_probe.png`，位于 Godot 用户数据目录，不会污染
Git 工作区。

探针内置以下回归门槛：

- 100 灯 Render CPU p95 增量不超过 `0.5 ms`；
- 100 灯 GPU p95 增量不超过 `1.0 ms`；
- 100 灯真实渐变 Render CPU/GPU p95 增量分别不超过 `1.0/1.5 ms`；
- 超过 100 灯的诊断渐变 Render CPU/GPU p95 增量分别不超过
  `2.0/4.0 ms`；
- 100/256 灯 Wall p95 不超过 `20 ms`；
- 300 灯主线程广播 CPU p95 不超过 `1 ms`、最大不超过 `2 ms`；
- 返回白天后全部灯关闭，Draw Call 回到初始白天的 ±1。
