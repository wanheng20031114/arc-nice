extends SceneTree

const QueryFacade := preload(
	"res://scene/combat/targeting/combat_query_facade.gd"
)
const Descriptor := preload(
	"res://scene/combat/targeting/combat_target_descriptor.gd"
)
const Relations := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)
const RuntimeFixture := preload(
	"res://dev_tools/fixtures/combat_runtime_test_fixture.gd"
)

class PlantPort:
	extends RefCounted

	var plants_by_id: Dictionary[int, PlantDefense] = {}
	var ids_by_instance: Dictionary[int, int] = {}


	func add(net_id: int, plant: PlantDefense) -> void:
		plants_by_id[net_id] = plant
		ids_by_instance[plant.get_instance_id()] = net_id


	func resolve(net_id: int) -> PlantDefense:
		return plants_by_id.get(net_id) as PlantDefense


	func get_id(plant: PlantDefense) -> int:
		return int(ids_by_instance.get(plant.get_instance_id(), 0))


	func query_radius_into(
		center: Vector2,
		radius: float,
		result: Array[PlantDefense]
	) -> void:
		result.clear()
		var radius_squared := radius * radius
		for net_id_variant in plants_by_id:
			var plant := plants_by_id[net_id_variant] as PlantDefense
			if center.distance_squared_to(plant.global_position) <= radius_squared:
				result.append(plant)


	func query_aabb_into(
		world_aabb: Rect2,
		result: Array[PlantDefense]
	) -> void:
		result.clear()
		for net_id_variant in plants_by_id:
			var plant := plants_by_id[net_id_variant] as PlantDefense
			if world_aabb.has_point(plant.global_position):
				result.append(plant)


var failures: Array[String] = []
var _runtime: CombatRuntimeTestFixture
var _facade: CombatQueryFacade
var _plant_port: PlantPort
var _local_player: Player
var _peer_player: Player
var _plant: PlantDefense
var _allied_enemy: Enemy
var _friendly_enemy: Enemy
var _custom_enemy: Enemy


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_setup_fixture()
	_test_describe_and_resolve()
	_test_default_hostile_radius_and_exclusion()
	_test_custom_directional_relation()
	_test_aabb_enumeration_and_stable_order()
	_cleanup_fixture()
	if failures.is_empty():
		print("COMBAT_QUERY_FACADE_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _setup_fixture() -> void:
	_runtime = RuntimeFixture.new()
	_runtime.multiplayer_local_peer_id = 1
	_local_player = Player.new()
	_local_player.position = Vector2(10.0, 0.0)
	_peer_player = Player.new()
	_peer_player.position = Vector2(20.0, 0.0)
	_runtime.player = _local_player
	_runtime.peer_players = {1: _local_player, 2: _peer_player}

	_plant = PlantDefense.new()
	_plant.position = Vector2(12.0, 0.0)
	_plant.set_meta(&"net_id", 201)
	_plant_port = PlantPort.new()
	_plant_port.add(201, _plant)

	_allied_enemy = _new_enemy(Vector2(15.0, 0.0), Relations.PLAYER_ALLIED)
	_friendly_enemy = _new_enemy(Vector2(6.0, 0.0), Relations.HOSTILE_WAVE)
	_custom_enemy = _new_enemy(Vector2(8.0, 0.0), 3)
	_runtime.combat_target_index.register_enemy(101, _allied_enemy)
	_runtime.combat_target_index.register_enemy(102, _friendly_enemy)
	_runtime.combat_target_index.register_enemy(103, _custom_enemy)

	_facade = QueryFacade.new(_runtime)
	_expect(
		_facade.bind_plant_query_port(
			Callable(_plant_port, &"resolve"),
			Callable(_plant_port, &"query_radius_into"),
			Callable(_plant_port, &"query_aabb_into"),
			Callable(_plant_port, &"get_id")
		),
		"植物解析/查询端口必须以显式 Callable 成功注入。"
	)


func _new_enemy(world_position: Vector2, faction_id: int) -> Enemy:
	var enemy := Enemy.new()
	enemy.position = world_position
	enemy.combat_faction_id = faction_id
	return enemy


func _test_describe_and_resolve() -> void:
	var player_descriptor := _facade.describe_target(_peer_player, 4)
	var plant_descriptor := _facade.describe_target(_plant, 5)
	var enemy_descriptor := _facade.describe_target(_allied_enemy, 6)
	_expect(
		player_descriptor != null
		and player_descriptor.kind == Descriptor.Kind.PLAYER
		and player_descriptor.id == 2
		and player_descriptor.revision == 4
		and plant_descriptor != null
		and plant_descriptor.kind == Descriptor.Kind.PLANT
		and plant_descriptor.id == 201
		and enemy_descriptor != null
		and enemy_descriptor.kind == Descriptor.Kind.ENEMY
		and enemy_descriptor.id == 101,
		"三类实体必须映射为各自稳定 ID 的通用描述符。"
	)
	_expect(
		_facade.resolve_target(player_descriptor) == _peer_player
		and _facade.resolve_target(plant_descriptor) == _plant
		and _facade.resolve_target(enemy_descriptor) == _allied_enemy
		and _facade.resolve_target(Descriptor.create_none(9)) == null,
		"描述符必须经各自生命周期存储解析，不合并底层注册表。"
	)
	_peer_player.is_dead = true
	_expect(
		_facade.resolve_target(player_descriptor) == null
		and _facade.describe_player(_peer_player) == null,
		"死亡目标不得被描述或解析成可攻击实体。"
	)
	_peer_player.is_dead = false


func _test_default_hostile_radius_and_exclusion() -> void:
	var result: Array[Node2D] = []
	_facade.query_hostile_radius_into(
		Vector2.ZERO,
		30.0,
		Relations.HOSTILE_WAVE,
		result
	)
	_expect(
		result == [
			_local_player,
			_plant,
			_allied_enemy,
			_peer_player,
		],
		"默认敌军查询必须按精确距离稳定合并玩家、植物与敌对敌人。"
	)
	_facade.query_hostile_radius_into(
		Vector2.ZERO,
		30.0,
		Relations.HOSTILE_WAVE,
		result,
		_local_player,
		2
	)
	_expect(
		result == [_plant, _allied_enemy],
		"自身排除必须跨玩家/植物/敌人统一生效，且 max_count 在稳定排序后裁剪。"
	)
	_expect(
		_facade.is_target_hostile(Relations.HOSTILE_WAVE, _plant)
		and not _facade.is_target_hostile(
			Relations.HOSTILE_WAVE,
			_friendly_enemy
		),
		"默认方向关系必须过滤同阵营目标。"
	)


func _test_custom_directional_relation() -> void:
	var custom_relations := Relations.new()
	custom_relations.set_hostile(Relations.HOSTILE_WAVE, 3, true)
	var result: Array[Node2D] = []
	_facade.query_hostile_radius_into(
		Vector2.ZERO,
		30.0,
		Relations.HOSTILE_WAVE,
		result,
		null,
		0,
		custom_relations
	)
	_expect(
		result == [
			_custom_enemy,
			_local_player,
			_plant,
			_allied_enemy,
			_peer_player,
		],
		"自定义方向性阵营关系必须直接进入敌人分区查询并保持稳定距离顺序。"
	)


func _test_aabb_enumeration_and_stable_order() -> void:
	var query_aabb := Rect2(Vector2(-1.0, -1.0), Vector2(40.0, 2.0))
	var result: Array[Node2D] = []
	_facade.query_world_aabb_into(query_aabb, result)
	_expect(
		result == [
			_local_player,
			_peer_player,
			_plant,
			_allied_enemy,
			_friendly_enemy,
			_custom_enemy,
		],
		"可见性 AABB 查询必须按 kind/稳定 ID 排序，不能依赖 Dictionary 遍历顺序。"
	)
	_facade.query_hostile_world_aabb_into(
		query_aabb,
		Relations.HOSTILE_WAVE,
		result
	)
	_expect(
		result == [
			_local_player,
			_peer_player,
			_plant,
			_allied_enemy,
		],
		"敌对 AABB 必须直接使用阵营分区，排除同阵营和未配置阵营。"
	)
	var custom_relations := Relations.new()
	custom_relations.set_hostile(Relations.HOSTILE_WAVE, 3, true)
	_facade.query_hostile_world_aabb_into(
		query_aabb,
		Relations.HOSTILE_WAVE,
		result,
		_allied_enemy,
		0,
		custom_relations
	)
	_expect(
		result == [
			_local_player,
			_peer_player,
			_plant,
			_custom_enemy,
		],
		"敌对 AABB 的自身排除、自定义关系和稳定结果必须同时成立。"
	)


func _cleanup_fixture() -> void:
	_runtime.combat_target_index.clear()
	for node in [
		_local_player,
		_peer_player,
		_plant,
		_allied_enemy,
		_friendly_enemy,
		_custom_enemy,
	]:
		if node != null and is_instance_valid(node):
			node.free()
	if _runtime != null and is_instance_valid(_runtime):
		_runtime.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
