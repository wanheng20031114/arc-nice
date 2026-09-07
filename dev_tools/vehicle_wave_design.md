# 小车模式十二波设计

配置入口：`resources/config/campaigns/vehicle/singleplayer/campaign.tres`。

这是一条独立于普通模式的十二波线性战役，沿用现有 `WaveCampaignConfig → FlowGraphConfig → WaveConfig` 结构和原有敌人资源。第十二波没有出口或额外 Boss 节点，清场后由小车模式结算胜利。

小车基线为 100 生命、10 攻击、100 速度、车头速射和榴弹技能。前段教转向与保持射距，中段加入爆破、远程与重甲，后段考验机械混编突围。每波只生成 1 名敌人/次，同屏数量从 5 增长到 20；敌人池随机混合，出生点使用原生均衡洗牌模式，减少连续在同一个入口生成的偏斜。

| 波次 | 主题 | 敌人配置（数量） | 总数 | 生成间隔 | 同屏上限 | 设计目的 |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 1 | 引擎预热 | `yuanshi_insect_basic` × 12；`slime` × 6 | 18 | 0.900 秒 | 5 | 慢速近战建立车头射击和转向节奏。 |
| 2 | 林道追逐 | `yuanshi_insect_basic` × 10；`yuanshi_insect_fast` × 10；`slime` × 2 | 22 | 0.850 秒 | 6 | 引入速度 40 的追击者，练习拉开距离再回头开火。 |
| 3 | 碎壳路障 | `yuanshi_insect_basic` × 10；`yuanshi_insect_fast` × 8；`yuanshi_insect_shell` × 4；`yuanshi_insect_bomber` × 4 | 26 | 0.800 秒 | 7 | 少量硬壳吸收火力，自爆虫要求保持安全距离。 |
| 4 | 焦土交叉 | `yuanshi_insect_basic` × 12；`yuanshi_insect_fast` × 8；`yuanshi_insect_bomber` × 6；`yuanshi_insect_fire_ranged` × 4 | 30 | 0.750 秒 | 8 | 第一批远程敌人只有 4 只，配合近战练习绕行和优先集火。 |
| 5 | 翠壳防线 | `yuanshi_insect_basic` × 10；`yuanshi_insect_fast` × 10；`yuanshi_insect_shell` × 6；`yuanshi_insect_green_shell` × 4；`yuanshi_insect_guardian` × 4 | 34 | 0.700 秒 | 10 | 慢速甲壳与守护者形成障碍，给榴弹提供成群目标。 |
| 6 | 猫虫伏击 | `yuanshi_insect_basic` × 10；`yuanshi_insect_fast` × 10；`yuanshi_insect_fire_ranged` × 6；`capoo_knight` × 6；`capoo_ak47` × 6 | 38 | 0.650 秒 | 11 | 骑士与缓慢枪手支援虫群，增加持续火力压力。 |
| 7 | 爆裂山道 | `yuanshi_insect_basic` × 10；`yuanshi_insect_fast` × 12；`yuanshi_insect_shell` × 2；`yuanshi_insect_bomber` × 8；`yuanshi_insect_purple_bomber` × 6；`capoo_rpg` × 4 | 42 | 0.600 秒 | 12 | 以低生命爆破虫降低清场负担，考验走位、榴弹时机和避免贴脸击杀。 |
| 8 | 冷热封锁 | `yuanshi_insect_basic` × 16；`yuanshi_insect_fast` × 16；`slime_fire` × 4；`slime_frost` × 4；`fire_sorcerer` × 3；`frost_sorcerer` × 3 | 46 | 0.600 秒 | 13 | 慢速元素敌人加入；普通术士各 3 只，避免精英术士的高伤害密集叠加。 |
| 9 | 机械前哨 | `yuanshi_insect_basic` × 16；`yuanshi_insect_fast` × 14；`combat_robot` × 10；`combat_robot_gunner` × 6；`combat_robot_shield_bearer` × 4 | 50 | 0.575 秒 | 15 | 虫群牵制，首次加入普通机械近战、枪手与举盾单位。 |
| 10 | 侧翼突击 | `stone_eroded_yuanshi_insect_basic` × 14；`stone_eroded_yuanshi_insect_fast` × 14；`combat_robot` × 10；`combat_robot_ninja` × 8；`combat_robot_gunner` × 4；`combat_robot_shield_bearer` × 4 | 54 | 0.550 秒 | 16 | 侵蚀虫增加耐久，速度 80 的普通忍者形成侧翼威胁；不用高伤害精英忍者。 |
| 11 | 重装封锁 | `stone_eroded_yuanshi_insect_basic` × 18；`stone_eroded_yuanshi_insect_fast` × 16；`combat_robot` × 10；`combat_robot_gunner` × 6；`combat_robot_shield_bearer` × 6；`capoo_knight_elite` × 2 | 58 | 0.525 秒 | 18 | 机械混编配两只精英骑士，给终局提供一次重装突破练习。 |
| 12 | 主战终局 | `stone_eroded_yuanshi_insect_basic` × 20；`stone_eroded_yuanshi_insect_fast` × 20；`combat_robot` × 12；`combat_robot_gunner` × 6；`combat_robot_shield_bearer` × 4；`combat_robot_ninja` × 2；`combat_robot_main_battle_elite` × 1 | 65 | 0.500 秒 | 20 | 一台 800 生命主战机器人率队；总同屏上限 20，主战是本波敌人，不追加第 13 波。 |

共 483 名配置敌人。每波清场后的收藏品三选一由小车模式运行时直接调用洛希卡牌；选择期间不推进战斗，随后使用每波配置的 4 秒休整进入下一波。第十二波奖励选择后结算。

没有选用伤害 200 的狙击手、伤害 100 及以上的石头人/精英无人机操作员，或高伤害精英术士。唯一的主战机器人位于第十二波，保留其原有 800 生命和 80 攻击，鼓励借助已获得的收藏品、榴弹及其技能预警保持距离；它按现有波次机制混入该波敌人池，不保证最后生成。

此处不改全局敌人数值，也不依赖特定收藏品才能清场。数值为初始设计，实际难度仍需结合车头瞄准、场地碰撞与收藏品组合的游玩反馈调整。
