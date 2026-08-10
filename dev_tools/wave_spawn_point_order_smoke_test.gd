extends SceneTree

const POINT_NAMES: Array[StringName] = [
	&"Spawn1",
	&"Spawn2",
	&"Spawn3",
]
const SAMPLE_COUNT := 30
const PRIMARY_SEED := 184467
const SECONDARY_SEED := 918273

var _failures := PackedStringArray()


class SpawnPointProbe:
	extends WaveCombatRuntimeBase

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(_peer_id: int) -> Player:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func _configure_singleplayer_player() -> void:
		pass

	func _configure_multiplayer_players() -> void:
		pass

	func _connect_mode_singleplayer_player_death_signal() -> void:
		pass

	func _update_multiplayer_remote_player_passive_state(_delta: float) -> void:
		pass

	func _connect_mode_dynamic_pickup_containers() -> void:
		pass

	func _register_static_multiplayer_pickups() -> void:
		pass


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_balanced_order_is_seed_stable()
	_test_balanced_order_can_vary_by_seed()
	_test_balanced_order_covers_each_point_per_bag()
	_test_balanced_order_keeps_prefix_counts_even()
	_test_uniform_random_preserves_legacy_selection()

	if _failures.is_empty():
		print("WAVE_SPAWN_POINT_ORDER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_balanced_order_is_seed_stable() -> void:
	var first := _sample_order(
		WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG,
		PRIMARY_SEED,
		SAMPLE_COUNT
	)
	var second := _sample_order(
		WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG,
		PRIMARY_SEED,
		SAMPLE_COUNT
	)
	_expect(first == second, "均衡随机袋必须在相同 seed 下生成相同点位序列。")


func _test_balanced_order_can_vary_by_seed() -> void:
	var first := _sample_order(
		WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG,
		PRIMARY_SEED,
		SAMPLE_COUNT
	)
	var second := _sample_order(
		WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG,
		SECONDARY_SEED,
		SAMPLE_COUNT
	)
	_expect(first != second, "均衡随机袋必须允许不同 seed 生成不同点位序列。")


func _test_balanced_order_covers_each_point_per_bag() -> void:
	var order := _sample_order(
		WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG,
		PRIMARY_SEED,
		SAMPLE_COUNT
	)
	for bag_start in range(0, order.size(), POINT_NAMES.size()):
		var bag_counts: Dictionary[StringName, int] = {}
		for offset in range(POINT_NAMES.size()):
			var point_name := order[bag_start + offset]
			bag_counts[point_name] = bag_counts.get(point_name, 0) + 1
		_expect(
			bag_counts.size() == POINT_NAMES.size()
			and _all_point_counts_equal(bag_counts, 1),
			"均衡随机袋的每个完整三次生成必须各覆盖一扇门。"
		)


func _test_balanced_order_keeps_prefix_counts_even() -> void:
	var order := _sample_order(
		WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG,
		PRIMARY_SEED,
		SAMPLE_COUNT
	)
	var counts: Dictionary[StringName, int] = {}
	for point_name in POINT_NAMES:
		counts[point_name] = 0
	for index in range(order.size()):
		var point_name := order[index]
		counts[point_name] += 1
		var values := counts.values()
		var minimum_count := int(values.min())
		var maximum_count := int(values.max())
		_expect(
			maximum_count - minimum_count <= 1,
			"均衡随机袋任意前缀的点位生成次数最大差不得超过1：%s。"
			% (index + 1)
		)


func _test_uniform_random_preserves_legacy_selection() -> void:
	var actual := _sample_order(
		WaveConfig.SpawnPointOrder.UNIFORM_RANDOM,
		PRIMARY_SEED,
		SAMPLE_COUNT
	)
	var expected := PackedStringArray()
	var expected_rng := RandomNumberGenerator.new()
	expected_rng.seed = PRIMARY_SEED
	for _index in range(SAMPLE_COUNT):
		expected.append(
			String(POINT_NAMES[expected_rng.randi_range(0, POINT_NAMES.size() - 1)])
		)
	_expect(
		actual == expected,
		"默认 UNIFORM_RANDOM 必须保持旧版每次独立均匀随机的序列。"
	)


func _sample_order(
	spawn_point_order: WaveConfig.SpawnPointOrder,
	seed_value: int,
	count: int
) -> PackedStringArray:
	var probe := SpawnPointProbe.new()
	var wave := WaveConfig.new()
	wave.spawn_point_order = spawn_point_order
	probe.current_flow_step = wave
	probe.random_generator.seed = seed_value
	for point_name in POINT_NAMES:
		var marker := Marker2D.new()
		marker.name = point_name
		probe.active_wave_spawn_points.append(marker)

	var result := PackedStringArray()
	for _index in range(count):
		var point := probe.call("_pick_spawn_point") as Marker2D
		if point == null:
			_failures.append("出生点策略在存在有效点位时返回了 null。")
			break
		result.append(String(point.name))

	for marker in probe.active_wave_spawn_points:
		marker.free()
	probe.free()
	return result


func _all_point_counts_equal(
	counts: Dictionary[StringName, int],
	expected_count: int
) -> bool:
	for point_name in POINT_NAMES:
		if counts.get(point_name, 0) != expected_count:
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
