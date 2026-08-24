extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const MP_ENEMY_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/enemy/mp_enemy_coordinator.tscn"
)
const MP_ENEMY_COORDINATOR_SOURCE_PATH := (
	"res://scene/multiplayer/enemy/mp_enemy_coordinator.gd"
)
const BASIC_CONFIG_PATH := (
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const PROXY_COUNT := 1_000
const NET_ID_BASE := 30_001
const SPAWN_BATCH_SIZE := MpEnemyCoordinator.ENEMY_SPAWN_BATCH_MAX_RECORDS
const SNAPSHOT_BATCH_ID := 7_701
const SNAPSHOT_TIMESTAMP := 2.0
const SNAPSHOT_HZ := 20
const POSITION_COLUMNS := 40
const POSITION_SPACING := 64.0
const PROXY_SNAPSHOT_HEALTH := 40
const VISIBILITY_QUERY_AABB := Rect2(
	Vector2(-160.0, -160.0),
	Vector2(320.0, 320.0)
)
const VISIBILITY_LEFT_TOP_INDEX := 0
const VISIBILITY_RIGHT_EDGE_INDEX := 1
const VISIBILITY_BOTTOM_EDGE_INDEX := 2
const VISIBILITY_INNER_EDGE_INDEX := 3

var failures: Array[String] = []
var initial_positions := PackedVector2Array()
var snapshot_positions := PackedVector2Array()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_validate_proxy_visual_source_contract()
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	var coordinator := (
		MP_ENEMY_COORDINATOR_SCENE.instantiate() as MpEnemyCoordinator
	)
	_expect(runtime != null, "客户端代理压力门禁必须实例化 authored combat runtime。")
	_expect(coordinator != null, "客户端代理压力门禁必须实例化真实 MpEnemyCoordinator。")
	if runtime == null or coordinator == null:
		if runtime != null:
			runtime.free()
		if coordinator != null:
			coordinator.free()
		_finish({})
		return

	# Runtime mode is fixed before entering the tree, so every authored service
	# observes CLIENT_VIEW during _ready and no authority ownership flashes on.
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	root.add_child(runtime)
	current_scene = runtime
	root.add_child(coordinator)
	coordinator.bind_runtime(runtime)
	await process_frame

	var simulation_coordinator := runtime.get_enemy_simulation_coordinator()
	_expect(
		simulation_coordinator != null,
		"CLIENT_VIEW authored runtime 必须保留但闲置 EnemySimulationCoordinator。"
	)
	if simulation_coordinator == null:
		await _dispose_fixture(runtime, coordinator)
		_finish({})
		return

	_build_positions()
	var spawn_started_usec := Time.get_ticks_usec()
	_spawn_proxy_batches(coordinator)
	var spawn_usec := Time.get_ticks_usec() - spawn_started_usec
	_validate_spawned_proxies(runtime, coordinator, simulation_coordinator)

	var simulation_metrics_before := simulation_coordinator.get_metrics()
	for _frame_index in range(3):
		await physics_frame
	var simulation_metrics_after := simulation_coordinator.get_metrics()
	_expect(
		int(simulation_metrics_after.get("registered_count", -1)) == 0
		and int(simulation_metrics_after.get("authoritative_steps", -1))
		== int(simulation_metrics_before.get("authoritative_steps", -2))
		and int(simulation_metrics_after.get("physics_ticks", -1))
		== int(simulation_metrics_before.get("physics_ticks", -2)),
		"CLIENT_VIEW coordinator 不得注册代理、执行 AI 或推进权威 tick。"
	)

	var snapshot_states := _build_snapshot_states()
	var snapshot_started_usec := Time.get_ticks_usec()
	_apply_chunked_snapshot(coordinator, snapshot_states)
	var snapshot_usec := Time.get_ticks_usec() - snapshot_started_usec
	_expect(
		coordinator.enemy_interpolators.size() == PROXY_COUNT,
		"协议 94 的 1,000 实体分块快照必须为每个代理建立插值状态。"
	)
	var snapshot_metrics := coordinator.get_snapshot_metrics()
	_expect(
		int(snapshot_metrics.get(
			"enemy_snapshot_completed_batch_count",
			0
		)) == 1,
		"完整 1,000 实体快照必须只提交一个完成批次。"
	)

	var interpolation_started_usec := Time.get_ticks_usec()
	coordinator.interpolate_remote_enemies(SNAPSHOT_TIMESTAMP + 0.25)
	var interpolation_usec := Time.get_ticks_usec() - interpolation_started_usec
	_validate_snapshot_positions_and_index(runtime)

	# The runtime fixture intentionally authors no camera. A single test observer
	# is added only to exercise the production proxy visual budget; no production
	# combat/service node is synthesized by this script.
	var camera := Camera2D.new()
	camera.name = "ClientProxyStressCamera"
	camera.position_smoothing_enabled = false
	camera.enabled = true
	runtime.add_child(camera)
	camera.global_position = Vector2.ZERO
	await process_frame
	_expect(
		runtime.get_viewport().get_camera_2d() == camera,
		"客户端可见性压力采样必须拥有唯一活动 Camera2D。"
	)
	var active_rect := _get_proxy_visual_active_aabb(runtime, camera)
	_place_visibility_boundary_proxies(runtime, active_rect)
	var visibility_started_usec := Time.get_ticks_usec()
	coordinator.update_proxy_visual_budget(1.0)
	var visibility_usec := Time.get_ticks_usec() - visibility_started_usec
	_validate_visibility_and_aabb(runtime, coordinator, active_rect)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"proxy_count": PROXY_COUNT,
		"snapshot_chunk_count": ceili(
			float(PROXY_COUNT)
			/ float(MpEnemyCoordinator.ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES)
		),
		"offscreen_proxy_count": int(
			coordinator.get_snapshot_metrics().get(
				"offscreen_enemy_proxy_count",
				-1
			)
		),
		# Timings are evidence only. This semantic gate deliberately has no brittle
		# machine-specific absolute-time threshold.
		"timings_usec": {
			"spawn": spawn_usec,
			"snapshot": snapshot_usec,
			"interpolation": interpolation_usec,
			"visibility": visibility_usec,
		},
		"failures": failures.duplicate(),
	}
	await _dispose_fixture(runtime, coordinator)
	_finish(result)


func _build_positions() -> void:
	initial_positions.resize(PROXY_COUNT)
	snapshot_positions.resize(PROXY_COUNT)
	for proxy_index in range(PROXY_COUNT):
		var column := proxy_index % POSITION_COLUMNS
		var row := floori(float(proxy_index) / float(POSITION_COLUMNS))
		var initial_position := Vector2(
			float(column - 20) * POSITION_SPACING,
			float(row - 12) * POSITION_SPACING
		)
		initial_positions[proxy_index] = initial_position
		# 64px placement against the production 96px hash guarantees that one
		# deterministic third of the cohort crosses a bucket boundary.
		snapshot_positions[proxy_index] = initial_position + Vector2(40.0, 24.0)


func _spawn_proxy_batches(coordinator: MpEnemyCoordinator) -> void:
	for batch_start in range(0, PROXY_COUNT, SPAWN_BATCH_SIZE):
		var batch_end := mini(batch_start + SPAWN_BATCH_SIZE, PROXY_COUNT)
		var net_ids := PackedInt32Array()
		var config_paths := PackedStringArray()
		var positions := PackedVector2Array()
		var spawn_times := PackedFloat64Array()
		var faction_ids := PackedByteArray()
		var faction_revisions := PackedInt32Array()
		for proxy_index in range(batch_start, batch_end):
			net_ids.append(NET_ID_BASE + proxy_index)
			config_paths.append(BASIC_CONFIG_PATH)
			positions.append(initial_positions[proxy_index])
			spawn_times.append(1.0)
			faction_ids.append(CombatRelationService.HOSTILE_WAVE)
			faction_revisions.append(0)
		coordinator.receive_enemy_spawn_batch(
			net_ids,
			config_paths,
			positions,
			spawn_times,
			1.0,
			false,
			0.0,
			faction_ids,
			faction_revisions,
			true
		)


func _validate_spawned_proxies(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: MpEnemyCoordinator,
	simulation_coordinator: EnemySimulationCoordinator
) -> void:
	_expect(
		coordinator.get_remote_enemy_count() == PROXY_COUNT
		and runtime.get_network_enemy_count() == PROXY_COUNT
		and runtime.combat_target_index.enemies_by_net_id.size() == PROXY_COUNT,
		"1,000 个客户端代理必须同时收敛到名册、运行时注册表和空间索引。"
	)
	_expect(
		int(simulation_coordinator.get_metrics().get("registered_count", -1)) == 0
		and not simulation_coordinator.is_physics_processing(),
		"CLIENT_VIEW 的 authored simulation coordinator 必须保持零注册并闲置。"
	)
	var previous_net_id := 0
	for proxy_index in range(PROXY_COUNT):
		var net_id := NET_ID_BASE + proxy_index
		var proxy := runtime.get_network_enemy(net_id)
		if proxy == null:
			failures.append("客户端代理 net_id=%d 缺失。" % net_id)
			continue
		_expect(
			net_id > previous_net_id
			and proxy.combat_target_index_net_id == net_id,
			"客户端代理必须保留严格递增且一致的稳定 net_id。"
		)
		previous_net_id = net_id
		_expect(
			proxy.is_multiplayer_proxy
			and not proxy.is_physics_processing()
			and not proxy.is_processing()
			and not proxy.is_centrally_simulated()
			and proxy.simulation_id == 0
			and proxy.scheduled_authoritative_step_count == 0,
			"客户端代理不得拥有逐节点 physics、状态 process 或权威模拟身份。"
		)
		_expect(
			proxy.global_position == initial_positions[proxy_index],
			"出生批次必须无漂移地提交代理初始位置。"
		)


func _build_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	var states: Array[SnapshotManager.EnemyState] = []
	states.resize(PROXY_COUNT)
	for proxy_index in range(PROXY_COUNT):
		var state := SnapshotManager.EnemyState.new()
		state.net_id = NET_ID_BASE + proxy_index
		state.position = snapshot_positions[proxy_index]
		state.velocity = Vector2(12.0, 0.0)
		state.locomotion_state = Enemy.LocomotionState.MOVING
		state.health = PROXY_SNAPSHOT_HEALTH
		state.health_revision = 1
		state.is_dead = false
		state.visual_status_mask = 0
		state.faction_id = CombatRelationService.HOSTILE_WAVE
		state.faction_revision = 0
		states[proxy_index] = state
	return states


func _apply_chunked_snapshot(
	coordinator: MpEnemyCoordinator,
	states: Array[SnapshotManager.EnemyState]
) -> void:
	var sender := SnapshotManager.new()
	var records_per_chunk := (
		MpEnemyCoordinator.ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES
	)
	var chunk_count := ceili(float(states.size()) / float(records_per_chunk))
	for chunk_index in range(chunk_count):
		var chunk_start := chunk_index * records_per_chunk
		var chunk_size := mini(records_per_chunk, states.size() - chunk_start)
		var data := sender.encode_enemy_snapshot_range_for_cohort(
			-77,
			states,
			chunk_start,
			chunk_size,
			true
		)
		coordinator.apply_authoritative_snapshot(
			SNAPSHOT_TIMESTAMP,
			data,
			SNAPSHOT_BATCH_ID,
			chunk_index,
			chunk_count,
			SNAPSHOT_HZ,
			SNAPSHOT_TIMESTAMP
		)


func _validate_snapshot_positions_and_index(
	runtime: EnemyGameplayGatewayTestRuntime
) -> void:
	var moved_count := 0
	for proxy_index in range(PROXY_COUNT):
		var net_id := NET_ID_BASE + proxy_index
		var proxy := runtime.get_network_enemy(net_id)
		if proxy == null:
			continue
		if proxy.global_position == snapshot_positions[proxy_index]:
			moved_count += 1
		_expect(
			proxy.combat_target_index_binding == runtime.combat_target_index
			and proxy.combat_target_index_net_id == net_id
			and runtime.combat_target_index.get_enemy(net_id) == proxy,
			"批量插值移动后每个代理必须保留原空间索引绑定。"
		)
		_expect(
			proxy.scheduled_authoritative_step_count == 0
			and not proxy.is_physics_processing(),
			"快照插值只能更新代理表现，不得激活客户端 AI/physics。"
		)
	_expect(
		moved_count == PROXY_COUNT,
		"1,000 个客户端代理必须全部应用批量位置快照。"
	)
	_expect(
		runtime.combat_target_index.enemies_by_net_id.size() == PROXY_COUNT
		and runtime.combat_target_index.event_bucket_migrations_total > 0,
		"批量位置更新必须迁移跨格成员且不能丢失索引注册。"
	)


func _validate_visibility_and_aabb(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: MpEnemyCoordinator,
	active_rect: Rect2
) -> void:
	var active_visual_count := 0
	var offscreen_visual_count := 0
	for proxy_index in range(PROXY_COUNT):
		var net_id := NET_ID_BASE + proxy_index
		var proxy := runtime.get_network_enemy(net_id)
		if proxy == null:
			continue
		var expected_active := active_rect.has_point(snapshot_positions[proxy_index])
		_expect(
			proxy.multiplayer_proxy_visual_active == expected_active,
			"客户端视觉预算必须与屏幕扩展 AABB 的精确边界规则一致：net_id=%d。"
			% net_id
		)
		if proxy.multiplayer_proxy_visual_active:
			active_visual_count += 1
		else:
			offscreen_visual_count += 1
	var metrics := coordinator.get_snapshot_metrics()
	_expect(
		offscreen_visual_count > 0
		and active_visual_count > 0
		and offscreen_visual_count
		== int(metrics.get("offscreen_enemy_proxy_count", -1))
		and active_visual_count
		== int(metrics.get("proxy_visual_candidate_count", -1))
		and active_visual_count
		== int(metrics.get("proxy_visual_active_count", -1))
		and offscreen_visual_count
		== int(metrics.get("proxy_visual_inactive_count", -1))
		and int(metrics.get("proxy_visual_aabb_query_count", 0)) == 1,
		"客户端视觉预算必须仅提交屏内候选，并保持 AABB 查询与状态统计一致。"
	)
	var left_top_proxy := runtime.get_network_enemy(
		NET_ID_BASE + VISIBILITY_LEFT_TOP_INDEX
	)
	var right_edge_proxy := runtime.get_network_enemy(
		NET_ID_BASE + VISIBILITY_RIGHT_EDGE_INDEX
	)
	var bottom_edge_proxy := runtime.get_network_enemy(
		NET_ID_BASE + VISIBILITY_BOTTOM_EDGE_INDEX
	)
	var inner_edge_proxy := runtime.get_network_enemy(
		NET_ID_BASE + VISIBILITY_INNER_EDGE_INDEX
	)
	_expect(
		left_top_proxy != null
		and right_edge_proxy != null
		and bottom_edge_proxy != null
		and inner_edge_proxy != null
		and left_top_proxy.multiplayer_proxy_visual_active
		and not right_edge_proxy.multiplayer_proxy_visual_active
		and not bottom_edge_proxy.multiplayer_proxy_visual_active
		and inner_edge_proxy.multiplayer_proxy_visual_active,
		"屏幕 AABB 必须包含左/上边界、排除右/下端点，并保留端点内侧候选。"
	)

	var expected_ids: Array[int] = []
	for proxy_index in range(PROXY_COUNT):
		if VISIBILITY_QUERY_AABB.has_point(snapshot_positions[proxy_index]):
			expected_ids.append(NET_ID_BASE + proxy_index)
	var visible_candidates: Array[Node2D] = []
	runtime.get_combat_query_facade().query_world_aabb_into(
		VISIBILITY_QUERY_AABB,
		visible_candidates,
		null,
		0,
		false,
		false,
		true
	)
	var actual_ids: Array[int] = []
	for candidate in visible_candidates:
		var enemy := candidate as Enemy
		if enemy != null:
			actual_ids.append(enemy.combat_target_index_net_id)
	_expect(
		actual_ids == expected_ids,
		"客户端 AABB 可见性候选必须与 1,000 代理的批量位置和稳定 ID 完全一致。"
	)


func _validate_proxy_visual_source_contract() -> void:
	var source := FileAccess.get_file_as_string(MP_ENEMY_COORDINATOR_SOURCE_PATH)
	var function_source := _extract_function_source(
		source,
		"func update_proxy_visual_budget("
	)
	_expect(
		not function_source.is_empty()
		and function_source.find("query_world_aabb_into(") >= 0
		and function_source.find("get_network_enemies(") < 0,
		"客户端代理视觉热路径必须使用空间 AABB 候选，禁止恢复全名册扫描。"
	)


func _get_proxy_visual_active_aabb(
	runtime: EnemyGameplayGatewayTestRuntime,
	camera: Camera2D
) -> Rect2:
	var viewport := runtime.get_viewport()
	var viewport_size := viewport.get_visible_rect().size
	var safe_zoom := Vector2(
		maxf(absf(camera.zoom.x), 0.001),
		maxf(absf(camera.zoom.y), 0.001)
	)
	var visible_world_size := viewport_size / safe_zoom
	var margin := Vector2.ONE * MpEnemyCoordinator.CLIENT_PROXY_VISUAL_BUDGET_MARGIN
	return Rect2(
		camera.get_screen_center_position() - visible_world_size * 0.5 - margin,
		visible_world_size + margin * 2.0
	)


func _place_visibility_boundary_proxies(
	runtime: EnemyGameplayGatewayTestRuntime,
	active_rect: Rect2
) -> void:
	var center := active_rect.get_center()
	var positions := {
		VISIBILITY_LEFT_TOP_INDEX: active_rect.position,
		VISIBILITY_RIGHT_EDGE_INDEX: Vector2(active_rect.end.x, center.y),
		VISIBILITY_BOTTOM_EDGE_INDEX: Vector2(center.x, active_rect.end.y),
		VISIBILITY_INNER_EDGE_INDEX: active_rect.end - Vector2(0.5, 0.5),
	}
	for proxy_index_variant in positions:
		var proxy_index := int(proxy_index_variant)
		var proxy := runtime.get_network_enemy(NET_ID_BASE + proxy_index)
		if proxy == null:
			continue
		var next_position: Vector2 = positions[proxy_index]
		proxy.global_position = next_position
		snapshot_positions[proxy_index] = next_position
		_expect(
			runtime.combat_target_index.get_enemy(
				NET_ID_BASE + proxy_index
			) == proxy,
			"屏幕边界夹具移动后必须保持 CombatTargetIndex 注册：index=%d。"
			% proxy_index
		)


func _extract_function_source(source: String, signature: String) -> String:
	var start := source.find(signature)
	if start < 0:
		return ""
	var finish := source.find("\n\nfunc ", start + signature.length())
	return source.substr(start) if finish < 0 else source.substr(start, finish - start)


func _dispose_fixture(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: MpEnemyCoordinator
) -> void:
	if coordinator != null and is_instance_valid(coordinator):
		coordinator.reset_session_state()
	await process_frame
	if runtime != null and is_instance_valid(runtime):
		_expect(
			coordinator.get_remote_enemy_count() == 0
			and runtime.get_network_enemy_count() == 0
			and runtime.combat_target_index.enemies_by_net_id.is_empty(),
			"客户端代理清理后协调器、运行时名册与 CombatTargetIndex 必须归零。"
		)
		var simulation_coordinator := runtime.get_enemy_simulation_coordinator()
		if simulation_coordinator != null:
			_expect(
				int(simulation_coordinator.get_metrics().get(
					"registered_count",
					-1
				)) == 0,
				"客户端代理清理后 authored coordinator 必须仍为零注册。"
			)
	if coordinator != null and is_instance_valid(coordinator):
		coordinator.unbind_runtime(runtime)
		coordinator.queue_free()
	if runtime != null and is_instance_valid(runtime):
		if current_scene == runtime:
			current_scene = null
		runtime.queue_free()
	await process_frame
	await physics_frame


func _finish(result: Dictionary) -> void:
	var output := result.duplicate(true)
	output["status"] = "ok" if failures.is_empty() else "failed"
	output["failures"] = failures.duplicate()
	print("ENEMY_CLIENT_PROXY_STRESS_JSON %s" % JSON.stringify(output))
	if failures.is_empty():
		print("ENEMY_CLIENT_PROXY_STRESS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
