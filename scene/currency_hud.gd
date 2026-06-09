extends CanvasLayer
class_name CurrencyHUD

@onready var panel: PanelContainer = $TopRightMargin/Panel
@onready var count_label: Label = $TopRightMargin/Panel/ContentMargin/Content/Count

var tracked_player: Player = null
var pulse_tween: Tween = null


func bind_player(player: Player) -> void:
	if tracked_player != null and tracked_player.xirang_changed.is_connected(_on_xirang_changed):
		tracked_player.xirang_changed.disconnect(_on_xirang_changed)

	tracked_player = player
	if tracked_player == null:
		visible = false
		return

	tracked_player.xirang_changed.connect(_on_xirang_changed)
	count_label.text = str(tracked_player.get_xirang())
	visible = true


func _on_xirang_changed(total: int, _added_amount: int) -> void:
	count_label.text = str(total)

	if pulse_tween != null:
		pulse_tween.kill()

	panel.pivot_offset = panel.size * 0.5
	panel.scale = Vector2.ONE
	pulse_tween = create_tween()
	pulse_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	pulse_tween.tween_property(panel, "scale", Vector2(1.1, 1.1), 0.09)
	pulse_tween.tween_property(panel, "scale", Vector2.ONE, 0.14)
