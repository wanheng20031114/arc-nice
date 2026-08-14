# 塔防四日战役导入格式（v3）

`dev_tools/import_tower_defense_wave_design.gd` 接受完整的四日正式战役设计。默认只校验；只有显式追加 `--apply` 才会事务性替换正式塔防的 12 个普通波次、单/多人流程资源，并把前三日地下探索行动力写入正式成长配置。

本工具不直接解析 `.xlsx`。编辑 `reports/塔防模式_4日战役智能设计器.xlsx` 后，应先交回 Codex，由 Codex校验工作簿并转换为本格式 JSON。

## 命令

```powershell
# 安全预检（推荐先运行）
Godot.exe --headless --path . --script res://dev_tools/import_tower_defense_wave_design.gd -- --input=C:\absolute\tower_defense_campaign.json

# 确认审计摘要无误后应用
Godot.exe --headless --path . --script res://dev_tools/import_tower_defense_wave_design.gd -- --input=C:\absolute\tower_defense_campaign.json --apply
```

`--input` 只允许绝对路径或 `res://` 路径。应用成功时会在 `user://tower_defense_wave_import/` 下保留应用前备份，并打印绝对路径。任何暂存、替换或复核失败都会尝试恢复本次备份。

## 根对象

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `schema_version` | 整数 | 必须为 `3` |
| `campaign_id` | 字符串 | 必须为 `tower_defense_formal` |
| `target_wave_count` | 整数 | 必须为 `12` |
| `day_count` | 整数 | 必须为 `4` |
| `waves_per_day` | 整数 | 必须为 `4` |
| `boss_after_wave` | 整数 | 必须为 `12` |
| `boss_day` | 整数 | 必须为 `4` |
| `boss_period` | 字符串 | 必须为 `day` |
| `daily_rogue_action_points` | 整数数组 | 必须恰好 3 项，依次对应第 1～3 日，且每项非负；默认 `[5,5,5]` |
| `waves` | 数组 | 必须按顺序恰好包含 `wave_01` 至 `wave_12` |

旧 16 波文件、错误 Boss 日期/时段、行动力长度错误或负数都会被拒绝。第 4 日没有普通波次：第 12 波出口固定连接 `boss_01_linglan`，Boss 击败后由现有运行时直接通关。

## 波次对象

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `wave_id` | 字符串 | 必须与数组位置严格对应，例如第 1 项为 `wave_01` |
| `display_name` | 字符串 | 非空，最多 80 字符，不含换行 |
| `spawn_point_mask` | 整数 | `1..63`，对应 6 个出生点位掩码 |
| `spawn_interval` | 数值 | `0.025..60` 秒 |
| `spawn_count_per_tick` | 整数 | `1..4` |
| `max_alive_enemies` | 整数 | `1..999` |
| `music_path` | 字符串 | 当前正式波次允许的 3 首战斗音乐之一 |
| `post_wave_music_path` | 字符串 | 当前正式波次允许的 3 首间歇音乐之一 |
| `entries` | 数组 | 非空；最多 18 项；同波 `enemy_id` 不得重复 |

若带有 `is_placeholder`，它必须为 `false`。前 11 波默认出口固定连接下一波，第 12 波固定连接 `boss_01_linglan`。

允许的战斗音乐路径：

- `res://resources/audio/shenmu_forest_combat.ogg`
- `res://resources/audio/shenmu_swamp_combat.ogg`
- `res://resources/audio/shenmu_town_combat.ogg`

允许的间歇音乐路径：

- `res://resources/audio/shenmu_forest_intermission.ogg`
- `res://resources/audio/shenmu_swamp_intermission.ogg`
- `res://resources/audio/shenmu_town_intermission.ogg`

## 敌人条目

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `enemy_id` | 字符串 | `EnemyCodexRegistry` 稳定 ID；Boss 不可用于普通波次 |
| `count` | 整数 | `1..9999` |
| `xirang_kill_reward_override` | 整数 | `-1` 继承敌人默认值，或 `0..999` 覆盖本波击杀息壤 |

## 最小结构示例

```json
{
  "schema_version": 3,
  "campaign_id": "tower_defense_formal",
  "target_wave_count": 12,
  "day_count": 4,
  "waves_per_day": 4,
  "boss_after_wave": 12,
  "boss_day": 4,
  "boss_period": "day",
  "daily_rogue_action_points": [5, 5, 5],
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

实际文件仍须包含完整 12 波。

## 应用范围与安全性

应用先完整校验 JSON、稳定 ID、数值边界、音乐资源、序列化结果、流程图与成长配置，再备份并替换：

- `resources/config/campaigns/tower_defense/formal/wave_01.tres` 至 `wave_12.tres`
- `resources/config/campaigns/tower_defense/singleplayer/flow.tres`
- `resources/config/campaigns/tower_defense/multiplayer/flow.tres`
- `resources/config/campaigns/tower_defense/formal_progression.tres`

成长配置只更新 `daily_rogue_action_points`，其余计时、多人倍率、起步包与追踪材料沿用应用前资源。工具不会修改 Boss 资源、标准战役、性能战役或旧通用波次资源。
