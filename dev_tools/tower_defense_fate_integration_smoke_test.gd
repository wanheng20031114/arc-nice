extends SceneTree

const GAME_SCENE := preload("res://scene/game_tower_defense.tscn")
const FATE_COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/fate_coordinator.tscn"
)

class FlowBoundaryProbe:
	extends GameTowerDefense

	var probe_wave_number := 1
	var probe_next_step: FlowStepConfig = null
	var entered_fate := false
	var entered_intermission := false
	var entered_victory := false
	var captured_next_step: FlowStepConfig = null

	func _get_default_next_flow_step(_flow_step: FlowStepConfig) -> FlowStepConfig:
		return probe_next_step

	func _get_wave_number_for_step(_wave_config: WaveConfig) -> int:
		return probe_wave_number

	func _enter_xiaocong_fate_interlude(next_step: FlowStepConfig) -> void:
		entered_fate = true
		captured_next_step = next_step

	func _enter_intermission(next_step: FlowStepConfig = null) -> void:
		entered_intermission = true
		captured_next_step = next_step

	func _enter_victory(_emit_multiplayer: bool = true) -> void:
		entered_victory = true

	func _record_progression_day(_day_number: int) -> void:
		pass


class LightingProbe:
	extends GameTowerDefense

	var lighting_events: Array[StringName] = []

	func transition_world_to_night(_duration_seconds: float = -1.0) -> void:
		lighting_events.append(&"night")

	func transition_world_to_day(_duration_seconds: float = -1.0) -> void:
		lighting_events.append(&"day")


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_day_and_lighting_boundaries()
	_test_wave_completion_boundaries()
	_test_elite_bias_day_window()
	_test_double_xirang_day_combat_states()
	_test_boss_runtime_health_cap()
	await _test_elite_config_prewarm()
	await _test_wave_hud_uses_day_cycle_config()
	await _test_xiaocong_collectible_offer_count()
	await _test_scene_config_and_interlude_freeze()
	await _test_fate_stone_zero_benefit_filter()
	if failures.is_empty():
		print("TOWER_DEFENSE_FATE_INTEGRATION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_elite_config_prewarm() -> void:
	var coordinator := FATE_COORDINATOR_SCENE.instantiate() as FateCoordinator
	root.add_child(coordinator)
	await process_frame
	coordinator.request_elite_enemy_config_loads()
	coordinator.request_elite_enemy_config_loads()
	_expect(
		coordinator.elite_enemy_config_loads_requested,
		"Fate elite threaded loads must use one idempotent request lifecycle."
	)
	await coordinator.prewarm_elite_enemy_configs()
	_expect(
		coordinator.elite_enemy_config_by_base_path.size()
		== coordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.size(),
		"All fate elite enemy configs must be cached before combat activation."
	)
	for base_path_value in coordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH:
		var base_path := str(base_path_value)
		var elite_config := (
			coordinator.elite_enemy_config_by_base_path.get(base_path) as EnemyConfig
		)
		_expect(
			elite_config != null
			and elite_config.resource_path
			== str(coordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH[base_path_value]),
			"Fate elite prewarm must retain the configured replacement for %s." % base_path
		)
	coordinator.queue_free()
	await process_frame


func _test_day_and_lighting_boundaries() -> void:
	var probe := LightingProbe.new()
	var expected_days := [1, 1, 1, 1, 2, 2, 2, 2, 3]
	for wave_index in range(expected_days.size()):
		var wave_number := wave_index + 1
		_expect(
			probe._get_day_number_for_wave(wave_number) == expected_days[wave_index],
			"Wave %d must map to day %d." % [wave_number, expected_days[wave_index]]
		)

	var expected_wave_lighting: Array[StringName] = [
		&"day", &"day", &"night", &"night",
		&"day", &"day", &"night", &"night",
	]
	for wave_index in range(expected_wave_lighting.size()):
		probe.lighting_events.clear()
		probe._apply_wave_start_lighting(wave_index + 1)
		_expect(
			probe.lighting_events == [expected_wave_lighting[wave_index]],
			"Wave %d lighting must be %s." % [
				wave_index + 1,
				String(expected_wave_lighting[wave_index]),
			]
		)

	var expected_rest_lighting: Array[StringName] = [
		&"day", &"day", &"night", &"day",
	]
	for completed_wave_index in range(expected_rest_lighting.size()):
		probe.lighting_events.clear()
		probe._apply_intermission_lighting(completed_wave_index + 1)
		_expect(
			probe.lighting_events == [expected_rest_lighting[completed_wave_index]],
			"Rest after wave %d must keep the expected phase lighting." % (
				completed_wave_index + 1
			)
		)
	probe.free()


func _test_wave_completion_boundaries() -> void:
	var next_wave := WaveConfig.new()
	for wave_number in [1, 3, 5]:
		var probe := FlowBoundaryProbe.new()
		probe.current_flow_step = WaveConfig.new()
		probe.probe_wave_number = wave_number
		probe.probe_next_step = next_wave
		probe._complete_current_step()
		_expect(
			probe.entered_intermission and not probe.entered_fate,
			"Non-day-ending wave %d must enter intermission." % wave_number
		)
		probe.free()

	var day_end_probe := FlowBoundaryProbe.new()
	day_end_probe.current_flow_step = WaveConfig.new()
	day_end_probe.probe_wave_number = 4
	day_end_probe.probe_next_step = next_wave
	day_end_probe._complete_current_step()
	_expect(day_end_probe.entered_fate, "Wave 4 must enter the fate interlude.")
	_expect(
		day_end_probe.captured_next_step == next_wave,
		"The fate interlude must retain the next campaign step."
	)
	day_end_probe.free()

	var terminal_probe := FlowBoundaryProbe.new()
	terminal_probe.current_flow_step = WaveConfig.new()
	terminal_probe.probe_wave_number = 12
	terminal_probe.probe_next_step = null
	terminal_probe._complete_current_step()
	_expect(
		terminal_probe.entered_victory and not terminal_probe.entered_fate,
		"Terminal wave 12 must enter victory directly without a meaningless fate vote."
	)
	terminal_probe.free()


func _test_elite_bias_day_window() -> void:
	var probe := GameTowerDefense.new()
	var coordinator := FateCoordinator.new()
	coordinator.setup(probe, probe.day_cycle_config)
	probe.fate_coordinator = coordinator
	var base_config := load(
		"res://resources/config/enemies/capoo_knight.tres"
	) as EnemyConfig
	var elite_config := load(
		"res://resources/config/enemies/capoo_knight_elite.tres"
	) as EnemyConfig
	_expect(base_config != null and elite_config != null, "Elite fixture configs must load.")
	if base_config == null or elite_config == null:
		coordinator.free()
		probe.free()
		return

	coordinator.elite_bias_day = 2
	coordinator.random_generator.seed = 246813579
	probe.current_wave_index = 0
	for sample_index in range(32):
		_expect(
			probe._resolve_fate_enemy_config(base_config) == base_config,
			"Elite bias must not leak into the day before its target window."
		)

	probe.current_wave_index = 4
	var saw_elite := false
	for sample_index in range(128):
		if probe._resolve_fate_enemy_config(base_config) == elite_config:
			saw_elite = true
			break
	_expect(saw_elite, "The configured next day must be able to replace base enemies.")

	probe.current_wave_index = 8
	for sample_index in range(32):
		_expect(
			probe._resolve_fate_enemy_config(base_config) == base_config,
			"Elite bias must expire after exactly one day."
		)
	coordinator.free()
	probe.free()


func _test_double_xirang_day_combat_states() -> void:
	var probe := GameTowerDefense.new()
	var coordinator := FateCoordinator.new()
	coordinator.setup(probe, probe.day_cycle_config)
	probe.fate_coordinator = coordinator
	coordinator.double_xirang_day = 2
	probe.current_wave_index = 4
	probe.wave_state = GameRuntimeBase.WaveState.WAVE_ACTIVE
	_expect(
		probe._is_fate_double_xirang_reward_active(),
		"The target day's ordinary waves must double Xirang kill rewards."
	)
	probe.wave_state = GameRuntimeBase.WaveState.BOSS_ACTIVE
	_expect(
		probe._is_fate_double_xirang_reward_active(),
		"A target-day boss fight must retain the next-day double-Xirang reward."
	)
	probe.wave_state = GameRuntimeBase.WaveState.INTERMISSION
	_expect(
		not probe._is_fate_double_xirang_reward_active(),
		"The double-Xirang fate must remain combat-only."
	)
	probe.current_wave_index = 8
	probe.wave_state = GameRuntimeBase.WaveState.WAVE_ACTIVE
	_expect(
		not probe._is_fate_double_xirang_reward_active(),
		"The double-Xirang fate must expire after its single target day."
	)
	coordinator.free()
	probe.free()


func _test_boss_runtime_health_cap() -> void:
	var boss_config := load(
		"res://resources/config/enemies/linglan_boss.tres"
	) as EnemyConfig
	_expect(boss_config != null, "Linglan boss config must load for fate health validation.")
	if boss_config == null or boss_config.enemy_scene == null:
		return
	var boss := boss_config.enemy_scene.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan boss scene must instantiate for fate health validation.")
	if boss == null:
		return
	boss.config = boss_config
	boss.current_health = boss_config.max_health
	boss.set_runtime_max_health_multiplier(0.9)
	_expect(
		boss.get_max_health() == boss.get_runtime_max_health()
		and boss.current_health == boss.get_runtime_max_health(),
		"All-enemy max-health fate must also drive Linglan's authoritative HUD cap."
	)
	boss.free()


func _test_wave_hud_uses_day_cycle_config() -> void:
	var custom_cycle := DayCycleConfig.new()
	custom_cycle.waves_per_day = 6
	custom_cycle.night_start_wave_in_day = 4
	var hud := preload("res://scene/wave_hud.tscn").instantiate() as WaveHUD
	root.add_child(hud)
	await process_frame
	hud.configure_tower_defense(100, 100, custom_cycle)
	hud.set_tower_defense_wave_progress(7, 0, 10)
	_expect(
		hud.day_label.text == "第 2 日"
		and hud.phase_label.text == "白昼 1/3"
		and hud.day_dial.phase_count == 6
		and hud.day_dial.night_start_phase_index == 3,
		"WaveHUD and its dial must derive day/night phases from DayCycleConfig."
	)
	hud.queue_free()
	await process_frame


func _test_xiaocong_collectible_offer_count() -> void:
	var coordinator := FATE_COORDINATOR_SCENE.instantiate() as FateCoordinator
	root.add_child(coordinator)
	await process_frame
	var game := GameTowerDefense.new()
	var merchant := LuoxiMerchant.new()
	var target_player := preload(
		"res://scene/player/weishidaier/player_weishidaier.tscn"
	).instantiate() as Player
	game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.fate_coordinator = coordinator
	game.fate_manager = coordinator.manager
	game.luoxi_merchant = merchant
	game.peer_players = {1: target_player}
	coordinator.setup(game, game.day_cycle_config)
	coordinator.manager.active = true
	coordinator.manager.stage = TowerDefenseFateManager.STAGE_RESOLVING
	coordinator.manager.eligible_peer_ids = [1]
	LuoxiMerchant.set_runtime_choice_count(LuoxiMerchant.MAX_CHOICE_COUNT)
	game._begin_fate_collectible_reward()
	var offer: Array = coordinator.manager.collectible_offers.get(1, []) as Array
	_expect(
		coordinator.manager.stage == TowerDefenseFateManager.STAGE_COLLECTIBLE_REWARD
		and offer.size() == LuoxiMerchant.DEFAULT_CHOICE_COUNT,
		"Xiaocong collectible fate must stay at three cards when Luoxi shows four."
	)
	LuoxiMerchant.reset_runtime_choice_count()
	game.peer_players.clear()
	target_player.free()
	merchant.free()
	game.free()
	coordinator.queue_free()
	await process_frame


func _test_scene_config_and_interlude_freeze() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	var game := GAME_SCENE.instantiate() as GameTowerDefense
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame
	_expect(
		game.has_node("FateCoordinator/TowerDefenseFateManager")
		and game.day_cycle_config != null
		and game.day_cycle_config.is_valid(),
		"The game scene must author one FateCoordinator and one valid DayCycleConfig."
	)
	var interlude := game.xiaocong_fate_interlude
	var xiaocong_sprite := interlude.get_node(
		"RoomRoot/Xiaocong"
	) as AnimatedSprite2D
	var scene_transition_layer := interlude.get_node(
		"SceneTransitionLayer"
	) as CanvasLayer
	var scene_transition_cover := interlude.get_node(
		"SceneTransitionLayer/Cover"
	) as ColorRect
	var scene_transition_material := (
		scene_transition_cover.material as ShaderMaterial
	)
	var outcome_shade := interlude.get_node(
		"OutcomeLayer/Root/Shade"
	) as ColorRect
	var outcome_label := interlude.get_node(
		"OutcomeLayer/Root/Message"
	) as Label
	var interaction_ui_layer := interlude.get_node(
		"InteractionUILayer"
	) as CanvasLayer
	var interaction_anchor := interlude.get_node(
		"InteractionUILayer/Anchor"
	) as Node2D
	var prompt_label := interlude.get_node(
		"InteractionUILayer/Anchor/InteractionPrompt"
	) as Label
	var dialogue_bubble := interlude.get_node(
		"InteractionUILayer/Anchor/XiaocongDialogueBubble"
	) as MerchantDialogueBubble
	var transition_cover_audio := interlude.get_node(
		"TransitionCoverAudio"
	) as AudioStreamPlayer
	var transition_reveal_audio := interlude.get_node(
		"TransitionRevealAudio"
	) as AudioStreamPlayer
	var top_room_wall := interlude.get_node(
		"RoomRoot/RoomBounds/TopWall"
	) as CollisionShape2D
	var right_room_wall := interlude.get_node(
		"RoomRoot/RoomBounds/RightWall"
	) as CollisionShape2D
	var first_xiaocong_frame := xiaocong_sprite.sprite_frames.get_frame_texture(
		&"idle",
		0
	)
	_expect(
		xiaocong_sprite.scale == Vector2.ONE
		and xiaocong_sprite.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and first_xiaocong_frame.get_size() == Vector2(27, 41)
		and xiaocong_sprite.sprite_frames.get_frame_count(&"idle") == 12
		and interaction_ui_layer.layer > interlude.z_index
		and prompt_label.get_parent() == interaction_anchor
		and dialogue_bubble.get_parent() == interaction_anchor
		and dialogue_bubble.scale == Vector2.ONE
		and dialogue_bubble.position == dialogue_bubble.position.round()
		and prompt_label.label_settings.font_size >= 15
		and transition_cover_audio.stream != null
		and transition_reveal_audio.stream != null
		and (top_room_wall.shape as RectangleShape2D).size == Vector2(368, 16)
		and (right_room_wall.shape as RectangleShape2D).size == Vector2(16, 264)
		and scene_transition_layer.layer
		> interlude.choice_overlay.layer
		and not scene_transition_layer.visible
		and scene_transition_material != null
		and scene_transition_material.resource_local_to_scene
		and scene_transition_material.shader.code.contains("cover_progress")
		and scene_transition_material.get_shader_parameter(
			&"transition_noise"
		) != null,
		"The fate room must use a native 27x41 nearest-neighbor Xiaocong sprite, crisp screen-space interaction UI, authored transition audio, and a full-screen shader transition."
	)
	game._set_fate_player_combat_locked(true)
	_expect(
		game.player.combat_actions_locked
		and not game.player.controls_locked,
		"The fate room must lock combat actions without locking player movement."
	)
	var original_player_position := game.player.global_position
	interlude.set_active(true, 1)
	await physics_frame
	game.player.global_position = interlude.get_player_spawn_position(0)
	game.player.reset_physics_interpolation()
	var movement_start := game.player.global_position
	var previous_local_input := game.player.uses_local_input
	game.player.uses_local_input = false
	game.player.network_move_input = Vector2.RIGHT
	await physics_frame
	await physics_frame
	_expect(
		game.player.global_position.x > movement_start.x,
		"A combat-locked fate-room player must still move from directional input."
	)
	game.player.global_position = interlude.global_position + Vector2(160, 0)
	game.player.reset_physics_interpolation()
	for _frame in range(24):
		await physics_frame
	_expect(
		game.player.global_position.x <= interlude.global_position.x + 176.0,
		"The authored fate-room walls must contain a moving player inside the chamber."
	)
	game.player.network_move_input = Vector2.ZERO
	game.player.uses_local_input = previous_local_input
	game.player.global_position = original_player_position
	game.player.reset_physics_interpolation()
	interlude.set_active(false)
	await physics_frame
	game._set_fate_player_combat_locked(false)
	_expect(
		XiaocongFateInterlude.DEFAULT_OUTCOME_TEXT
		== "队伍做出了一个选择..."
		and XiaocongFateInterlude.FATE_STONE_OUTCOME_TEXT
		== "世界发生了改变"
		and outcome_shade.color == Color.BLACK
		and outcome_label.label_settings.outline_size == 0,
		"The normal outcome must use the team-choice line on pure black, while only the fate stone branch may replace it."
	)
	var transition_edge_color := Color(
		scene_transition_material.get_shader_parameter(
			&"growth_edge_color"
		)
	)
	var transition_core_color := Color(
		scene_transition_material.get_shader_parameter(
			&"growth_core_color"
		)
	)
	_expect(
		XiaocongFateInterlude.SCENE_COVER_DURATION_SECONDS <= 0.32
		and XiaocongFateInterlude.ROOM_REVEAL_DURATION_SECONDS <= 0.38
		and XiaocongFateChoiceOverlay.RETURN_TO_ROOM_DURATION_SECONDS <= 0.32
		and transition_edge_color.g - transition_edge_color.r <= 0.01
		and transition_core_color.g - transition_core_color.r <= 0.02
		and transition_core_color.r > transition_edge_color.r,
		"Fate scene transitions must stay brisk and use a restrained neutral-cool edge instead of yellow-green."
	)
	game.fate_coordinator.active_permanent_buff_ids = [
		TowerDefenseFateRegistry.BUFF_LOW_HEALTH_REDUCTION,
	]
	game.fate_coordinator.hurt_speed_penalty_enabled = true
	game.fate_coordinator.apply_player_modifiers_to_all()
	var low_health_config := TowerDefenseFateRegistry.get_permanent_buff_config(
		TowerDefenseFateRegistry.BUFF_LOW_HEALTH_REDUCTION
	)
	var dangerous_speed_config := TowerDefenseFateRegistry.get_option_config(
		TowerDefenseFateRegistry.OPTION_DANGEROUS_SPEED
	)
	_expect(
		game.player != null
		and low_health_config != null
		and dangerous_speed_config != null
		and is_equal_approx(
			game.player.tower_defense_fate_low_health_ratio,
			low_health_config.secondary_magnitude
		)
		and is_equal_approx(
			game.player.tower_defense_fate_low_health_damage_reduction,
			low_health_config.magnitude
		)
		and is_equal_approx(
			game.player.tower_defense_fate_hurt_move_speed_multiplier,
			dangerous_speed_config.secondary_amount
		)
		and is_equal_approx(
			game.player.tower_defense_fate_hurt_move_speed_duration,
			dangerous_speed_config.duration_seconds
		),
		"Player fate behavior must consume magnitudes from the shared named configs."
	)
	game._set_fate_interlude_systems_frozen(true)
	_expect(
		not game.production_coordinator.authoritative_processing_enabled
		and not game.research_coordinator.authoritative_processing_enabled
		and game.plant_terrain_decay_timer.is_stopped()
		and not game.plant_placement_controller.placement_input_enabled
		and not game.plant_placement_controller.open_selection(),
		"Fate interlude must freeze production, research, terrain decay, and normal T input."
	)
	var placement_rejections: Array[StringName] = []
	game.multiplayer_plant_placement_rejected.connect(
		func(_request_id: int, _peer_id: int, reason: StringName) -> void:
			placement_rejections.append(reason)
	)
	game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.wave_state = GameRuntimeBase.WaveState.FATE_INTERLUDE
	game.request_multiplayer_inventory_plant_placement(
		2,
		91,
		PlantDefenseRegistry.AGAVE_CANNON_ID,
		Vector2i.ZERO,
		0,
		0,
		"invalid"
	)
	_expect(
		placement_rejections == [GameTowerDefense.PLANT_PLACEMENT_REJECT_FLOW_LOCKED],
		"The authoritative server must reject stale building requests during fate interlude."
	)
	game.runtime_mode = GameRuntimeBase.RuntimeMode.SINGLEPLAYER
	game._set_fate_interlude_systems_frozen(false)
	_expect(
		game.production_coordinator.authoritative_processing_enabled
		and game.research_coordinator.authoritative_processing_enabled
		and not game.plant_terrain_decay_timer.is_stopped(),
		"Leaving fate interlude must resume the frozen authoritative systems."
	)
	current_scene = null
	game.queue_free()
	await process_frame


func _test_fate_stone_zero_benefit_filter() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	var stone := load(
		"res://resources/config/pickups/xiaocong_fate_stone.tres"
	) as PickupConfig
	_expect(run_state.try_add_item(stone), "The fate-stone filter fixture must be stored.")
	var coordinator := FATE_COORDINATOR_SCENE.instantiate() as FateCoordinator
	root.add_child(coordinator)
	await process_frame
	var game := GameTowerDefense.new()
	game.run_state = run_state
	game.player = Player.new()
	coordinator.setup(game, game.day_cycle_config)
	coordinator.begin_interlude(1, &"next", [0], 0)
	_expect(
		not coordinator.manager.available_option_ids.has(
			TowerDefenseFateRegistry.OPTION_FATE_STONE
		),
		"Fate stone must be filtered when it would benefit no eligible player."
	)
	coordinator.manager.force_finish()
	game.player.free()
	game.free()
	coordinator.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
