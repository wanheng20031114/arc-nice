extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const CANDIDATE_COUNT := 100

var failures: Array[String] = []


class InteractionBuildingStub:
	extends PlantDefense

	var interaction_player: Player = null
	var modal_open := false
	var selected := false
	var selection_write_count := 0

	func _ready() -> void:
		super._ready()
		add_to_group(PlantDefense.BUILDING_INTERACTION_GROUP)

	func get_interaction_player() -> Player:
		return interaction_player

	func set_interaction_target_selected(value: bool) -> void:
		selected = value
		selection_write_count += 1

	func is_modal_ui_open() -> bool:
		return modal_open


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var fixture := Node2D.new()
	root.add_child(fixture)
	var selector := PlantSystem.new()
	fixture.add_child(selector)
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.set_physics_process(false)
	player.global_position = Vector2.ZERO

	var buildings: Array[InteractionBuildingStub] = []
	for index in CANDIDATE_COUNT:
		var building := InteractionBuildingStub.new()
		fixture.add_child(building)
		building.is_operational = true
		building.interaction_player = player
		building.global_position = Vector2(64.0 + float(index), 0.0)
		building.set_meta(&"net_id", 1000 + index)
		building.bind_building_interaction_selection_host(selector)
		buildings.append(building)

	# Two equal-distance candidates prove that the existing authoritative net-id
	# tie break remains intact after moving arbitration into PlantSystem.
	buildings[0].global_position = Vector2(-10.0, 0.0)
	buildings[0].set_meta(&"net_id", 20)
	buildings[1].global_position = Vector2(10.0, 0.0)
	buildings[1].set_meta(&"net_id", 10)

	selector.reset_local_interaction_selection_metrics()
	for building in buildings:
		building._register_local_building_interaction_overlap(player)
	await process_frame
	var metrics := selector.get_local_interaction_selection_metrics()
	_expect(
		int(metrics.get("flush_count", 0)) == 1
		and int(metrics.get("players_refreshed", 0)) == 1
		and int(metrics.get("candidates_visited", 0)) == CANDIDATE_COUNT
		and int(metrics.get("dirty_request_count", 0)) == CANDIDATE_COUNT,
		"100个同帧Area进入事件必须合并成一次线性仲裁，只访问100个候选。"
	)
	_expect(
		buildings[1].selected and not buildings[0].selected,
		"等距交互候选必须继续选择较小的权威net_id。"
	)
	_expect(
		selector.is_processing(),
		"存在本地交互候选时PlantSystem必须启用低频周期刷新。"
	)

	selector.reset_local_interaction_selection_metrics()
	buildings[1].modal_open = true
	selector.notify_local_interaction_state_changed(player)
	await process_frame
	metrics = selector.get_local_interaction_selection_metrics()
	_expect(
		not _has_selected_building(buildings)
		and int(metrics.get("flush_count", 0)) >= 1
		and int(metrics.get("candidates_visited", 0)) == CANDIDATE_COUNT,
		(
			"任意重叠建筑打开模态面板时必须用一次线性仲裁抑制全部提示：%s，selected=%s"
			% [str(metrics), str(_has_selected_building(buildings))]
		)
	)

	buildings[1].modal_open = false
	selector.notify_local_interaction_state_changed(player)
	await process_frame
	_expect(
		buildings[1].selected,
		"模态面板关闭后必须恢复唯一最近交互目标。"
	)

	selector.reset_local_interaction_selection_metrics()
	buildings[1]._unregister_local_building_interaction_overlap(player)
	_expect(
		not buildings[1].selected,
		"当前目标退出Area时必须立即撤销旧目标。"
	)
	await process_frame
	metrics = selector.get_local_interaction_selection_metrics()
	_expect(
		buildings[0].selected
		and int(metrics.get("flush_count", 0)) >= 1
		and int(metrics.get("candidates_visited", 0)) == CANDIDATE_COUNT - 1,
		"当前目标退出Area后必须在同帧合并刷新中切换到下一候选。"
	)

	selector.reset_local_interaction_selection_metrics()
	selector.unregister_local_interaction_building(buildings[0])
	_expect(
		not buildings[0].selected,
		"建筑移除时必须立即撤销旧交互目标。"
	)
	await process_frame
	metrics = selector.get_local_interaction_selection_metrics()
	_expect(
		_has_selected_building(buildings)
		and int(metrics.get("flush_count", 0)) >= 1
		and int(metrics.get("candidates_visited", 0)) == CANDIDATE_COUNT - 2,
		"建筑移除后必须在同帧合并刷新中选择仍重叠的候选。"
	)

	for index in range(2, buildings.size()):
		buildings[index]._unregister_local_building_interaction_overlap(player)
	await process_frame
	_expect(
		not selector.is_processing()
		and int(
			selector.get_local_interaction_selection_metrics().get(
				"tracked_player_count",
				-1
			)
		) == 0,
		"最后一个本地候选退出后必须停用周期刷新并释放玩家候选状态。"
	)

	fixture.queue_free()
	await process_frame
	if failures.is_empty():
		print("BUILDING_INTERACTION_SELECTION_PERFORMANCE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _has_selected_building(
	buildings: Array[InteractionBuildingStub]
) -> bool:
	for building in buildings:
		if building.selected:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
