# 塔防正式战役波次导入格式（v1）

`dev_tools/import_tower_defense_wave_design.gd` 只接受一份完整的正式战役设计。默认运行只校验；只有显式追加 `--apply` 才会替换正式塔防的 16 个波次资源和单/多人流程资源。

## 命令

```powershell
# 安全预检（推荐先运行）
Godot.exe --headless --path . --script res://dev_tools/import_tower_defense_wave_design.gd -- --input=C:\absolute\tower_defense_waves.json

# 确认审计摘要无误后应用
Godot.exe --headless --path . --script res://dev_tools/import_tower_defense_wave_design.gd -- --input=C:\absolute\tower_defense_waves.json --apply
```

`--input` 只允许绝对路径或 `res://` 路径。应用成功时会在 Godot 的 `user://tower_defense_wave_import/` 下保留应用前备份，并在输出中打印其绝对路径。

## 根对象

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `schema_version` | 整数 | 必须为 `1` |
| `campaign_id` | 字符串 | 必须为 `tower_defense_formal` |
| `waves` | 数组 | 必须按顺序恰好包含 `wave_01` 至 `wave_16` |

如果提供 `target_wave_count`、`day_count`、`waves_per_day`、`boss_after_wave`，其值必须分别为 `16`、`4`、`4`、`16`。工作簿携带的其他只读统计与敌人目录元数据不会进入游戏资源。

## 波次对象

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `wave_id` | 字符串 | 必须与数组位置严格对应，例如第 1 项为 `wave_01` |
| `display_name` | 字符串 | 非空，最多 80 字符，不含换行 |
| `spawn_point_mask` | 整数 | `1..63`，对应 6 个出生点的位掩码 |
| `spawn_interval` | 数值 | `0.025..60` 秒 |
| `spawn_count_per_tick` | 整数 | `1..4` |
| `max_alive_enemies` | 整数 | `1..999` |
| `music_path` | 字符串 | 必须是当前正式波次已使用的 3 首战斗音乐之一 |
| `post_wave_music_path` | 字符串 | 必须是当前正式波次已使用的 3 首间歇音乐之一 |
| `entries` | 数组 | 非空；最多 18 项；同波 `enemy_id` 不得重复 |

若带有 `is_placeholder`，它必须为 `false`。第 16 波的默认出口由导入器固定连接到 `boss_01_linglan`，前 15 波固定线性连接到下一波。

允许的战斗音乐路径为：

- `res://resources/audio/shenmu_forest_combat.ogg`
- `res://resources/audio/shenmu_swamp_combat.ogg`
- `res://resources/audio/shenmu_town_combat.ogg`

允许的间歇音乐路径为：

- `res://resources/audio/shenmu_forest_intermission.ogg`
- `res://resources/audio/shenmu_swamp_intermission.ogg`
- `res://resources/audio/shenmu_town_intermission.ogg`

## 敌人条目

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `enemy_id` | 字符串 | 必须是 `EnemyCodexRegistry` 中的稳定 ID；Boss 条目不可用于普通波次 |
| `count` | 整数 | `1..9999` |
| `xirang_kill_reward_override` | 整数 | `-1` 表示继承敌人默认值，或使用 `0..999` 覆盖本波该敌人的击杀息壤 |

最小结构示例（实际文件仍须包含完整 16 波）：

```json
{
  "schema_version": 1,
  "campaign_id": "tower_defense_formal",
  "waves": [
    {
      "wave_id": "wave_01",
      "display_name": "第1波 林地试探",
      "spawn_point_mask": 63,
      "spawn_interval": 0.8,
      "spawn_count_per_tick": 1,
      "max_alive_enemies": 24,
      "music_path": "res://resources/audio/shenmu_forest_combat.ogg",
      "post_wave_music_path": "res://resources/audio/shenmu_forest_intermission.ogg",
      "entries": [
        {
          "enemy_id": "yuanshi_insect_basic",
          "count": 18,
          "xirang_kill_reward_override": -1
        }
      ]
    }
  ]
}
```

## 应用范围与安全性

应用会先完整校验 JSON、稳定 ID、数值边界、音乐资源、序列化结果和流程图，再备份并替换以下内容：

- `resources/config/campaigns/tower_defense/formal/wave_01.tres` 至 `wave_16.tres`
- `resources/config/campaigns/tower_defense/singleplayer/flow.tres`
- `resources/config/campaigns/tower_defense/multiplayer/flow.tres`

它不会修改 campaign wrapper、Boss 资源、标准战役、性能战役或旧的通用波次资源。写入或复核失败时，工具会使用本次备份尝试回滚。
