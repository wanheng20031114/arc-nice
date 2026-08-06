extends Node
class_name TowerDefensePresentationCoordinator

const COUNTDOWN_FINAL_SECONDS := 3
const SPECTATOR_CAMERA_SPEED := 180.0
const DEFAULT_MUSIC_VOLUME_DB := -6.0
const MUSIC_FADE_IN_SECONDS := 3.0
const MUSIC_FADE_IN_START_VOLUME_DB := -12.0
const BOSS_INTRO_CAMERA_FOCUS_SECONDS := 0.9
const DEFEAT_CAMERA_TRAVEL_SECONDS := 0.55

signal return_to_lobby_requested
signal start_wave_requested

var music_fade_tween: Tween = null
var boss_intro_camera_tween: Tween = null
var defeat_camera_tween: Tween = null
var defeat_presentation_completed := false
var spectator_camera_active := false

var _runtime: TowerDefenseGame = null
var _campaign_coordinator: TowerDefenseCampaignCoordinator = null
var _plant_placement_coordinator: TowerDefensePlantPlacementCoordinator = null
var _day_cycle_config: DayCycleConfig = null
var _map_camera: Camera2D = null
var _music_player: AudioStreamPlayer = null
var _countdown_audio: AudioStreamPlayer = null
var _wave_start_audio: AudioStreamPlayer = null
var _defeat_audio: AudioStreamPlayer = null
var _wave_hud: TowerDefenseWaveHUD = null
var _day_phase_announcement: DayPhaseAnnouncement = null
var _status_hud: TowerDefenseStatusHUD = null
var _last_day_phase_announcement_key: StringName = &""
var _client_countdown_sequence_key: StringName = &""
var _client_last_countdown_tick_seconds := COUNTDOWN_FINAL_SECONDS + 1


func setup(
	runtime: TowerDefenseGame,
	campaign_coordinator: TowerDefenseCampaignCoordinator,
	plant_placement_coordinator: TowerDefensePlantPlacementCoordinator,
	day_cycle_config: DayCycleConfig,
	map_camera: Camera2D,
	music_player: AudioStreamPlayer,
	countdown_audio: AudioStreamPlayer,
	wave_start_audio: AudioStreamPlayer,
	defeat_audio: AudioStreamPlayer,
	wave_hud: TowerDefenseWaveHUD,
	day_phase_announcement: DayPhaseAnnouncement,
	status_hud: TowerDefenseStatusHUD
) -> void:
	_runtime = runtime
	_campaign_coordinator = campaign_coordinator
	_plant_placement_coordinator = plant_placement_coordinator
	_day_cycle_config = day_cycle_config
	_map_camera = map_camera
	_music_player = music_player
	_countdown_audio = countdown_audio
	_wave_start_audio = wave_start_audio
	_defeat_audio = defeat_audio
	_wave_hud = wave_hud
	_day_phase_announcement = day_phase_announcement
	_status_hud = status_hud


func is_bound() -> bool:
	return (
		_runtime != null
		and _campaign_coordinator != null
		and _plant_placement_coordinator != null
		and _day_cycle_config != null
		and _map_camera != null
		and _music_player != null
		and _countdown_audio != null
		and _wave_start_audio != null
		and _defeat_audio != null
		and _wave_hud != null
		and _day_phase_announcement != null
		and _status_hud != null
	)


func replace_music_fade_tween(tween: Tween) -> void:
	music_fade_tween = tween


func replace_boss_intro_camera_tween(tween: Tween) -> void:
	boss_intro_camera_tween = tween


func replace_defeat_camera_tween(tween: Tween) -> void:
	defeat_camera_tween = tween


func configure_status_hud(runtime_mode: int) -> void:
	_status_hud.set_dead_player_list_enabled(
		runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	)
	_status_hud.show()


func configure_wave_hud(
	runtime_mode: int,
	current_base_health: int,
	maximum_base_health: int
) -> void:
	_wave_hud.configure_tower_defense(
		current_base_health,
		maximum_base_health,
		_day_cycle_config
	)
	_wave_hud.set_return_button_text(
		"返回菜单"
		if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else "返回大厅"
	)


func connect_wave_hud_requests() -> void:
	if not _wave_hud.return_to_lobby_requested.is_connected(
		_on_wave_hud_return_to_lobby_requested
	):
		_wave_hud.return_to_lobby_requested.connect(
			_on_wave_hud_return_to_lobby_requested
		)
	if not _wave_hud.start_wave_requested.is_connected(
		_on_wave_hud_start_wave_requested
	):
		_wave_hud.start_wave_requested.connect(
			_on_wave_hud_start_wave_requested
		)


func _on_wave_hud_return_to_lobby_requested() -> void:
	return_to_lobby_requested.emit()


func _on_wave_hud_start_wave_requested() -> void:
	start_wave_requested.emit()


func apply_wave_start_lighting(wave_number: int) -> void:
	if _campaign_coordinator.is_night_wave(wave_number):
		_runtime.transition_world_to_night()
	else:
		_runtime.transition_world_to_day()


func apply_intermission_lighting(completed_wave_number: int) -> void:
	if _campaign_coordinator.is_night_intermission_after_wave(
		completed_wave_number
	):
		_runtime.transition_world_to_night()
	else:
		_runtime.transition_world_to_day()


func transition_world_to_day() -> void:
	_runtime.transition_world_to_day()


func announce_wave_phase_start(
	wave_number: int,
	announcements_enabled: bool
) -> bool:
	if not announcements_enabled:
		return false
	var safe_wave := maxi(wave_number, 1)
	var wave_in_day := _campaign_coordinator.get_wave_in_day(safe_wave)
	if wave_in_day not in [1, _day_cycle_config.night_start_wave_in_day]:
		return false
	var is_night := _campaign_coordinator.is_night_wave(safe_wave)
	var day_number := _campaign_coordinator.get_day_number_for_wave(safe_wave)
	var announcement_key := StringName("%d:%d" % [day_number, int(is_night)])
	if announcement_key == _last_day_phase_announcement_key:
		return true
	_last_day_phase_announcement_key = announcement_key
	_day_phase_announcement.show_day_phase(day_number, is_night)
	return true


func show_countdown(seconds: int, can_start_early: bool) -> void:
	_wave_hud.show_countdown(seconds, can_start_early)


func show_base_health(
	current_health: int,
	maximum_health: int,
	play_damage_pulse: bool
) -> void:
	_wave_hud.set_tower_defense_core_health(
		current_health,
		maximum_health,
		play_damage_pulse
	)


func play_gate_damage_warning() -> void:
	_status_hud.play_gate_damage_warning()


func stop_gate_damage_warning() -> void:
	_status_hud.stop_gate_damage_warning()


func show_enemy_count(alive_count: int) -> void:
	_wave_hud.set_tower_defense_enemy_count(maxi(alive_count, 0))


func show_wave_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	_wave_hud.show_tower_defense_wave_progress(
		wave_number,
		defeated,
		escaped,
		resolved,
		total
	)


func show_boss_progress(defeated: int, total: int) -> void:
	_wave_hud.show_tower_defense_boss_progress(defeated, total)


func show_custom_phase_announcement(text: String) -> void:
	if _day_phase_announcement != null and not text.strip_edges().is_empty():
		_day_phase_announcement.show_announcement(text)


func show_victory() -> void:
	_wave_hud.show_victory()


func hide_wave_hud() -> void:
	_wave_hud.hide_all()


func show_defeat() -> void:
	_wave_hud.show_tower_defense_defeat()
	_defeat_audio.play()


func update_player_respawn_countdown(
	peer_id: int,
	display_name: String,
	seconds_left: int,
	is_local: bool
) -> void:
	_status_hud.set_player_respawn(
		peer_id,
		display_name,
		seconds_left,
		is_local
	)


func clear_player_respawn_countdown(peer_id: int) -> void:
	_status_hud.clear_player_respawn(peer_id)


func clear_result_status() -> void:
	spectator_camera_active = false
	_status_hud.clear_all_respawns()


func present_player_death(player_instance: Player) -> void:
	if player_instance != null and is_instance_valid(player_instance):
		player_instance.apply_tower_defense_death_presentation()


func attach_camera_to_local_player(player_instance: Player) -> void:
	if _map_camera == null or player_instance == null:
		return
	_map_camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	player_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	if _map_camera.get_parent() != player_instance:
		_map_camera.reparent(player_instance)
	_map_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	_map_camera.position = Vector2.ZERO
	_map_camera.zoom = Vector2(2.0, 2.0)
	_map_camera.position_smoothing_enabled = false
	_map_camera.enabled = true
	player_instance.reset_physics_interpolation()
	_map_camera.reset_physics_interpolation()


func begin_local_spectator_camera(player_instance: Player) -> void:
	if spectator_camera_active or _map_camera == null or player_instance == null:
		return
	if _map_camera.get_parent() != _runtime:
		_map_camera.reparent(_runtime, true)
	_map_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_map_camera.reset_physics_interpolation()
	spectator_camera_active = true


func end_local_spectator_camera(player_instance: Player) -> void:
	if not spectator_camera_active:
		return
	spectator_camera_active = false
	attach_camera_to_local_player(player_instance)


func update_local_spectator_camera(delta: float) -> void:
	if not spectator_camera_active or _map_camera == null:
		return
	if _plant_placement_coordinator.has_exclusive_modal_open():
		return
	var move_input := Input.get_vector(
		&"move_left",
		&"move_right",
		&"move_up",
		&"move_down"
	)
	if move_input == Vector2.ZERO:
		return
	_map_camera.global_position += move_input * SPECTATOR_CAMERA_SPEED * delta
	_map_camera.global_position = clamp_camera_position(
		_map_camera.global_position
	)


func clamp_camera_position(camera_position: Vector2) -> Vector2:
	if _map_camera == null:
		return camera_position
	var ground_layer := _runtime.ground_tile_map_layer
	if ground_layer == null or ground_layer.tile_set == null:
		return camera_position
	var used_rect := ground_layer.get_used_rect()
	if used_rect.size.x <= 0 or used_rect.size.y <= 0:
		return camera_position
	var top_left := ground_layer.to_global(
		ground_layer.map_to_local(used_rect.position)
	)
	var bottom_right := ground_layer.to_global(
		ground_layer.map_to_local(used_rect.end - Vector2i.ONE)
	)
	return Vector2(
		clampf(
			camera_position.x,
			minf(top_left.x, bottom_right.x),
			maxf(top_left.x, bottom_right.x)
		),
		clampf(
			camera_position.y,
			minf(top_left.y, bottom_right.y),
			maxf(top_left.y, bottom_right.y)
		)
	)


func cancel_defeat_camera() -> void:
	if defeat_camera_tween == null:
		return
	defeat_camera_tween.kill()
	defeat_camera_tween = null


func begin_defeat_camera_sequence(
	home_objective_targets: Array[Node2D]
) -> void:
	_kill_boss_intro_camera_tween()
	cancel_defeat_camera()
	if _map_camera == null or home_objective_targets.is_empty():
		_runtime._complete_defeat_presentation()
		return
	spectator_camera_active = false
	if _map_camera.get_parent() != _runtime:
		_map_camera.reparent(_runtime, true)
	_map_camera.process_callback = Camera2D.CAMERA2D_PROCESS_IDLE
	_map_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_map_camera.reset_physics_interpolation()
	var gate_center := home_objective_targets[0].global_position.round()
	if (
		_map_camera.global_position.is_equal_approx(gate_center)
		or not _runtime.is_inside_tree()
	):
		_map_camera.global_position = gate_center
		_runtime._complete_defeat_presentation()
		return
	defeat_camera_tween = create_tween()
	defeat_camera_tween.set_trans(Tween.TRANS_SINE)
	defeat_camera_tween.set_ease(Tween.EASE_IN_OUT)
	defeat_camera_tween.tween_method(
		_set_map_camera_rounded_global_position,
		_map_camera.global_position,
		gate_center,
		DEFEAT_CAMERA_TRAVEL_SECONDS
	)
	defeat_camera_tween.tween_callback(
		_runtime._complete_defeat_presentation
	)


func reset_defeat_presentation() -> void:
	defeat_presentation_completed = false


func complete_defeat_presentation() -> void:
	defeat_camera_tween = null
	if defeat_presentation_completed:
		return
	defeat_presentation_completed = true
	show_defeat()


func _set_map_camera_rounded_global_position(camera_position: Vector2) -> void:
	if _map_camera != null:
		_map_camera.global_position = camera_position.round()


func focus_camera_on_boss_intro(boss_position: Vector2) -> void:
	_kill_boss_intro_camera_tween()
	if _map_camera == null:
		return
	spectator_camera_active = false
	if _map_camera.get_parent() != _runtime:
		_map_camera.reparent(_runtime, true)
	_map_camera.process_callback = Camera2D.CAMERA2D_PROCESS_IDLE
	_map_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_map_camera.reset_physics_interpolation()
	var rounded_target := boss_position.round()
	if (
		_map_camera.global_position.is_equal_approx(rounded_target)
		or not _runtime.is_inside_tree()
	):
		_map_camera.global_position = rounded_target
		return
	boss_intro_camera_tween = create_tween()
	boss_intro_camera_tween.set_trans(Tween.TRANS_SINE)
	boss_intro_camera_tween.set_ease(Tween.EASE_IN_OUT)
	boss_intro_camera_tween.tween_method(
		_set_map_camera_rounded_global_position,
		_map_camera.global_position,
		rounded_target,
		BOSS_INTRO_CAMERA_FOCUS_SECONDS
	)


func restore_camera_after_boss_intro(player_instance: Player) -> void:
	_kill_boss_intro_camera_tween()
	if _map_camera == null or player_instance == null:
		return
	spectator_camera_active = false
	attach_camera_to_local_player(player_instance)


func _kill_boss_intro_camera_tween() -> void:
	if boss_intro_camera_tween == null:
		return
	boss_intro_camera_tween.kill()
	boss_intro_camera_tween = null


func play_countdown_tick() -> void:
	_countdown_audio.pitch_scale = 1.0
	_countdown_audio.play()


func play_client_countdown_tick_if_new(
	state: CombatFlowState.State,
	step_id: StringName,
	seconds: int
) -> void:
	var sequence_key := StringName("%d:%s" % [int(state), String(step_id)])
	if sequence_key != _client_countdown_sequence_key:
		_client_countdown_sequence_key = sequence_key
		_client_last_countdown_tick_seconds = COUNTDOWN_FINAL_SECONDS + 1
	if (
		seconds <= 0
		or seconds > COUNTDOWN_FINAL_SECONDS
		or seconds >= _client_last_countdown_tick_seconds
	):
		return
	_client_last_countdown_tick_seconds = seconds
	play_countdown_tick()


func play_wave_start_audio() -> void:
	_wave_start_audio.play()


func update_wave_music(wave_config: WaveConfig) -> void:
	if wave_config.music == null:
		return
	play_music_stream(
		wave_config.music,
		DEFAULT_MUSIC_VOLUME_DB,
		0.0,
		true
	)


func update_post_wave_music(flow_step: FlowStepConfig) -> void:
	var wave_config := flow_step as WaveConfig
	if wave_config == null or wave_config.post_wave_music == null:
		return
	play_music_stream(
		wave_config.post_wave_music,
		DEFAULT_MUSIC_VOLUME_DB,
		0.0,
		true
	)


func update_boss_music(boss_config: BossConfig) -> void:
	if boss_config == null or boss_config.music == null:
		return
	play_music_stream(
		boss_config.music,
		boss_config.music_volume_db,
		boss_config.music_loop_offset,
		false
	)


func pause_all_background_music() -> void:
	stop_music_fade_tween()
	pause_background_music_players(_runtime)


func stop_background_music_for_defeat() -> void:
	stop_music_fade_tween()
	_music_player.stream_paused = false
	_music_player.stop()


func play_music_stream(
	stream: AudioStream,
	volume_db: float,
	loop_offset: float = 0.0,
	fade_in: bool = false
) -> void:
	if stream == null:
		return
	configure_music_loop(stream, loop_offset)
	_music_player.stream_paused = false
	if _music_player.stream == stream and _music_player.playing:
		return
	stop_music_fade_tween()
	_music_player.stream = stream
	_music_player.volume_db = (
		MUSIC_FADE_IN_START_VOLUME_DB if fade_in else volume_db
	)
	_music_player.play()
	if fade_in:
		var fade_tween := create_tween()
		music_fade_tween = fade_tween
		fade_tween.tween_property(
			_music_player,
			"volume_db",
			volume_db,
			MUSIC_FADE_IN_SECONDS
		)
		fade_tween.finished.connect(
			func() -> void:
				if music_fade_tween == fade_tween:
					music_fade_tween = null
		)


func stop_music_fade_tween() -> void:
	if music_fade_tween == null:
		return
	music_fade_tween.kill()
	music_fade_tween = null


func configure_music_loop(stream: AudioStream, loop_offset: float) -> void:
	if stream == null:
		return
	if audio_stream_has_property(stream, &"loop"):
		stream.set(&"loop", true)
	if audio_stream_has_property(stream, &"loop_offset"):
		stream.set(&"loop_offset", maxf(loop_offset, 0.0))


func audio_stream_has_property(
	stream: AudioStream,
	property_name: StringName
) -> bool:
	for property in stream.get_property_list():
		if property.get("name") == property_name:
			return true
	return false


func pause_background_music_players(root_node: Node) -> void:
	if root_node == null:
		return
	if is_background_music_player(root_node):
		root_node.set(&"stream_paused", true)
	for child in root_node.get_children():
		pause_background_music_players(child)


func is_background_music_player(node: Node) -> bool:
	if not (
		node is AudioStreamPlayer
		or node is AudioStreamPlayer2D
		or node is AudioStreamPlayer3D
	):
		return false
	if not bool(node.get(&"playing")):
		return false
	var bus_name := String(node.get(&"bus")).to_lower()
	var node_name := String(node.name).to_lower()
	return (
		bus_name == "music"
		or node_name.contains("music")
		or node_name.contains("bgm")
	)
