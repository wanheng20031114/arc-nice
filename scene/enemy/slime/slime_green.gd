extends Slime
class_name GreenSlime

const REGENERATION_AMOUNT := 15
const REGENERATION_INTERVAL_SECONDS := 0.5

@onready var regeneration_timer: Timer = $RegenerationTimer


func configure_multiplayer_proxy() -> void:
	super.configure_multiplayer_proxy()
	regeneration_timer.stop()


func remove_for_home_escape() -> bool:
	regeneration_timer.stop()
	return super.remove_for_home_escape()


func _die() -> void:
	regeneration_timer.stop()
	super._die()


func _on_regeneration_timer_timeout() -> void:
	if is_dead or is_multiplayer_proxy or config == null:
		return
	restore_health(REGENERATION_AMOUNT)
