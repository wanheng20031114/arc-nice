extends SceneTree

const PLAYER_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/player/mp_player_coordinator.tscn"
)


class ProbeRuntime:
	extends CombatRuntimeBase

	var last_damage_number := 0

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass

	func show_damage_number(
		amount: int,
		_spawn_position: Vector2,
		_impact_direction: Vector2 = Vector2.ZERO,
		_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		_display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
	) -> bool:
		last_damage_number = amount
		return true


class ProbePlayer:
	extends Player

	var last_healing_number := 0
	var revive_countdown_seconds := -1
	var revived_position := Vector2.ZERO
	var remote_state_apply_count := 0
	var last_remote_position := Vector2.ZERO
	var last_remote_velocity := Vector2.ZERO
	var dash_active := false
	var dash_protection_accept := true
	var dash_protection_count := 0
	var remote_dash_visual_count := 0

	func set_multiplayer_health_state(new_health: int, new_is_dead: bool) -> void:
		current_health = new_health
		is_dead = new_is_dead

	func queue_healing_number(amount: int) -> void:
		last_healing_number = amount

	func set_multiplayer_revive_countdown(seconds_left: int) -> void:
		revive_countdown_seconds = seconds_left

	func revive_multiplayer(
		revive_position: Vector2,
		revived_health: int = -1,
		invincible_seconds: float = 0.0
	) -> void:
		revived_position = revive_position
		global_position = revive_position
		current_health = max_health if revived_health < 0 else revived_health
		is_dead = false
		invincibility_time_left = invincible_seconds

	func apply_remote_multiplayer_state(
		remote_position: Vector2,
		remote_velocity: Vector2,
		_shoot_input: Vector2,
		_use_skill1: bool = false,
		_use_reload: bool = false
	) -> void:
		remote_state_apply_count += 1
		last_remote_position = remote_position
		last_remote_velocity = remote_velocity
		global_position = remote_position
		velocity = remote_velocity

	func is_dashing() -> bool:
		return dash_active

	func get_dash_distance() -> float:
		return 160.0

	func get_dash_cooldown() -> float:
		return 1.0

	func start_multiplayer_dash_protection(_direction: Vector2) -> bool:
		if not dash_protection_accept:
			return false
		dash_protection_count += 1
		return true

	func play_remote_dash_visual(_direction: Vector2) -> void:
		remote_dash_visual_count += 1


class ProbeHoePlayer:
	extends PlayerHoeCat

	var accept_primary := true
	var accept_whirlwind := true
	var primary_count := 0
	var whirlwind_count := 0
	var predicted_count := 0
	var reconciled_count := 0
	var remote_action_count := 0
	var last_request_id := 0
	var last_accepted := false

	func try_authoritative_hoe_primary_attack(_attack_direction: Vector2) -> bool:
		if not accept_primary:
			return false
		primary_count += 1
		return true

	func try_authoritative_hoe_whirlwind() -> bool:
		if not accept_whirlwind:
			return false
		whirlwind_count += 1
		return true

	func play_predicted_hoe_action(
		_action_kind: StringName,
		_attack_direction: Vector2,
		request_id: int
	) -> void:
		predicted_count += 1
		last_request_id = request_id

	func reconcile_predicted_hoe_action(
		request_id: int,
		accepted: bool,
		_action_kind: StringName,
		_cooldown_ratio: float,
		_authoritative_skill_charge: float
	) -> void:
		reconciled_count += 1
		last_request_id = request_id
		last_accepted = accepted

	func play_remote_hoe_action(
		_action_kind: StringName,
		_attack_direction: Vector2,
		_sequence: int
	) -> void:
		remote_action_count += 1

	func get_primary_cooldown_ratio() -> float:
		return 0.5


class ProbeTangoPlayer:
	extends PlayerTango

	var charge_active := false
	var barrage_active := false
	var electric_surge_active := false
	var charge_started_count := 0
	var charge_released_count := 0
	var charge_cancelled_count := 0
	var reconciled_charge_count := 0
	var reconciled_barrage_count := 0
	var remote_charge_count := 0
	var remote_barrage_count := 0
	var remote_cancel_count := 0
	var rejected_prediction_count := 0
	var electric_surge_started_count := 0
	var remote_electric_surge_started_count := 0
	var remote_electric_surge_cancel_count := 0
	var last_charge_ratio := 0.0
	var last_remote_surge_remaining := 0.0

	func try_start_authoritative_electric_surge(
		_activation_id: int,
		_origin: Vector2,
		_auto_fire_charge_sequence: int = 0
	) -> bool:
		if electric_surge_active:
			return false
		electric_surge_active = true
		electric_surge_started_count += 1
		return true

	func play_remote_electric_surge_started(
		_activation_id: int,
		_origin: Vector2,
		remaining_seconds: float,
		_spawn_visual: bool = true,
		_auto_fire_charge_sequence: int = 0
	) -> void:
		electric_surge_active = true
		remote_electric_surge_started_count += 1
		last_remote_surge_remaining = remaining_seconds

	func is_electric_surge_active() -> bool:
		return electric_surge_active

	func cancel_remote_electric_surge(_activation_id: int) -> void:
		electric_surge_active = false
		remote_electric_surge_cancel_count += 1

	func try_authoritative_tango_charge_started(_direction: Vector2) -> bool:
		if charge_active:
			return false
		charge_active = true
		barrage_active = false
		charge_started_count += 1
		return true

	func try_authoritative_tango_charge_released(
		direction: Vector2,
		authoritative_charge_ratio: float
	) -> Dictionary:
		if not charge_active:
			return {
				"accepted": false,
				"fired": false,
				"direction": Vector2.ZERO,
			}
		charge_active = false
		barrage_active = true
		charge_released_count += 1
		last_charge_ratio = authoritative_charge_ratio
		return {
			"accepted": true,
			"fired": true,
			"direction": direction,
			"charge_ratio": authoritative_charge_ratio,
		}

	func cancel_authoritative_tango_charge() -> void:
		charge_active = false
		charge_cancelled_count += 1

	func is_tango_charge_active() -> bool:
		return charge_active

	func is_tango_barrage_active() -> bool:
		return barrage_active

	func reconcile_predicted_tango_charge_started(
		_direction: Vector2,
		_sequence: int
	) -> void:
		reconciled_charge_count += 1

	func reconcile_predicted_tango_barrage_started(
		_direction: Vector2,
		charge_ratio: float,
		_sequence: int
	) -> void:
		reconciled_barrage_count += 1
		last_charge_ratio = charge_ratio

	func play_remote_tango_charge_started(
		_direction: Vector2,
		_sequence: int
	) -> void:
		remote_charge_count += 1

	func play_remote_tango_barrage_started(
		_direction: Vector2,
		charge_ratio: float,
		_sequence: int
	) -> void:
		remote_barrage_count += 1
		last_charge_ratio = charge_ratio

	func play_remote_tango_charge_cancelled(_sequence: int) -> void:
		remote_cancel_count += 1

	func reject_predicted_tango_charge() -> void:
		rejected_prediction_count += 1


class ProbeModeAdapter:
	extends MultiplayerModeAdapter

	func allows_player_respawn(_peer_id: int) -> bool:
		return true


class ProbeNetManager:
	extends NetManagerStore
	var host_mode := false
	var client_mode := true
	var local_peer_id := 4

	func is_host() -> bool:
		return host_mode

	func is_client() -> bool:
		return client_mode

	func get_local_peer_id() -> int:
		return local_peer_id

	func get_host_peer_id() -> int:
		return 1


var failures: Array[String] = []
var _probe_net_time := 24.0
var _probe_tango_cancel_count := 0
var _probe_revive_action_cancel_count := 0
var _probe_tiyi_clear_count := 0
var _probe_committed_revive_position := Vector2.ZERO
var _probe_action_broadcast_methods: Array[StringName] = []
var _probe_action_to_host_methods: Array[StringName] = []
var _probe_action_to_peer_methods: Array[StringName] = []
var _probe_state_correction_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := (
		PLAYER_COORDINATOR_SCENE.instantiate() as MpPlayerCoordinator
	)
	var runtime := ProbeRuntime.new()
	_expect(coordinator != null, "PlayerCoordinator 场景必须可实例化。")
	var prebind_target := Vector2(320.0, 180.0)
	_expect(
		coordinator.queue_authoritative_teleport(
			9,
			prebind_target,
			4,
			3,
			1.0
		),
		"运行时装配前到达的可靠传送必须进入等待队列。"
	)
	coordinator.bind_runtime(runtime)
	var net_manager := ProbeNetManager.new()
	coordinator.bind_player_action_dependencies(
		net_manager,
		_probe_get_net_time,
		_probe_is_embedded_participant_suspended
	)
	coordinator.player_action_rpc_to_host_requested.connect(
		_probe_on_action_rpc_to_host
	)
	coordinator.player_action_rpc_to_peer_requested.connect(
		_probe_on_action_rpc_to_peer
	)
	coordinator.player_action_rpc_broadcast_requested.connect(
		_probe_on_action_rpc_broadcast
	)
	coordinator.player_state_correction_requested.connect(
		_probe_on_player_state_correction
	)
	_expect(coordinator.is_bound(), "PlayerCoordinator 必须强类型绑定战斗运行时。")
	_expect(
		coordinator.has_pending_authoritative_teleport(9),
		"首次绑定运行时不得清除更早到达的可靠传送。"
	)
	var prebind_player := Player.new()
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	runtime.multiplayer_local_peer_id = 3
	runtime.peer_players[9] = prebind_player
	_expect(
		coordinator.try_apply_pending_authoritative_teleport(9, 3, 1.5),
		"玩家装配后必须补交绑定前缓存的可靠传送。"
	)
	_expect(
		prebind_player.global_position == prebind_target
		and not coordinator.has_pending_authoritative_teleport(9),
		"补交后的可靠传送位置或等待队列状态错误。"
	)
	coordinator.clear_peer(9)
	runtime.peer_players.erase(9)
	prebind_player.free()

	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	coordinator.remember_latest_client_state(
		true,
		2,
		Vector2(88.0, 42.0),
		Vector2(5.0, -3.0),
		3,
		7
	)
	var state := SnapshotManager.PlayerState.new()
	state.peer_id = 2
	state.character_id = &"weishidaier"
	state.position = Vector2(1.0, 2.0)
	state.velocity = Vector2.ZERO
	state.current_health = 80
	state.max_health = 100
	var states: Array[SnapshotManager.PlayerState] = [state]
	var ready_peers: Array[int] = [2, 3]
	coordinator.sync_snapshot_cohort_readiness(ready_peers)
	var batch := coordinator.build_host_snapshot_batch(
		states,
		ready_peers,
		12.5,
		{2: 9}
	)
	_expect(batch != null and not batch.is_empty(), "Host 必须生成玩家快照批次。")
	if batch != null:
		_expect(batch.peer_ids == ready_peers, "批次接收者顺序必须保持不变。")
		var receiver := SnapshotManager.new()
		var decoded := receiver.decode_player_snapshots_with_baseline(batch.data)
		_expect(decoded.size() == 1, "玩家快照必须可由现有协议解码。")
		if decoded.size() == 1:
			var decoded_state := decoded[0] as SnapshotManager.PlayerState
			_expect(decoded_state.sequence == 1, "首批 Host 快照序列必须为 1。")
			_expect(decoded_state.health_revision == 9, "可靠生命 revision 必须写入快照。")
			_expect(
				decoded_state.position.distance_to(Vector2(88.0, 42.0)) < 0.12,
				"Host 快照必须采用最新已接纳的客户端位置。"
			)
	_expect(coordinator.get_snapshot_encode_count() == 1, "编码计数必须由协调器持有。")
	_expect(coordinator.get_snapshot_cohort_size() == 2, "cohort 成员必须由协调器持有。")

	var remote_player := Player.new()
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	runtime.multiplayer_local_peer_id = 3
	runtime.peer_players[2] = remote_player
	var target_position := Vector2(4096.0, 3072.0)
	_expect(
		coordinator.queue_authoritative_teleport(
			2,
			target_position,
			17,
			3,
			20.0
		),
		"可靠传送必须被玩家协调器接受。"
	)
	_expect(
		remote_player.global_position == target_position,
		"可靠传送必须立即写入已存在的远端玩家。"
	)
	var interpolator := coordinator.get_visual_interpolator(2)
	_expect(
		interpolator != null and interpolator.get_buffer_size() == 1,
		"可靠传送必须重置远端视觉插值历史。"
	)
	_expect(
		not coordinator.accept_snapshot_motion_after_teleport(2, 17),
		"跨信道到达的旧快照不得回拉已传送玩家。"
	)
	_expect(
		coordinator.accept_snapshot_motion_after_teleport(2, 18),
		"首个较新快照必须释放传送屏障。"
	)
	coordinator.mark_health_revision_applied(2, 6)
	coordinator.mark_health_revision_applied(2, 4)
	_expect(
		coordinator.get_applied_health_revision(2) == 6,
		"快照生命 revision 栅栏不得回退。"
	)
	coordinator.clear_peer(2)
	_expect(
		not coordinator.has_visual_interpolator(2)
		and not coordinator.has_latest_client_state(2)
		and coordinator.get_applied_health_revision(2) == 0,
		"peer 清理必须释放全部玩家快照专属状态。"
	)
	runtime.peer_players.erase(2)
	remote_player.free()

	net_manager.host_mode = true
	net_manager.client_mode = false
	net_manager.local_peer_id = 1
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	runtime.multiplayer_local_peer_id = 1
	_probe_net_time = 30.0
	var action_player := ProbePlayer.new()
	action_player.peer_id = 2
	action_player.move_speed = 100.0
	runtime.peer_players[2] = action_player
	coordinator.handle_client_player_state(
		2,
		1,
		Vector2(8.0, 0.0),
		Vector2(20.0, 0.0),
		Vector2.RIGHT,
		Vector2.ZERO,
		0,
		0,
		Vector2.ZERO,
		Vector2.ZERO
	)
	_expect(
		action_player.remote_state_apply_count == 1
		and action_player.last_remote_position == Vector2(8.0, 0.0)
		and coordinator.get_accepted_player_position(2) == Vector2(8.0, 0.0),
		"客户端玩家状态接纳后必须同步更新权威姿态与快照覆盖。"
	)
	coordinator.handle_client_player_state(
		2,
		1,
		Vector2(10.0, 0.0),
		Vector2.ZERO,
		Vector2.RIGHT,
		Vector2.ZERO,
		0,
		0,
		Vector2.ZERO,
		Vector2.ZERO
	)
	_expect(
		_probe_state_correction_count == 1
		and action_player.remote_state_apply_count == 1,
		"重复玩家状态序列必须拒绝并请求可靠位置修正。"
	)
	var action_broadcast_count := _probe_action_broadcast_methods.size()
	_expect(
		coordinator.try_accept_client_dash_request(
			2,
			action_player,
			1,
			Vector2.RIGHT,
			Vector2.RIGHT
		),
		"合法 Dash 序列必须由玩家协调器接纳。"
	)
	_expect(
		action_player.dash_protection_count == 1
		and _probe_action_broadcast_methods.size() == action_broadcast_count + 1
		and _probe_action_broadcast_methods.back() == &"net_player_dash_confirmed",
		"Dash 接纳必须启动保护并经根出口广播确认。"
	)
	_expect(
		not coordinator.try_accept_client_dash_request(
			2,
			action_player,
			1,
			Vector2.RIGHT,
			Vector2.RIGHT
		),
		"重复 Dash 序列不得再次启动保护。"
	)
	var admitted_actions := 0
	for _index in range(int(MpPlayerCoordinator.PLAYER_ACTION_INGRESS_RATE_BURST)):
		if coordinator.consume_remote_player_action_admission(2, 40.0):
			admitted_actions += 1
	_expect(
		admitted_actions == int(MpPlayerCoordinator.PLAYER_ACTION_INGRESS_RATE_BURST)
		and not coordinator.consume_remote_player_action_admission(2, 40.0),
		"玩家动作共享令牌桶必须保持既有 burst 上限。"
	)
	var authoritative_target := Vector2(96.0, 48.0)
	_expect(
		coordinator.commit_authoritative_player_teleport(2, authoritative_target)
		and coordinator.get_accepted_player_position(2) == authoritative_target,
		"权威传送必须原子更新玩家位置与已接纳姿态。"
	)
	coordinator.clear_peer(2)
	_expect(
		coordinator.get_accepted_player_position(2) == null
		and coordinator.consume_remote_player_action_admission(2, 40.0),
		"peer 清理必须释放姿态、序列与动作限流状态。"
	)

	net_manager.host_mode = false
	net_manager.client_mode = true
	net_manager.local_peer_id = 2
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	runtime.multiplayer_local_peer_id = 2
	action_player.dash_active = true
	coordinator.notify_local_player_dash_started(
		Vector2.RIGHT,
		Vector2.RIGHT,
		true
	)
	_expect(
		coordinator.has_pending_dash_input_packet()
		and _probe_action_to_host_methods.back() == &"net_player_dash_requested",
		"客户端 Dash 必须同时发送可靠请求并保留输入冗余。"
	)
	for _index in range(MpPlayerCoordinator.DASH_INPUT_REDUNDANCY_PACKETS):
		coordinator.consume_pending_dash_input_packet()
	_expect(
		not coordinator.has_pending_dash_input_packet(),
		"Dash 输入冗余必须保持三包后清空的既有顺序。"
	)
	var remote_dash_player := ProbePlayer.new()
	remote_dash_player.peer_id = 3
	runtime.peer_players[3] = remote_dash_player
	coordinator.apply_dash_confirmation(3, Vector2.LEFT, 1)
	_expect(
		remote_dash_player.remote_dash_visual_count == 1,
		"远端 Dash 确认必须只播放一次对应视觉。"
	)

	var hoe_player := ProbeHoePlayer.new()
	hoe_player.peer_id = 5
	runtime.peer_players[5] = hoe_player
	net_manager.host_mode = true
	net_manager.client_mode = false
	net_manager.local_peer_id = 1
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	action_broadcast_count = _probe_action_broadcast_methods.size()
	_expect(
		coordinator.apply_authoritative_hoe_action(
			5,
			MpPlayerCoordinator.HOE_ACTION_PRIMARY,
			Vector2.RIGHT,
			1
		),
		"Hoe 普攻必须通过强类型角色入口执行。"
	)
	_expect(
		hoe_player.primary_count == 1
		and _probe_action_broadcast_methods.size() == action_broadcast_count + 1
		and _probe_action_broadcast_methods.back() == &"net_hoe_action_confirmed",
		"Hoe 成功动作必须推进序列并广播确认。"
	)
	hoe_player.accept_primary = false
	_expect(
		not coordinator.apply_authoritative_hoe_action(
			5,
			MpPlayerCoordinator.HOE_ACTION_PRIMARY,
			Vector2.RIGHT,
			2
		)
		and _probe_action_to_peer_methods.back() == &"net_hoe_action_confirmed",
		"Hoe 拒绝结果必须仅回送请求客户端。"
	)
	net_manager.host_mode = false
	net_manager.client_mode = true
	net_manager.local_peer_id = 5
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	_expect(
		coordinator.request_hoe_primary_attack(Vector2.RIGHT, true)
		and hoe_player.predicted_count == 1
		and _probe_action_to_host_methods.back() == &"net_hoe_primary_attack_requested",
		"Hoe 客户端预测与请求顺序必须保持不变。"
	)
	coordinator.apply_hoe_action_confirmation(
		1,
		5,
		"primary",
		Vector2.RIGHT,
		1,
		hoe_player.last_request_id,
		true,
		0.5,
		0.0
	)
	_expect(
		hoe_player.reconciled_count == 1 and hoe_player.last_accepted,
		"Hoe 本地预测必须由房主确认完成对账。"
	)

	var tango_host_player := ProbeTangoPlayer.new()
	tango_host_player.peer_id = 6
	runtime.peer_players[6] = tango_host_player
	net_manager.host_mode = true
	net_manager.client_mode = false
	net_manager.local_peer_id = 1
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	runtime.multiplayer_local_peer_id = 1
	_probe_net_time = 60.0
	action_broadcast_count = _probe_action_broadcast_methods.size()
	coordinator.handle_tango_charge_started_request(6, Vector2.RIGHT, 1)
	_expect(
		coordinator.has_active_tango_charge(6)
		and tango_host_player.charge_started_count == 1
		and coordinator.get_tango_charge_sequence(6) == 1
		and _probe_action_broadcast_methods.size() == action_broadcast_count + 1
		and _probe_action_broadcast_methods.back() == &"net_tango_charge_started",
		"探戈蓄力开始必须经过共享 admission、推进序列并由根出口广播。"
	)
	var tango_snapshot := SnapshotManager.PlayerState.new()
	tango_snapshot.peer_id = 6
	tango_snapshot.character_id = &"tango"
	var tango_states: Array[SnapshotManager.PlayerState] = [tango_snapshot]
	_probe_net_time = 61.2
	coordinator.apply_authoritative_tango_charge_snapshot_ratios(
		tango_states,
		_probe_net_time
	)
	_expect(
		is_equal_approx(tango_snapshot.primary_cooldown_ratio, 0.5),
		"Host 玩家快照必须携带权威探戈蓄力比例。"
	)
	_probe_net_time = 61.3
	coordinator.handle_tango_charge_released_request(6, Vector2.RIGHT, 1)
	_expect(
		not coordinator.has_active_tango_charge(6)
		and tango_host_player.charge_released_count == 1
		and is_equal_approx(tango_host_player.last_charge_ratio, 0.5)
		and _probe_action_broadcast_methods.back() == &"net_tango_charge_released",
		"探戈释放必须由 Host 时钟计算倍率并广播唯一终端。"
	)
	_expect(
		not coordinator.apply_authoritative_tango_charge_started(
			6,
			Vector2.RIGHT,
			1
		),
		"重复探戈请求号不得重新开启蓄力。"
	)
	_probe_net_time = 62.0
	_expect(
		coordinator.apply_authoritative_tango_charge_started(
			6,
			Vector2.UP,
			2
		),
		"较新的探戈蓄力请求必须被接纳。"
	)
	_probe_net_time = 62.1
	_expect(
		coordinator.apply_authoritative_tango_charge_released(
			6,
			Vector2.UP,
			2
		)
		and tango_host_player.charge_cancelled_count == 1
		and _probe_action_broadcast_methods.back() == &"net_tango_charge_cancelled",
		"未达到最短蓄力时长必须可靠取消且不得发射。"
	)
	_expect(
		not coordinator.apply_authoritative_tango_charge_released(
			6,
			Vector2.RIGHT,
			99
		)
		and _probe_action_to_peer_methods.back() == &"net_tango_charge_rejected",
		"无匹配蓄力的释放必须仅向请求端拒绝。"
	)
	_probe_net_time = 63.0
	coordinator.handle_tango_electric_surge_request(6, 1)
	var active_surge_record := coordinator.get_active_tango_electric_surge_record(6)
	_expect(
		coordinator.has_active_tango_electric_surge(6)
		and tango_host_player.electric_surge_started_count == 1
		and int(active_surge_record.get("activation_id", 0)) == 1
		and int(active_surge_record.get("charge_sequence", 0)) == 3
		and is_equal_approx(
			coordinator.get_tango_laser_barrage_maximum_seconds(6, 1.0),
			MpPlayerCoordinator.TANGO_ELECTRIC_SURGE_DURATION_SECONDS
		)
		and _probe_action_broadcast_methods.back()
			== &"net_tango_electric_surge_started",
		"电涌必须分配独立激活序列并延长对应权威弹幕生命周期。"
	)
	_probe_net_time = 64.0
	coordinator.send_active_tango_electric_surges_to_peer(9)
	_expect(
		_probe_action_to_peer_methods.back() == &"net_tango_electric_surge_started",
		"迟加入玩家必须收到仍在运行的电涌重建事件。"
	)
	coordinator.mark_tango_owner_disconnected(6)
	coordinator.clear_peer(6)
	active_surge_record = coordinator.get_active_tango_electric_surge_record(6)
	_expect(
		coordinator.has_active_tango_electric_surge(6)
		and bool(active_surge_record.get("owner_disconnected", false)),
		"施法者断线后世界电场及其序列栅栏必须保留到场自身结束。"
	)
	coordinator.finish_authoritative_tango_electric_surge(6, 1)
	_expect(
		not coordinator.has_active_tango_electric_surge(6)
		and coordinator.get_tango_charge_sequence(6) == 0
		and _probe_action_broadcast_methods.back()
			== &"net_tango_electric_surge_finished",
		"断线施法者的电场结束后必须广播并释放全部保留序列。"
	)

	var tango_client_player := ProbeTangoPlayer.new()
	tango_client_player.peer_id = 7
	runtime.peer_players[7] = tango_client_player
	net_manager.host_mode = false
	net_manager.client_mode = true
	net_manager.local_peer_id = 7
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	runtime.multiplayer_local_peer_id = 7
	_expect(
		coordinator.request_tango_charge_started(Vector2.LEFT, true)
		and coordinator.has_local_tango_prediction()
		and _probe_action_to_host_methods.back()
			== &"net_tango_charge_started_requested",
		"客户端探戈蓄力必须登记本地预测请求并经根出口发往 Host。"
	)
	coordinator.apply_tango_charge_started(1, 7, Vector2.LEFT, 1, 1)
	_expect(
		tango_client_player.reconciled_charge_count == 1,
		"Host 蓄力确认必须对账本地探戈预测。"
	)
	_expect(
		coordinator.request_tango_charge_released(Vector2.LEFT, true)
		and _probe_action_to_host_methods.back()
			== &"net_tango_charge_released_requested",
		"客户端探戈释放必须只发送当前活动请求。"
	)
	coordinator.apply_tango_charge_released(
		1,
		7,
		Vector2.LEFT,
		0.75,
		1,
		1
	)
	_expect(
		tango_client_player.reconciled_barrage_count == 1
		and not coordinator.has_local_tango_prediction(),
		"可靠释放确认必须完成本地弹幕对账并清除预测事务。"
	)
	_expect(
		coordinator.request_tango_charge_started(Vector2.DOWN, true),
		"完成一次对账后必须允许开启新的探戈预测。"
	)
	coordinator.apply_tango_charge_rejected(
		1,
		7,
		2,
		MpPlayerCoordinator.TANGO_CHARGE_PHASE_START
	)
	_expect(
		tango_client_player.rejected_prediction_count == 1
		and not coordinator.has_local_tango_prediction(),
		"Host 拒绝必须只终止匹配的本地探戈预测。"
	)

	var tango_remote_player := ProbeTangoPlayer.new()
	tango_remote_player.peer_id = 8
	runtime.peer_players[8] = tango_remote_player
	coordinator.apply_tango_electric_surge_started(
		1,
		8,
		1,
		Vector2(32.0, 48.0),
		7.0,
		64.0,
		true,
		1,
		4,
		1.0
	)
	_expect(
		coordinator.has_active_tango_electric_surge(8)
		and tango_remote_player.remote_electric_surge_started_count == 1
		and is_equal_approx(tango_remote_player.last_remote_surge_remaining, 6.0),
		"客户端必须按既有 Host 时差裁剪电涌重建时长。"
	)
	coordinator.apply_tango_electric_surge_started(
		1,
		8,
		1,
		Vector2(32.0, 48.0),
		5.0,
		65.0,
		false,
		1,
		4,
		0.0
	)
	_expect(
		tango_remote_player.remote_electric_surge_started_count == 1
		and tango_remote_player.remote_electric_surge_cancel_count == 1,
		"恢复重放不得重新生成电场，且 Host 已结束的增益不得被旧状态复活。"
	)
	coordinator.apply_tango_electric_surge_finished(1, 8, 1)
	_expect(
		not coordinator.has_active_tango_electric_surge(8),
		"电涌结束事件必须清理客户端活动记录。"
	)

	runtime.peer_players.erase(2)
	runtime.peer_players.erase(3)
	runtime.peer_players.erase(5)
	runtime.peer_players.erase(6)
	runtime.peer_players.erase(7)
	runtime.peer_players.erase(8)
	action_player.free()
	remote_dash_player.free()
	hoe_player.free()
	tango_host_player.free()
	tango_client_player.free()
	tango_remote_player.free()

	net_manager.host_mode = false
	net_manager.client_mode = true
	net_manager.local_peer_id = 4
	var mode_adapter := ProbeModeAdapter.new()
	var projectile_coordinator := MpProjectileCoordinator.new()
	coordinator.bind_life_dependencies(
		net_manager,
		mode_adapter,
		projectile_coordinator,
		_probe_get_net_time,
		_probe_cancel_tango,
		_probe_cancel_revive_actions,
		_probe_clear_tiyi_state,
		_probe_get_revive_anchor,
		_probe_commit_revive_position
	)
	var life_player := ProbePlayer.new()
	life_player.peer_id = 4
	life_player.max_health = 100
	life_player.current_health = 100
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	runtime.multiplayer_local_peer_id = 4
	runtime.peer_players[4] = life_player
	coordinator.apply_player_damage_confirmation(
		4,
		65,
		false,
		1,
		35,
		Vector2.LEFT,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		life_player.current_health == 65
		and coordinator.get_health_revision(4) == 1
		and coordinator.get_applied_health_revision(4) == 1
		and runtime.last_damage_number == 35,
		"可靠玩家伤害确认必须同时推进生命状态、revision 与反馈。"
	)
	coordinator.apply_player_damage_confirmation(
		4,
		10,
		false,
		1,
		55,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(life_player.current_health == 65, "重复生命 revision 不得重复应用伤害。")
	coordinator.apply_player_heal_confirmation(4, 80, 2, 15)
	_expect(
		life_player.current_health == 80
		and life_player.last_healing_number == 15
		and coordinator.get_health_revision(4) == 2,
		"可靠治疗确认必须复用同一生命 revision 栅栏。"
	)
	coordinator.apply_player_revive_countdown(4, 7)
	_expect(
		life_player.revive_countdown_seconds == 7,
		"非塔防模式复活倒计时必须仍写入玩家名牌。"
	)
	life_player.is_dead = true
	life_player.current_health = 0
	var revive_position := Vector2(512.0, 256.0)
	coordinator.apply_player_revived(4, revive_position, 100, 3.0, 3)
	_expect(
		not life_player.is_dead
		and life_player.current_health == 100
		and life_player.revived_position == revive_position
		and coordinator.get_health_revision(4) == 3
		and _probe_tiyi_clear_count == 1,
		"可靠复活确认必须恢复玩家并清理角色生命期状态。"
	)
	var reconnect_life_state := coordinator.capture_reconnect_life_state(4)
	_expect(
		int(reconnect_life_state.get("health_revision", 0)) == 3
		and int(reconnect_life_state.get("applied_health_revision", 0)) == 3,
		"重连快照必须由玩家协调器持有完整生命 revision。"
	)
	coordinator.clear_peer(4)
	_expect(
		coordinator.get_health_revision(4) == 0
		and coordinator.get_applied_health_revision(4) == 0
		and not coordinator.has_pending_revive(4),
		"peer 清理必须同时释放生命与复活事务状态。"
	)

	runtime.peer_players.clear()
	life_player.free()
	projectile_coordinator.free()
	mode_adapter.free()
	net_manager.free()
	coordinator.unbind_runtime(runtime)
	_expect(not coordinator.is_bound(), "解绑后不得保留旧战斗运行时。")
	runtime.free()
	coordinator.free()

	if failures.is_empty():
		print("MP_PLAYER_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _probe_get_net_time() -> float:
	return _probe_net_time


func _probe_cancel_tango(_peer_id: int) -> void:
	_probe_tango_cancel_count += 1


func _probe_cancel_revive_actions(_peer_id: int) -> void:
	_probe_revive_action_cancel_count += 1


func _probe_clear_tiyi_state(_peer_id: int) -> void:
	_probe_tiyi_clear_count += 1


func _probe_get_revive_anchor(_peer_id: int, player_node: Player) -> Vector2:
	return player_node.global_position


func _probe_commit_revive_position(
	_peer_id: int,
	revive_position: Vector2,
	_net_time: float
) -> void:
	_probe_committed_revive_position = revive_position


func _probe_is_embedded_participant_suspended(_peer_id: int) -> bool:
	return false


func _probe_on_action_rpc_to_host(
	method_name: StringName,
	_arguments: Array
) -> void:
	_probe_action_to_host_methods.append(method_name)


func _probe_on_action_rpc_to_peer(
	_peer_id: int,
	method_name: StringName,
	_arguments: Array
) -> void:
	_probe_action_to_peer_methods.append(method_name)


func _probe_on_action_rpc_broadcast(
	method_name: StringName,
	_arguments: Array
) -> void:
	_probe_action_broadcast_methods.append(method_name)


func _probe_on_player_state_correction(
	_peer_id: int,
	_corrected_position: Vector2,
	_corrected_velocity: Vector2
) -> void:
	_probe_state_correction_count += 1
