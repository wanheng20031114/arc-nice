extends SceneTree

const PROJECTILE_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.tscn"
)
const MpProjectileCoordinatorScript := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)


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

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(
		_spawn_global_position: Vector2
	) -> void:
		pass


class ProbeProjectile:
	extends Node2D

	signal projectile_finished(projectile_id: int, projectile: Node)

	var projectile_id := 0
	var owner_peer_id := 0
	var projectile_type: StringName = &""
	var retired := false

	func setup_multiplayer(
		new_projectile_id: int,
		new_owner_peer_id: int,
		new_projectile_type: StringName
	) -> void:
		projectile_id = new_projectile_id
		owner_peer_id = new_owner_peer_id
		projectile_type = new_projectile_type

	func retire() -> void:
		retired = true


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := (
		PROJECTILE_COORDINATOR_SCENE.instantiate() as MpProjectileCoordinatorScript
	)
	var runtime := ProbeRuntime.new()
	_expect(coordinator != null, "ProjectileCoordinator 场景必须可实例化。")
	if coordinator == null:
		quit(1)
		return
	coordinator.bind_runtime(runtime)
	_expect(coordinator.is_bound(), "弹体协调器必须强类型绑定战斗运行时。")

	var encoded_host_id := MpProjectileCoordinatorScript.encode_projectile_id(
		7,
		MpProjectileCoordinatorScript.PROJECTILE_ID_HOST_ORIGIN_BIT | 19
	)
	_expect(
		MpProjectileCoordinatorScript.decode_projectile_owner_peer_id(encoded_host_id) == 7
		and MpProjectileCoordinatorScript.decode_projectile_sequence_counter(
			encoded_host_id
		) == 19
		and MpProjectileCoordinatorScript.is_projectile_id_valid_for_host_owner(
			encoded_host_id,
			7
		),
		"弹体 ID 必须稳定编码 owner、序号与 Host 来源位。"
	)

	var finished_projectile := ProbeProjectile.new()
	var finished_id := coordinator.register_local_projectile(
		finished_projectile,
		&"player_bullet",
		2,
		37,
		1.5,
		false,
		true,
		100.0
	)
	_expect(
		finished_id > 0
		and coordinator.get_projectile(finished_id) == finished_projectile
		and coordinator.has_projectile_record(finished_id),
		"本地弹体必须同时登记实例与权威命中记录。"
	)
	var admission := coordinator.prepare_enemy_hit(
		finished_id,
		2,
		41,
		999,
		100.1
	)
	_expect(
		admission != null
		and admission.authoritative_damage == 37
		and admission.consumes_first_confirmed_hit,
		"非穿透玩家弹体必须使用权威伤害且只准入首次命中。"
	)
	if admission != null:
		coordinator.commit_enemy_hit(
			finished_id,
			41,
			admission.consumes_first_confirmed_hit,
			100.1
		)
	_expect(
		coordinator.prepare_enemy_hit(
			finished_id,
			2,
			41,
			37,
			100.2
		) == null,
		"重复或已消费的敌人命中不得再次准入。"
	)
	coordinator.notify_projectile_finished(finished_id, finished_projectile)
	_expect(
		not coordinator.has_projectile(finished_id)
		and coordinator.has_projectile_record(finished_id),
		"弹体结束后应移除实例，但保留短期命中去重记录。"
	)

	var accepted_count := 0
	for sequence in range(1, 66):
		var client_id := MpProjectileCoordinatorScript.encode_projectile_id(4, sequence)
		if coordinator.accept_client_projectile_request_identity(
			4,
			client_id,
			4,
			false,
			200.0
		):
			accepted_count += 1
	_expect(
		accepted_count == 64,
		"同一时刻客户端弹体请求必须严格受 64 次 burst 限制。"
	)
	_expect(
		coordinator.accept_client_projectile_request_identity(
			4,
			MpProjectileCoordinatorScript.encode_projectile_id(4, 66),
			4,
			false,
			200.01
		),
		"令牌桶经过时间推进后必须按既有速率恢复准入。"
	)

	var expiring_id := MpProjectileCoordinatorScript.encode_projectile_id(5, 99)
	coordinator.remember_projectile_record(
		expiring_id,
		5,
		&"player_bullet",
		12,
		1.0,
		false,
		10.0
	)
	coordinator.prune_records(15.999)
	_expect(
		coordinator.has_projectile_record(expiring_id),
		"弹体记录不得在 lifetime 加保留窗之前被清理。"
	)
	coordinator.prune_records(16.0)
	_expect(
		not coordinator.has_projectile_record(expiring_id),
		"弹体记录必须在保留窗边界按原语义清理。"
	)

	var peer_two_projectile := ProbeProjectile.new()
	var peer_three_projectile := ProbeProjectile.new()
	var peer_two_id := coordinator.register_local_projectile(
		peer_two_projectile,
		&"probe",
		2,
		10,
		1.0,
		false,
		true,
		300.0
	)
	var peer_three_id := coordinator.register_local_projectile(
		peer_three_projectile,
		&"probe",
		3,
		10,
		1.0,
		false,
		true,
		300.0
	)
	coordinator.clear_peer(2)
	_expect(
		peer_two_projectile.retired
		and not coordinator.has_projectile(peer_two_id)
		and not coordinator.has_projectile_record(peer_two_id)
		and not peer_three_projectile.retired
		and coordinator.get_projectile(peer_three_id) == peer_three_projectile,
		"peer 清理必须只回收该玩家的弹体、记录与限流状态。"
	)

	coordinator.reset_session_state()
	_expect(
		peer_three_projectile.retired
		and int(coordinator.get_state_metrics().get("next_sequence", -1)) == 1
		and int(coordinator.get_state_metrics().get("known_projectiles", -1)) == 0
		and int(coordinator.get_state_metrics().get("projectile_records", -1)) == 0,
		"会话重置必须回收存活弹体并清空身份、记录和序号状态。"
	)
	coordinator.unbind_runtime(runtime)
	_expect(not coordinator.is_bound(), "解绑后不得保留旧战斗运行时。")

	coordinator.free()
	runtime.free()
	finished_projectile.free()
	peer_two_projectile.free()
	peer_three_projectile.free()
	if failures.is_empty():
		print("MP_PROJECTILE_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
