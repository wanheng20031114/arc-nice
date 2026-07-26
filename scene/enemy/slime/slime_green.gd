extends Slime
class_name GreenSlime

const REGENERATION_AMOUNT := 15
const REGENERATION_INTERVAL_SECONDS := 0.5


func _on_regeneration_timer_timeout() -> void:
	if is_dead or is_multiplayer_proxy or config == null:
		return
	restore_health(REGENERATION_AMOUNT)
