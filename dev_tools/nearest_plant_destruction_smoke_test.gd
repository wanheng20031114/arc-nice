extends SceneTree

const TILE_SIZE := 16.0
const DESTRUCTION_RADIUS_CELLS := 3.0
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const SIMPLE_FENCE_CONFIG := preload(
	"res://resources/config/plant_defense/simple_fence.tres"
)
const PROJECT_SOURCE_PATH := "res://project.godot"
const TOWER_GAME_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.gd"
)
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")


class QueryProbePlantSystem:
	extends PlantSystem

	func register_probe_plant(
		plant: PlantDefense,
		cell: Vector2i,
		config: PlantDefenseConfig
	) -> void:
		_register_plant_footprint(plant, [cell], config)

	func get_complete_index_membership_count() -> int:
		return int(
			get_plant_target_spatial_index_metrics().get(
				"membership_count",
				-1
			)
		)


class HostNetManager:
	extends NetManagerStore

	func is_host() -> bool:
		return true

	func is_client() -> bool:
		return false

	func get_local_peer_id() -> int:
		return 1


class AlwaysAdmitTransactions:
	extends MpTransactionsCoordinator

	func consume_remote_transaction_admission(
		peer_id: int,
		_now_seconds: float = -1.0
	) -> bool:
		return peer_id > 0


class AuthorityProbeAdapter:
	extends TowerDefenseMultiplayerModeAdapter

	var authority_requests: Array[Dictionary] = []

	func request_authoritative_nearest_plant_destruction(
		requester_peer_id: int,
		target_net_id: int
	) -> bool:
		authority_requests.append({
			"peer_id": requester_peer_id,
			"target_net_id": target_net_id,
		})
		return true

	func supports_terrain_state() -> bool:
		return true


var failures: Array[String] = []
var fixture: Node2D = null
var tile_map: TileMapLayer = null
var plant_container: Node2D = null
var plant_system: QueryProbePlantSystem = null
var player: Player = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_static_input_and_rpc_contracts()
	_build_plant_fixture()
	_test_complete_index_radius_and_one_shot_destruction()
	_test_dead_removing_and_stable_net_id_selection()
	_test_runtime_authority_guards()
	_test_world_host_request_order_and_rate_limit()

	if fixture != null and is_instance_valid(fixture):
		fixture.queue_free()
	if player != null and is_instance_valid(player):
		player.free()
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("NEAREST_PLANT_DESTRUCTION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_static_input_and_rpc_contracts() -> void:
	var project_source := FileAccess.get_file_as_string(PROJECT_SOURCE_PATH).replace(
		"\r\n",
		"\n"
	)
	_expect(
		project_source.contains("\ndelete={\n")
		and project_source.contains("\"physical_keycode\":4194312"),
		"project.godot 必须保留已配置的 delete 输入动作及 Delete 实体键。"
	)

	var tower_game_source := FileAccess.get_file_as_string(
		TOWER_GAME_SOURCE_PATH
	).replace("\r\n", "\n")
	_expect(
		tower_game_source.contains(
			"event.is_action_pressed(&\"delete\")"
		)
		and tower_game_source.contains("key_event.echo")
		and tower_game_source.contains(
			"not plant_placement_coordinator.has_exclusive_modal_open()"
		)
		and tower_game_source.contains(
			"not plant_placement_controller.is_active()"
		)
		and tower_game_source.contains(
			"tower_multiplayer_mode_adapter.request_nearest_plant_destruction()"
		),
		"正式塔防 delete 输入必须过滤键盘 echo，并受模态与放置状态门禁后委托多人适配器。"
	)

	var mp_game_source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH).replace(
		"\r\n",
		"\n"
	)
	_expect(
		mp_game_source.contains(
			"@rpc(\"any_peer\", \"call_remote\", \"reliable\", 5)\n"
			+ "func net_nearest_plant_destruction_requested("
		)
		and mp_game_source.contains(
			"tower_world_coordinator.handle_remote_nearest_plant_destruction_request("
		)
		and mp_game_source.contains(
			"&\"net_nearest_plant_destruction_requested\""
		),
		"MpGame 必须用可靠 RPC 将 delete 请求双向委托给 TowerWorldCoordinator。"
	)


func _build_plant_fixture() -> void:
	fixture = Node2D.new()
	fixture.name = "NearestPlantDestructionSmokeTest"
	root.add_child(fixture)

	tile_map = TileMapLayer.new()
	tile_map.name = "GroundTileMapLayer"
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(int(TILE_SIZE), int(TILE_SIZE))
	tile_map.tile_set = tile_set
	fixture.add_child(tile_map)

	plant_container = Node2D.new()
	plant_container.name = "PlantContainer"
	fixture.add_child(plant_container)

	plant_system = QueryProbePlantSystem.new()
	plant_system.name = "PlantSystem"
	fixture.add_child(plant_system)
	plant_system.setup(
		tile_map,
		null,
		plant_container,
		Rect2i(-256, -256, 512, 512)
	)

	player = Player.new()
	player.is_dead = false


func _test_complete_index_radius_and_one_shot_destruction() -> void:
	var center_cell := Vector2i.ZERO
	var center_world := _cell_world(center_cell)
	var nearest_fence := _add_plant(
		&"NearestContactOnlyFence",
		center_cell + Vector2i.RIGHT,
		31,
		SIMPLE_FENCE_CONFIG
	)
	var second_agave := _add_plant(
		&"SecondAgave",
		center_cell + Vector2i(2, 0),
		32,
		AGAVE_CONFIG
	)
	var boundary_agave := _add_plant(
		&"BoundaryAgave",
		center_cell + Vector2i(3, 0),
		33,
		AGAVE_CONFIG
	)
	var outside_agave := _add_plant(
		&"OutsideAgave",
		center_cell + Vector2i(4, 0),
		34,
		AGAVE_CONFIG
	)

	_expect(
		plant_system.find_nearest_enemy_objective(
			center_world,
			DESTRUCTION_RADIUS_CELLS
		) == second_agave
		and plant_system.find_nearest_living_plant_in_logical_radius(
			center_world,
			DESTRUCTION_RADIUS_CELLS
		) == nearest_fence,
		"销毁查询必须使用全建筑索引：CONTACT_ONLY 围栏也必须比主动交战塔优先入选。"
	)
	_expect(
		plant_system.get_complete_index_membership_count() == 4,
		"完整建筑空间索引必须登记范围内外的全部四座建筑。"
	)

	var runtime_coordinator := TowerDefensePlantRuntimeCoordinator.new()
	runtime_coordinator.setup(
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
		null,
		null,
		plant_system,
		null
	)
	player.global_position = center_world
	_expect(
		runtime_coordinator.destroy_nearest_plant_for_player(player),
		"第一次 delete 权威执行必须成功。"
	)
	_expect(
		nearest_fence.is_dead
		and nearest_fence.current_health == 0
		and second_agave.current_health > 0
		and boundary_agave.current_health > 0,
		"单次 delete 只能销毁最近的一座建筑，不能批量伤害后续建筑。"
	)

	_expect(
		runtime_coordinator.destroy_nearest_plant_for_player(player),
		"第二次 delete 必须继续销毁下一个最近建筑。"
	)
	_expect(
		second_agave.is_dead
		and boundary_agave.current_health > 0
		and outside_agave.current_health > 0,
		"第二次 delete 才能销毁第二座建筑，3格边界与范围外建筑必须保持完整。"
	)
	_expect(
		plant_system.find_nearest_living_plant_in_logical_radius(
			center_world,
			DESTRUCTION_RADIUS_CELLS
		) == boundary_agave,
		"精确3格边界必须按闭区间纳入最近建筑查询。"
	)
	boundary_agave.is_dead = true
	_expect(
		plant_system.find_nearest_living_plant_in_logical_radius(
			center_world,
			DESTRUCTION_RADIUS_CELLS
		) == null
		and outside_agave.current_health > 0,
		"范围内候选失效后，4格外建筑不得被 delete 查询越界选中。"
	)
	runtime_coordinator.free()


func _test_dead_removing_and_stable_net_id_selection() -> void:
	var lifecycle_center := Vector2i(0, 20)
	var dead_nearest := _add_plant(
		&"DeadNearest",
		lifecycle_center,
		201,
		AGAVE_CONFIG
	)
	var removing_second := _add_plant(
		&"RemovingSecond",
		lifecycle_center + Vector2i.RIGHT,
		202,
		AGAVE_CONFIG
	)
	var living_third := _add_plant(
		&"LivingThird",
		lifecycle_center + Vector2i(2, 0),
		203,
		AGAVE_CONFIG
	)
	dead_nearest.is_dead = true
	removing_second.is_removing = true
	_expect(
		plant_system.find_nearest_living_plant_in_logical_radius(
			_cell_world(lifecycle_center),
			DESTRUCTION_RADIUS_CELLS
		) == living_third,
		"死亡与 removing 建筑即使尚留在空间索引中，也必须从 delete 候选过滤。"
	)

	var tie_center := Vector2i(0, 40)
	var higher_id_left := _add_plant(
		&"TieHigherIdLeft",
		tie_center + Vector2i.LEFT,
		20,
		AGAVE_CONFIG
	)
	var lower_id_right := _add_plant(
		&"TieLowerIdRight",
		tie_center + Vector2i.RIGHT,
		10,
		AGAVE_CONFIG
	)
	for _repeat_index in range(8):
		_expect(
			plant_system.find_nearest_living_plant_in_logical_radius(
				_cell_world(tie_center),
				DESTRUCTION_RADIUS_CELLS
			) == lower_id_right,
			"等距联机建筑必须始终选择更小 net_id，不能受索引遍历顺序影响。"
		)
	_expect(
		higher_id_left.current_health > 0,
		"等距稳定选择测试不得误伤较大 net_id 建筑。"
	)


func _test_runtime_authority_guards() -> void:
	var host_center := Vector2i(0, 60)
	var host_target := _add_plant(
		&"HostExpectedTarget",
		host_center + Vector2i.RIGHT,
		501,
		AGAVE_CONFIG
	)
	player.global_position = _cell_world(host_center)
	var host_coordinator := TowerDefensePlantRuntimeCoordinator.new()
	host_coordinator.setup(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		null,
		null,
		plant_system,
		null
	)
	var host_health_before := host_target.current_health
	_expect(
		not host_coordinator.destroy_nearest_plant_for_player(player, 999)
		and host_target.current_health == host_health_before,
		"Host 必须拒绝与权威最近目标不一致的 expected net_id，且不得扣血。"
	)
	_expect(
		host_coordinator.destroy_nearest_plant_for_player(player, 501)
		and host_target.is_dead,
		"Host 只应在 expected net_id 与重新计算结果一致时销毁建筑。"
	)
	host_coordinator.free()

	var client_center := Vector2i(0, 80)
	var client_target := _add_plant(
		&"ClientViewTarget",
		client_center + Vector2i.RIGHT,
		601,
		AGAVE_CONFIG
	)
	player.global_position = _cell_world(client_center)
	var client_coordinator := TowerDefensePlantRuntimeCoordinator.new()
	client_coordinator.setup(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		null,
		null,
		plant_system,
		null
	)
	var client_health_before := client_target.current_health
	_expect(
		not client_coordinator.destroy_nearest_plant_for_player(player, 601)
		and client_target.current_health == client_health_before
		and not client_target.is_dead,
		"CLIENT_VIEW 运行态不得自行扣血或销毁建筑。"
	)
	client_coordinator.free()


func _test_world_host_request_order_and_rate_limit() -> void:
	var session := MP_GAME_SCENE.instantiate() as MultiplayerGameplaySession
	var session_coordinator := MpSessionCoordinator.new()
	var runtime := TowerDefenseGame.new()
	var adapter := AuthorityProbeAdapter.new()
	var net_manager := HostNetManager.new()
	var transactions := AlwaysAdmitTransactions.new()
	var enemy_coordinator := MpEnemyCoordinator.new()
	var tower_economy := MpTowerEconomyCoordinator.new()
	var world := MpTowerWorldCoordinator.new()
	world.bind_session(
		session,
		session_coordinator,
		runtime,
		adapter,
		net_manager,
		transactions,
		enemy_coordinator,
		tower_economy
	)

	world.handle_remote_nearest_plant_destruction_request(2, 1, 701)
	world.handle_remote_nearest_plant_destruction_request(2, 1, 702)
	world.handle_remote_nearest_plant_destruction_request(2, 0, 703)
	world.handle_remote_nearest_plant_destruction_request(2, 2, 704)
	world.handle_remote_nearest_plant_destruction_request(3, 1, 705)
	_expect(
		adapter.authority_requests == [
			{"peer_id": 2, "target_net_id": 701},
			{"peer_id": 2, "target_net_id": 704},
			{"peer_id": 3, "target_net_id": 705},
		],
		"World Host 必须拒绝重复/非递增 request_id，并按请求 peer 独立转交权威 adapter。"
	)

	world.reset_session_state()
	adapter.authority_requests.clear()
	var destruction_burst := int(
		MpTowerWorldCoordinator.PLANT_DESTRUCTION_RATE_BURST
	)
	for request_id in range(
		1,
		destruction_burst + 2
	):
		world.handle_remote_nearest_plant_destruction_request(
			7,
			request_id,
			800 + request_id
		)
	world.handle_remote_nearest_plant_destruction_request(8, 1, 901)
	_expect(
		adapter.authority_requests.size()
		== destruction_burst + 1
		and adapter.authority_requests.back() == {
			"peer_id": 8,
			"target_net_id": 901,
		},
		"单个 peer 超过销毁突发上限时必须被限流，另一 peer 仍应拥有独立额度。"
	)

	world.unbind_session(session)
	world.free()
	tower_economy.free()
	enemy_coordinator.free()
	transactions.free()
	net_manager.free()
	adapter.free()
	runtime.free()
	session_coordinator.free()
	session.free()


func _add_plant(
	plant_name: StringName,
	cell: Vector2i,
	net_id: int,
	config: PlantDefenseConfig
) -> PlantDefense:
	var plant: PlantDefense = null
	if config.uses_cardinal_connections():
		var cardinal_plant := CardinalConnectedPlant.new()
		for sprite_name in [&"Sprite2D", &"ConnectorRight", &"ConnectorDown"]:
			var sprite := Sprite2D.new()
			sprite.name = sprite_name
			cardinal_plant.add_child(sprite)
		plant = cardinal_plant
	else:
		plant = PlantDefense.new()
	plant.name = plant_name
	plant_container.add_child(plant)
	plant.global_position = _cell_world(cell)
	plant.setup(config, null, [cell], false, 100, 0, 100, false)
	plant.set_meta(&"net_id", net_id)
	plant_system.register_probe_plant(plant, cell, config)
	return plant


func _cell_world(cell: Vector2i) -> Vector2:
	return tile_map.to_global(tile_map.map_to_local(cell))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
