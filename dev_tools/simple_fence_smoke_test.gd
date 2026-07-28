extends SceneTree

const SIMPLE_FENCE_CONFIG_PATH := (
	"res://resources/config/plant_defense/simple_fence.tres"
)
const SIMPLE_FENCE_ITEM_PATH := (
	"res://resources/config/buildings/building_simple_fence.tres"
)
const TILE_SIZE := 16
const EXPECTED_COLLISION_LAYERS := 512 | 1024
const CONNECTION_UP := 1
const CONNECTION_RIGHT := 2
const CONNECTION_DOWN := 4
const CONNECTION_LEFT := 8
const MAIN_ATLAS_PATH := (
	"res://resources/texture/plant_defense/simple_fence/simple_fence_atlas.png"
)
const CONNECTOR_TEXTURE_PATH := (
	"res://resources/texture/plant_defense/simple_fence/"
	+ "simple_fence_connector.png"
)

var failures: Array[String] = []
var fixture: Node2D = null
var simple_fence_config: PlantDefenseConfig = null
var simple_fence_item: PickupConfig = null


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
	simple_fence_config = load(SIMPLE_FENCE_CONFIG_PATH) as PlantDefenseConfig
	simple_fence_item = load(SIMPLE_FENCE_ITEM_PATH) as PickupConfig
	await _test_config_scene_and_component_visuals()
	await _test_connection_masks_and_local_refresh()
	await _test_connection_removal_from_either_endpoint()
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


func _test_config_scene_and_component_visuals() -> void:
	_expect(
		simple_fence_config != null and simple_fence_config.is_valid(),
		"简易围栏配置必须有效并能从植物注册资源加载。"
	)
	if simple_fence_config == null or not simple_fence_config.is_valid():
		return
	_expect(
		simple_fence_config.plant_id == &"simple_fence"
		and simple_fence_config.display_name == "简易围栏"
		and simple_fence_config.max_health == 500
		and simple_fence_config.physical_defense == 0
		and simple_fence_config.magic_defense == 0
		and simple_fence_config.footprint_size == Vector2i.ONE
		and simple_fence_config.placement_preview_display_size
		== Vector2(16.0, 16.0)
		and simple_fence_config.placement_preview_offset == Vector2.ZERO
		and simple_fence_config.supports_multiplayer
		and simple_fence_config.enemy_engagement_mode
		== PlantDefenseConfig.EnemyEngagementMode.CONTACT_ONLY
		and simple_fence_config.cardinal_connection_group != &"",
		"简易围栏必须为1×1、500生命、0/0基础双防、多人可用且只允许接触交战。"
	)
	var invalid_connected_config := (
		simple_fence_config.duplicate(true) as PlantDefenseConfig
	)
	invalid_connected_config.footprint_size = Vector2i(2, 2)
	_expect(
		not invalid_connected_config.is_valid(),
		"声明四向连接组的建筑配置必须严格限制为1×1。"
	)
	_expect(
		simple_fence_item != null
		and simple_fence_item.pickup_type == PickupConfig.PickupType.BUILDING
		and simple_fence_item.placeable_plant_id == &"simple_fence"
		and simple_fence_item.stackable
		and simple_fence_item.inventory_stack_limit == 999,
		"简易围栏建筑物品必须可放置且仅占一个999上限堆栈。"
	)

	var plant := (
		simple_fence_config.plant_scene.instantiate()
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
		simple_fence_config,
		null,
		[Vector2i.ZERO],
		false,
		500,
		0,
		500,
		false
	)

	var sprite := plant.get_node_or_null("Sprite2D") as Sprite2D
	var connector_right := plant.get_node_or_null("ConnectorRight") as Sprite2D
	var connector_down := plant.get_node_or_null("ConnectorDown") as Sprite2D
	var collision_shape := _find_first_node_by_class(
		plant,
		&"CollisionShape2D"
	) as CollisionShape2D
	_expect(
		_count_nodes_by_class(plant, &"StaticBody2D") == 1
		and _count_nodes_by_class(plant, &"Sprite2D") == 3
		and _count_nodes_by_class(plant, &"CollisionShape2D") == 1
		and _count_direct_children_by_class(
			plant,
			&"NavigationObstacle2D"
		) == 0
		and _count_direct_children_by_class(plant, &"Area2D") == 0
		and _count_direct_children_by_class(plant, &"Timer") == 0,
		"围栏场景必须预建一个固定主体、右/下两个连接精灵、一个近满格碰撞与现有血条，不得加入导航障碍或轮询节点。"
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
		and sprite.hframes == 1
		and sprite.vframes == 1
		and sprite.frame == 0
		and sprite.texture is AtlasTexture
		and (sprite.texture as AtlasTexture).atlas != null
		and (sprite.texture as AtlasTexture).atlas.resource_path == MAIN_ATLAS_PATH
		and (sprite.texture as AtlasTexture).region == Rect2(0, 0, 32, 32)
		and sprite.texture.get_size() == Vector2(32, 32)
		and sprite.scale == Vector2(0.5, 0.5)
		and sprite.position == Vector2.ZERO
		and Vector2(32.0, 32.0) * sprite.scale == Vector2(16.0, 16.0)
		and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and sprite.z_index == 1,
		"围栏主体必须固定使用building_simple_fence的32×32首帧，以最近邻缩放为16×16且位于连接件上层。"
	)
	var body_image := sprite.texture.get_image() if sprite != null else null
	_expect(
		body_image != null
		and body_image.get_used_rect().size == Vector2i(30, 28),
		"围栏固定主体的可见像素必须接近方形，不能继续使用30×23的扁平轮廓。"
	)
	_expect(
		sprite != null
		and connector_right != null
		and connector_down != null
		and not connector_right.visible
		and not connector_down.visible
		and connector_right.texture != null
		and connector_right.texture.resource_path == CONNECTOR_TEXTURE_PATH
		and connector_down.texture == connector_right.texture
		and connector_right.texture.get_size() == Vector2(14, 10)
		and connector_right.scale == Vector2(0.5, 0.5)
		and connector_down.scale == Vector2(0.5, 0.5)
		and connector_right.position == Vector2(8.0, 0.0)
		and connector_down.position == Vector2(0.0, 8.0)
		and is_zero_approx(connector_right.rotation)
		and is_equal_approx(connector_down.rotation, PI * 0.5)
		and connector_right.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and connector_down.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and connector_right.z_index < sprite.z_index
		and connector_down.z_index < sprite.z_index,
		"围栏必须预建同一张14×10最近邻连接图：右连接位于(8,0)，下连接位于(0,8)并旋转90度，且均绘制在主体下层。"
	)
	_expect(
		plant.lifecycle_visual_paths.has(NodePath("Sprite2D"))
		and plant.lifecycle_visual_paths.has(NodePath("ConnectorRight"))
		and plant.lifecycle_visual_paths.has(NodePath("ConnectorDown"))
		and plant.lifecycle_visual_paths.size() == 3
		and sprite != null
		and connector_right != null
		and connector_down != null
		and sprite.material != null
		and connector_right.material == sprite.material
		and connector_down.material == sprite.material,
		"主体与两个连接件必须共同加入生命周期视觉并共享现有植物生命周期材质。"
	)
	if connector_right != null and connector_right.texture != null:
		var connector_image := connector_right.texture.get_image()
		_expect(
			connector_image != null
			and connector_image.get_size() == Vector2i(14, 10)
			and not connector_image.has_mipmaps()
			and _image_has_visible_pixel(connector_image)
			and _image_uses_binary_alpha(connector_image),
			"围栏连接图必须为14×10、包含可见像素、使用二值alpha且不得生成mipmap。"
		)
		_expect(
			connector_image != null
			and _image_is_horizontally_symmetric(connector_image)
			and _image_is_vertically_symmetric(connector_image),
			"同一张围栏连接图必须在水平轴和垂直轴上逐像素对称，确保旋转复用后接缝一致。"
		)
		_expect(
			_connection_has_no_transparent_seam(
				body_image,
				connector_image,
				false
			)
			and _connection_has_no_transparent_seam(
				body_image,
				connector_image,
				true
			),
			"围栏横向与纵向的相邻主体之间都必须由连接木段连续跨过，不能留下透明行或透明列。"
		)
	var original_texture := sprite.texture if sprite != null else null
	var original_frame := sprite.frame if sprite != null else -1
	for mask in range(16):
		plant.set_cardinal_connection_mask(mask)
		_expect(
			plant.get_cardinal_connection_mask() == mask
			and sprite != null
			and sprite.texture == original_texture
			and sprite.frame == original_frame
			and connector_right != null
			and connector_right.visible == ((mask & CONNECTION_RIGHT) != 0)
			and connector_down != null
			and connector_down.visible == ((mask & CONNECTION_DOWN) != 0),
			"连接mask %d只能切换规范所有权的右/下连接件，不得替换固定主体。" % mask
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
		if (mask & CONNECTION_UP) != 0:
			neighbor_cells.append(base_cell + Vector2i.UP)
		if (mask & CONNECTION_RIGHT) != 0:
			neighbor_cells.append(base_cell + Vector2i.RIGHT)
		if (mask & CONNECTION_DOWN) != 0:
			neighbor_cells.append(base_cell + Vector2i.DOWN)
		if (mask & CONNECTION_LEFT) != 0:
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
		var topology_cells: Array[Vector2i] = [base_cell]
		topology_cells.append_array(neighbor_cells)
		_assert_unique_connector_topology(
			system,
			topology_cells,
			"连接mask %d" % mask
		)
	_cleanup_fixture(built)
	await process_frame


func _test_connection_removal_from_either_endpoint() -> void:
	var cases: Array[Dictionary] = [
		{
			"label": "横向连接移除左侧所有者",
			"neighbor_offset": Vector2i.RIGHT,
			"connector_name": NodePath("ConnectorRight"),
			"remove_owner": true,
		},
		{
			"label": "横向连接移除右侧端点",
			"neighbor_offset": Vector2i.RIGHT,
			"connector_name": NodePath("ConnectorRight"),
			"remove_owner": false,
		},
		{
			"label": "纵向连接移除上侧所有者",
			"neighbor_offset": Vector2i.DOWN,
			"connector_name": NodePath("ConnectorDown"),
			"remove_owner": true,
		},
		{
			"label": "纵向连接移除下侧端点",
			"neighbor_offset": Vector2i.DOWN,
			"connector_name": NodePath("ConnectorDown"),
			"remove_owner": false,
		},
	]
	for case_index in range(cases.size()):
		var case_data := cases[case_index]
		var label := String(case_data["label"])
		var neighbor_offset := case_data["neighbor_offset"] as Vector2i
		var connector_name := case_data["connector_name"] as NodePath
		var remove_owner := bool(case_data["remove_owner"])
		var built := _build_plant_system_fixture(
			"SimpleFenceEndpointRemoval%d" % case_index
		)
		var system := built["system"] as PlantSystem
		var owner_net_id := 6000 + case_index * 2
		var neighbor_net_id := owner_net_id + 1
		var owner := _spawn_fence(system, Vector2i.ZERO, owner_net_id)
		var neighbor := _spawn_fence(system, neighbor_offset, neighbor_net_id)
		var owned_connector := (
			owner.get_node_or_null(connector_name) as Sprite2D
			if owner != null
			else null
		)
		_expect(
			owner != null
			and neighbor != null
			and owned_connector != null
			and owned_connector.visible,
			"%s：放置相邻围栏后必须由左侧或上侧围栏唯一显示连接件。" % label
		)
		_assert_unique_connector_topology(
			system,
			[Vector2i.ZERO, neighbor_offset],
			label + "移除前"
		)
		var removed_net_id := owner_net_id if remove_owner else neighbor_net_id
		_expect(
			system.remove_plant_by_net_id(
				removed_net_id,
				PlantDefense.RemovalMode.SILENT
			),
			"%s：指定端点必须能立即进入移除流程。" % label
		)
		_assert_local_refresh_bound(system)
		_expect(
			owned_connector != null and not owned_connector.visible,
			"%s：无论移除连接所有者或另一端，连接件都必须在同一事务内立即隐藏。" % label
		)
		var survivor_cell := neighbor_offset if remove_owner else Vector2i.ZERO
		_assert_unique_connector_topology(
			system,
			[survivor_cell],
			label + "移除后"
		)
		_cleanup_fixture(built)
		await process_frame


func _test_connection_groups_and_late_join() -> void:
	var built := _build_plant_system_fixture("SimpleFenceGroups")
	var system := built["system"] as ProbePlantSystem
	var center := _spawn_fence(system, Vector2i.ZERO, 1001)
	_expect(center != null, "不同连接组夹具必须能放置中心围栏。")
	var other_config := simple_fence_config.duplicate(true) as PlantDefenseConfig
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
	_assert_unique_connector_topology(
		system,
		[Vector2i.ZERO, Vector2i.RIGHT],
		"不同连接组"
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
	_assert_unique_connector_topology(host_system, topology, "Host连接图")
	_assert_unique_connector_topology(late_system, topology, "晚加入连接图")
	_expect(
		host_system.remove_plant_by_net_id(2002, PlantDefense.RemovalMode.SILENT),
		"连接移除夹具必须能按权威net id移除围栏。"
	)
	_assert_local_refresh_bound(host_system)
	_expect(
		(host_system.get_plant_at_cell(Vector2i.ZERO) as CardinalConnectedPlant)
		.get_cardinal_connection_mask()
		== (CONNECTION_UP | CONNECTION_DOWN | CONNECTION_LEFT),
		"移除东侧邻居后中心围栏必须立即清除右连接位，且只刷新局部五格。"
	)
	var remaining_topology := topology.duplicate()
	remaining_topology.erase(Vector2i.RIGHT)
	_assert_unique_connector_topology(
		host_system,
		remaining_topology,
		"移除东侧邻居后的Host连接图"
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


func _assert_unique_connector_topology(
	system: PlantSystem,
	cells: Array,
	label: String
) -> void:
	var unique_cells: Dictionary = {}
	for cell_variant in cells:
		unique_cells[cell_variant as Vector2i] = true
	var expected_edge_count := 0
	var visible_connector_count := 0
	for cell_variant in unique_cells:
		var cell := cell_variant as Vector2i
		var plant := system.get_plant_at_cell(cell) as CardinalConnectedPlant
		if plant == null:
			continue
		var connector_right := (
			plant.get_node_or_null("ConnectorRight") as Sprite2D
		)
		var connector_down := (
			plant.get_node_or_null("ConnectorDown") as Sprite2D
		)
		_expect(
			connector_right != null and connector_down != null,
			"%s：每个在场围栏都必须预建右/下两个规范所有权连接节点。" % label
		)
		var right_neighbor := (
			system.get_plant_at_cell(cell + Vector2i.RIGHT)
			as CardinalConnectedPlant
		)
		var down_neighbor := (
			system.get_plant_at_cell(cell + Vector2i.DOWN)
			as CardinalConnectedPlant
		)
		var expects_right := _plants_share_cardinal_group(plant, right_neighbor)
		var expects_down := _plants_share_cardinal_group(plant, down_neighbor)
		var right_visible := connector_right != null and connector_right.visible
		var down_visible := connector_down != null and connector_down.visible
		if expects_right:
			expected_edge_count += 1
		if expects_down:
			expected_edge_count += 1
		if right_visible:
			visible_connector_count += 1
		if down_visible:
			visible_connector_count += 1
		_expect(
			right_visible == expects_right and down_visible == expects_down,
			(
				"%s：格%s只能为实际存在的右/下同组邻接边显示连接件，"
				+ "期望=(%s,%s)，实际=(%s,%s)。"
			)
			% [
				label,
				cell,
				expects_right,
				expects_down,
				right_visible,
				down_visible,
			]
		)
	_expect(
		visible_connector_count == expected_edge_count,
		(
			"%s：可见连接件总数必须等于无向同组邻接边数，"
			+ "不得遗漏或在边界两端重复绘制；期望=%d，实际=%d。"
		)
		% [label, expected_edge_count, visible_connector_count]
	)


func _plants_share_cardinal_group(
	first: CardinalConnectedPlant,
	second: CardinalConnectedPlant
) -> bool:
	return (
		first != null
		and second != null
		and first.config != null
		and second.config != null
		and first.config.cardinal_connection_group != &""
		and first.config.cardinal_connection_group
		== second.config.cardinal_connection_group
	)


func _image_has_visible_pixel(image: Image) -> bool:
	if image == null or image.is_empty():
		return false
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a > 0.0:
				return true
	return false


func _image_uses_binary_alpha(image: Image) -> bool:
	if image == null or image.is_empty():
		return false
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var alpha := image.get_pixel(x, y).a
			if not is_zero_approx(alpha) and not is_equal_approx(alpha, 1.0):
				return false
	return true


func _image_is_horizontally_symmetric(image: Image) -> bool:
	if image == null or image.is_empty():
		return false
	var width := image.get_width()
	for y in range(image.get_height()):
		for x in range(width / 2):
			if (
				image.get_pixel(x, y).to_rgba32()
				!= image.get_pixel(width - 1 - x, y).to_rgba32()
			):
				return false
	return true


func _image_is_vertically_symmetric(image: Image) -> bool:
	if image == null or image.is_empty():
		return false
	var height := image.get_height()
	for y in range(height / 2):
		for x in range(image.get_width()):
			if (
				image.get_pixel(x, y).to_rgba32()
				!= image.get_pixel(x, height - 1 - y).to_rgba32()
			):
				return false
	return true


func _connection_has_no_transparent_seam(
	body: Image,
	connector: Image,
	vertical: bool
) -> bool:
	if body == null or connector == null:
		return false
	var bridge := _rotate_image_clockwise(connector) if vertical else connector
	var pair_size := Vector2i(32, 64) if vertical else Vector2i(64, 32)
	var pair := Image.create(
		pair_size.x,
		pair_size.y,
		false,
		Image.FORMAT_RGBA8
	)
	pair.fill(Color(0.0, 0.0, 0.0, 0.0))
	var seam_center := Vector2i(16, 32) if vertical else Vector2i(32, 16)
	var bridge_origin := seam_center - bridge.get_size() / 2
	pair.blend_rect(
		bridge,
		Rect2i(Vector2i.ZERO, bridge.get_size()),
		bridge_origin
	)
	pair.blend_rect(body, Rect2i(Vector2i.ZERO, body.get_size()), Vector2i.ZERO)
	var second_origin := Vector2i(0, 32) if vertical else Vector2i(32, 0)
	pair.blend_rect(body, Rect2i(Vector2i.ZERO, body.get_size()), second_origin)
	for seam_offset in range(-8, 9):
		var seam_coordinate := 32 + seam_offset
		var line_has_pixel := false
		var line_length := pair.get_width() if vertical else pair.get_height()
		for cross_coordinate in range(line_length):
			var point := (
				Vector2i(cross_coordinate, seam_coordinate)
				if vertical
				else Vector2i(seam_coordinate, cross_coordinate)
			)
			if pair.get_pixelv(point).a > 0.0:
				line_has_pixel = true
				break
		if not line_has_pixel:
			return false
	return true


func _rotate_image_clockwise(source: Image) -> Image:
	var rotated := Image.create(
		source.get_height(),
		source.get_width(),
		false,
		Image.FORMAT_RGBA8
	)
	for y in range(source.get_height()):
		for x in range(source.get_width()):
			rotated.set_pixel(source.get_height() - 1 - y, x, source.get_pixel(x, y))
	return rotated


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
