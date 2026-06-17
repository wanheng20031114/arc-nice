extends YuanshiInsectAuraConfig
class_name YuanshiInsectGreenShellConfig

@export_group("翠壳毒性光环")
# 光环连续命中玩家之间的最短间隔（秒）。
@export_range(0.1, 10.0, 0.01, "or_greater") var aura_damage_interval: float = 1.0
