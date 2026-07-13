extends CanvasLayer
class_name TowerDefenseStatusHUD

const GATE_WARNING_COOLDOWN_MSEC := 500
const GATE_WARNING_FADE_SECONDS := 0.42
const DEATH_EFFECT_FADE_SECONDS := 0.62
const LOCAL_DEATH_FADE_SECONDS := 0.26
const LOCAL_DEATH_HOLD_SECONDS := 0.18
const LOCAL_DEATH_MOVE_SECONDS := 0.56
const DEAD_PLAYERS_FADE_SECONDS := 0.3
const COUNTDOWN_PULSE_SECONDS := 0.22

@onready var death_screen_effect: ColorRect = $DeathScreenEffect
@onready var gate_warning_overlay: ColorRect = $GateWarningOverlay
@onready var dead_players_panel: PanelContainer = $RightMargin/DeadPlayersPanel
@onready var dead_players_label: Label = $RightMargin/DeadPlayersPanel/Margin/Content/Players
@onready var local_death_center: CenterContainer = $LocalDeathCenter
@onready var local_countdown_label: Label = $LocalDeathCenter/Panel/Margin/Content/Countdown
@onready var gate_warning_audio: AudioStreamPlayer = $GateWarningAudio

var respawn_entries: Dictionary = {}
var local_dead_peer_id := -1
var local_death_top_position := Vector2.ZERO
var local_death_intro_active := false
var death_effect_tween: Tween = null
var local_death_tween: Tween = null
var dead_players_tween: Tween = null
var countdown_pulse_tween: Tween = null
var gate_warning_tween: Tween = null
var last_gate_warning_msec := -GATE_WARNING_COOLDOWN_MSEC


func _ready() -> void:
	local_death_top_position = local_death_center.position
	death_screen_effect.hide()
	gate_warning_overlay.hide()
	dead_players_panel.hide()
	local_death_center.hide()
	dead_players_panel.modulate.a = 0.0
	local_death_center.modulate.a = 0.0
	local_countdown_label.pivot_offset = local_countdown_label.size * 0.5
	_set_shader_intensity(death_screen_effect, 0.0)
	_set_shader_intensity(gate_warning_overlay, 0.0)


func set_player_respawn(
	peer_id: int,
	display_name: String,
	seconds_left: int,
	is_local_player: bool
) -> void:
	if peer_id < 0:
		return
	var begins_local_death := (
		is_local_player
		and (local_dead_peer_id != peer_id or not local_death_center.visible)
	)
	respawn_entries[peer_id] = {
		"name": display_name if not display_name.is_empty() else "玩家",
		"seconds": maxi(seconds_left, 0),
	}
	if is_local_player:
		local_dead_peer_id = peer_id
		if begins_local_death:
			_play_local_death_intro()
		_update_local_countdown(maxi(seconds_left, 0), begins_local_death)
	_refresh_dead_player_list()


func clear_player_respawn(peer_id: int) -> void:
	respawn_entries.erase(peer_id)
	if peer_id == local_dead_peer_id:
		local_dead_peer_id = -1
		_stop_local_death_presentation()
	_refresh_dead_player_list()


func clear_all_respawns() -> void:
	respawn_entries.clear()
	local_dead_peer_id = -1
	_stop_local_death_presentation()
	if dead_players_tween != null:
		dead_players_tween.kill()
		dead_players_tween = null
	dead_players_panel.hide()
	dead_players_panel.modulate.a = 0.0
	dead_players_label.text = ""


func play_gate_damage_warning() -> bool:
	var now_msec := Time.get_ticks_msec()
	if gate_warning_tween != null:
		gate_warning_tween.kill()
	gate_warning_overlay.show()
	_set_shader_intensity(gate_warning_overlay, 1.0)
	gate_warning_tween = create_tween()
	gate_warning_tween.tween_method(
		_set_gate_warning_intensity,
		1.0,
		0.0,
		GATE_WARNING_FADE_SECONDS
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	gate_warning_tween.finished.connect(_on_gate_warning_finished)
	if now_msec - last_gate_warning_msec < GATE_WARNING_COOLDOWN_MSEC:
		return false
	last_gate_warning_msec = now_msec
	gate_warning_audio.play()
	return true


func stop_gate_damage_warning() -> void:
	if gate_warning_tween != null:
		gate_warning_tween.kill()
		gate_warning_tween = null
	gate_warning_audio.stop()
	gate_warning_overlay.hide()
	_set_shader_intensity(gate_warning_overlay, 0.0)


func _refresh_dead_player_list() -> void:
	if respawn_entries.is_empty():
		if dead_players_tween != null:
			dead_players_tween.kill()
			dead_players_tween = null
		dead_players_panel.hide()
		dead_players_panel.modulate.a = 0.0
		dead_players_label.text = ""
		return
	var was_visible := dead_players_panel.visible
	var peer_ids: Array[int] = []
	for peer_id_variant in respawn_entries:
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()
	var lines := PackedStringArray()
	for peer_id in peer_ids:
		var entry := respawn_entries[peer_id] as Dictionary
		lines.append("%s：%d秒后复活" % [
			str(entry.get("name", "玩家")),
			int(entry.get("seconds", 0)),
		])
	dead_players_label.text = "\n".join(lines)
	if not was_visible:
		dead_players_panel.show()
		dead_players_panel.modulate.a = 0.0
	if dead_players_tween != null:
		return
	if local_death_intro_active and not was_visible:
		_play_dead_players_intro(
			LOCAL_DEATH_FADE_SECONDS
			+ LOCAL_DEATH_HOLD_SECONDS
			+ LOCAL_DEATH_MOVE_SECONDS
		)
	elif not was_visible or dead_players_panel.modulate.a < 1.0:
		_play_dead_players_intro(0.0)


func _update_local_countdown(seconds_left: int, force_pulse := false) -> void:
	var countdown_text := (
		"正在复活……"
		if seconds_left <= 0
		else "%d 秒后复活" % seconds_left
	)
	if local_countdown_label.text == countdown_text and not force_pulse:
		return
	local_countdown_label.text = countdown_text
	if countdown_pulse_tween != null:
		countdown_pulse_tween.kill()
	local_countdown_label.pivot_offset = local_countdown_label.size * 0.5
	local_countdown_label.scale = Vector2.ONE * 1.1
	countdown_pulse_tween = create_tween()
	countdown_pulse_tween.tween_property(
		local_countdown_label,
		"scale",
		Vector2.ONE,
		COUNTDOWN_PULSE_SECONDS
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	countdown_pulse_tween.finished.connect(_on_countdown_pulse_finished)


func _play_local_death_intro() -> void:
	_stop_local_death_tweens()
	local_death_intro_active = true
	death_screen_effect.show()
	_set_shader_intensity(death_screen_effect, 0.0)
	death_effect_tween = create_tween()
	death_effect_tween.tween_method(
		_set_death_effect_intensity,
		0.0,
		1.0,
		DEATH_EFFECT_FADE_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	death_effect_tween.finished.connect(_on_death_effect_intro_finished)

	local_death_center.position = _get_local_death_intro_position()
	local_death_center.modulate.a = 0.0
	local_death_center.show()
	local_death_tween = create_tween()
	local_death_tween.tween_property(
		local_death_center,
		"modulate:a",
		1.0,
		LOCAL_DEATH_FADE_SECONDS
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	local_death_tween.tween_interval(LOCAL_DEATH_HOLD_SECONDS)
	local_death_tween.tween_property(
		local_death_center,
		"position",
		local_death_top_position,
		LOCAL_DEATH_MOVE_SECONDS
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	local_death_tween.finished.connect(_on_local_death_intro_finished)


func _play_dead_players_intro(delay_seconds: float) -> void:
	if dead_players_tween != null:
		dead_players_tween.kill()
	dead_players_panel.show()
	dead_players_panel.modulate.a = 0.0
	dead_players_tween = create_tween()
	if delay_seconds > 0.0:
		dead_players_tween.tween_interval(delay_seconds)
	dead_players_tween.tween_property(
		dead_players_panel,
		"modulate:a",
		1.0,
		DEAD_PLAYERS_FADE_SECONDS
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	dead_players_tween.finished.connect(_on_dead_players_intro_finished)


func _stop_local_death_presentation() -> void:
	_stop_local_death_tweens()
	if dead_players_tween != null and dead_players_panel.modulate.a < 1.0:
		dead_players_tween.kill()
		dead_players_tween = null
	local_death_intro_active = false
	death_screen_effect.hide()
	local_death_center.hide()
	local_death_center.position = local_death_top_position
	local_death_center.modulate.a = 0.0
	local_countdown_label.scale = Vector2.ONE
	_set_shader_intensity(death_screen_effect, 0.0)


func _stop_local_death_tweens() -> void:
	if death_effect_tween != null:
		death_effect_tween.kill()
		death_effect_tween = null
	if local_death_tween != null:
		local_death_tween.kill()
		local_death_tween = null
	if countdown_pulse_tween != null:
		countdown_pulse_tween.kill()
		countdown_pulse_tween = null


func _get_local_death_intro_position() -> Vector2:
	var viewport_height := get_viewport().get_visible_rect().size.y
	var centered_y := (viewport_height - local_death_center.size.y) * 0.5
	return Vector2(
		local_death_top_position.x,
		maxf(centered_y, local_death_top_position.y)
	)


func _set_death_effect_intensity(intensity: float) -> void:
	_set_shader_intensity(death_screen_effect, intensity)


func _on_death_effect_intro_finished() -> void:
	death_effect_tween = null


func _on_local_death_intro_finished() -> void:
	local_death_tween = null
	local_death_intro_active = false


func _on_dead_players_intro_finished() -> void:
	dead_players_tween = null


func _on_countdown_pulse_finished() -> void:
	countdown_pulse_tween = null


func _set_gate_warning_intensity(intensity: float) -> void:
	_set_shader_intensity(gate_warning_overlay, intensity)


func _on_gate_warning_finished() -> void:
	gate_warning_tween = null
	gate_warning_overlay.hide()
	_set_shader_intensity(gate_warning_overlay, 0.0)


func _set_shader_intensity(target: ColorRect, intensity: float) -> void:
	if target == null:
		return
	var shader_material := target.material as ShaderMaterial
	if shader_material != null:
		shader_material.set_shader_parameter(&"intensity", clampf(intensity, 0.0, 1.0))
