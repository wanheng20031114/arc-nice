extends Label
class_name BouncyNameLetter

var _tween: Tween


func restart_animation() -> void:
	if _tween != null:
		_tween.kill()
	pivot_offset = size * 0.5
	scale = Vector2.ONE
	var target_y := position.y
	_tween = create_tween()
	_tween.tween_property(self, "position:y", target_y, 0.42).from(target_y - 10.0).set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_property(self, "scale:y", 1.0, 0.42).from(1.45).set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_property(self, "scale:x", 1.0, 0.32).from(0.82).set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
