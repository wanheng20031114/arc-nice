extends CanvasLayer
class_name BossHealthHUD

const BAR_ASPECT := 1674.0 / 281.0
const NAMEPLATE_ASPECT := 838.0 / 256.0
const MAX_BAR_WIDTH := 760.0
const MIN_BAR_WIDTH := 360.0

@onready var root_control: Control = $Root
@onready var health_bar: TextureProgressBar = $Root/HealthBar
@onready var health_text: Label = $Root/HealthBar/HealthText
@onready var nameplate: TextureRect = $Root/Nameplate
@onready var name_label: Label = $Root/Nameplate/Name

var bound_boss: LinglanBoss = null
var reveal_tween: Tween = null


func _ready() -> void:
	get_viewport().size_changed.connect(_layout_for_viewport)
	_layout_for_viewport()
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
	root_control.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_on_boss_health_changed(bound_boss.current_health, bound_boss.get_max_health())
	_play_reveal()


func hide_all() -> void:
	_stop_reveal_tween()
	root_control.visible = false
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


func _layout_for_viewport() -> void:
	if root_control == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var bar_width := clampf(viewport_size.x - 96.0, MIN_BAR_WIDTH, MAX_BAR_WIDTH)
	var bar_height := bar_width / BAR_ASPECT
	var bar_position := Vector2((viewport_size.x - bar_width) * 0.5, 8.0)
	health_bar.position = bar_position
	health_bar.size = Vector2(bar_width, bar_height)

	var name_width := clampf(bar_width * 0.38, 230.0, 320.0)
	var name_height := name_width / NAMEPLATE_ASPECT
	nameplate.position = Vector2((viewport_size.x - name_width) * 0.5, bar_position.y + bar_height - 22.0)
	nameplate.size = Vector2(name_width, name_height)


func _play_reveal() -> void:
	_stop_reveal_tween()
	reveal_tween = create_tween()
	reveal_tween.tween_property(root_control, "modulate", Color.WHITE, 0.35).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


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
