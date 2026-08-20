extends SceneTree

const TRANSACTIONS_SCENE := preload(
	"res://scene/multiplayer/transactions/mp_transactions_coordinator.tscn"
)
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const VOID_BATTERY: PickupConfig = preload(
	"res://resources/config/consumables/void_battery.tres"
)
const SKILL_CHARGE_BATTERY: PickupConfig = preload(
	"res://resources/config/consumables/skill_charge_battery.tres"
)
const MAGIC_RESISTANCE_POTION: PickupConfig = preload(
	"res://resources/config/consumables/magic_resistance_potion.tres"
)
const TEST_PEER_ID := 9


class TestRuntime:
	extends CombatRuntimeBase
	var players: Dictionary = {}

	func _ready() -> void:
		pass

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return players.get(peer_id) as Player

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := (
		TRANSACTIONS_SCENE.instantiate() as MpTransactionsCoordinator
	)
	var session := MP_GAME_SCRIPT.new() as MultiplayerGameplaySession
	var runtime := TestRuntime.new()
	var adapter := MultiplayerModeAdapter.new()
	var net_manager := NetManagerStore.new()
	var host_run_state := RunStateStore.new()
	host_run_state.begin_new_run(&"weishidaier", false)
	host_run_state.register_multiplayer_peer_state(TEST_PEER_ID)
	var suspended_peers: Dictionary[int, bool] = {}
	var host_player := PLAYER_SCENE.instantiate() as Player
	root.add_child(net_manager)
	root.add_child(host_player)
	await process_frame
	await physics_frame
	host_player.set_physics_process(false)
	runtime.players[TEST_PEER_ID] = host_player
	net_manager.net_role = NetManagerStore.NetRole.HOST
	coordinator.bind_session(
		session,
		runtime,
		adapter,
		net_manager,
		host_run_state,
		suspended_peers
	)
	var broadcasts: Array[Dictionary] = []
	coordinator.inventory_item_used_broadcast_requested.connect(
		func(
			peer_id: int,
			slot_index: int,
			config_path: String,
			success: bool,
			inventory_snapshot: Dictionary,
			force_inventory_repair: bool
		) -> void:
			broadcasts.append({
				"peer_id": peer_id,
				"slot_index": slot_index,
				"config_path": config_path,
				"success": success,
				"inventory_snapshot": inventory_snapshot.duplicate(true),
				"force_inventory_repair": force_inventory_repair,
			})
	)

	_expect(
		host_run_state.try_add_item_count_for_peer(
			TEST_PEER_ID,
			VOID_BATTERY,
			2
		),
		"Host测试必须建立两件虚空电池堆叠。"
	)
	var battery_slot := _find_item_slot_for_peer(
		host_run_state,
		TEST_PEER_ID,
		VOID_BATTERY
	)
	var expected_revision := host_run_state.get_inventory_revision_for_peer(
		TEST_PEER_ID
	)
	coordinator.apply_authoritative_inventory_item_use(
		TEST_PEER_ID,
		battery_slot,
		expected_revision
	)
	_expect(
		broadcasts.size() == 1
		and bool(broadcasts[0].get("success", false))
		and str(broadcasts[0].get("config_path", ""))
		== VOID_BATTERY.resource_path
		and host_run_state.get_item_count_for_peer(
			TEST_PEER_ID,
			battery_slot
		) == 1
		and host_player.has_void_battery_charge(),
		"Host必须只扣一件、建立一层充能并广播新revision。"
	)
	var successful_snapshot := (
		broadcasts[0].get("inventory_snapshot", {}) as Dictionary
	).duplicate(true)
	host_player.skill1_charge = 0.0
	host_player.set_controls_locked(true)
	host_player.set("_last_skill_activation_msec", -1000000)
	_expect(
		not host_player.consume_multiplayer_skill1_charge()
		and host_player.has_void_battery_charge()
		and is_zero_approx(host_player.skill1_charge),
		"Host操作锁定导致技能失败时不得消费虚空充能或技力。"
	)
	host_player.set_controls_locked(false)
	host_player.set("_last_skill_activation_msec", -1000000)
	_expect(
		host_player.consume_multiplayer_skill1_charge()
		and not host_player.has_void_battery_charge()
		and is_zero_approx(host_player.skill1_charge),
		"Host零技力成功技能必须消费充能并保留原有技力。"
	)
	coordinator.apply_authoritative_inventory_item_use(
		TEST_PEER_ID,
		battery_slot,
		expected_revision
	)
	_expect(
		broadcasts.size() == 2
		and not bool(broadcasts[1].get("success", true))
		and bool(broadcasts[1].get("force_inventory_repair", false))
		and host_run_state.get_item_count_for_peer(
			TEST_PEER_ID,
			battery_slot
		) == 1
		and not host_player.has_void_battery_charge(),
		"陈旧revision不得再次扣除或重新充能。"
	)
	_expect(
		host_run_state.try_add_item_count_for_peer(
			TEST_PEER_ID,
			SKILL_CHARGE_BATTERY,
			1
		),
		"技力电池乱序测试必须建立一件独立物品。"
	)
	var skill_battery_slot := _find_item_slot_for_peer(
		host_run_state,
		TEST_PEER_ID,
		SKILL_CHARGE_BATTERY
	)
	var skill_battery_expected_revision := (
		host_run_state.get_inventory_revision_for_peer(TEST_PEER_ID)
	)
	host_player.skill1_charge = 0.0
	coordinator.apply_authoritative_inventory_item_use(
		TEST_PEER_ID,
		skill_battery_slot,
		skill_battery_expected_revision
	)
	_expect(
		broadcasts.size() == 3
		and bool(broadcasts[2].get("success", false))
		and str(broadcasts[2].get("config_path", ""))
		== SKILL_CHARGE_BATTERY.resource_path
		and is_equal_approx(host_player.skill1_charge, 3.0),
		"Host必须权威结算蓝晶技力电池的3点恢复。"
	)
	var skill_battery_snapshot := (
		broadcasts[2].get("inventory_snapshot", {}) as Dictionary
	).duplicate(true)
	var second_void_expected_revision := (
		host_run_state.get_inventory_revision_for_peer(TEST_PEER_ID)
	)
	coordinator.apply_authoritative_inventory_item_use(
		TEST_PEER_ID,
		battery_slot,
		second_void_expected_revision
	)
	_expect(
		broadcasts.size() == 4
		and bool(broadcasts[3].get("success", false))
		and host_player.has_void_battery_charge()
		and host_run_state.get_item_count_for_peer(
			TEST_PEER_ID,
			battery_slot
		) == 0,
		"前一层消费后Host必须能权威建立第二层虚空充能。"
	)
	var second_void_inventory_snapshot := (
		broadcasts[3].get("inventory_snapshot", {}) as Dictionary
	).duplicate(true)
	_expect(
		host_run_state.try_add_item_count_for_peer(
			TEST_PEER_ID,
			MAGIC_RESISTANCE_POTION,
			1
		),
		"死亡跨频道回归必须建立一瓶紫晶法抗药水。"
	)
	var magic_potion_slot := _find_item_slot_for_peer(
		host_run_state,
		TEST_PEER_ID,
		MAGIC_RESISTANCE_POTION
	)
	coordinator.apply_authoritative_inventory_item_use(
		TEST_PEER_ID,
		magic_potion_slot,
		host_run_state.get_inventory_revision_for_peer(TEST_PEER_ID)
	)
	_expect(
		broadcasts.size() == 5
		and bool(broadcasts[4].get("success", false))
		and host_player.potion_magic_defense_bonus == 15,
		"Host必须在玩家存活时权威结算法抗药水。"
	)
	var magic_potion_inventory_snapshot := (
		broadcasts[4].get("inventory_snapshot", {}) as Dictionary
	).duplicate(true)
	coordinator.unbind_session(session)

	var client_run_state := RunStateStore.new()
	client_run_state.begin_new_run(&"weishidaier", false)
	client_run_state.register_multiplayer_peer_state(TEST_PEER_ID)
	var client_player := PLAYER_SCENE.instantiate() as Player
	root.add_child(client_player)
	await process_frame
	await physics_frame
	client_player.set_physics_process(false)
	runtime.players[TEST_PEER_ID] = client_player
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	coordinator.bind_session(
		session,
		runtime,
		adapter,
		net_manager,
		client_run_state,
		suspended_peers
	)
	coordinator.receive_inventory_item_used(
		TEST_PEER_ID,
		battery_slot,
		VOID_BATTERY.resource_path,
		true,
		successful_snapshot
	)
	_expect(
		not client_player.has_void_battery_charge()
		and client_run_state.get_item_count_for_peer(
			TEST_PEER_ID,
			battery_slot
		) == 1,
		"可靠背包事件只能更新库存，void状态必须等待PlayerState权威值。"
	)
	client_player.apply_authoritative_void_battery_state(true)
	client_player.skill1_charge = 2.0
	client_player.set_controls_locked(true)
	client_player.set("_last_skill_activation_msec", -1000000)
	_expect(
		not client_player.try_begin_skill1_activation(false)
		and client_player.has_void_battery_charge()
		and is_equal_approx(client_player.skill1_charge, 2.0),
		"客户端失败的低技力技能不得消费虚空充能。"
	)
	client_player.set_controls_locked(false)
	client_player.set("_last_skill_activation_msec", -1000000)
	_expect(
		client_player.try_begin_skill1_activation(false, true, 1001)
		and client_player.has_void_battery_charge()
		and is_equal_approx(client_player.skill1_charge, 2.0),
		"客户端低技力预测必须保留充能，等待Host绝对状态确认。"
	)
	client_player.apply_authoritative_void_battery_state(false)
	_expect(
		not client_player.has_void_battery_charge()
		and is_equal_approx(client_player.skill1_charge, 2.0),
		"Host确认成功后PlayerState必须清除预测层且保留原有技力。"
	)
	coordinator.receive_inventory_item_used(
		TEST_PEER_ID,
		battery_slot,
		VOID_BATTERY.resource_path,
		true,
		successful_snapshot
	)
	_expect(
		not client_player.has_void_battery_charge()
		and client_run_state.get_item_count_for_peer(
			TEST_PEER_ID,
			battery_slot
		) == 1,
		"重复确认的相同revision不得重新建立客户端充能。"
	)
	client_player.apply_inventory_item_use_replay(VOID_BATTERY)
	_expect(
		not client_player.has_void_battery_charge(),
		"技能后的旧item-used跨频道晚到时不得重新建立已消费层。"
	)
	# Simulate a newer realtime Player snapshot arriving before the reliable
	# inventory transaction. Its authoritative charge must not receive +3 twice.
	client_player.skill1_charge = 3.0
	coordinator.receive_inventory_item_used(
		TEST_PEER_ID,
		skill_battery_slot,
		SKILL_CHARGE_BATTERY.resource_path,
		true,
		skill_battery_snapshot
	)
	_expect(
		is_equal_approx(client_player.skill1_charge, 3.0),
		"可靠物品事件晚于Player快照时不得重复叠加技力恢复。"
	)
	# A second battery may be used after the previous cast. Its reliable inventory
	# event still does not own the bit; the following absolute PlayerState does.
	coordinator.receive_inventory_item_used(
		TEST_PEER_ID,
		battery_slot,
		VOID_BATTERY.resource_path,
		true,
		second_void_inventory_snapshot
	)
	_expect(
		not client_player.has_void_battery_charge(),
		"第二层的inventory事件不得被旧技能频道顺序直接解释为充能。"
	)
	client_player.apply_authoritative_void_battery_state(true)
	_expect(
		client_player.has_void_battery_charge(),
		"较新的Host PlayerState必须最终建立第二层且不受旧技能事件影响。"
	)
	client_player.skill1_charge = 0.0
	client_player.set("_last_skill_activation_msec", -1000000)
	_expect(
		client_player.try_begin_skill1_activation(false, true, 1002),
		"客户端零技力必须能建立虚空技能预测保留。"
	)
	client_player.cancel_predicted_void_battery_activation(1002)
	_expect(
		client_player.has_void_battery_charge()
		and is_zero_approx(client_player.skill1_charge),
		"Host拒绝的预测在投射物结束后必须解除保留但不消费第二层。"
	)
	client_player.set("_last_skill_activation_msec", -1000000)
	_expect(
		client_player.try_begin_skill1_activation(false, true, 1003),
		"ABA回归测试必须先建立第二次预测保留。"
	)
	# Host may consume the old layer and arm a new one before any PlayerState is
	# sampled, so the only absolute value observed by the client remains true.
	client_player.apply_authoritative_void_battery_state(true)
	client_player.confirm_predicted_void_battery_activation(1002)
	_expect(
		not client_player.try_begin_skill1_activation(false, true, 1004),
		"旧投射物确认不得解除新一轮ABA预测保留。"
	)
	client_player.confirm_predicted_void_battery_activation(1003)
	_expect(
		client_player.has_void_battery_charge(),
		"预测确认必须解除ABA保留但不得清掉较新的Host true绝对状态。"
	)
	client_player.set("_last_skill_activation_msec", -1000000)
	_expect(
		client_player.try_begin_skill1_activation(false, true, 1004),
		"ABA确认后不得软锁后续技能。"
	)
	client_player.cancel_predicted_void_battery_activation(1004)
	client_player.is_dead = true
	coordinator.receive_inventory_item_used(
		TEST_PEER_ID,
		magic_potion_slot,
		MAGIC_RESISTANCE_POTION.resource_path,
		true,
		magic_potion_inventory_snapshot
	)
	_expect(
		client_player.potion_magic_defense_bonus == 15
		and is_equal_approx(
			client_player.potion_magic_defense_time_left,
			10.0
		),
		"death事件先于item-used到达时仍必须重放Host已接受的计时药水。"
	)
	client_player.is_dead = false
	_test_void_battery_snapshot_absolute_field()

	coordinator.unbind_session(session)
	_stop_audio_players(host_player)
	_stop_audio_players(client_player)
	host_player.queue_free()
	client_player.queue_free()
	net_manager.free()
	adapter.free()
	runtime.free()
	session.free()
	host_run_state.free()
	client_run_state.free()
	coordinator.free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	_finish()


func _test_void_battery_snapshot_absolute_field() -> void:
	var sender := SnapshotManager.new()
	var receiver := SnapshotManager.new()
	var state := SnapshotManager.PlayerState.new()
	state.peer_id = TEST_PEER_ID
	state.sequence = 1
	state.current_health = 50
	state.max_health = 50
	state.void_battery_charged = true
	var second_state := SnapshotManager.PlayerState.new()
	second_state.peer_id = TEST_PEER_ID + 1
	second_state.sequence = 1
	second_state.current_health = 50
	second_state.max_health = 50
	second_state.void_battery_charged = false
	var armed_packet := sender.encode_player_snapshots_for_peer(
		TEST_PEER_ID,
		[state, second_state],
		true
	)
	var armed_states := receiver.decode_player_snapshots_with_baseline(
		armed_packet
	)
	_expect(
		armed_states.size() == 2
		and armed_states[0].void_battery_charged,
		"多玩家PlayerState keyframe必须正确分隔并携带虚空充能绝对值。"
	)
	state.sequence = 2
	state.void_battery_charged = false
	second_state.sequence = 2
	second_state.void_battery_charged = true
	var discharged_packet := sender.encode_player_snapshots_for_peer(
		TEST_PEER_ID,
		[state, second_state],
		false
	)
	var discharged_states := receiver.decode_player_snapshots_with_baseline(
		discharged_packet
	)
	_expect(
		discharged_states.size() == 2
		and not discharged_states[0].void_battery_charged
		and discharged_states[1].void_battery_charged,
		"即使meta无变化，每帧Player delta也必须携带已消费的false绝对值。"
	)


func _find_item_slot_for_peer(
	run_state: RunStateStore,
	peer_id: int,
	expected_item: PickupConfig
) -> int:
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		if run_state.get_item_for_peer(peer_id, slot_index) == expected_item:
			return slot_index
	return -1


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("VOID_BATTERY_MULTIPLAYER_TRANSACTION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
