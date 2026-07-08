# 息壤线性成长审查报告

审查范围：所有使用 `attack_speed_xirang_step` 或 `defense_xirang_step` 的收藏品。命中获得息壤、击杀获得息壤、免费升级概率不属于“当前持有息壤越多，数值越高”的线性成长，本次不调整。

新增审计护栏：

- 攻速成长步长必须不低于 500 息壤。
- 攻速成长单步收益不超过 +2，折算每 1000 息壤不超过 +2 攻速。
- 3000 息壤时，单个收藏品提供的攻速成长不超过 +8。
- 双防成长步长必须不低于 1500 息壤。
- 双防成长单步收益不超过 +1，折算每 1000 息壤不超过 +0.75 双防。
- 5000 息壤时，单个收藏品提供的双防成长不超过 +3。

| 收藏品 | 来源 | 调整前 | 调整后 | 严格审查结论 |
| --- | --- | --- | --- | --- |
| 铜齿轮 | 新增 | 每 300 息壤，攻速 +1 | 每 600 息壤，攻速 +1 | 普通道具原值在 3000 息壤时给 +10 攻速，偏高；调整后为 +5。 |
| 回声小鼓 | 新增 | 每 200 息壤，攻速 +3 | 每 800 息壤，攻速 +1 | 原值折算每 1000 息壤 +15 攻速，过高；调整后为 +1.25。 |
| 金酒之杯 | 旧道具 | 每 100 息壤，攻速 +6 | 每 1000 息壤，攻速 +5 | 按最新设定保留更强的史诗收益；3000 息壤时从 +180 降为 +15。 |
| 王家圣杯 | 新增 | 每 100 息壤，攻速 +8 | 每 1000 息壤，攻速 +2 | 原值在 3000 息壤时给 +240 攻速，严重膨胀；调整后为 +6。 |
| 石刻片 | 新增 | 每 1500 息壤，双防 +1 | 每 2500 息壤，双防 +1 | 原值接近上限；保守处理后 5000 息壤时从 +3 降为 +2。 |
| 天师桩 | 旧道具 | 每 1000 息壤，双防 +1 | 每 2000 息壤，双防 +1 | 原值在 5000 息壤时给 +5 双防，后期偏硬；调整后为 +2。 |

相关文件：

- `dev_tools/audit_collectibles.py`：加入息壤线性成长硬阈值。
- `dev_tools/generate_collectible_expansion.py`：新增道具表改为保守数值；旧道具只对上述风险字段做平衡覆盖。
- `resources/config/collectibles/collectible_copper_gear.tres`
- `resources/config/collectibles/collectible_echo_drum.tres`
- `resources/config/collectibles/collectible_gold_wine_cup.tres`
- `resources/config/collectibles/collectible_royal_goblet.tres`
- `resources/config/collectibles/collectible_stone_tablet.tres`
- `resources/config/collectibles/collectible_tianshi_stake.tres`
