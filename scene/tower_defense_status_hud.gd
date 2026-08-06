extends CanvasLayer
class_name TowerDefenseStatusHUD

const GATE_WARNING_COOLDOWN_MSEC := 500
const GATE_WARNING_FADE_SECONDS := 0.42
const PERMANENT_DEATH_FULL_TEXT := PlayerLifeStatusHUD.PERMANENT_DEATH_FULL_TEXT
const PERMANENT_DEATH_COMPACT_TEXT := (
	PlayerLifeStatusHUD.PERMANENT_DEATH_COMPACT_TEXT
)

@onready var player_life_status_hud: PlayerLifeStatusHUD = $PlayerLifeStatusHUD
@onready var gate_warning_overlay: ColorRect = $GateWarningOverlay
@onready var gate_warning_audio: AudioStreamPlayer = $GateWarningAudio

# Public façade aliases retained for tower-defense runtime and diagnostics.
@onready var death_screen_effect: ColorRect = (
	player_life_status_hud.death_screen_effect
)
@onready var dead_players_panel: PanelContainer = (
	player_life_status_hud.dead_players_panel
)
@onready var dead_players_label: Label = player_life_status_hud.dead_players_label
@onready var local_death_center: Control = player_life_status_hud.local_death_center
@onready var local_death_full_content: VBoxContainer = (
	player_life_status_hud.local_death_full_content
)
@onready var local_countdown_label: Label = (
	player_life_status_hud.local_countdown_label
)
@onready var local_death_compact_content: MarginContainer = (
	player_life_status_hud.local_death_compact_content
)
@onready var local_compact_countdown_label: Label = (
	player_life_status_hud.local_compact_countdown_label
)

var respawn_entries: Dictionary:
	get:
		return player_life_status_hud.respawn_entries

var _dead_player_list_enabled: bool:
	get:
		return player_life_status_hud.dead_player_list_enabled

var local_dead_peer_id: int:
	get:
		return player_life_status_hud.local_dead_peer_id

var local_permanent_death_active: bool:
	get:
		return player_life_status_hud.local_permanent_death_active

var local_death_top_position: Vector2:
	get:
		return player_life_status_hud.local_death_top_position

var local_death_top_size: Vector2:
	get:
		return player_life_status_hud.local_death_top_size

var local_death_intro_active: bool:
	get:
		return player_life_status_hud.local_death_intro_active

var death_effect_tween: Tween:
	get:
		return player_life_status_hud.death_effect_tween

var local_death_tween: Tween:
	get:
		return player_life_status_hud.local_death_tween

var dead_players_tween: Tween:
	get:
		return player_life_status_hud.dead_players_tween

var countdown_pulse_tween: Tween:
	get:
		return player_life_status_hud.countdown_pulse_tween

var countdown_pulse_target: Label:
	get:
		return player_life_status_hud.countdown_pulse_target

var gate_warning_tween: Tween = null
var last_gate_warning_msec := -GATE_WARNING_COOLDOWN_MSEC


func _ready() -> void:
	gate_warning_overlay.hide()
	_set_gate_warning_intensity(0.0)


func set_player_respawn(
	peer_id: int,
	display_name: String,
	seconds_left: int,
	is_local_player: bool
) -> void:
	player_life_status_hud.set_player_respawn(
		peer_id,
		display_name,
		seconds_left,
		is_local_player
	)


func show_local_permanent_death(peer_id: int) -> void:
	player_life_status_hud.show_local_permanent_death(peer_id)


func set_dead_player_list_enabled(enabled: bool) -> void:
	player_life_status_hud.set_dead_player_list_enabled(enabled)


func clear_player_respawn(peer_id: int) -> void:
	player_life_status_hud.clear_player_respawn(peer_id)


func clear_all_respawns() -> void:
	player_life_status_hud.clear_all_respawns()


func play_gate_damage_warning() -> bool:
	var now_msec := Time.get_ticks_msec()
	if gate_warning_tween != null:
		gate_warning_tween.kill()
	gate_warning_overlay.show()
	_set_gate_warning_intensity(1.0)
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
	_set_gate_warning_intensity(0.0)


func _set_gate_warning_intensity(intensity: float) -> void:
	var shader_material := gate_warning_overlay.material as ShaderMaterial
	if shader_material != null:
		shader_material.set_shader_parameter(
			&"intensity",
			clampf(intensity, 0.0, 1.0)
		)


func _on_gate_warning_finished() -> void:
	gate_warning_tween = null
	gate_warning_overlay.hide()
	_set_gate_warning_intensity(0.0)
