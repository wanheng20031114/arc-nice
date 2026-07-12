extends CanvasLayer
class_name TowerDefenseStatusHUD

const GATE_WARNING_COOLDOWN_MSEC := 500
const GATE_WARNING_FADE_SECONDS := 0.42

@onready var death_screen_effect: ColorRect = $DeathScreenEffect
@onready var gate_warning_overlay: ColorRect = $GateWarningOverlay
@onready var dead_players_panel: PanelContainer = $RightMargin/DeadPlayersPanel
@onready var dead_players_label: Label = $RightMargin/DeadPlayersPanel/Margin/Content/Players
@onready var local_death_center: CenterContainer = $LocalDeathCenter
@onready var local_countdown_label: Label = $LocalDeathCenter/Panel/Margin/Content/Countdown
@onready var gate_warning_audio: AudioStreamPlayer = $GateWarningAudio

var respawn_entries: Dictionary = {}
var local_dead_peer_id := -1
var gate_warning_tween: Tween = null
var last_gate_warning_msec := -GATE_WARNING_COOLDOWN_MSEC


func _ready() -> void:
	death_screen_effect.hide()
	gate_warning_overlay.hide()
	dead_players_panel.hide()
	local_death_center.hide()
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
	respawn_entries[peer_id] = {
		"name": display_name if not display_name.is_empty() else "玩家",
		"seconds": maxi(seconds_left, 0),
	}
	if is_local_player:
		local_dead_peer_id = peer_id
		death_screen_effect.show()
		local_death_center.show()
		_set_shader_intensity(death_screen_effect, 1.0)
		_update_local_countdown(maxi(seconds_left, 0))
	_refresh_dead_player_list()


func clear_player_respawn(peer_id: int) -> void:
	respawn_entries.erase(peer_id)
	if peer_id == local_dead_peer_id:
		local_dead_peer_id = -1
		death_screen_effect.hide()
		local_death_center.hide()
		_set_shader_intensity(death_screen_effect, 0.0)
	_refresh_dead_player_list()


func clear_all_respawns() -> void:
	respawn_entries.clear()
	local_dead_peer_id = -1
	death_screen_effect.hide()
	local_death_center.hide()
	dead_players_panel.hide()
	_set_shader_intensity(death_screen_effect, 0.0)


func play_gate_damage_warning() -> bool:
	var now_msec := Time.get_ticks_msec()
	if now_msec - last_gate_warning_msec < GATE_WARNING_COOLDOWN_MSEC:
		return false
	last_gate_warning_msec = now_msec
	if gate_warning_tween != null:
		gate_warning_tween.kill()
	gate_warning_overlay.show()
	_set_shader_intensity(gate_warning_overlay, 1.0)
	gate_warning_audio.play()
	gate_warning_tween = create_tween()
	gate_warning_tween.tween_method(
		_set_gate_warning_intensity,
		1.0,
		0.0,
		GATE_WARNING_FADE_SECONDS
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	gate_warning_tween.finished.connect(_on_gate_warning_finished)
	return true


func _refresh_dead_player_list() -> void:
	if respawn_entries.is_empty():
		dead_players_panel.hide()
		dead_players_label.text = ""
		return
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
	dead_players_panel.show()


func _update_local_countdown(seconds_left: int) -> void:
	local_countdown_label.text = (
		"即将复活……"
		if seconds_left <= 0
		else "将在 %d 秒后复活" % seconds_left
	)


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
