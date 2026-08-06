extends Control
class_name PlayerStatsView

signal player_died
signal xirang_changed

const PORTRAIT_DEFAULT_POSITION := Vector2(150.0, 178.0)
const PORTRAIT_WITH_SKILL_POSITION := Vector2(150.0, 147.0)

@onready var portrait: Sprite2D = $Portrait
@onready var attack_value: Label = $AttackValue
@onready var health_value: Label = $HealthValue
@onready var attack_speed_value: Label = $AttackSpeedValue
@onready var move_speed_value: Label = $MoveSpeedValue
@onready var dodge_value: Label = $DodgeValue
@onready var physical_defense_value: Label = $PhysicalDefenseValue
@onready var magic_defense_value: Label = $MagicDefenseValue
@onready var skill_info: Control = $SkillInfo
@onready var skill_icon: TextureRect = $SkillInfo/SkillIcon
@onready var skill_name_label: Label = $SkillInfo/SkillName
@onready var skill_description_label: Label = $SkillInfo/SkillDescription
@onready var skill_cost_label: Label = $SkillInfo/SkillCost

var tracked_player: Player = null


func bind_player(player: Player) -> void:
	_disconnect_tracked_player()
	tracked_player = player
	if tracked_player == null:
		portrait.texture = null
		portrait.position = PORTRAIT_DEFAULT_POSITION
		skill_info.visible = false
		return

	tracked_player.health_changed.connect(_on_health_changed)
	tracked_player.attack_speed_changed.connect(_on_attack_speed_changed)
	tracked_player.xirang_changed.connect(_on_xirang_changed)
	tracked_player.dodge_changed.connect(_on_dodge_changed)
	tracked_player.profile_display_changed.connect(_on_profile_display_changed)
	tracked_player.died.connect(_on_player_died)
	_refresh_character_portrait()
	refresh()


func refresh() -> void:
	if tracked_player == null:
		return
	attack_value.text = str(tracked_player.attack_damage)
	_on_health_changed(tracked_player.current_health, tracked_player.max_health)
	_on_attack_speed_changed(tracked_player.get_attack_speed())
	_on_dodge_changed(tracked_player.dodge_chance)
	move_speed_value.text = str(roundi(tracked_player.move_speed))
	physical_defense_value.text = str(tracked_player.physical_defense)
	magic_defense_value.text = str(tracked_player.magic_defense)
	_refresh_skill_display()


func _disconnect_tracked_player() -> void:
	if tracked_player == null or not is_instance_valid(tracked_player):
		return
	if tracked_player.health_changed.is_connected(_on_health_changed):
		tracked_player.health_changed.disconnect(_on_health_changed)
	if tracked_player.attack_speed_changed.is_connected(_on_attack_speed_changed):
		tracked_player.attack_speed_changed.disconnect(_on_attack_speed_changed)
	if tracked_player.xirang_changed.is_connected(_on_xirang_changed):
		tracked_player.xirang_changed.disconnect(_on_xirang_changed)
	if tracked_player.dodge_changed.is_connected(_on_dodge_changed):
		tracked_player.dodge_changed.disconnect(_on_dodge_changed)
	if tracked_player.profile_display_changed.is_connected(
		_on_profile_display_changed
	):
		tracked_player.profile_display_changed.disconnect(
			_on_profile_display_changed
		)
	if tracked_player.died.is_connected(_on_player_died):
		tracked_player.died.disconnect(_on_player_died)


func _refresh_character_portrait() -> void:
	portrait.texture = null
	if tracked_player == null:
		return
	var config := tracked_player.get_character_config()
	if config == null or config.portrait_texture.is_empty():
		return
	portrait.texture = load(config.portrait_texture) as Texture2D


func _on_health_changed(current: int, maximum: int) -> void:
	health_value.text = "%d / %d" % [current, maximum]


func _on_attack_speed_changed(attack_speed: float) -> void:
	var rounded_speed := roundf(attack_speed)
	attack_speed_value.text = (
		str(roundi(rounded_speed))
		if is_equal_approx(attack_speed, rounded_speed)
		else "%.2f" % attack_speed
	)


func _on_dodge_changed(chance: float) -> void:
	dodge_value.text = "%.0f%%" % (clampf(chance, 0.0, 1.0) * 100.0)


func _on_profile_display_changed() -> void:
	refresh()


func _refresh_skill_display() -> void:
	if tracked_player == null:
		skill_info.visible = false
		portrait.position = PORTRAIT_DEFAULT_POSITION
		return
	var has_skill := tracked_player.has_skill1()
	skill_info.visible = has_skill
	portrait.position = (
		PORTRAIT_WITH_SKILL_POSITION
		if has_skill
		else PORTRAIT_DEFAULT_POSITION
	)
	_refresh_skill_presentation()
	if not has_skill:
		return
	var required_charge := maxf(tracked_player.skill1_charge_duration, 0.01)
	skill_cost_label.text = "技力需求%d" % roundi(required_charge)
	_update_skill_tooltip()


func _update_skill_tooltip() -> void:
	if tracked_player == null:
		return
	var tooltip := "%s\n%s" % [
		tracked_player.get_skill1_display_name(),
		tracked_player.get_skill1_description(),
	]
	skill_info.tooltip_text = tooltip
	skill_icon.tooltip_text = tooltip


func _refresh_skill_presentation() -> void:
	if tracked_player == null:
		return
	skill_name_label.text = tracked_player.get_skill1_display_name()
	skill_description_label.text = tracked_player.get_skill1_description()
	skill_icon.texture = tracked_player.get_skill1_icon()


func _on_xirang_changed(_total: int, _added_amount: int) -> void:
	xirang_changed.emit()


func _on_player_died() -> void:
	player_died.emit()
