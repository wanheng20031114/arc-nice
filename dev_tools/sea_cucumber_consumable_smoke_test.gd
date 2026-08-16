extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TANGO_PLAYER_SCENE := preload(
	"res://scene/player/tango/player_tango.tscn"
)
const TRANSACTIONS_SCENE := preload(
	"res://scene/multiplayer/transactions/mp_transactions_coordinator.tscn"
)
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const SEA_CUCUMBER: PickupConfig = preload(
	"res://resources/config/consumables/sea_cucumber.tres"
)
const HIDE_PIXELS_PARAMETER := &"hide_pixels"


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
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	_test_resource_contract()

	var fixture := Node2D.new()
	fixture.name = "SeaCucumberConsumableSmokeTest"
	root.add_child(fixture)
	var player := PLAYER_SCENE.instantiate() as Player
	var other_player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	fixture.add_child(other_player)
	await process_frame
	await physics_frame
	player.set_physics_process(false)
	other_player.set_physics_process(false)

	var player_material := player.body_sprite.material as ShaderMaterial
	var other_material := other_player.body_sprite.material as ShaderMaterial
	_expect(
		player_material != null
		and other_material != null
		and player_material != other_material
		and not bool(player_material.get_shader_parameter(HIDE_PIXELS_PARAMETER))
		and not bool(other_material.get_shader_parameter(HIDE_PIXELS_PARAMETER)),
		"玩家场景必须为每个实例提供默认可见的本地状态材质。"
	)
	await _test_complete_player_visual_hide(fixture)
	await _test_exit_tree_visual_restore(fixture)

	_expect(
		run_state.try_add_item_count(SEA_CUCUMBER, 2),
		"海参必须能以消耗品堆叠进入背包。"
	)
	var slot_index := _find_local_item_slot(run_state, SEA_CUCUMBER)
	var revision_before_use := run_state.get_inventory_revision()
	_expect(
		slot_index >= 0
		and run_state.try_use_item(slot_index, player)
		and run_state.get_inventory_revision() == revision_before_use + 1
		and run_state.get_item_count(slot_index) == 1,
		"首次使用海参必须只消费一个并单步推进背包 revision。"
	)
	_expect(
		player.is_hidden_by_consumable()
		and is_equal_approx(player.potion_hide_time_left, 5.0)
		and not player.visible
		and other_player.visible
		and bool(player_material.get_shader_parameter(HIDE_PIXELS_PARAMETER))
		and not bool(other_material.get_shader_parameter(HIDE_PIXELS_PARAMETER)),
		"海参必须只隐藏使用者的完整玩家视觉，不能污染同场景其他玩家。"
	)

	player.call("_update_potion_effects", 2.0)
	_expect(
		is_equal_approx(player.potion_hide_time_left, 3.0)
		and run_state.try_use_item(slot_index, player)
		and is_equal_approx(player.potion_hide_time_left, 5.0)
		and not player.visible,
		"合法的第二次使用必须刷新五秒计时、保持隐藏并再消费一个。"
	)
	var revision_after_stack_consumed := run_state.get_inventory_revision()
	_expect(
		not run_state.try_use_item(slot_index, player)
		and run_state.get_inventory_revision() == revision_after_stack_consumed
		and is_equal_approx(player.potion_hide_time_left, 5.0),
		"空槽重复请求必须幂等拒绝，不能推进 revision 或篡改计时。"
	)
	player.call("_update_potion_effects", 5.1)
	_expect(
		not player.is_hidden_by_consumable()
		and player.visible
		and not bool(player_material.get_shader_parameter(HIDE_PIXELS_PARAMETER)),
		"五秒到期后必须稳定恢复完整玩家视觉。"
	)

	player.call("_set_nameplate_layer_visible", true)
	player.apply_multiplayer_death_state()
	_expect(
		not player.apply_pickup(SEA_CUCUMBER)
		and player.apply_inventory_item_use_replay(SEA_CUCUMBER)
		and player.is_hidden_by_consumable()
		and not player.visible
		and bool(player_material.get_shader_parameter(HIDE_PIXELS_PARAMETER)),
		"死亡玩家必须拒绝新使用，但仍重放跨频道到达的 Host 已确认计时效果。"
	)
	player.apply_permanent_death_presentation()
	_expect(
		not player.nameplate_layer.visible,
		"隐身期间进入永久死亡表现必须更新名牌的待恢复状态。"
	)
	player.call("_update_potion_effects", 5.1)
	_expect(
		not player.is_hidden_by_consumable()
		and player.visible
		and not player.nameplate_layer.visible
		and not bool(player_material.get_shader_parameter(HIDE_PIXELS_PARAMETER)),
		"永久死亡期间到期必须恢复根渲染状态，但不能错误重现已隐藏的名牌。"
	)
	player.revive_multiplayer(Vector2.ZERO)
	_expect(
		not player.is_hidden_by_consumable()
		and player.visible
		and not bool(player_material.get_shader_parameter(HIDE_PIXELS_PARAMETER)),
		"死亡期间到期的隐身必须在复活后保持恢复，不能残留隐藏材质状态。"
	)

	player.world_movement_mode = true
	_expect(
		not player.apply_inventory_item_use_replay(SEA_CUCUMBER)
		and not player.is_hidden_by_consumable(),
		"路线/场景切换模式必须按既有规则拒绝消耗品效果重放。"
	)
	player.world_movement_mode = false

	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame
	var replacement := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(replacement)
	await process_frame
	await physics_frame
	replacement.set_physics_process(false)
	var replacement_material := replacement.body_sprite.material as ShaderMaterial
	_expect(
		replacement_material != null
		and replacement.visible
		and not bool(
			replacement_material.get_shader_parameter(HIDE_PIXELS_PARAMETER)
		),
		"切换场景后新玩家必须从默认可见材质状态开始。"
	)
	await _test_multiplayer_transactions(fixture)

	_stop_audio_players(other_player)
	_stop_audio_players(replacement)
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	_finish()


func _test_complete_player_visual_hide(fixture: Node2D) -> void:
	var tango := TANGO_PLAYER_SCENE.instantiate() as Player
	fixture.add_child(tango)
	await process_frame
	await physics_frame
	tango.set_physics_process(false)
	var casting_units := tango.get_node("CastingUnits") as Node2D
	var unit_a := tango.get_node("CastingUnits/UnitA") as AnimatedSprite2D
	var unit_b := tango.get_node("CastingUnits/UnitB") as AnimatedSprite2D
	var unit_c := tango.get_node("CastingUnits/UnitC") as AnimatedSprite2D
	var trail := tango.get_node("MoveSpeedTrailEffect") as Node2D
	var dash_indicator := tango.get_node("DashReadyIndicator") as Control
	var runtime_effect := Polygon2D.new()
	runtime_effect.polygon = PackedVector2Array([
		Vector2(-2.0, -2.0),
		Vector2(2.0, -2.0),
		Vector2(0.0, 2.0),
	])
	tango.add_child(runtime_effect)
	tango.call("_set_speed_trail_effect_active", true)
	tango.call("_set_nameplate_layer_visible", true)
	var material := tango.body_sprite.material as ShaderMaterial
	var collision_was_disabled := tango.collision_shape.disabled
	_expect(
		tango.visible
		and casting_units.visible
		and unit_a.is_visible_in_tree()
		and unit_b.is_visible_in_tree()
		and unit_c.is_visible_in_tree()
		and trail.is_visible_in_tree()
		and dash_indicator.is_visible_in_tree()
		and runtime_effect.is_visible_in_tree()
		and tango.night_light.is_visible_in_tree()
		and tango.nameplate_layer.visible,
		"Tango 完整视觉隐藏测试必须从可见的角色、常驻机组与反馈节点开始。"
	)
	_expect(tango.apply_pickup(SEA_CUCUMBER), "Tango 必须能使用海参。")
	_expect(
		material != null
		and bool(material.get_shader_parameter(HIDE_PIXELS_PARAMETER))
		and not tango.visible
		and casting_units.visible
		and unit_a.visible
		and unit_b.visible
		and unit_c.visible
		and trail.visible
		and dash_indicator.visible
		and runtime_effect.visible
		and not unit_a.is_visible_in_tree()
		and not unit_b.is_visible_in_tree()
		and not unit_c.is_visible_in_tree()
		and not trail.is_visible_in_tree()
		and not dash_indicator.is_visible_in_tree()
		and not runtime_effect.is_visible_in_tree()
		and not tango.night_light.is_visible_in_tree()
		and not tango.nameplate_layer.visible
		and tango.collision_shape.disabled == collision_was_disabled,
		"隐身必须覆盖 Tango 常驻机组、拖尾、冲刺提示、灯光和运行时子特效，同时保留各节点自身状态与碰撞。"
	)
	tango.call("_update_potion_effects", 2.0)
	_expect(
		is_equal_approx(tango.potion_hide_time_left, 3.0)
		and tango.apply_pickup(SEA_CUCUMBER)
		and is_equal_approx(tango.potion_hide_time_left, 5.0)
		and not tango.visible,
		"重复使用海参必须只刷新计时，不能提前恢复玩家视觉。"
	)
	tango.call("_update_multiplayer_nameplate_text", 3)
	_expect(
		not tango.nameplate_layer.visible,
		"隐身期间死亡倒计时更新不能让独立 CanvasLayer 名牌泄露像素。"
	)
	tango.call("_update_potion_effects", 5.1)
	_expect(
		not tango.is_hidden_by_consumable()
		and tango.visible
		and not bool(material.get_shader_parameter(HIDE_PIXELS_PARAMETER))
		and unit_a.is_visible_in_tree()
		and unit_b.is_visible_in_tree()
		and unit_c.is_visible_in_tree()
		and trail.is_visible_in_tree()
		and dash_indicator.is_visible_in_tree()
		and runtime_effect.is_visible_in_tree()
		and tango.night_light.is_visible_in_tree()
		and tango.nameplate_layer.visible
		and tango.collision_shape.disabled == collision_was_disabled,
		"到期必须原样恢复 Tango 的完整视觉、运行时子特效和最新名牌状态。"
	)
	tango.call("_set_speed_trail_effect_active", false)
	_stop_audio_players(tango)
	tango.queue_free()
	await process_frame
	await physics_frame


func _test_exit_tree_visual_restore(fixture: Node2D) -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	await process_frame
	await physics_frame
	player.set_physics_process(false)
	player.call("_set_nameplate_layer_visible", true)
	player.visible = false
	var material := player.body_sprite.material as ShaderMaterial
	_expect(
		player.apply_pickup(SEA_CUCUMBER)
		and bool(material.get_shader_parameter(HIDE_PIXELS_PARAMETER)),
		"退出树恢复测试必须先激活海参隐藏 shader。"
	)
	_stop_audio_players(player)
	fixture.remove_child(player)
	_expect(
		not player.is_hidden_by_consumable()
		and not player.visible
		and player.nameplate_layer.visible
		and not bool(material.get_shader_parameter(HIDE_PIXELS_PARAMETER)),
		"退出场景树必须恢复玩家原有隐藏状态与名牌状态，不能粗暴设置 visible=true。"
	)
	player.free()


func _test_resource_contract() -> void:
	_expect(
		SEA_CUCUMBER.is_consumable_item()
		and SEA_CUCUMBER.display_name == "海参"
		and SEA_CUCUMBER.description
		== "使用后隐去玩家显示，持续5秒；碰撞、操作与战斗状态保持不变。"
		and SEA_CUCUMBER.can_store_in_inventory
		and SEA_CUCUMBER.stackable
		and SEA_CUCUMBER.potion_hides_player
		and is_equal_approx(SEA_CUCUMBER.duration, 5.0)
		and SEA_CUCUMBER.icon_texture != null
		and SEA_CUCUMBER.icon_texture.resource_path
		== "res://resources/texture/consumables/sea_cucumber.png",
		"海参资源必须声明约定名称、文案、图标与五秒隐藏效果。"
	)


func _test_multiplayer_transactions(fixture: Node2D) -> void:
	const PEER_ID := 71
	var coordinator := (
		TRANSACTIONS_SCENE.instantiate() as MpTransactionsCoordinator
	)
	var session := MP_GAME_SCENE.instantiate() as MultiplayerGameplaySession
	var runtime := TestRuntime.new()
	var adapter := MultiplayerModeAdapter.new()
	var net_manager := NetManagerStore.new()
	var host_run_state := RunStateStore.new()
	host_run_state.begin_new_run(&"weishidaier", false)
	var suspended_peers: Dictionary[int, bool] = {}
	var host_player := PLAYER_SCENE.instantiate() as Player
	root.add_child(net_manager)
	fixture.add_child(host_player)
	await process_frame
	await physics_frame
	host_player.set_physics_process(false)
	runtime.players[PEER_ID] = host_player
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
		host_run_state.register_multiplayer_peer_state(PEER_ID),
		"Host 海参事务测试必须先注册玩家背包账本。"
	)
	_expect(
		host_run_state.try_add_item_count_for_peer(
			PEER_ID,
			SEA_CUCUMBER,
			2
		),
		"Host 海参事务测试必须建立两个消耗品。"
	)
	var slot_index := _find_peer_item_slot(
		host_run_state,
		PEER_ID,
		SEA_CUCUMBER
	)
	var expected_revision := host_run_state.get_inventory_revision_for_peer(
		PEER_ID
	)
	coordinator.apply_authoritative_inventory_item_use(
		PEER_ID,
		slot_index,
		expected_revision
	)
	_expect(
		broadcasts.size() == 1
		and bool(broadcasts[0].get("success", false))
		and str(broadcasts[0].get("config_path", ""))
		== SEA_CUCUMBER.resource_path
		and host_run_state.get_item_count_for_peer(PEER_ID, slot_index) == 1
		and host_player.is_hidden_by_consumable()
		and is_equal_approx(host_player.potion_hide_time_left, 5.0),
		"Host 必须权威扣除一个海参、应用一次隐藏并广播新 revision。"
	)
	var successful_snapshot := (
		broadcasts[0].get("inventory_snapshot", {}) as Dictionary
	).duplicate(true)
	host_player.call("_update_potion_effects", 2.0)
	coordinator.apply_authoritative_inventory_item_use(
		PEER_ID,
		slot_index,
		expected_revision
	)
	_expect(
		broadcasts.size() == 2
		and not bool(broadcasts[1].get("success", true))
		and bool(broadcasts[1].get("force_inventory_repair", false))
		and host_run_state.get_item_count_for_peer(PEER_ID, slot_index) == 1
		and is_equal_approx(host_player.potion_hide_time_left, 3.0),
		"Host 必须幂等拒绝旧 revision，不能重复扣除或刷新隐身。"
	)
	coordinator.unbind_session(session)

	var client_run_state := RunStateStore.new()
	client_run_state.begin_new_run(&"weishidaier", false)
	var client_player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(client_player)
	await process_frame
	await physics_frame
	client_player.set_physics_process(false)
	runtime.players[PEER_ID] = client_player
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	coordinator.bind_session(
		session,
		runtime,
		adapter,
		net_manager,
		client_run_state,
		suspended_peers
	)
	_expect(
		client_run_state.register_multiplayer_peer_state(PEER_ID),
		"客户端海参事务测试必须先注册玩家背包账本。"
	)
	coordinator.receive_inventory_item_used(
		PEER_ID,
		slot_index,
		SEA_CUCUMBER.resource_path,
		true,
		successful_snapshot
	)
	_expect(
		client_player.is_hidden_by_consumable()
		and is_equal_approx(client_player.potion_hide_time_left, 5.0)
		and client_run_state.get_item_count_for_peer(PEER_ID, slot_index) == 1,
		"客户端必须在新 revision 首次到达时只重放一次海参效果。"
	)
	client_player.call("_update_potion_effects", 2.0)
	coordinator.receive_inventory_item_used(
		PEER_ID,
		slot_index,
		SEA_CUCUMBER.resource_path,
		true,
		successful_snapshot
	)
	_expect(
		is_equal_approx(client_player.potion_hide_time_left, 3.0)
		and client_run_state.get_item_count_for_peer(PEER_ID, slot_index) == 1,
		"客户端重复收到同 revision 时不得二次重放或刷新隐身。"
	)
	coordinator.unbind_session(session)
	_stop_audio_players(host_player)
	_stop_audio_players(client_player)
	host_player.free()
	client_player.free()
	net_manager.free()
	adapter.free()
	runtime.free()
	session.free()
	host_run_state.free()
	client_run_state.free()
	coordinator.free()


func _find_local_item_slot(
	run_state: RunStateStore,
	expected_item: PickupConfig
) -> int:
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		if run_state.get_item(slot_index) == expected_item:
			return slot_index
	return -1


func _find_peer_item_slot(
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
		print("SEA_CUCUMBER_CONSUMABLE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
