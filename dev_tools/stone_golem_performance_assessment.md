# 石头人 300 数量压力测试

日期：2026-07-18
Godot：4.6.3 stable
渲染：D3D12 / Forward+ / NVIDIA GeForce RTX 3080
测试方式：真实塔防场景与渲染窗口，固定种子，60 FPS 上限

## 口径

石头人使用与中等体量骑士完全相同的生产塔防场景、共享
`GridPathfinder`、玩家/基地目标分配、碰撞、镜头和运行时遥测。每轮均创建
300 个真实敌人，不使用空节点替身。`approach` 比较持续移动和寻路；
`engagement` 强制附近玩家目标，覆盖前摇、攻击状态和范围查询。

Windows 60 Hz 帧节拍会在 16.667 ms 两侧抖动，因此主要比较同机同参数的
p95/p99、物理时间、导航积压、节点/内存稳定性和砸地查询累计。

## 结果

### 300 数量接近阶段

60 帧预热，360 帧采样：

| 指标 | 骑士基线 | 石头人 |
|---|---:|---:|
| 墙钟 p95 | 24.645 ms | 25.118 ms |
| 墙钟 p99 | 29.217 ms | 27.484 ms |
| 物理 p95 | 12.942 ms | 13.030 ms |
| 导航延迟 / 窗口结束积压 | 29 / 0 | 0 / 0 |
| 节点峰值 | 6572 | 6281 |
| Godot 静态内存峰值 | 184.132 MiB | 181.992 MiB |

石头人的移动/寻路负载没有显著劣于同体量骑士，且本轮没有导航预算饱和。

### 300 数量持续交战

180 帧预热，600 帧采样：

| 指标 | 骑士对照 | 石头人 |
|---|---:|---:|
| 全程存活 | 300 / 300 | 300 / 300 |
| 墙钟 p95 | 155.865 ms | 26.185 ms |
| 墙钟 p99 | 165.821 ms | 29.548 ms |
| 物理 p95 | 27.952 ms | 17.419 ms |
| 导航延迟 / 窗口结束积压 | 39003 / 236 | 0 / 0 |
| 节点峰值 | 6725 | 6281 |
| Godot 静态内存峰值 | 187.083 MiB | 185.256 MiB |

石头人在采样窗内执行 328 次砸地形状查询，纯查询累计 8.248 ms，约
25.1 微秒/次；包含目标去重与伤害派发的整次砸地处理累计 9.971 ms，约
30.4 微秒/次。共执行 328 次底层物理查询。玩家持续移动，因此仅 16 次查询在
实际伤害帧仍覆盖目标，这属于前摇可躲避语义。查询对象、圆形资源、警示与冲击
节点均复用，对象池 `created/dropped/overflow/in_use` 增量全部为 0，节点数
没有增长。

专用功能测试另以单次砸地覆盖 70 个密集植物目标，确认分页查询不会在默认单页
上限处截断，并保证每个目标只受一次伤害。

## 结论

300 数量并不满足“所有机器稳定 60 FPS”的绝对承诺；本机同体量骑士基线本身
已经超过 16.667 ms。石头人的验收结论是：

- 移动/寻路阶段不劣于同体量骑士；
- 高密度砸地没有新增导航积压、对象池扩张或节点/内存持续增长；
- 形状查询成本保持线性且相对整帧很小；
- 0.35 秒实例错峰避免 300 个单位在同一帧同时提交首次攻击。

## 复现

```powershell
& .\dev_tools\run_tower_defense_enemy_cohort_probe.ps1 `
  -EnemyConfig res://resources/config/enemies/stone_golem.tres `
  -Phase approach -EnemyCount 300 `
  -WarmupFrames 60 -SampleFrames 360 `
  -EnemyHotMetrics $true -RuntimeCountScans $true

& .\dev_tools\run_tower_defense_enemy_cohort_probe.ps1 `
  -EnemyConfig res://resources/config/enemies/stone_golem.tres `
  -Phase engagement -EnemyCount 300 `
  -WarmupFrames 180 -SampleFrames 600 `
  -EnemyHotMetrics $true -RuntimeCountScans $true

& .\dev_tools\run_tower_defense_enemy_cohort_probe.ps1 `
  -EnemyConfig res://resources/config/enemies/capoo_knight.tres `
  -Phase approach -EnemyCount 300 `
  -WarmupFrames 60 -SampleFrames 360 `
  -EnemyHotMetrics $true -RuntimeCountScans $true

& .\dev_tools\run_tower_defense_enemy_cohort_probe.ps1 `
  -EnemyConfig res://resources/config/enemies/capoo_knight.tres `
  -Phase engagement -EnemyCount 300 `
  -WarmupFrames 180 -SampleFrames 600 `
  -EnemyHotMetrics $true -RuntimeCountScans $true
```
