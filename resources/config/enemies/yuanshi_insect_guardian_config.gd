extends YuanshiInsectAuraConfig
class_name YuanshiInsectGuardianConfig

@export_group("守护光环")
# 光环范围内敌人获得的额外物理防御。
@export_range(0, 99, 1, "or_greater") var aura_physical_defense_bonus: int = 3
