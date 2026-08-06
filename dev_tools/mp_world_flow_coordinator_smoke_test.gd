extends SceneTree

const WORLD_FLOW_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.tscn"
)
const MpWorldFlowCoordinatorScript := preload(
	"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.gd"
)
const BOSS_CONFIG_PATH := "res://resources/config/bosses/boss_01_linglan.tres"
const PICKUP_CONFIG_PATH := "res://resources/config/materials/material_wood.tres"


class ProbeRuntime:
	extends CombatRuntimeBase

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(net_id: int) -> Enemy:
		return multiplayer_enemies_by_net_id.get(net_id) as Enemy

	func get_pickup_for_net_id(net_id: int) -> Pickup:
		return multiplayer_pickups.get(net_id) as Pickup

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class ProbeEnemyCoordinator:
	extends MpEnemyCoordinator

	var remote_count := 0

	func get_remote_enemy_count() -> int:
		return remote_count


class ProbeModeAdapter:
	extends MultiplayerModeAdapter

	var wave_start_peer_id := 0
	var merchant_state := false
	var flow_state: Dictionary = {}
	var boss_net_id := 0
	var defeat_reason := ""
	var defeat_apply_count := 0
	var victory_apply_count := 0
	var enemy_count_apply_count := 0
	var last_enemy_count := -1
	var wave_apply_count := 0
	var last_wave_progress: Dictionary = {}
	var wave_snapshot := {
		"wave_number": 3,
		"defeated": 4,
		"escaped": 1,
		"resolved": 5,
		"total": 9,
	}

	func supports_multiplayer_wave_progress() -> bool:
		return true

	func request_authoritative_wave_start(requester_peer_id: int) -> bool:
		wave_start_peer_id = requester_peer_id
		return true

	func get_wave_progress_snapshot() -> Dictionary:
		return wave_snapshot.duplicate()

	func get_flow_state_snapshot() -> Dictionary:
		return {
			"step_id": &"wave_active",
			"state": 2,
			"countdown_seconds": 0,
		}

	func get_multiplayer_defeat_reason() -> String:
		return "base_destroyed"

	func apply_remote_merchant_active(active: bool) -> void:
		merchant_state = active

	func apply_remote_flow_state(
		step_id: StringName,
		state: int,
		seconds: int
	) -> void:
		flow_state = {
			"step_id": step_id,
			"state": state,
			"countdown_seconds": seconds,
		}

	func apply_remote_boss_started(
		net_id: int,
		_boss_config: BossConfig,
		_spawn_position: Vector2
	) -> void:
		boss_net_id = net_id

	func apply_remote_defeat_with_reason(reason: String) -> void:
		defeat_reason = reason
		defeat_apply_count += 1

	func apply_remote_victory() -> void:
		victory_apply_count += 1

	func apply_remote_enemy_count(alive_count: int) -> void:
		last_enemy_count = alive_count
		enemy_count_apply_count += 1

	func apply_remote_wave_progress(
		wave_number: int,
		defeated: int,
		escaped: int,
		resolved: int,
		total: int
	) -> void:
		last_wave_progress = {
			"wave_number": wave_number,
			"defeated": defeated,
			"escaped": escaped,
			"resolved": resolved,
			"total": total,
		}
		wave_apply_count += 1


var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var coordinator: MpWorldFlowCoordinatorScript = (
		WORLD_FLOW_COORDINATOR_SCENE.instantiate()
	)
	var runtime := ProbeRuntime.new()
	var mode_adapter := ProbeModeAdapter.new()
	var enemy_coordinator := ProbeEnemyCoordinator.new()
	var gameplay_gateway := MultiplayerGameplayGateway.new()
	_expect(coordinator != null, "WorldFlowCoordinator 场景必须可实例化。")
	if coordinator == null:
		quit(1)
		return

	var host_events: Array[StringName] = []
	var progress_packets: Array[Dictionary] = []
	var terminal_events: Array[bool] = []
	coordinator.pickup_spawn_broadcast_requested.connect(
		func(_net_id: int, _path: String, _position: Vector2) -> void:
			host_events.append(&"pickup_spawn")
	)
	coordinator.pickup_remove_broadcast_requested.connect(
		func(_net_id: int) -> void:
			host_events.append(&"pickup_remove")
	)
	coordinator.merchant_active_broadcast_requested.connect(
		func(_active: bool) -> void:
			host_events.append(&"merchant")
	)
	coordinator.wave_progress_broadcast_requested.connect(
		func(progress: Dictionary, reliable: bool) -> void:
			progress_packets.append({
				"progress": progress.duplicate(),
				"reliable": reliable,
			})
			host_events.append(&"wave_keyframe" if reliable else &"wave_delta")
	)
	coordinator.flow_state_broadcast_requested.connect(
		func(_step_id: StringName, _state: int, _seconds: int) -> void:
			host_events.append(&"flow")
	)
	coordinator.boss_started_broadcast_requested.connect(
		func(_net_id: int, _path: String, _position: Vector2) -> void:
			host_events.append(&"boss")
	)
	coordinator.defeat_broadcast_requested.connect(
		func(_reason: String) -> void:
			host_events.append(&"defeat")
	)
	coordinator.victory_broadcast_requested.connect(
		func() -> void:
			host_events.append(&"victory")
	)
	coordinator.terminal_flow_started.connect(
		func() -> void:
			terminal_events.append(true)
	)

	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	coordinator.bind_runtime(
		runtime,
		mode_adapter,
		enemy_coordinator,
		gameplay_gateway
	)
	_expect(coordinator.is_bound(), "协调器必须绑定四个强类型运行时依赖。")
	_expect(
		coordinator.request_authoritative_wave_start(7)
		and mode_adapter.wave_start_peer_id == 7,
		"Host 开波请求必须只经模式适配器提交。"
	)
	mode_adapter.wave_progress_changed.emit(2, 1, 0, 1, 8)
	_expect(
		coordinator.update_host(0.1)
		and progress_packets.size() == 1
		and not bool(progress_packets[0].get("reliable", true)),
		"波次进度必须继续按 0.1 秒窗口合并为不可靠包。"
	)
	mode_adapter.wave_progress_changed.emit(2, 2, 0, 2, 8)
	mode_adapter.flow_state_changed.emit(&"wave_active", 2, 0)
	_expect(
		host_events.slice(host_events.size() - 3) == [
			&"wave_delta",
			&"wave_keyframe",
			&"flow",
		],
		"流转前必须依次刷新波次增量、可靠关键帧，再发送流状态。"
	)

	var pickup_config := load(PICKUP_CONFIG_PATH) as PickupConfig
	var boss_config := load(BOSS_CONFIG_PATH) as BossConfig
	_expect(pickup_config != null and boss_config != null, "smoke 配置必须可加载。")
	if pickup_config != null:
		gameplay_gateway.pickup_spawned.emit(31, pickup_config, Vector2(4, 5))
		gameplay_gateway.pickup_removed.emit(31)
	mode_adapter.merchant_active_changed.emit(true)
	if boss_config != null:
		mode_adapter.boss_started.emit(91, boss_config, Vector2(8, 9))
	mode_adapter.defeat_started.emit()
	mode_adapter.victory_started.emit()
	_expect(
		host_events.slice(host_events.size() - 6) == [
			&"pickup_spawn",
			&"pickup_remove",
			&"merchant",
			&"boss",
			&"defeat",
			&"victory",
		]
		and terminal_events.size() == 2,
		"Host 世界事件、Boss 与胜败必须保持统一有序出站。"
	)

	coordinator.unbind_runtime(runtime)
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	coordinator.bind_runtime(
		runtime,
		mode_adapter,
		enemy_coordinator,
		gameplay_gateway
	)
	coordinator.receive_merchant_active(true)
	coordinator.receive_flow_state(&"wave_active", 2, 3)
	enemy_coordinator.remote_count = 12
	var first_enemy_apply: bool = coordinator.update_client_enemy_count()
	var duplicate_enemy_apply: bool = coordinator.update_client_enemy_count()
	coordinator.receive_flow_state(&"wave_active", 2, 2)
	var invalidated_enemy_apply: bool = coordinator.update_client_enemy_count()
	coordinator.receive_wave_progress(4, 6, 1, 7, 10)
	coordinator.receive_boss_started(99, BOSS_CONFIG_PATH, Vector2.ZERO, 4.0)
	coordinator.receive_defeat("timeout")
	coordinator.receive_victory()
	_expect(
		mode_adapter.merchant_state
		and StringName(mode_adapter.flow_state.get("step_id", &"")) == &"wave_active"
		and first_enemy_apply
		and not duplicate_enemy_apply
		and invalidated_enemy_apply
		and mode_adapter.enemy_count_apply_count == 2
		and mode_adapter.last_enemy_count == 12,
		"客户端敌人数只应在变化或流转失效后重绘。"
	)
	_expect(
		mode_adapter.wave_apply_count == 1
		and mode_adapter.last_wave_progress == {
			"wave_number": 4,
			"defeated": 6,
			"escaped": 1,
			"resolved": 7,
			"total": 10,
		}
		and mode_adapter.boss_net_id == 99
		and mode_adapter.defeat_reason == "timeout"
		and mode_adapter.defeat_apply_count == 1
		and mode_adapter.victory_apply_count == 1,
		"客户端流转、Boss 与胜败必须只经模式适配器应用。"
	)

	coordinator.unbind_runtime(runtime)
	var metrics: Dictionary = coordinator.get_state_metrics()
	_expect(
		not coordinator.is_bound()
		and int(metrics.get("pending_wave_progress", -1)) == 0
		and not bool(metrics.get("client_has_received_flow_state", true))
		and int(metrics.get("last_applied_remote_enemy_count", 0)) == -1,
		"解绑必须清空所有会话态。"
	)

	coordinator.free()
	gameplay_gateway.free()
	enemy_coordinator.free()
	mode_adapter.free()
	runtime.free()
	if failures.is_empty():
		print("MP_WORLD_FLOW_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
