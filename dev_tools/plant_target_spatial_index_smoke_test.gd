extends SceneTree

const PlantTargetSpatialIndexScript := preload(
	"res://scene/combat/targeting/plant_target_spatial_index.gd"
)


class ProbePlant:
	extends RefCounted

	var label: StringName

	func _init(new_label: StringName) -> void:
		label = new_label


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_negative_coordinates_and_closed_boundaries()
	_test_swap_removal_and_explicit_movement()
	_test_duplicate_registration_and_reconfiguration()
	_test_nearest_world_anchor_selection()
	_test_nearest_world_anchor_extremes_and_invalid_objects()
	_test_invalid_parameters_and_clear()

	if failures.is_empty():
		print("PLANT_TARGET_SPATIAL_INDEX_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_negative_coordinates_and_closed_boundaries() -> void:
	var index: Variant = PlantTargetSpatialIndexScript.new(64.0)
	index.call("set_query_metrics_enabled", true)
	var negative_fraction := ProbePlant.new(&"negative_fraction")
	var negative_boundary := ProbePlant.new(&"negative_boundary")
	var origin := ProbePlant.new(&"origin")
	var positive_boundary := ProbePlant.new(&"positive_boundary")
	var far_outside := ProbePlant.new(&"far_outside")

	_expect(index.call("register", negative_fraction, Vector2(-0.25, -0.25)), "负坐标登记必须成功。")
	_expect(index.call("register", negative_boundary, Vector2(-64.0, -64.0)), "负桶边界登记必须成功。")
	_expect(index.call("register", origin, Vector2.ZERO), "原点登记必须成功。")
	_expect(index.call("register", positive_boundary, Vector2(64.0, 64.0)), "正桶边界登记必须成功。")
	_expect(index.call("register", far_outside, Vector2(256.0, 256.0)), "远端登记必须成功。")

	var zero_size_result: Array = [positive_boundary]
	var zero_count := int(index.call(
		"query_world_aabb_into",
		Rect2(Vector2(-64.0, -64.0), Vector2.ZERO),
		zero_size_result
	))
	var zero_size_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		zero_count == 1
		and zero_size_result == [negative_boundary]
		and zero_size_metrics.get("query_mode") == &"buckets",
		"桶扫描下，零尺寸 AABB 必须复用数组并仅命中完全同坐标的 anchor。"
	)

	var closed_boundary_result: Array = []
	index.call(
		"query_world_aabb_into",
		Rect2(Vector2(-64.0, -64.0), Vector2(128.0, 128.0)),
		closed_boundary_result
	)
	var closed_boundary_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		closed_boundary_result.size() == 4
		and closed_boundary_result.has(negative_fraction)
		and closed_boundary_result.has(negative_boundary)
		and closed_boundary_result.has(origin)
		and closed_boundary_result.has(positive_boundary)
		and not closed_boundary_result.has(far_outside)
		and closed_boundary_metrics.get("query_mode") == &"registry",
		"Registry 扫描也必须按闭区间精确过滤，负坐标 floor 分桶不得漏查。"
	)

	var normalized_result: Array = []
	index.call(
		"query_world_aabb_into",
		Rect2(Vector2(64.0, 64.0), Vector2(-128.0, -128.0)),
		normalized_result
	)
	var normalized_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		normalized_result.size() == closed_boundary_result.size()
		and normalized_metrics.get("normalized_aabb") == Rect2(
			Vector2(-64.0, -64.0),
			Vector2(128.0, 128.0)
		),
		"负尺寸 Rect2 必须先标准化，并保持与正尺寸查询相同的闭区间语义。"
	)
	index.call("clear")


func _test_swap_removal_and_explicit_movement() -> void:
	var index: Variant = PlantTargetSpatialIndexScript.new(64.0)
	index.call("set_query_metrics_enabled", true)
	var first := ProbePlant.new(&"first")
	var middle := ProbePlant.new(&"middle")
	var last := ProbePlant.new(&"last")
	index.call("register", first, Vector2(1.0, 1.0))
	index.call("register", middle, Vector2(2.0, 2.0))
	index.call("register", last, Vector2(3.0, 3.0))

	_expect(index.call("unregister", middle), "桶中间成员必须可被 swap-remove。")
	var remaining: Array = []
	index.call("query_world_aabb_into", Rect2(Vector2.ZERO, Vector2(8.0, 8.0)), remaining)
	var removal_metrics := index.call("get_structure_metrics") as Dictionary
	_expect(
		remaining.size() == 2
		and remaining.has(first)
		and remaining.has(last)
		and not remaining.has(middle)
		and int(removal_metrics.get("bucket_swap_removals_total", -1)) == 1
		and bool(removal_metrics.get("structure_counts_consistent", false)),
		"移除中间槽位必须换入末尾成员、修复 reverse slot，并保持单成员结构一致。"
	)

	_expect(index.call("update", last, Vector2(130.0, 3.0)), "显式跨桶 update 必须成功。")
	var old_area: Array = []
	var new_area: Array = []
	index.call("query_world_aabb_into", Rect2(Vector2.ZERO, Vector2(8.0, 8.0)), old_area)
	index.call("query_world_aabb_into", Rect2(Vector2(129.0, 2.0), Vector2(2.0, 2.0)), new_area)
	var movement_metrics := index.call("get_structure_metrics") as Dictionary
	_expect(
		old_area == [first]
		and new_area == [last]
		and int(movement_metrics.get("bucket_migrations_total", -1)) == 1
		and int(movement_metrics.get("membership_count", -1)) == 2,
		"跨桶移动必须立即移除旧 membership、登记新 membership，且总数不变。"
	)
	index.call("clear")


func _test_duplicate_registration_and_reconfiguration() -> void:
	var index: Variant = PlantTargetSpatialIndexScript.new(64.0)
	index.call("set_query_metrics_enabled", true)
	var plant := ProbePlant.new(&"duplicate")
	_expect(index.call("register", plant, Vector2(1.0, 1.0)), "首次登记必须成功。")
	_expect(index.call("register", plant, Vector2(130.0, 1.0)), "重复登记必须幂等刷新 anchor。")

	var result: Array = []
	index.call("query_world_aabb_into", Rect2(Vector2(128.0, 0.0), Vector2(4.0, 4.0)), result)
	var duplicate_metrics := index.call("get_structure_metrics") as Dictionary
	_expect(
		result == [plant]
		and int(duplicate_metrics.get("registered_count", -1)) == 1
		and int(duplicate_metrics.get("membership_count", -1)) == 1
		and int(duplicate_metrics.get("duplicate_registrations_total", -1)) == 1
		and int(duplicate_metrics.get("bucket_migrations_total", -1)) == 1,
		"重复登记不得复制 membership，并应按新 anchor 迁移唯一成员。"
	)

	_expect(index.call("configure_bucket_size", 32.0), "合法 bucket size 必须可重配。")
	result.clear()
	index.call("query_world_aabb_into", Rect2(Vector2(130.0, 1.0), Vector2.ZERO), result)
	var rebuilt_metrics := index.call("get_structure_metrics") as Dictionary
	_expect(
		result == [plant]
		and is_equal_approx(float(rebuilt_metrics.get("bucket_size", 0.0)), 32.0)
		and int(rebuilt_metrics.get("bucket_rebuilds_total", -1)) == 1
		and bool(rebuilt_metrics.get("structure_counts_consistent", false)),
		"重配 bucket size 后必须重建唯一 membership，并保留精确 anchor。"
	)
	index.call("clear")


func _test_nearest_world_anchor_selection() -> void:
	var index: Variant = PlantTargetSpatialIndexScript.new(64.0)
	index.call("set_query_metrics_enabled", true)
	var center := Vector2(20.0, 20.0)
	var exact := ProbePlant.new(&"exact")
	var tie_left := ProbePlant.new(&"tie_left")
	var tie_right := ProbePlant.new(&"tie_right")
	var aabb_corner_outside_circle := ProbePlant.new(&"aabb_corner")
	var far := ProbePlant.new(&"far")
	index.call("register", exact, center)
	index.call("register", tie_left, center + Vector2(-4.0, 0.0))
	index.call("register", tie_right, center + Vector2(4.0, 0.0))
	index.call(
		"register",
		aabb_corner_outside_circle,
		center + Vector2(4.0, 4.0)
	)
	index.call("register", far, Vector2(1000.0, 1000.0))

	var zero_radius_result: Variant = index.call(
		"find_nearest_world_anchor",
		center,
		0.0
	)
	var zero_radius_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		zero_radius_result == exact
		and zero_radius_metrics.get("query_mode") == &"buckets"
		and int(zero_radius_metrics.get("results_written", -1)) == 1,
		"零半径 nearest 必须只命中完全同 anchor 的对象，且无需候选数组。"
	)

	var excluded: Dictionary = {}
	excluded[exact.get_instance_id()] = true
	var expected_tie: ProbePlant = (
		tie_left
		if tie_left.get_instance_id() < tie_right.get_instance_id()
		else tie_right
	)
	var other_tie: ProbePlant = tie_right if expected_tie == tie_left else tie_left
	var tied_result: Variant = index.call(
		"find_nearest_world_anchor",
		center,
		4.0,
		excluded
	)
	_expect(
		tied_result == expected_tie,
		"等 distance² 的 nearest 必须稳定选择较小 instance ID。"
	)
	var broad_result: Variant = index.call(
		"find_nearest_world_anchor",
		center,
		2000.0,
		excluded
	)
	var broad_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		broad_result == expected_tie
		and broad_metrics.get("query_mode") == &"registry",
		"Registry 与 bucket 模式必须产生相同的 distance²/instance-ID 结果。"
	)
	excluded[expected_tie.get_instance_id()] = true
	var second_tie_result: Variant = index.call(
		"find_nearest_world_anchor",
		center,
		4.0,
		excluded
	)
	_expect(
		second_tie_result == other_tie,
		"excluded instance ID 必须被跳过，并选中下一等距对象。"
	)
	excluded[other_tie.get_instance_id()] = true
	var no_circle_result: Variant = index.call(
		"find_nearest_world_anchor",
		center,
		4.0,
		excluded
	)
	var no_circle_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		no_circle_result == null
		and int(no_circle_metrics.get("results_written", -1)) == 0,
		"AABB 角落内但精确圆外的 anchor 不得成为 nearest。"
	)
	index.call("clear")

	# Make the lower-ID object very slightly farther away. Approximate equality
	# would incorrectly let its ID override the truly smaller distance².
	var strict_index: Variant = PlantTargetSpatialIndexScript.new(64.0)
	var first := ProbePlant.new(&"strict_first")
	var second := ProbePlant.new(&"strict_second")
	var lower_id: ProbePlant = (
		first if first.get_instance_id() < second.get_instance_id() else second
	)
	var higher_id: ProbePlant = second if lower_id == first else first
	strict_index.call("register", lower_id, Vector2(10.00002, 0.0))
	strict_index.call("register", higher_id, Vector2(10.0, 0.0))
	_expect(
		strict_index.call(
			"find_nearest_world_anchor",
			Vector2.ZERO,
			11.0
		) == higher_id,
		"近似相等但不相等的距离必须优先真实较近者，ID 仅用于精确同距。"
	)
	strict_index.call("clear")

	# The center-bucket target is encountered first. An equidistant lower-ID
	# target lives across the x=64 bucket boundary in ring one; equality must not
	# be pruned by the already-known nearest distance.
	var ring_index: Variant = PlantTargetSpatialIndexScript.new(64.0)
	ring_index.call("set_query_metrics_enabled", true)
	var ring_first := ProbePlant.new(&"ring_first")
	var ring_second := ProbePlant.new(&"ring_second")
	var ring_lower_id: ProbePlant = (
		ring_first
		if ring_first.get_instance_id() < ring_second.get_instance_id()
		else ring_second
	)
	var ring_higher_id: ProbePlant = (
		ring_second if ring_lower_id == ring_first else ring_first
	)
	ring_index.call("register", ring_lower_id, Vector2(64.0, 8.0))
	ring_index.call("register", ring_higher_id, Vector2(62.0, 8.0))
	for filler_index in range(4):
		var filler := ProbePlant.new(
			StringName("ring_filler_%d" % filler_index)
		)
		ring_index.call(
			"register",
			filler,
			Vector2(512.0 + float(filler_index) * 64.0, 512.0)
		)
	var ring_center := Vector2(63.0, 8.0)
	var cross_ring_result: Variant = ring_index.call(
		"find_nearest_world_anchor",
		ring_center,
		1.0
	)
	var cross_ring_metrics := (
		ring_index.call("get_last_query_metrics") as Dictionary
	)
	_expect(
		cross_ring_result == ring_lower_id
		and cross_ring_metrics.get("query_mode") == &"buckets"
		and int(cross_ring_metrics.get("bucket_cells_considered", -1)) == 2
		and int(
			cross_ring_metrics.get("bucket_cells_pruned_by_nearest", -1)
		) == 0,
		"跨 ring 的闭圆边界等距桶不得被 nearest 下界剪枝，仍须按低 ID 胜出。"
	)
	var ring_excluded: Dictionary = {}
	ring_excluded[ring_lower_id.get_instance_id()] = false
	_expect(
		ring_index.call(
			"find_nearest_world_anchor",
			ring_center,
			1.0,
			ring_excluded
		) == ring_higher_id,
		"跨 ring nearest 必须按 excluded.has(instance_id) 排除，值本身无意义。"
	)
	ring_index.call("clear")


func _test_nearest_world_anchor_extremes_and_invalid_objects() -> void:
	var empty_index: Variant = PlantTargetSpatialIndexScript.new(64.0)
	empty_index.call("set_query_metrics_enabled", true)
	_expect(
		empty_index.call(
			"find_nearest_world_anchor",
			Vector2.ZERO,
			0.0
		) == null
		and (
			empty_index.call("get_last_query_metrics") as Dictionary
		).get("query_mode") == &"empty",
		"空索引的有限零半径 nearest 必须直接返回 null。"
	)
	var index: Variant = PlantTargetSpatialIndexScript.new(64.0)
	index.call("set_query_metrics_enabled", true)
	var origin := ProbePlant.new(&"origin")
	var nearby := ProbePlant.new(&"nearby")
	index.call("register", origin, Vector2.ZERO)
	index.call("register", nearby, Vector2(32.0, 0.0))

	var huge_result: Variant = index.call(
		"find_nearest_world_anchor",
		Vector2.ZERO,
		1.0e300
	)
	var huge_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		huge_result == origin
		and bool(huge_metrics.get("valid", false))
		and huge_metrics.get("query_mode") == &"registry"
		and int(huge_metrics.get("bucket_cells_considered", 0))
		== 9223372036854775807,
		"极大但有限的半径必须安全回退 registry，并保持精确 nearest。"
	)

	var rejected_before := int(
		(index.call("get_structure_metrics") as Dictionary).get(
			"rejected_operations_total",
			0
		)
	)
	_expect(
		index.call("find_nearest_world_anchor", Vector2(NAN, 0.0), 1.0) == null
		and index.call("find_nearest_world_anchor", Vector2.ZERO, NAN) == null
		and index.call("find_nearest_world_anchor", Vector2.ZERO, INF) == null
		and index.call("find_nearest_world_anchor", Vector2.ZERO, -1.0) == null,
		"非有限 center/radius 与负半径必须被 nearest 查询拒绝。"
	)
	var rejected_after := int(
		(index.call("get_structure_metrics") as Dictionary).get(
			"rejected_operations_total",
			0
		)
	)
	_expect(
		rejected_after == rejected_before + 4,
		"非法 nearest 参数必须逐次计入 rejected operation。"
	)

	var invalid_object_index: Variant = PlantTargetSpatialIndexScript.new(64.0)
	invalid_object_index.call("set_query_metrics_enabled", true)
	var freed_plant := Node.new()
	var valid_plant := ProbePlant.new(&"valid_after_freed")
	invalid_object_index.call("register", freed_plant, Vector2.ZERO)
	invalid_object_index.call("register", valid_plant, Vector2(1.0, 0.0))
	freed_plant.free()
	var valid_result: Variant = invalid_object_index.call(
		"find_nearest_world_anchor",
		Vector2.ZERO,
		2.0
	)
	_expect(
		valid_result == valid_plant,
		"nearest 必须跳过已失效对象，同时保留通用 Object 域语义。"
	)
	invalid_object_index.call("clear")
	index.call("clear")


func _test_invalid_parameters_and_clear() -> void:
	var fallback_index: Variant = PlantTargetSpatialIndexScript.new(0.0)
	var fallback_metrics := fallback_index.call("get_structure_metrics") as Dictionary
	_expect(
		is_equal_approx(
			float(fallback_index.call("get_bucket_size")),
			PlantTargetSpatialIndexScript.DEFAULT_BUCKET_SIZE
		)
		and int(fallback_metrics.get("rejected_operations_total", 0)) == 1,
		"非法构造 bucket size 必须回退默认值并可观测地计数。"
	)

	var index: Variant = PlantTargetSpatialIndexScript.new(64.0)
	index.call("set_query_metrics_enabled", true)
	var registered := ProbePlant.new(&"registered")
	var unregistered := ProbePlant.new(&"unregistered")
	index.call("register", registered, Vector2.ZERO)
	_expect(not index.call("configure_bucket_size", -1.0), "负 bucket size 必须被拒绝。")
	_expect(not index.call("configure_bucket_size", NAN), "非有限 bucket size 必须被拒绝。")
	_expect(not index.call("register", null, Vector2.ZERO), "null 登记必须被拒绝。")
	_expect(not index.call("register", unregistered, Vector2(NAN, 0.0)), "非有限 anchor 必须被拒绝。")
	_expect(not index.call("update", unregistered, Vector2.ZERO), "未登记对象 update 必须被拒绝。")
	_expect(not index.call("unregister", unregistered), "未登记对象移除必须被拒绝。")
	_expect(
		not index.call(
			"register",
			unregistered,
			Vector2(200_000_000_000.0, 0.0)
		),
		"超出 Vector2i 桶坐标域的 finite anchor 必须在登记前被拒绝。"
	)
	_expect(
		not index.call("update", registered, Vector2(200_000_000_000.0, 0.0))
		and index.call("find_nearest_world_anchor", Vector2.ZERO, 0.0) == registered,
		"越界 anchor 更新必须保持原成员及原 anchor 不变。"
	)
	_expect(
		index.call("register", unregistered, Vector2(1.0, 0.0))
		and not index.call("configure_bucket_size", 1.0e-300)
		and is_equal_approx(float(index.call("get_bucket_size")), 64.0),
		"会令现有 anchor 无法分桶的重配置必须被原子拒绝。"
	)
	_expect(
		index.call("unregister", unregistered),
		"重配置拒绝后，既有非零 anchor 成员必须保持可正常移除。"
	)

	var invalid_result: Array = [registered]
	var invalid_count := int(index.call(
		"query_world_aabb_into",
		Rect2(Vector2(INF, 0.0), Vector2.ONE),
		invalid_result
	))
	var invalid_query_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		invalid_count == 0
		and invalid_result.is_empty()
		and not bool(invalid_query_metrics.get("valid", true))
		and invalid_query_metrics.get("query_mode") == &"invalid"
		and int(invalid_query_metrics.get("candidates_visited", -1)) == 0,
		"非有限 Rect2 必须清空调用方数组、返回 0，且不访问任何候选。"
	)

	var overflow_result: Array = [registered]
	var overflow_count := int(index.call(
		"query_world_aabb_into",
		Rect2(Vector2(3.0e38, 0.0), Vector2(3.0e38, 1.0)),
		overflow_result
	))
	var overflow_query_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		overflow_count == 0
		and overflow_result.is_empty()
		and not bool(overflow_query_metrics.get("valid", true))
		and overflow_query_metrics.get("query_mode") == &"invalid",
		"两个 finite Rect2 字段相加溢出时，派生 corner 必须被识别为非法。"
	)

	var huge_result: Array = []
	index.call(
		"query_world_aabb_into",
		Rect2(
			Vector2(-100_000_000_000.0, -100_000_000_000.0),
			Vector2(200_000_000_000.0, 200_000_000_000.0)
		),
		huge_result
	)
	var huge_query_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		huge_result == [registered]
		and huge_query_metrics.get("query_mode") == &"registry"
		and int(huge_query_metrics.get("bucket_cells_considered", 0))
		== 9223372036854775807,
		"超大但有限的 AABB 必须自适应 registry 扫描，桶格数量指标不得整数溢出。"
	)

	var out_of_bucket_domain_result: Array = []
	index.call(
		"query_world_aabb_into",
		Rect2(
			Vector2(-200_000_000_000.0, -200_000_000_000.0),
			Vector2(400_000_000_000.0, 400_000_000_000.0)
		),
		out_of_bucket_domain_result
	)
	var out_of_bucket_domain_metrics := (
		index.call("get_last_query_metrics") as Dictionary
	)
	_expect(
		out_of_bucket_domain_result == [registered]
		and out_of_bucket_domain_metrics.get("query_mode") == &"registry"
		and int(out_of_bucket_domain_metrics.get("bucket_cells_considered", 0))
		== 9223372036854775807,
		"超出 Vector2i 桶坐标域的 finite AABB 必须在转换前安全回退 registry。"
	)

	index.call("clear")
	var cleared_metrics := index.call("get_structure_metrics") as Dictionary
	var cleared_query_metrics := index.call("get_last_query_metrics") as Dictionary
	_expect(
		int(cleared_metrics.get("registered_count", -1)) == 0
		and int(cleared_metrics.get("membership_count", -1)) == 0
		and int(cleared_metrics.get("bucket_count", -1)) == 0
		and int(cleared_metrics.get("queries_total", -1)) == 0
		and bool(cleared_metrics.get("structure_counts_consistent", false))
		and cleared_query_metrics.get("query_mode") == &"none",
		"clear 必须释放全部结构并重置累计及上次查询指标。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
