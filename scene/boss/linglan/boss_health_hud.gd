extends CanvasLayer
class_name BossHealthHUD

@onready var root_control: Control = $Root
@onready var health_bar: ProgressBar = $HealthBar
@onready var health_text: Label = $HealthBar/HealthText
@onready var name_label: Label = $Root/Nameplate/Name

var bound_boss: LinglanBoss = null
var reveal_tween: Tween = null


func _ready() -> void:
	hide_all()


func show_for_boss(boss: LinglanBoss, boss_name: String = "") -> void:
	if boss == null:
		return
	_unbind_boss()
	bound_boss = boss
	if not bound_boss.health_changed.is_connected(_on_boss_health_changed):
		bound_boss.health_changed.connect(_on_boss_health_changed)
	if not bound_boss.defeated.is_connected(_on_boss_defeated):
		bound_boss.defeated.connect(_on_boss_defeated)

	var display_name := boss_name.strip_edges()
	if display_name.is_empty() and bound_boss.config != null:
		display_name = bound_boss.config.display_name
	if display_name.is_empty():
		display_name = bound_boss.boss_display_name
	name_label.text = display_name

	root_control.visible = true
	health_bar.visible = true
	root_control.modulate = Color(1.0, 1.0, 1.0, 0.0)
	health_bar.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_on_boss_health_changed(bound_boss.current_health, bound_boss.get_max_health())
	_play_reveal()


func hide_all() -> void:
	_stop_reveal_tween()
	root_control.visible = false
	health_bar.visible = false
	_unbind_boss()


func _on_boss_health_changed(current_health: int, maximum_health: int) -> void:
	var safe_maximum := maxi(maximum_health, 1)
	health_bar.max_value = safe_maximum
	health_bar.value = clampi(current_health, 0, safe_maximum)
	health_text.text = "%d / %d" % [clampi(current_health, 0, safe_maximum), safe_maximum]


func _on_boss_defeated(enemy: Enemy) -> void:
	if enemy != bound_boss:
		return
	_on_boss_health_changed(0, bound_boss.get_max_health())


func _play_reveal() -> void:
	_stop_reveal_tween()
	reveal_tween = create_tween()
	reveal_tween.set_parallel(true)
	reveal_tween.tween_property(root_control, "modulate", Color.WHITE, 0.35).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	reveal_tween.tween_property(health_bar, "modulate", Color.WHITE, 0.35).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _stop_reveal_tween() -> void:
	if reveal_tween != null:
		reveal_tween.kill()
		reveal_tween = null


func _unbind_boss() -> void:
	if bound_boss == null:
		return
	if is_instance_valid(bound_boss):
		if bound_boss.health_changed.is_connected(_on_boss_health_changed):
			bound_boss.health_changed.disconnect(_on_boss_health_changed)
		if bound_boss.defeated.is_connected(_on_boss_defeated):
			bound_boss.defeated.disconnect(_on_boss_defeated)
	bound_boss = null
