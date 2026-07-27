extends SceneTree

const SIMPLE_FENCE_CONFIG := preload(
	"res://resources/config/plant_defense/simple_fence.tres"
)
const SIMPLE_FENCE_ITEM := preload(
	"res://resources/config/buildings/building_simple_fence.tres"
)
const TILE_SIZE := 16
const EXPECTED_COLLISION_LAYERS := 512 | 1024

var failures: Array[String] = []
var fixture: Node2D = null


class ProbePlantSystem:
	extends PlantSystem

	func register_configured_probe(
		plant: CardinalConnectedPlant,
		cell: Vector2i,
		config: PlantDefenseConfig
	) -> void:
		_register_plant_footprint(plant, [cell], config)


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _test_config_scene_and_all_frames()
	await _test_connection_masks_and_local_refresh()
	await _test_connection_groups_and_late_join()
	await _test_defense_upgrade_order_independence()

	if fixture != null and is_instance_valid(fixture):
		fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
	if failures.is_empty():
		print("SIMPLE_FENCE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_scene_and_all_frames() -> void:
	_expect(
		SIMPLE_FENCE_CONFIG != null and SIMPLE_FENCE_CONFIG.is_valid(),
		"简易围栏配置必须有效并能从植物注册资源加载。"
	)
	if SIMPLE_FENCE_CONFIG == null or not SIMPLE_FENCE_CONFIG.is_valid():
		return
	_expect(
		SIMPLE_FENCE_CONFIG.plant_id == &"simple_fence"
		and SIMPLE_FENCE_CONFIG.display_name == "简易围栏"
		and SIMPLE_FENCE_CONFIG.max_health == 500
		and SIMPLE_FENCE_CONFIG.physical_defense == 0
		and SIMPLE_FENCE_CONFIG.magic_defense == 0
		and SIMPLE_FENCE_CONFIG.footprint_size == Vector2i.ONE
		and SIMPLE_FENCE_CONFIG.placement_preview_display_size
		== Vector2(16.0, 16.0)
		and SIMPLE_FENCE_CONFIG.placement_preview_offset == Vector2.ZERO
		and SIMPLE_FENCE_CONFIG.supports_multiplayer
		and SIMPLE_FENCE_CONFIG.enemy_engagement_mode
		== PlantDefenseConfig.EnemyEngagementMode.CONTACT_ONLY
		and SIMPLE_FENCE_CONFIG.cardinal_connection_group != &"",
		"简易围栏必须为1×1、500生命、0/0基础双防、多人可用且只允许接触交战。"
	)
	var invalid_connected_config := (
		SIMPLE_FENCE_CONFIG.duplicate(true) as PlantDefenseConfig
	)
	invalid_connected_config.footprint_size = Vector2i(2, 2)
	_expect(
		not invalid_connected_config.is_valid(),
		"声明四向连接组的建筑配置必须严格限制为1×1。"
	)
	_expect(
		SIMPLE_FENCE_ITEM != null
		and SIMPLE_FENCE_ITEM.pickup_type == PickupConfig.PickupType.BUILDING
		and SIMPLE_FENCE_ITEM.placeable_plant_id == &"simple_fence"
		and SIMPLE_FENCE_ITEM.stackable
		and SIMPLE_FENCE_ITEM.inventory_stack_limit == 999,
		"简易围栏建筑物品必须可放置且仅占一个999上限堆栈。"
	)

	var plant := (
		SIMPLE_FENCE_CONFIG.plant_scene.instantiate()
		as CardinalConnectedPlant
	)
	_expect(plant != null, "简易围栏场景根节点必须严格继承CardinalConnectedPlant。")
	if plant == null:
		return
	fixture = Node2D.new()
	fixture.name = "SimpleFenceSceneContractFixture"
	root.add_child(fixture)
	fixture.add_child(plant)
	await process_frame
	plant.setup(
		SIMPLE_FENCE_CONFIG,
		null,
		[Vector2i.ZERO],
		false,
		500,
		0,
		500,
		false
	)

	var sprite := plant.get_node_or_null("Sprite2D") as Sprite2D
	var collision_shape := _find_first_node_by_class(
		plant,
		&"CollisionShape2D"
	) as CollisionShape2D
	_expect(
		_count_nodes_by_class(plant, &"StaticBody2D") == 1
		and _count_nodes_by_class(plant, &"Sprite2D") == 1
		and _count_nodes_by_class(plant, &"CollisionShape2D") == 1
		and _count_direct_children_by_class(
			plant,
			&"NavigationObstacle2D"
		) == 0
		and _count_direct_children_by_class(plant, &"Area2D") == 0
		and _count_direct_children_by_class(plant, &"Timer") == 0,
		"围栏场景只能预建一个静态体、一个精灵、一个近满格碰撞与现有血条，不得加入导航障碍或轮询节点。"
	)
	_expect(
		plant.collision_layer == EXPECTED_COLLISION_LAYERS
		and (plant.collision_layer & 1) == 0,
		"围栏碰撞层必须同时占用植物层512与玩家阻挡层1024，且不得污染世界层1。"
	)
	var rectangle := (
		collision_shape.shape as RectangleShape2D
		if collision_shape != null
		else null
	)
	_expect(
		rectangle != null
		and rectangle.size.x >= 14.0
		and rectangle.size.y >= 14.0
		and rectangle.size.x <= 16.0
		and rectangle.size.y <= 16.0,
		"围栏矩形碰撞必须近乎撑满16×16世界格，但不能越出单格。"
	)
	_expect(
		sprite != null
		and sprite.hframes == 4
		and sprite.vframes == 4
		and sprite.texture != null
		and sprite.texture.get_size() == Vector2(128, 128)
		and sprite.scale == Vector2(0.5, 0.5)
		and sprite.position == Vector2.ZERO
		and Vector2(32.0, 32.0) * sprite.scale == Vector2(16.0, 16.0)
		and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"围栏精灵必须使用最近邻128×128四乘四图集，并把32×32帧严格映射为单格16×16。"
	)
	if sprite != null and sprite.texture != null:
		var atlas_image := sprite.texture.get_image()
		_expect(
			atlas_image != null and not atlas_image.has_mipmaps(),
			"围栏透明PNG不得生成mipmap。"
		)
		if atlas_image != null:
			for mask in range(16):
				var bounds := _alpha_bounds_for_frame(atlas_image, mask)
				_expect(
					maxi(bounds.size.x, bounds.size.y) >= 28
					and bounds.size.x <= 32
					and bounds.size.y <= 32,
					"围栏图集第%d帧主体必须在单个32×32格内近乎撑满，实际包围盒=%s。"
					% [mask, bounds]
				)
				_expect(
					_frame_has_alpha_on_edge(atlas_image, mask, 0)
					== ((mask & 1) != 0)
					and _frame_has_alpha_on_edge(atlas_image, mask, 1)
					== ((mask & 2) != 0)
					and _frame_has_alpha_on_edge(atlas_image, mask, 2)
					== ((mask & 4) != 0)
					and _frame_has_alpha_on_edge(atlas_image, mask, 3)
					== ((mask & 8) != 0),
					"图集第%d帧四边alpha必须精确对应上1、右2、下4、左8连接位。" % mask
				)
	for mask in range(16):
		plant.set_cardinal_connection_mask(mask)
		_expect(
			plant.get_cardinal_connection_mask() == mask
			and sprite != null
			and sprite.frame == mask,
			"连接mask %d必须直接且唯一映射到同号图集帧。" % mask
		)
	_expect(
		not plant.is_processing() and not plant.is_physics_processing(),
		"简易围栏不得启用逐帧_process或_physics_process。"
	)
	fixture.queue_free()
	await process_frame
	fixture = null


func _test_connection_masks_and_local_refresh() -> void:
	var built := _build_plant_system_fixture("SimpleFenceAllMasks")
	var system := built["system"] as PlantSystem
	var next_net_id := 1
	for mask in range(16):
		var base_cell := Vector2i((mask % 4) * 8, (mask / 4) * 8)
		var neighbor_cells: Array[Vector2i] = []
		if (mask & 1) != 0:
			neighbor_cells.append(base_cell + Vector2i.UP)
		if (mask & 2) != 0:
			neighbor_cells.append(base_cell + Vector2i.RIGHT)
		if (mask & 4) != 0:
			neighbor_cells.append(base_cell + Vector2i.DOWN)
		if (mask & 8) != 0:
			neighbor_cells.append(base_cell + Vector2i.LEFT)
		var center: CardinalConnectedPlant = null
		if (mask % 2) == 0:
			center = _spawn_fence(system, base_cell, next_net_id)
			next_net_id += 1
		for neighbor_cell in neighbor_cells:
			var neighbor := _spawn_fence(system, neighbor_cell, next_net_id)
			next_net_id += 1
			_expect(neighbor != null, "连接穷举夹具必须能放置邻居围栏。")
			_assert_local_refresh_bound(system)
		if center == null:
			center = _spawn_fence(system, base_cell, next_net_id)
			next_net_id += 1
		_assert_local_refresh_bound(system)
		_expect(
			center != null and center.get_cardinal_connection_mask() == mask,
			"无论中心先放或后放，四向连接拓扑都必须收敛到mask %d。" % mask
		)
	_cleanup_fixture(built)
	await process_frame


func _test_connection_groups_and_late_join() -> void:
	var built := _build_plant_system_fixture("SimpleFenceGroups")
	var system := built["system"] as ProbePlantSystem
	var center := _spawn_fence(system, Vector2i.ZERO, 1001)
	_expect(center != null, "不同连接组夹具必须能放置中心围栏。")
	var other_config := SIMPLE_FENCE_CONFIG.duplicate(true) as PlantDefenseConfig
	other_config.cardinal_connection_group = &"test_foreign_fence_group"
	var foreign := (
		other_config.plant_scene.instantiate() as CardinalConnectedPlant
	)
	var container := built["container"] as Node2D
	var tile_map := built["tile_map"] as TileMapLayer
	container.add_child(foreign)
	foreign.global_position = tile_map.to_global(
		tile_map.map_to_local(Vector2i.RIGHT)
	)
	foreign.setup(
		other_config,
		null,
		[Vector2i.RIGHT],
		false,
		500,
		0,
		500,
		false
	)
	system.register_configured_probe(foreign, Vector2i.RIGHT, other_config)
	_assert_local_refresh_bound(system)
	_expect(
		center != null
		and center.get_cardinal_connection_mask() == 0
		and foreign.get_cardinal_connection_mask() == 0,
		"相邻但连接组不同的建筑必须互不连接。"
	)
	_cleanup_fixture(built)
	await process_frame

	var host := _build_plant_system_fixture("SimpleFenceHostGraph")
	var late_join := _build_plant_system_fixture("SimpleFenceLateJoinGraph")
	var topology := [
		Vector2i.ZERO,
		Vector2i.UP,
		Vector2i.RIGHT,
		Vector2i.DOWN,
		Vector2i.LEFT,
		Vector2i(1, -1),
	]
	var host_system := host["system"] as PlantSystem
	var late_system := late_join["system"] as PlantSystem
	for index in range(topology.size()):
		_spawn_fence(host_system, topology[index], 2000 + index)
	for reverse_index in range(topology.size() - 1, -1, -1):
		_spawn_fence(late_system, topology[reverse_index], 3000 + reverse_index)
	var host_signature := _connection_signature(host_system, topology)
	var late_signature := _connection_signature(late_system, topology)
	_expect(
		host_signature == late_signature,
		"Host顺序放置与晚加入客户端逆序生成必须仅由权威占格表推导出相同连接图，不得依赖贴图RPC。"
	)
	_expect(
		host_system.remove_plant_by_net_id(2002, PlantDefense.RemovalMode.SILENT),
		"连接移除夹具必须能按权威net id移除围栏。"
	)
	_assert_local_refresh_bound(host_system)
	_expect(
		(host_system.get_plant_at_cell(Vector2i.ZERO) as CardinalConnectedPlant)
		.get_cardinal_connection_mask() == (1 | 4 | 8),
		"移除东侧邻居后中心围栏必须立即清除右连接位，且只刷新局部五格。"
	)
	_cleanup_fixture(host)
	_cleanup_fixture(late_join)
	await process_frame


func _test_defense_upgrade_order_independence() -> void:
	var before := _build_plant_system_fixture("SimpleFenceDefenseBefore")
	var before_system := before["system"] as PlantSystem
	var before_fence := _spawn_fence(before_system, Vector2i.ZERO, 4001)
	before_system.set_global_physical_defense_bonus(10)
	_expect(
		before_fence != null
		and before_fence.physical_defense == 0
		and before_fence.get_effective_physical_defense() == 10
		and before_fence.get_effective_magic_defense() == 0,
		"围栏先放置、科技后完成时必须保留0基础物防并得到+10有效物防。"
	)
	_cleanup_fixture(before)
	await process_frame

	var after := _build_plant_system_fixture("SimpleFenceDefenseAfter")
	var after_system := after["system"] as PlantSystem
	after_system.set_global_physical_defense_bonus(10)
	var after_fence := _spawn_fence(after_system, Vector2i.ZERO, 5001)
	_expect(
		after_fence != null
		and after_fence.physical_defense == 0
		and after_fence.get_effective_physical_defense() == 10
		and after_fence.get_effective_magic_defense() == 0,
		"科技先完成、围栏后放置时也必须得到相同+10有效物防。"
	)
	_cleanup_fixture(after)
	await process_frame


func _build_plant_system_fixture(fixture_name: String) -> Dictionary:
	var fixture_root := Node2D.new()
	fixture_root.name = fixture_name
	root.add_child(fixture_root)
	var tile_map := TileMapLayer.new()
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)
	tile_map.tile_set = tile_set
	fixture_root.add_child(tile_map)
	var container := Node2D.new()
	container.name = "PlantContainer"
	fixture_root.add_child(container)
	var system := ProbePlantSystem.new()
	fixture_root.add_child(system)
	system.setup(
		tile_map,
		null,
		container,
		Rect2i(-128, -128, 256, 256)
	)
	return {
		"root": fixture_root,
		"tile_map": tile_map,
		"container": container,
		"system": system,
	}


func _spawn_fence(
	system: PlantSystem,
	cell: Vector2i,
	net_id: int
) -> CardinalConnectedPlant:
	return system.spawn_multiplayer_replica(
		&"simple_fence",
		cell,
		null,
		net_id,
		500,
		500,
		0,
		false
	) as CardinalConnectedPlant


func _assert_local_refresh_bound(system: PlantSystem) -> void:
	var metrics := system.get_last_cardinal_connection_refresh_metrics()
	_expect(
		int(metrics.get("cells_visited", -1)) > 0
		and int(metrics.get("cells_visited", -1)) <= 5
		and int(metrics.get("plants_updated", -1)) <= 5,
		"任意围栏局部变化最多只能访问变化格及其四邻，指标=%s。" % metrics
	)


func _connection_signature(
	system: PlantSystem,
	cells: Array
) -> PackedInt32Array:
	var signature := PackedInt32Array()
	for cell_variant in cells:
		var plant := system.get_plant_at_cell(cell_variant as Vector2i)
		var connected := plant as CardinalConnectedPlant
		signature.append(
			connected.get_cardinal_connection_mask()
			if connected != null
			else -1
		)
	return signature


func _alpha_bounds_for_frame(image: Image, frame: int) -> Rect2i:
	var frame_origin := Vector2i((frame % 4) * 32, (frame / 4) * 32)
	var minimum := Vector2i(32, 32)
	var maximum := Vector2i(-1, -1)
	for y in range(32):
		for x in range(32):
			if image.get_pixelv(frame_origin + Vector2i(x, y)).a <= 0.01:
				continue
			minimum.x = mini(minimum.x, x)
			minimum.y = mini(minimum.y, y)
			maximum.x = maxi(maximum.x, x)
			maximum.y = maxi(maximum.y, y)
	if maximum.x < minimum.x or maximum.y < minimum.y:
		return Rect2i()
	return Rect2i(minimum, maximum - minimum + Vector2i.ONE)


func _frame_has_alpha_on_edge(
	image: Image,
	frame: int,
	edge: int
) -> bool:
	var frame_origin := Vector2i((frame % 4) * 32, (frame / 4) * 32)
	for offset in range(32):
		var pixel := Vector2i.ZERO
		match edge:
			0:
				pixel = Vector2i(offset, 0)
			1:
				pixel = Vector2i(31, offset)
			2:
				pixel = Vector2i(offset, 31)
			3:
				pixel = Vector2i(0, offset)
		if image.get_pixelv(frame_origin + pixel).a > 0.01:
			return true
	return false


func _count_nodes_by_class(node: Node, class_name_value: StringName) -> int:
	var count := 1 if node.is_class(class_name_value) else 0
	for child in node.get_children():
		count += _count_nodes_by_class(child, class_name_value)
	return count


func _count_direct_children_by_class(
	node: Node,
	class_name_value: StringName
) -> int:
	var count := 0
	for child in node.get_children():
		if child.is_class(class_name_value):
			count += 1
	return count


func _find_first_node_by_class(
	node: Node,
	class_name_value: StringName
) -> Node:
	if node.is_class(class_name_value):
		return node
	for child in node.get_children():
		var found := _find_first_node_by_class(child, class_name_value)
		if found != null:
			return found
	return null


func _cleanup_fixture(built: Dictionary) -> void:
	var fixture_root := built.get("root") as Node
	if fixture_root != null and is_instance_valid(fixture_root):
		fixture_root.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
