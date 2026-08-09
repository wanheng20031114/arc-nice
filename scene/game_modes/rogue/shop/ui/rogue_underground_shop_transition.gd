extends RogueSceneTransition
class_name RogueUndergroundShopTransition


func cover() -> bool:
	_set_reveal_phase(false)
	return await super.cover()


func reveal() -> bool:
	_set_reveal_phase(true)
	var completed := await super.reveal()
	if completed:
		_set_reveal_phase(false)
	return completed


func hide_immediately() -> void:
	_set_reveal_phase(false)
	super.hide_immediately()


func _set_reveal_phase(enabled: bool) -> void:
	if cover_rect != null:
		cover_rect.set_instance_shader_parameter(
			&"reveal_phase",
			1.0 if enabled else 0.0
		)
