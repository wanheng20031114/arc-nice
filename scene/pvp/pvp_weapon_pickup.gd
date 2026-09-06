extends Node2D
class_name PvpWeaponPickup

var pickup_id := 0
var weapon := "deagle"
var ammunition: Dictionary = {}

func configure(id: int, weapon_id: String, weapon_ammunition: Dictionary, location: Vector2) -> void:
	pickup_id = id
	weapon = weapon_id
	ammunition = weapon_ammunition.duplicate(true)
	global_position = location
	$Deagle.visible = weapon == "deagle"
	$AK.visible = weapon == "ak"
	$Name.text = "AK-47" if weapon == "ak" else "沙漠之鹰"

func serialize() -> Dictionary:
	return {"id": pickup_id, "weapon": weapon, "ammunition": ammunition,
		"position": global_position}
