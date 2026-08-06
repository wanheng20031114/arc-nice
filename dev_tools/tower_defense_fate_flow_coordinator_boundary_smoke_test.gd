extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const ROOT_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.gd"
)
const ROOT_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const COORDINATOR_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/fate/"
	+ "tower_defense_fate_flow_coordinator.gd"
)
const COORDINATOR_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/fate/"
	+ "tower_defense_fate_flow_coordinator.tscn"
)

var failures: Array[String] = []
var exit_code := 0
var exit_timer: Timer


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_static_structure_and_order_guards()
	await _test_runtime_binding_and_behavior()
	if failures.is_empty():
		print("TOWER_DEFENSE_FATE_FLOW_COORDINATOR_BOUNDARY_SMOKE_TEST_OK")
		_schedule_exit(0)
		return
	for failure in failures:
		push_error(failure)
	_schedule_exit(1)


func _test_static_structure_and_order_guards() -> void:
	var root_source := _read_text(ROOT_SOURCE_PATH)
	var root_scene_source := _read_text(ROOT_SCENE_PATH)
	var coordinator_source := _read_text(COORDINATOR_SOURCE_PATH)
	var coordinator_scene_source := _read_text(COORDINATOR_SCENE_PATH)
	_expect(
		root_scene_source.contains(
			'[node name="FateFlowCoordinator" parent="." '
			+ 'instance=ExtResource("69_fate_flow")]'
		),
		"TowerDefenseGame 必须静态实例化 FateFlowCoordinator。"
	)
	_expect(
		coordinator_scene_source.contains('uid="uid://')
		and coordinator_scene_source.contains('type="Script" uid="uid://'),
		"FateFlowCoordinator 场景与脚本引用必须持有稳定 UID。"
	)
	_expect(
		root_scene_source.contains(
			'type="PackedScene" uid="uid://d0brkwgd71xus" '
			+ 'path="res://scene/game_modes/tower_defense/fate/'
			+ 'tower_defense_fate_flow_coordinator.tscn"'
		),
		"TowerDefenseGame 对 FateFlowCoordinator 的引用必须携带 scene UID。"
	)
	_expect(
		root_source.contains("fate_flow_coordinator.setup(")
		and coordinator_source.contains("func setup("),
		"FateFlowCoordinator 必须由 root 显式 setup。"
	)
	for forbidden in [
		"get_tree().current_scene",
		"get_node(\"../",
		"has_method(",
		".call(",
		"mode_adapter",
		"multiplayer_gateway",
	]:
		_expect(
			not coordinator_source.contains(forbidden),
			"FateFlowCoordinator 禁止动态依赖或网络外观直连：%s" % forbidden
		)
	for migrated_state in [
		"fate_frozen_terrain_decay_time_left",
		"remote_fate_entry_in_progress",
		"remote_fate_departure_in_progress",
		"remote_fate_departure_covered",
		"pending_remote_fate_flow_state",
	]:
		_expect(
			not root_source.contains("var %s" % migrated_state),
			"FateFlow 状态仍残留 root：%s" % migrated_state
		)

	var interaction_source := _function_source(
		root_source,
		"func request_xiaocong_interaction(",
		"func request_xiaocong_fate_vote("
	)
	_expect_order(
		interaction_source,
		[
			"runtime_mode == RuntimeMode.CLIENT_VIEW",
			"wave_state != CombatFlowState.State.FATE_INTERLUDE",
			"fate_flow_coordinator.request_interaction(peer_id)",
		],
		"root interaction authority gate"
	)
	var vote_source := _function_source(
		root_source,
		"func request_xiaocong_fate_vote(",
		"func request_xiaocong_collectible_choice("
	)
	_expect_order(
		vote_source,
		[
			"runtime_mode == RuntimeMode.CLIENT_VIEW",
			"wave_state != CombatFlowState.State.FATE_INTERLUDE",
			"fate_flow_coordinator.request_fate_vote(",
		],
		"root fate vote authority gate"
	)
	var collectible_source := _function_source(
		root_source,
		"func request_xiaocong_collectible_choice(",
		"func _is_fate_collectible_choice_pending_for_peer("
	)
	_expect_order(
		collectible_source,
		[
			"runtime_mode == RuntimeMode.CLIENT_VIEW",
			"wave_state != CombatFlowState.State.FATE_INTERLUDE",
			"fate_flow_coordinator.request_collectible_choice(",
		],
		"root collectible authority gate"
	)
	var remote_snapshot_source := _function_source(
		root_source,
		"func apply_remote_xiaocong_fate_state(",
		"func _on_xiaocong_fate_state_changed("
	)
	_expect_order(
		remote_snapshot_source,
		[
			"runtime_mode != RuntimeMode.CLIENT_VIEW",
			'int(state.get("revision", 0)) < fate_manager.state_revision',
			"fate_flow_coordinator.apply_remote_state(state)",
		],
		"root remote snapshot authority/revision gate"
	)
	var snapshot_emit_source := _function_source(
		root_source,
		"func _emit_xiaocong_fate_state_snapshot(",
		"func _resume_flow_after_fate_interlude("
	)
	_expect_order(
		snapshot_emit_source,
		[
			"runtime_mode == RuntimeMode.HOST_AUTHORITY",
			"tower_multiplayer_mode_adapter.xiaocong_fate_state_changed.emit(snapshot)",
		],
		"root host snapshot outbound"
	)

	var host_entry_source := _function_source(
		coordinator_source,
		"func enter_interlude(",
		"func present_locally("
	)
	_expect_order(
		host_entry_source,
		[
			"set_interlude_systems_frozen(true)",
			"runtime.wave_state = CombatFlowState.State.FATE_INTERLUDE",
			"set_player_combat_locked(true)",
			"runtime.next_flow_step_after_rest = next_step",
			"runtime.countdown_seconds = 0",
			"enemy_spawn_timer.stop()",
			"state_timer.stop()",
			"runtime._emit_multiplayer_flow_state(CombatFlowState.State.FATE_INTERLUDE)",
			"await xiaocong_fate_interlude.cover_scene_for_transfer()",
			"runtime._set_merchant_active(false)",
			"runtime.transition_world_to_day()",
			"runtime._force_revive_dead_players()",
			"present_locally(completed_day)",
			"teleport_authoritative_players_to_room()",
			"await xiaocong_fate_interlude.play_room_reveal()",
			"fate_coordinator.begin_interlude(",
		],
		"host fate entry"
	)
	var remote_entry_source := _function_source(
		coordinator_source,
		"func begin_remote_entry(",
		"func begin_remote_departure("
	)
	_expect_order(
		remote_entry_source,
		[
			"if remote_entry_in_progress:",
			"remote_entry_in_progress = true",
			"remote_departure_in_progress = false",
			"remote_departure_covered = false",
			"pending_remote_flow_state.clear()",
			"await xiaocong_fate_interlude.cover_scene_for_transfer()",
			"runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW",
			"runtime.transition_world_to_day()",
			"runtime._set_local_merchants_active(false)",
			"present_locally(day_number)",
			"await xiaocong_fate_interlude.play_room_reveal()",
			"remote_entry_in_progress = false",
		],
		"client fate entry"
	)
	var remote_departure_source := _function_source(
		coordinator_source,
		"func begin_remote_departure(",
		"func complete_remote_flow_transition("
	)
	_expect_order(
		remote_departure_source,
		[
			"if remote_departure_in_progress:",
			"remote_departure_in_progress = true",
			"await xiaocong_fate_interlude.play_outcome_message(",
			"await xiaocong_fate_interlude.cover_scene_for_transfer()",
			"remote_departure_covered = true",
			"if pending_remote_flow_state.is_empty():",
			"var deferred_flow_state := pending_remote_flow_state.duplicate()",
			"pending_remote_flow_state.clear()",
			"runtime.apply_remote_flow_state(",
		],
		"client fate departure"
	)
	var completion_source := _function_source_to_end(
		coordinator_source, "func _on_interlude_completed("
	)
	_expect_order(
		completion_source,
		[
			"await xiaocong_fate_interlude.play_outcome_message(winning_option_id)",
			"await xiaocong_fate_interlude.cover_scene_for_transfer()",
			"fate_coordinator.clear_pending_rewards()",
			"leave_presentation()",
			"restore_authoritative_players_from_room()",
			"runtime._resume_flow_after_fate_interlude(next_step_id)",
			"await xiaocong_fate_interlude.reveal_world_after_transfer()",
		],
		"host fate departure"
	)
	var freeze_source := _function_source(
		coordinator_source,
		"func set_interlude_systems_frozen(",
		"func set_player_combat_locked("
	)
	_expect_order(
		freeze_source,
		[
			"if plant_terrain_decay_timer == null:",
			"if frozen:",
			"if not plant_terrain_decay_timer.is_stopped():",
			"frozen_terrain_decay_time_left = plant_terrain_decay_timer.time_left",
			"plant_terrain_decay_timer.stop()",
			"\t\treturn",
			"if plant_terrain_decay_timer.is_stopped():",
			"plant_terrain_decay_timer.start(",
			"frozen_terrain_decay_time_left = 0.0",
		],
		"fate timer pause/resume"
	)


func _test_runtime_binding_and_behavior() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "塔防主场景无法实例化。")
	if game == null:
		return
	game.auto_start_waves = false
	var static_coordinator := game.get_node_or_null(
		"FateFlowCoordinator"
	) as TowerDefenseFateFlowCoordinator
	_expect(static_coordinator != null, "ready 前必须已有静态 FateFlowCoordinator。")
	var runtime_fate := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if runtime_fate != null:
		runtime_fate.elite_enemy_config_loads_requested = true
	var runtime_boss := game.get_node_or_null(
		"BossCoordinator"
	) as TowerDefenseBossCoordinator
	if runtime_boss != null:
		runtime_boss.runtime_scene_loads_requested = true
	root.add_child(game)
	current_scene = game
	await process_frame
	var coordinator := game.fate_flow_coordinator
	_expect(
		coordinator == static_coordinator,
		"root onready 必须绑定静态 FateFlowCoordinator。"
	)
	_expect(
		coordinator != null and coordinator.is_bound(),
		"FateFlowCoordinator 依赖绑定不完整。"
	)
	if coordinator == null or not coordinator.is_bound():
		current_scene = null
		game.queue_free()
		await process_frame
		return

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	game.plant_terrain_decay_timer.start(8.0)
	await process_frame
	coordinator.set_interlude_systems_frozen(true)
	var captured_time_left := coordinator.frozen_terrain_decay_time_left
	coordinator.set_interlude_systems_frozen(true)
	_expect(
		game.plant_terrain_decay_timer.is_stopped()
		and captured_time_left > 0.0
		and is_equal_approx(
			coordinator.frozen_terrain_decay_time_left,
			captured_time_left
		)
		and not game.production_coordinator.authoritative_processing_enabled
		and not game.research_coordinator.authoritative_processing_enabled
		and not game.plant_placement_controller.placement_input_enabled,
		"重复 freeze 必须保留首次 timer time_left 且冻结权威系统。"
	)
	coordinator.set_interlude_systems_frozen(false)
	_expect(
		not game.plant_terrain_decay_timer.is_stopped()
		and coordinator.frozen_terrain_decay_time_left == 0.0
		and game.production_coordinator.authoritative_processing_enabled
		and game.research_coordinator.authoritative_processing_enabled,
		"unfreeze 必须恢复 timer、生产与科研。"
	)

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	game.plant_terrain_decay_timer.start(6.0)
	game.production_coordinator.set_authoritative_processing_enabled(true)
	game.research_coordinator.set_authoritative_processing_enabled(true)
	coordinator.set_interlude_systems_frozen(true)
	_expect(
		not game.plant_terrain_decay_timer.is_stopped()
		and game.production_coordinator.authoritative_processing_enabled
		and game.research_coordinator.authoritative_processing_enabled
		and not game.plant_placement_controller.placement_input_enabled,
		"CLIENT freeze 只能关闭本地放置，不能暂停权威系统或 timer。"
	)
	coordinator.set_interlude_systems_frozen(false)

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	coordinator.set_player_combat_locked(true)
	_expect(
		game.player.combat_actions_locked and not game.player.controls_locked,
		"命运幕间必须只锁战斗动作并保留移动。"
	)
	coordinator.set_player_combat_locked(false)
	game.player.global_position = Vector2(19.0, 23.0)
	game.player.velocity = Vector2(7.0, -3.0)
	coordinator.teleport_authoritative_players_to_room()
	_expect(
		game.player.global_position
		== game.xiaocong_fate_interlude.get_player_spawn_position(0)
		and game.player.velocity == Vector2.ZERO,
		"单人进入命运房间必须按 position→velocity→interpolation 顺序传送。"
	)
	coordinator.restore_authoritative_players_from_room()
	_expect(
		game.player.global_position == game.player_spawn.global_position,
		"单人离开命运房间必须恢复到玩家出生点。"
	)

	var teleport_peer_order: Array[int] = []
	var teleport_listener := func(peer_id: int, _target: Vector2) -> void:
		teleport_peer_order.append(peer_id)
	game.multiplayer_gateway.player_teleport_requested.connect(teleport_listener)
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.peer_players.clear()
	game.peer_players[7] = game.player
	game.peer_players[2] = game.player
	game.multiplayer_spawn_slot_indices.clear()
	game.multiplayer_spawn_slot_indices[7] = 1
	game.multiplayer_spawn_slot_indices[2] = 0
	coordinator.teleport_authoritative_players_to_room()
	coordinator.restore_authoritative_players_from_room()
	_expect(
		teleport_peer_order == [2, 7, 2, 7],
		"HOST 进入与恢复传送必须按排序 peer 经 root gateway façade 出站。"
	)
	game.multiplayer_gateway.player_teleport_requested.disconnect(teleport_listener)
	game.peer_players.clear()

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	game.fate_coordinator.begin_interlude(1, &"next", [0], 0)
	game.player.global_position = game.xiaocong_fate_interlude.global_position
	game.wave_state = CombatFlowState.State.PRE_WAVE
	game.request_xiaocong_interaction(0)
	_expect(
		not game.fate_manager.interacted_peer_ids.has(0),
		"非 FATE flow 的 interaction 必须由 root 拒绝。"
	)
	game.wave_state = CombatFlowState.State.FATE_INTERLUDE
	game.request_xiaocong_interaction(0)
	_expect(
		game.fate_manager.interacted_peer_ids.has(0),
		"获准的 interaction 必须委托 coordinator 写入 manager。"
	)
	var current_revision := game.fate_manager.state_revision
	game.fate_coordinator.elite_bias_day = 4
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	game.apply_remote_xiaocong_fate_state({
		"revision": current_revision - 1,
		"elite_bias_day": 99,
	})
	_expect(
		game.fate_coordinator.elite_bias_day == 4,
		"过期 fate snapshot 必须在 root revision gate 被拒绝。"
	)
	var accepted_snapshot := coordinator.get_state_snapshot()
	accepted_snapshot["revision"] = current_revision
	accepted_snapshot["elite_bias_day"] = 8
	game.apply_remote_xiaocong_fate_state(accepted_snapshot)
	_expect(
		game.fate_coordinator.elite_bias_day == 8,
		"相等 revision 的 fate snapshot 必须保持旧版可接受语义。"
	)

	_stop_audio_recursive(game)
	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("无法读取验证源码：%s" % path)
		return ""
	return file.get_as_text()


func _function_source(source: String, start_marker: String, end_marker: String) -> String:
	var start := source.find(start_marker)
	var end := source.find(end_marker, start + start_marker.length())
	if start < 0 or end <= start:
		failures.append("无法提取函数区间：%s -> %s" % [start_marker, end_marker])
		return ""
	return source.substr(start, end - start)


func _function_source_to_end(source: String, start_marker: String) -> String:
	var start := source.find(start_marker)
	if start < 0:
		failures.append("无法提取函数：%s" % start_marker)
		return ""
	return source.substr(start)


func _expect_order(source: String, markers: Array[String], label: String) -> void:
	var cursor := -1
	for marker in markers:
		var position := source.find(marker, cursor + 1)
		if position < 0:
			failures.append("%s 缺少顺序标记：%s" % [label, marker])
			return
		if position <= cursor:
			failures.append("%s 顺序发生变化：%s" % [label, marker])
			return
		cursor = position


func _stop_audio_recursive(node: Node) -> void:
	var player_2d := node as AudioStreamPlayer2D
	if player_2d != null:
		player_2d.stop()
		player_2d.stream = null
	var player := node as AudioStreamPlayer
	if player != null:
		player.stop()
		player.stream = null
	for child in node.get_children():
		_stop_audio_recursive(child)


func _schedule_exit(code: int) -> void:
	exit_code = code
	exit_timer = Timer.new()
	exit_timer.one_shot = true
	exit_timer.wait_time = 0.1
	root.add_child(exit_timer)
	exit_timer.timeout.connect(_quit_after_async_release)
	exit_timer.start()


func _quit_after_async_release() -> void:
	exit_timer.stop()
	exit_timer.queue_free()
	quit(exit_code)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
