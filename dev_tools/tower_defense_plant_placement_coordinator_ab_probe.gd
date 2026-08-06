extends SceneTree

const FIXED_SEED := 0x62A19D37
const TRACE_LENGTH := 4096

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = FIXED_SEED
	var legacy_trace: Array = []
	var extracted_trace: Array = []
	for event_index in range(TRACE_LENGTH):
		var has_player := random_generator.randi_range(0, 1) == 1
		var player_dead := random_generator.randi_range(0, 1) == 1
		var flow_state := random_generator.randi_range(
			CombatFlowState.State.PRE_WAVE,
			CombatFlowState.State.FATE_INTERLUDE
		) as CombatFlowState.State
		var modal_open := random_generator.randi_range(0, 1) == 1
		var runtime_mode := random_generator.randi_range(
			CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
			CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		)
		var local_peer_id := random_generator.randi_range(-2, 32)
		legacy_trace.append([
			event_index,
			_legacy_input_enabled(
				has_player,
				player_dead,
				flow_state,
				modal_open
			),
			_legacy_inventory_peer_id(runtime_mode, local_peer_id),
		])
		extracted_trace.append([
			event_index,
			TowerDefensePlantPlacementCoordinator.evaluate_placement_input_enabled(
				has_player,
				player_dead,
				flow_state,
				modal_open
			),
			TowerDefensePlantPlacementCoordinator.resolve_inventory_peer_id(
				runtime_mode,
				local_peer_id
			),
		])
	_expect(
		legacy_trace == extracted_trace,
		"PlantPlacement 输入锁与背包 peer 选择轨迹必须严格一致。"
	)
	_expect(
		hash(legacy_trace) == hash(extracted_trace),
		"PlantPlacement 固定 seed A/B 哈希必须严格一致。"
	)
	if failures.is_empty():
		print(
			"TOWER_DEFENSE_PLANT_PLACEMENT_COORDINATOR_AB_PROBE_OK "
			+ "events=%d trajectory_hash=%d"
			% [TRACE_LENGTH, hash(extracted_trace)]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _legacy_input_enabled(
	has_player: bool,
	player_dead: bool,
	flow_state: CombatFlowState.State,
	modal_open: bool
) -> bool:
	return (
		has_player
		and not player_dead
		and flow_state not in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
			CombatFlowState.State.FATE_INTERLUDE,
		]
		and not modal_open
	)


func _legacy_inventory_peer_id(runtime_mode: int, local_peer_id: int) -> int:
	return (
		maxi(local_peer_id, 0)
		if runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else 0
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
