# 精英石头人 300 数量压力测试

日期：2026-07-18
Godot：4.6.3 stable
渲染：D3D12 / Forward+ / NVIDIA GeForce RTX 3080

> 归档说明（2026-08-26）：对应旧烟测与探针已删除；下方命令和数值仅作为历史记录，后续验证应按当前结构重写。

后续视觉重做只把同一张 256×256、16 帧、无损 RGBA 贴图中的 278 个内部
像素替换为红晶细节，没有改变节点、碰撞、动画帧数、纹理尺寸或运行时脚本；
因此本报告的运行时性能结论仍然适用。

## 口径

测试使用精英石头人的生产配置、独立场景和独立贴图，创建 300 个真实实例。
`approach` 使用 60 帧预热、360 帧采样；`engagement` 使用 180 帧预热、
600 帧采样。两者都使用石头人的 8 帧导航刷新间隔，并开启敌人热路径与运行时
计数遥测。

为排除单轮调度波动，交战测试之后又以完全相同参数补跑了原版石头人作为同版本
对照。

## 结果

| 指标 | 精英接近 | 精英交战 | 原版交战对照 |
|---|---:|---:|---:|
| 墙钟 p95 / p99 | 24.496 / 26.612 ms | 25.587 / 27.835 ms | 25.091 / 28.676 ms |
| 物理 p95 | 11.493 ms | 16.496 ms | 14.280 ms |
| 渲染 CPU p95 | 0.849 ms | 1.143 ms | 1.232 ms |
| 渲染 GPU p95 | 0.491 ms | 0.531 ms | 0.545 ms |
| 导航预算延迟 / 结束积压 | 0 / 0 | 0 / 0 | 0 / 0 |
| 节点峰值 | 6281 | 6281 | 6281 |
| 静态内存峰值 | 184.370 MiB | 187.578 MiB | 185.571 MiB |
| 核心伤害累计 | 0.831 ms | 10.971 ms | 11.894 ms |
| 砸地次数 / 完整处理累计 | 16 / 0.863 ms | 335 / 10.945 ms | 318 / 9.134 ms |

## 结论

精英版没有新增逐实例节点，导航也没有延迟或积压。交战墙钟 p95 相对原版同版本
对照增加 0.496 ms（约 2.0%），p99 反而低 0.841 ms；渲染 CPU/GPU 都没有
恶化。物理 p95 的单轮差异没有对应到任何热路径持续增长，更符合 Windows
帧调度和样本相位波动，不构成新的结构性性能问题。

0.6 秒前摇让 600 帧样本中的砸地次数从 318 增至 335，完整砸地成本只多
1.811 ms，摊到每个采样帧约 0.003 ms。本轮静态内存峰值比原版对照高约
2 MiB，其中包含独立贴图的一次性资源成本和运行波动；它不会随 300 个实例
成倍复制。

因此无需为精英版引入单独的性能降级或削减攻击语义。300 数量本身仍属于远高于
正常波次的压力夹具，整体压力来源继续是大量活动 `CharacterBody2D`、接触
`Area2D`、碰撞形状、动画和导航更新，详见
`dev_tools/stone_golem_performance_assessment.md`。

## 复现

```powershell
& .\dev_tools\run_tower_defense_enemy_cohort_probe.ps1 `
  -EnemyConfig res://resources/config/enemies/stone_golem_elite.tres `
  -Phase approach -EnemyCount 300 `
  -WarmupFrames 60 -SampleFrames 360 `
  -NavigationInterval 8 `
  -EnemyHotMetrics $true -RuntimeCountScans $true

& .\dev_tools\run_tower_defense_enemy_cohort_probe.ps1 `
  -EnemyConfig res://resources/config/enemies/stone_golem_elite.tres `
  -Phase engagement -EnemyCount 300 `
  -WarmupFrames 180 -SampleFrames 600 `
  -NavigationInterval 8 `
  -EnemyHotMetrics $true -RuntimeCountScans $true
```
