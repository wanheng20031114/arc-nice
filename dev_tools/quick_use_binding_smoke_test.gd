extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const BASIC_PROFILE_SCENE := preload(
	"res://scene/game_modes/standard/ui/standard_player_profile_panel.tscn"
)
const TOWER_PROFILE_SCENE := preload(
	"res://scene/game_modes/tower_defense/ui/tower_defense_player_profile_panel.tscn"
)
const HEALING_POTION: PickupConfig = preload(
	"res://resources/config/consumables/healing_potion.tres"
)
const ROCK_POTION: PickupConfig = preload(
	"res://resources/config/consumables/rock_potion.tres"
)
const WOOD: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)

const BASIC_PROFILE_SOURCE := (
	"res://scene/ui/shared/profile/basic_player_profile_panel.gd"
)
const TOWER_PROFILE_SOURCE := (
	"res://scene/game_modes/tower_defense/ui/tower_defense_player_profile_panel.gd"
)

var failures: Array[String] = []
var test_root: Node2D
var run_state: RunStateStore


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "QuickUseBindingSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	run_state = root.get_node("RunState") as RunStateStore

	_test_input_contract()
	_test_local_binding_lifecycle()
	_test_multiplayer_owner_lifecycle()
	await _test_basic_profile_singleplayer_dispatch()
	await _test_tower_profile_multiplayer_dispatch()

	current_scene = null
	test_root.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("QUICK_USE_BINDING_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_input_contract() -> void:
	_expect(InputMap.has_action("use_item"), "项目必须保留 use_item 输入映射。")
	for source_path in [BASIC_PROFILE_SOURCE, TOWER_PROFILE_SOURCE]:
		var source := FileAccess.get_file_as_string(source_path)
		_expect(
			source.contains('event.is_action_pressed("use_item")')
			and source.contains("_request_quick_use_item()")
			and source.contains("_on_inventory_item_use_requested(slot_index)"),
			"%s 必须把 use_item 接入既有背包使用入口。" % source_path
		)


func _test_local_binding_lifecycle() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var binding_events: Array[Dictionary] = []
	var on_binding_changed := func(
		owner_peer_id: int,
		config_path: String,
		preferred_slot_index: int
	) -> void:
		binding_events.append({
			"owner": owner_peer_id,
			"path": config_path,
			"slot": preferred_slot_index,
		})
	run_state.quick_use_binding_changed.connect(on_binding_changed)
	_expect(run_state.try_add_item(HEALING_POTION), "本地绑定测试必须加入治疗血瓶。")
	_expect(run_state.try_add_item(WOOD), "本地绑定测试必须加入木材。")
	var revision_before_binding := run_state.get_inventory_revision()
	_expect(
		not run_state.set_quick_use_binding(1)
		and run_state.set_quick_use_binding(0),
		"快捷绑定必须只接受未锁定消耗品。"
	)
	_expect(
		run_state.get_inventory_revision() == revision_before_binding
		and run_state.get_quick_use_bound_config_path() == HEALING_POTION.resource_path
		and run_state.get_quick_use_slot_index() == 0
		and run_state.is_quick_use_slot(0)
		and run_state.is_quick_use_item(HEALING_POTION),
		"设置绑定必须独立于背包 revision，并公开一致的路径、槽位和物品查询。"
	)
	var inventory_snapshot := run_state.export_inventory_snapshot()
	_expect(
		not inventory_snapshot.has("quick_use_binding")
		and not inventory_snapshot.has("quick_use_config_path"),
		"本地快捷偏好不得进入 Host 权威背包快照或网络协议。"
	)

	var move_revision := run_state.get_inventory_revision()
	_expect(
		run_state.move_item_stack_to_slot(0, 5, move_revision),
		"绑定跟随测试必须能把药水整栈移到新槽位。"
	)
	_expect(
		run_state.get_quick_use_slot_index() == 5
		and run_state.is_quick_use_slot(5)
		and not run_state.is_quick_use_slot(0),
		"快捷绑定必须在整栈移槽后重定位到新槽。"
	)

	var duplicate_revision := run_state.get_inventory_revision()
	_expect(
		run_state.try_add_item_count_to_slot_if_revision(
			HEALING_POTION,
			1,
			2,
			duplicate_revision
		),
		"重复药水栈测试必须在指定槽位建立第二栈。"
	)
	_expect(
		run_state.get_quick_use_slot_index() == 5,
		"首选槽仍持有绑定物品时不得跳到另一同类栈。"
	)
	var revision_before_preferred_switch := run_state.get_inventory_revision()
	_expect(
		run_state.toggle_quick_use_binding(2)
		and run_state.get_quick_use_slot_index() == 2
		and run_state.get_quick_use_bound_config_path() == HEALING_POTION.resource_path
		and run_state.get_inventory_revision() == revision_before_preferred_switch,
		"选择另一同类栈必须移动首选 marker，而不是取消类型绑定。"
	)
	_expect(
		run_state.toggle_quick_use_binding(5)
		and run_state.get_quick_use_slot_index() == 5,
		"再次选择非首选同类栈必须把 marker 移回该槽。"
	)
	var consume_preferred_revision := run_state.get_inventory_revision()
	_expect(
		run_state.try_consume_item_at_slot_if_revision(
			5,
			HEALING_POTION,
			consume_preferred_revision
		),
		"首选药水栈必须能通过 revision 事务消耗。"
	)
	_expect(
		run_state.get_quick_use_slot_index() == 2,
		"首选栈耗尽后必须确定性地迁移到最低的同类槽。"
	)
	var consume_last_revision := run_state.get_inventory_revision()
	_expect(
		run_state.try_consume_item_at_slot_if_revision(
			2,
			HEALING_POTION,
			consume_last_revision
		),
		"最后一瓶药水必须能正常消耗。"
	)
	_expect(
		run_state.get_quick_use_slot_index() == -1
		and run_state.get_quick_use_bound_config_path() == HEALING_POTION.resource_path,
		"绑定物品耗尽时必须进入休眠，而不是丢失物品身份。"
	)
	_expect(run_state.try_add_item(HEALING_POTION), "休眠恢复测试必须重新加入药水。")
	_expect(
		run_state.get_quick_use_slot_index() == 0,
		"重新获得休眠绑定物品后必须自动恢复到实际槽位。"
	)

	var revision_before_toggle := run_state.get_inventory_revision()
	_expect(
		run_state.toggle_quick_use_binding(0)
		and run_state.get_quick_use_bound_config_path().is_empty()
		and run_state.get_inventory_revision() == revision_before_toggle,
		"对已绑定物品执行 toggle 必须取消绑定且不推进 revision。"
	)
	_expect(
		run_state.toggle_quick_use_binding(0)
		and run_state.get_quick_use_slot_index() == 0
		and run_state.get_inventory_revision() == revision_before_toggle,
		"再次 toggle 必须恢复绑定且仍不推进 revision。"
	)
	_expect(binding_events.size() >= 3, "设置、取消和恢复绑定必须发布独立变更信号。")
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.get_quick_use_bound_config_path().is_empty()
		and run_state.get_quick_use_slot_index() == -1,
		"新一局必须清空上一局的快捷绑定。"
	)
	run_state.quick_use_binding_changed.disconnect(on_binding_changed)


func _test_multiplayer_owner_lifecycle() -> void:
	const OLD_PEER_ID := 21
	const NEW_PEER_ID := 31
	const RACING_OLD_PEER_ID := 51
	const RACING_NEW_PEER_ID := 61
	run_state.begin_new_run(&"weishidaier", false)
	run_state.ensure_multiplayer_peer_state(OLD_PEER_ID)
	_expect(
		run_state.try_add_item_for_peer(OLD_PEER_ID, ROCK_POTION),
		"多人绑定测试必须给旧 peer 加入岩石药水。"
	)
	var revision_before_binding := run_state.get_inventory_revision_for_peer(OLD_PEER_ID)
	_expect(
		run_state.set_quick_use_binding(0, OLD_PEER_ID)
		and run_state.get_inventory_revision_for_peer(OLD_PEER_ID) == revision_before_binding,
		"多人本地偏好绑定不得改变 Host 权威背包 revision。"
	)
	_expect(
		run_state.remap_multiplayer_peer_state(OLD_PEER_ID, NEW_PEER_ID)
		and run_state.get_quick_use_bound_config_path(OLD_PEER_ID).is_empty()
		and run_state.get_quick_use_bound_config_path(NEW_PEER_ID) == ROCK_POTION.resource_path
		and run_state.get_quick_use_slot_index(NEW_PEER_ID) == 0,
		"同进程重连 remap 必须把快捷绑定和实际背包一起迁移。"
	)
	run_state.set_active_multiplayer_peer(NEW_PEER_ID)
	_expect(
		run_state.get_quick_use_slot_index() == 0,
		"默认 owner 查询必须解析到当前 active multiplayer peer。"
	)
	run_state.ensure_multiplayer_peer_state(RACING_OLD_PEER_ID)
	run_state.ensure_multiplayer_peer_state(RACING_NEW_PEER_ID)
	_expect(
		run_state.try_add_item_for_peer(RACING_OLD_PEER_ID, ROCK_POTION)
		and run_state.set_quick_use_binding(0, RACING_OLD_PEER_ID)
		and run_state.try_add_item_for_peer(RACING_NEW_PEER_ID, HEALING_POTION),
		"重连乱序测试必须同时准备旧身份绑定与新身份权威背包。"
	)
	_expect(
		run_state.remap_multiplayer_peer_state(
			RACING_OLD_PEER_ID,
			RACING_NEW_PEER_ID,
			true,
			true
		)
		and run_state.get_quick_use_bound_config_path(RACING_OLD_PEER_ID).is_empty()
		and run_state.get_quick_use_bound_config_path(RACING_NEW_PEER_ID)
		== ROCK_POTION.resource_path
		and run_state.get_quick_use_slot_index(RACING_NEW_PEER_ID) == -1
		and run_state.get_item_for_peer(RACING_NEW_PEER_ID, 0) == HEALING_POTION,
		"较新的 new-peer 背包快照先到时必须保留该背包，同时迁移旧身份的本地快捷偏好为休眠绑定。"
	)
	run_state.prune_multiplayer_peer_states(PackedInt32Array())
	_expect(
		run_state.get_quick_use_bound_config_path(NEW_PEER_ID).is_empty(),
		"prune 已离开玩家时必须清理对应的本地快捷绑定。"
	)
	run_state.set_active_multiplayer_peer(0)


func _test_basic_profile_singleplayer_dispatch() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.try_add_item_count(HEALING_POTION, 2)
		and run_state.set_quick_use_binding(0),
		"单机输入分发测试必须准备绑定的治疗血瓶。"
	)
	var player := await _spawn_player()
	player.current_health = maxi(player.max_health - 40, 1)
	var profile := BASIC_PROFILE_SCENE.instantiate() as BasicPlayerProfilePanel
	test_root.add_child(profile)
	await process_frame
	profile.bind_player(player)
	var revision_before_ui_toggle := run_state.get_inventory_revision()
	profile.inventory_view.item_quick_use_toggle_requested.emit(0)
	_expect(
		run_state.get_quick_use_bound_config_path().is_empty()
		and run_state.get_inventory_revision() == revision_before_ui_toggle,
		"背包详情的快捷切换信号必须通过 ProfilePanel 取消绑定且不改 revision。"
	)
	profile.inventory_view.item_quick_use_toggle_requested.emit(0)
	_expect(
		run_state.get_quick_use_slot_index() == 0
		and run_state.get_inventory_revision() == revision_before_ui_toggle,
		"背包详情的快捷切换信号必须能通过 ProfilePanel 恢复绑定。"
	)
	var health_before := player.current_health
	profile.call("_unhandled_input", _make_quick_use_event())
	_expect(
		player.current_health == mini(health_before + 20, player.max_health)
		and run_state.get_item_count(0) == 1,
		"正常未锁定的单机 use_item 必须复用既有使用入口并只扣一瓶。"
	)
	player.set_controls_locked(true)
	var count_before_locked_request := run_state.get_item_count(0)
	_expect(
		not bool(profile.call("_request_quick_use_item"))
		and run_state.get_item_count(0) == count_before_locked_request,
		"玩家控制锁定时快捷输入必须拒绝且不消耗物品。"
	)
	player.set_controls_locked(false)
	player.set_world_movement_mode(true, false)
	_expect(
		not bool(profile.call("_request_quick_use_item"))
		and run_state.get_item_count(0) == count_before_locked_request,
		"路线移动模式必须在输入入口提前拒绝快捷使用。"
	)
	player.set_world_movement_mode(false, false)
	profile.queue_free()
	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame


func _test_tower_profile_multiplayer_dispatch() -> void:
	const PEER_ID := 41
	run_state.begin_new_run(&"weishidaier", false)
	run_state.ensure_multiplayer_peer_state(PEER_ID)
	run_state.set_active_multiplayer_peer(PEER_ID)
	_expect(
		run_state.try_add_item_count_for_peer(PEER_ID, ROCK_POTION, 2)
		and run_state.set_quick_use_binding(0, PEER_ID),
		"多人输入分发测试必须准备绑定的岩石药水。"
	)
	var player := await _spawn_player()
	player.configure_multiplayer_control(PEER_ID, true, "快捷使用测试")
	var profile := TOWER_PROFILE_SCENE.instantiate() as TowerDefensePlayerProfilePanel
	test_root.add_child(profile)
	await process_frame
	profile.configure_multiplayer_requests(true)
	profile.bind_player(player)
	var requested_slots: Array[int] = []
	profile.multiplayer_inventory_item_use_requested.connect(
		func(slot_index: int) -> void:
			requested_slots.append(slot_index)
	)
	var revision_before_request := run_state.get_inventory_revision_for_peer(PEER_ID)
	profile.call("_unhandled_input", _make_quick_use_event())
	_expect(
		requested_slots == [0],
		"多人快捷输入必须向既有权威事务入口只请求一次绑定槽。"
	)
	_expect(
		run_state.get_inventory_revision_for_peer(PEER_ID) == revision_before_request
		and run_state.get_item_count_for_peer(PEER_ID, 0) == 2,
		"客户端请求阶段不得本地扣除物品或推进背包 revision。"
	)
	profile.queue_free()
	_stop_audio_players(player)
	player.queue_free()
	run_state.set_active_multiplayer_peer(0)
	await process_frame
	await physics_frame


func _make_quick_use_event() -> InputEventAction:
	var event := InputEventAction.new()
	event.action = &"use_item"
	event.pressed = true
	return event


func _spawn_player() -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	await physics_frame
	player.set_physics_process(false)
	return player


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
