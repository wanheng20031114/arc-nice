extends Label
class_name BouncyNameLetter

var _tween: Tween


func restart_animation() -> void:
	if _tween != null:
		_tween.kill()
	scale = Vector2.ONE
	var target_y := position.y
	modulate.a = 0.55
	_tween = create_tween()
	_tween.tween_property(self, "position:y", target_y, 0.42).from(target_y - 10.0).set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_property(self, "modulate:a", 1.0, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
