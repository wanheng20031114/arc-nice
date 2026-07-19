extends ProductionProgressBorderBuilding
class_name PlantCultivationCenter

@onready var hotspot_glow: NightPointLight2D = $HotspotGlow


func _on_construction_started() -> void:
	super._on_construction_started()
	hotspot_glow.set_emission_allowed(false)


func _on_construction_finished(was_animated: bool) -> void:
	super._on_construction_finished(was_animated)
	hotspot_glow.set_emission_allowed(true)


func _on_removal_started(mode: RemovalMode) -> void:
	hotspot_glow.set_emission_allowed(false)
	super._on_removal_started(mode)
