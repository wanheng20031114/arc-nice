extends SceneTree

const SAMPLE_COUNT := 9
# 512 replicated boundary events already exceeds a practical single-frame burst;
# the probe measures adapter overhead without turning dispatch into a synthetic
# throughput benchmark unrelated to the runtime traffic shape.
const EVENTS_PER_SAMPLE := 512
const FIXED_SEED := 0x4D504144


class TraceRecorder:
	extends RefCounted

	var events: Array[int] = []

	func clear() -> void:
		events.clear()

	func append_event(code: int, values: Array[int]) -> void:
		events.append(code)
		events.append_array(values)


class RosterProbe:
	extends TowerDefensePlayerRosterCoordinator

	var probe_death_counts: Dictionary[int, int] = {}

	func reset_probe() -> void:
		probe_death_counts.clear()

	func consume_next_respawn_delay(peer_id: int) -> float:
		var death_count := int(probe_death_counts.get(peer_id, 0))
		probe_death_counts[peer_id] = death_count + 1
		return float([5, 10, 15, 20][mini(death_count, 3)])

	func get_fixed_respawn_position(peer_id: int) -> Variant:
		return Vector2(float(peer_id * 17), float(peer_id * -9))


class ExtractedAdapterProbe:
	extends TowerDefenseMultiplayerModeAdapter

	var probe_merchant_active := false

	func reset_probe() -> void:
		probe_merchant_active = false

	func _set_local_merchants_active(active: bool) -> bool:
		var changed := probe_merchant_active != active
		probe_merchant_active = active
		return changed


class LegacyTowerBridgeProbe:
	extends Node

	signal source_base_health_changed(
		current_health: int,
		maximum_health: int,
		revision: int
	)
	signal source_wave_progress_changed(
		wave_number: int,
		defeated: int,
		escaped: int,
		resolved: int,
		total: int
	)
	signal source_plant_health_changed(
		net_id: int,
		current_health: int,
		maximum_health: int,
		revision: int
	)
	signal flow_state_changed(step_id: StringName, state: int, seconds: int)
	signal base_health_changed(
		current_health: int,
		maximum_health: int,
		revision: int
	)
	signal wave_progress_changed(
		wave_number: int,
		defeated: int,
		escaped: int,
		resolved: int,
		total: int
	)
	signal inventory_changed(peer_id: int)
	signal merchant_active_changed(active: bool)
	signal plant_health_changed(
		net_id: int,
		current_health: int,
		maximum_health: int,
		revision: int
	)

	var runtime_mode := CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var countdown_seconds := 0
	var merchant_active := false
	var roster: RosterProbe = null

	func bind_sources(configured_roster: RosterProbe) -> void:
		roster = configured_roster
		source_base_health_changed.connect(_on_base_health_changed)
		source_wave_progress_changed.connect(_on_wave_progress_changed)
		source_plant_health_changed.connect(plant_health_changed.emit)

	func reset_probe() -> void:
		merchant_active = false
		roster.reset_probe()

	func publish_flow_state(state: CombatFlowState.State) -> void:
		if runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
			flow_state_changed.emit(&"", int(state), countdown_seconds)

	func publish_inventory_changed(peer_id: int) -> void:
		if (
			runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
			and peer_id > 0
		):
			inventory_changed.emit(peer_id)

	func set_merchant_active(active: bool) -> void:
		var changed := merchant_active != active
		merchant_active = active
		if (
			changed
			and runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		):
			merchant_active_changed.emit(active)

	func consume_next_player_respawn_delay(peer_id: int) -> float:
		return roster.consume_next_respawn_delay(peer_id)

	func get_fixed_multiplayer_respawn_position(peer_id: int) -> Variant:
		return roster.get_fixed_respawn_position(peer_id)

	func _on_base_health_changed(
		current_health: int,
		maximum_health: int,
		revision: int
	) -> void:
		if runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
			base_health_changed.emit(current_health, maximum_health, revision)

	func _on_wave_progress_changed(
		wave_number: int,
		defeated: int,
		escaped: int,
		resolved: int,
		total: int
	) -> void:
		if runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
			wave_progress_changed.emit(
				wave_number,
				defeated,
				escaped,
				resolved,
				total
			)


var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var legacy_fixture := _create_legacy_fixture()
	var extracted_fixture := _create_extracted_fixture()
	var legacy_strict := _run_legacy_trace(legacy_fixture, FIXED_SEED)
	var extracted_strict := _run_extracted_trace(extracted_fixture, FIXED_SEED)
	_expect(
		legacy_strict == extracted_strict,
		"塔防 Adapter 固定 seed 边界轨迹必须严格一致：legacy=%d extracted=%d。"
		% [legacy_strict, extracted_strict]
	)
	_warm_up(legacy_fixture, extracted_fixture, true)
	_warm_up(legacy_fixture, extracted_fixture, false)

	var legacy_time_samples: Array[int] = []
	var extracted_time_samples: Array[int] = []
	var legacy_memory_samples: Array[int] = []
	var extracted_memory_samples: Array[int] = []
	var legacy_hash := 0
	var extracted_hash := 0
	for sample_index in range(SAMPLE_COUNT):
		if sample_index % 2 == 0:
			legacy_hash ^= _measure_legacy(
				legacy_fixture,
				legacy_time_samples,
				legacy_memory_samples
			)
			extracted_hash ^= _measure_extracted(
				extracted_fixture,
				extracted_time_samples,
				extracted_memory_samples
			)
		else:
			extracted_hash ^= _measure_extracted(
				extracted_fixture,
				extracted_time_samples,
				extracted_memory_samples
			)
			legacy_hash ^= _measure_legacy(
				legacy_fixture,
				legacy_time_samples,
				legacy_memory_samples
			)

	legacy_time_samples.sort()
	extracted_time_samples.sort()
	legacy_memory_samples.sort()
	extracted_memory_samples.sort()
	var p50_index := _nearest_rank_index(0.50)
	var p95_index := _nearest_rank_index(0.95)
	var legacy_p50 := legacy_time_samples[p50_index]
	var extracted_p50 := extracted_time_samples[p50_index]
	var legacy_p95 := legacy_time_samples[p95_index]
	var extracted_p95 := extracted_time_samples[p95_index]
	var legacy_memory_p50 := legacy_memory_samples[p50_index]
	var extracted_memory_p50 := extracted_memory_samples[p50_index]
	var legacy_memory_p95 := legacy_memory_samples[p95_index]
	var extracted_memory_p95 := extracted_memory_samples[p95_index]
	var p50_limit := legacy_p50 + maxi(ceili(legacy_p50 * 0.05), 200)
	var p95_limit := legacy_p95 + maxi(ceili(legacy_p95 * 0.05), 200)
	var memory_p50_limit := legacy_memory_p50 + maxi(
		ceili(legacy_memory_p50 * 0.05),
		16 * 1024 * 1024
	)
	var memory_p95_limit := legacy_memory_p95 + maxi(
		ceili(legacy_memory_p95 * 0.05),
		16 * 1024 * 1024
	)

	_expect(
		legacy_hash == extracted_hash,
		"塔防 Adapter A/B 轨迹哈希必须严格一致：legacy=%d extracted=%d。"
		% [legacy_hash, extracted_hash]
	)
	_expect(
		extracted_p50 <= p50_limit,
		"extracted p50 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_p50, extracted_p50, p50_limit]
	)
	_expect(
		extracted_p95 <= p95_limit,
		"extracted p95 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_p95, extracted_p95, p95_limit]
	)
	_expect(
		extracted_memory_p50 <= memory_p50_limit,
		"extracted memory p50 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_memory_p50, extracted_memory_p50, memory_p50_limit]
	)
	_expect(
		extracted_memory_p95 <= memory_p95_limit,
		"extracted memory p95 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_memory_p95, extracted_memory_p95, memory_p95_limit]
	)

	_cleanup_legacy_fixture(legacy_fixture)
	_cleanup_extracted_fixture(extracted_fixture)
	if failures.is_empty():
		print(
			"TOWER_DEFENSE_MULTIPLAYER_MODE_ADAPTER_AB_PROBE_OK legacy_p50_usec=%d extracted_p50_usec=%d legacy_p95_usec=%d extracted_p95_usec=%d p50_limit_usec=%d p95_limit_usec=%d legacy_memory_p50_bytes=%d extracted_memory_p50_bytes=%d legacy_memory_p95_bytes=%d extracted_memory_p95_bytes=%d memory_p50_limit_bytes=%d memory_p95_limit_bytes=%d trajectory_hash=%d seed=%d samples=%d events_per_sample=%d scope=micro_boundary"
			% [
				legacy_p50,
				extracted_p50,
				legacy_p95,
				extracted_p95,
				p50_limit,
				p95_limit,
				legacy_memory_p50,
				extracted_memory_p50,
				legacy_memory_p95,
				extracted_memory_p95,
				memory_p50_limit,
				memory_p95_limit,
				legacy_hash,
				FIXED_SEED,
				SAMPLE_COUNT,
				EVENTS_PER_SAMPLE,
			]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _create_legacy_fixture() -> Dictionary:
	var bridge := LegacyTowerBridgeProbe.new()
	var roster := RosterProbe.new()
	var recorder := TraceRecorder.new()
	bridge.bind_sources(roster)
	_connect_recorder(bridge, recorder)
	return {
		"bridge": bridge,
		"roster": roster,
		"recorder": recorder,
	}


func _create_extracted_fixture() -> Dictionary:
	var runtime := TowerDefenseGame.new()
	var adapter := ExtractedAdapterProbe.new()
	var campaign := TowerDefenseCampaignCoordinator.new()
	var enemy := TowerDefenseEnemyCoordinator.new()
	var home := TowerDefenseHomeDefenseCoordinator.new()
	var plant := TowerDefensePlantRuntimeCoordinator.new()
	var roster := RosterProbe.new()
	var boss := TowerDefenseBossCoordinator.new()
	var fate := FateCoordinator.new()
	var fate_flow := TowerDefenseFateFlowCoordinator.new()
	var fate_manager := TowerDefenseFateManager.new()
	var presentation := TowerDefensePresentationCoordinator.new()
	var profile_panel := TowerDefensePlayerProfilePanel.new()
	var debug_window := DebugCollectibleWindow.new()
	var merchant := ZhuangfangyiMerchant.new()
	var luoxi_merchant := TowerDefenseLuoxiMerchant.new()
	var luoxi_game := LuoxiSpecialGameCoordinator.new()
	var run_state := RunStateStore.new()
	var research := ResearchCoordinator.new()
	var placement := TowerDefensePlantPlacementCoordinator.new()
	var state_timer := Timer.new()
	adapter.bind_tower_dependencies(
		runtime,
		campaign,
		enemy,
		home,
		plant,
		roster,
		boss,
		fate,
		fate_flow,
		fate_manager,
		presentation,
		profile_panel,
		debug_window,
		merchant,
		luoxi_merchant,
		luoxi_game,
		run_state,
		research,
		placement,
		state_timer
	)
	var recorder := TraceRecorder.new()
	_connect_recorder(adapter, recorder)
	return {
		"runtime": runtime,
		"adapter": adapter,
		"campaign": campaign,
		"enemy": enemy,
		"home": home,
		"plant": plant,
		"roster": roster,
		"boss": boss,
		"fate": fate,
		"fate_flow": fate_flow,
		"fate_manager": fate_manager,
		"presentation": presentation,
		"profile_panel": profile_panel,
		"debug_window": debug_window,
		"merchant": merchant,
		"luoxi_merchant": luoxi_merchant,
		"luoxi_game": luoxi_game,
		"run_state": run_state,
		"research": research,
		"placement": placement,
		"state_timer": state_timer,
		"recorder": recorder,
	}


func _connect_recorder(source: Node, recorder: TraceRecorder) -> void:
	source.connect(&"flow_state_changed",
		func(_step_id: StringName, state: int, seconds: int) -> void:
			recorder.append_event(100, [state, seconds])
	)
	source.connect(&"base_health_changed",
		func(current_health: int, maximum_health: int, revision: int) -> void:
			recorder.append_event(
				200, [current_health, maximum_health, revision]
			)
	)
	source.connect(&"wave_progress_changed",
		func(
			wave_number: int,
			defeated: int,
			escaped: int,
			resolved: int,
			total: int
		) -> void:
			recorder.append_event(
				300, [wave_number, defeated, escaped, resolved, total]
			)
	)
	source.connect(&"inventory_changed",
		func(peer_id: int) -> void: recorder.append_event(400, [peer_id])
	)
	source.connect(&"merchant_active_changed",
		func(active: bool) -> void:
			recorder.append_event(500, [int(active)])
	)
	source.connect(&"plant_health_changed",
		func(
			net_id: int,
			current_health: int,
			maximum_health: int,
			revision: int
		) -> void:
			recorder.append_event(
				600, [net_id, current_health, maximum_health, revision]
			)
	)


func _run_legacy_trace(fixture: Dictionary, seed: int) -> int:
	var bridge := fixture["bridge"] as LegacyTowerBridgeProbe
	var recorder := fixture["recorder"] as TraceRecorder
	bridge.reset_probe()
	recorder.clear()
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = seed
	for event_index in range(EVENTS_PER_SAMPLE):
		var event_kind := random_generator.randi_range(0, 7)
		var mode := (
			CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
			if random_generator.randi_range(0, 1) == 0
			else CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		)
		bridge.runtime_mode = mode
		_dispatch_legacy_event(bridge, recorder, random_generator, event_index, event_kind)
	return hash(recorder.events)


func _run_extracted_trace(fixture: Dictionary, seed: int) -> int:
	var runtime := fixture["runtime"] as TowerDefenseGame
	var adapter := fixture["adapter"] as ExtractedAdapterProbe
	var home := fixture["home"] as TowerDefenseHomeDefenseCoordinator
	var enemy := fixture["enemy"] as TowerDefenseEnemyCoordinator
	var plant := fixture["plant"] as TowerDefensePlantRuntimeCoordinator
	var roster := fixture["roster"] as RosterProbe
	var recorder := fixture["recorder"] as TraceRecorder
	adapter.reset_probe()
	roster.reset_probe()
	recorder.clear()
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = seed
	for event_index in range(EVENTS_PER_SAMPLE):
		var event_kind := random_generator.randi_range(0, 7)
		var mode := (
			CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
			if random_generator.randi_range(0, 1) == 0
			else CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		)
		runtime.runtime_mode = mode
		_dispatch_extracted_event(
			runtime,
			adapter,
			home,
			enemy,
			plant,
			recorder,
			random_generator,
			event_index,
			event_kind
		)
	return hash(recorder.events)


func _dispatch_legacy_event(
	bridge: LegacyTowerBridgeProbe,
	recorder: TraceRecorder,
	random_generator: RandomNumberGenerator,
	event_index: int,
	event_kind: int
) -> void:
	match event_kind:
		0:
			bridge.countdown_seconds = random_generator.randi_range(0, 90)
			bridge.publish_flow_state(
				random_generator.randi_range(
					CombatFlowState.State.PRE_WAVE,
					CombatFlowState.State.BOSS_ACTIVE
				) as CombatFlowState.State
			)
		1:
			bridge.source_base_health_changed.emit(
				random_generator.randi_range(0, 100),
				100,
				event_index + 1
			)
		2:
			var total := random_generator.randi_range(1, 30)
			var defeated := random_generator.randi_range(0, total)
			var escaped := random_generator.randi_range(0, total - defeated)
			bridge.source_wave_progress_changed.emit(
				random_generator.randi_range(1, 12),
				defeated,
				escaped,
				defeated + escaped,
				total
			)
		3:
			bridge.publish_inventory_changed(
				random_generator.randi_range(0, 8)
			)
		4:
			bridge.set_merchant_active(random_generator.randi_range(0, 1) == 1)
		5:
			bridge.source_plant_health_changed.emit(
				random_generator.randi_range(1, 256),
				random_generator.randi_range(0, 80),
				80,
				event_index + 1
			)
		6:
			var peer_id := random_generator.randi_range(1, 8)
			recorder.append_event(700, [
				peer_id,
				roundi(bridge.consume_next_player_respawn_delay(peer_id)),
			])
		7:
			var peer_id := random_generator.randi_range(1, 8)
			var position := (
				bridge.get_fixed_multiplayer_respawn_position(peer_id) as Vector2
			)
			recorder.append_event(800, [
				peer_id,
				roundi(position.x),
				roundi(position.y),
			])


func _dispatch_extracted_event(
	runtime: TowerDefenseGame,
	adapter: ExtractedAdapterProbe,
	home: TowerDefenseHomeDefenseCoordinator,
	enemy: TowerDefenseEnemyCoordinator,
	plant: TowerDefensePlantRuntimeCoordinator,
	recorder: TraceRecorder,
	random_generator: RandomNumberGenerator,
	event_index: int,
	event_kind: int
) -> void:
	match event_kind:
		0:
			runtime.countdown_seconds = random_generator.randi_range(0, 90)
			adapter.publish_flow_state(
				random_generator.randi_range(
					CombatFlowState.State.PRE_WAVE,
					CombatFlowState.State.BOSS_ACTIVE
				) as CombatFlowState.State
			)
		1:
			home.base_health_changed.emit(
				random_generator.randi_range(0, 100),
				100,
				event_index + 1
			)
		2:
			var total := random_generator.randi_range(1, 30)
			var defeated := random_generator.randi_range(0, total)
			var escaped := random_generator.randi_range(0, total - defeated)
			enemy.wave_progress_changed.emit(
				random_generator.randi_range(1, 12),
				defeated,
				escaped,
				defeated + escaped,
				total
			)
		3:
			adapter.publish_inventory_changed(
				random_generator.randi_range(0, 8)
			)
		4:
			adapter.set_merchant_active(random_generator.randi_range(0, 1) == 1)
		5:
			plant.plant_health_changed.emit(
				random_generator.randi_range(1, 256),
				random_generator.randi_range(0, 80),
				80,
				event_index + 1
			)
		6:
			var peer_id := random_generator.randi_range(1, 8)
			recorder.append_event(700, [
				peer_id,
				roundi(adapter.consume_next_player_respawn_delay(peer_id)),
			])
		7:
			var peer_id := random_generator.randi_range(1, 8)
			var position := (
				adapter.get_fixed_multiplayer_respawn_position(peer_id) as Vector2
			)
			recorder.append_event(800, [
				peer_id,
				roundi(position.x),
				roundi(position.y),
			])


func _measure_legacy(
	fixture: Dictionary,
	time_samples: Array[int],
	memory_samples: Array[int]
) -> int:
	var started_at := Time.get_ticks_usec()
	var result := _run_legacy_trace(fixture, FIXED_SEED)
	time_samples.append(Time.get_ticks_usec() - started_at)
	memory_samples.append(int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	return result


func _measure_extracted(
	fixture: Dictionary,
	time_samples: Array[int],
	memory_samples: Array[int]
) -> int:
	var started_at := Time.get_ticks_usec()
	var result := _run_extracted_trace(fixture, FIXED_SEED)
	time_samples.append(Time.get_ticks_usec() - started_at)
	memory_samples.append(int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	return result


func _warm_up(
	legacy_fixture: Dictionary,
	extracted_fixture: Dictionary,
	use_legacy: bool
) -> void:
	if use_legacy:
		_run_legacy_trace(legacy_fixture, FIXED_SEED)
	else:
		_run_extracted_trace(extracted_fixture, FIXED_SEED)


func _cleanup_legacy_fixture(fixture: Dictionary) -> void:
	(fixture["bridge"] as LegacyTowerBridgeProbe).free()
	(fixture["roster"] as RosterProbe).free()


func _cleanup_extracted_fixture(fixture: Dictionary) -> void:
	for key in [
		"adapter",
		"campaign",
		"enemy",
		"home",
		"plant",
		"roster",
		"boss",
		"fate",
		"fate_flow",
		"fate_manager",
		"presentation",
		"profile_panel",
		"debug_window",
		"merchant",
		"luoxi_merchant",
		"luoxi_game",
		"run_state",
		"research",
		"placement",
		"state_timer",
		"runtime",
	]:
		var node := fixture[key] as Node
		if node != null and is_instance_valid(node):
			node.free()


func _nearest_rank_index(percentile: float) -> int:
	return clampi(ceili(SAMPLE_COUNT * percentile) - 1, 0, SAMPLE_COUNT - 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
