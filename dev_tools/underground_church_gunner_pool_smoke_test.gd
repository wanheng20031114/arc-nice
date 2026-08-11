extends SceneTree

const BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn"
)
const CHURCH_POOL_CAPACITY := 240

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var pool := SessionObjectPool.new()
	root.add_child(pool)
	# Wave runtime first applies the shared lazy 0/96 baseline. The encounter
	# coordinator must be able to upgrade that existing bucket before activation.
	CombatRuntimeBase.register_combat_robot_gunner_bullet_pool(pool)
	CombatRuntimeBase.register_combat_robot_gunner_bullet_pool(
		pool,
		CHURCH_POOL_CAPACITY,
		CHURCH_POOL_CAPACITY
	)
	_assert_coordinator_bindings()
	_assert_recycled_metrics(pool, "预热")
	for round_index in range(2):
		var leased: Array[Node] = []
		var leased_ids: Dictionary = {}
		for bullet_index in range(CHURCH_POOL_CAPACITY):
			var bullet := pool.acquire(BULLET_SCENE)
			if bullet == null:
				break
			leased.append(bullet)
			leased_ids[bullet.get_instance_id()] = true
		_expect(
			leased.size() == CHURCH_POOL_CAPACITY
			and leased_ids.size() == CHURCH_POOL_CAPACITY,
			"第%d轮必须无丢失地租借240枚互不相同的弹丸。" % (round_index + 1)
		)
		for bullet in leased:
			_expect(
				pool.release(bullet),
				"第%d轮的每枚弹丸都必须成功归还。" % (round_index + 1)
			)
		await physics_frame
		await physics_frame
		_assert_recycled_metrics(pool, "第%d轮回收" % (round_index + 1))
	pool.queue_free()
	await process_frame
	if _failures.is_empty():
		print("UNDERGROUND_CHURCH_GUNNER_POOL_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _assert_coordinator_bindings() -> void:
	for source_path in [
		"res://scene/game_modes/rogue/combat/rogue_combat_singleplayer_coordinator.gd",
		"res://scene/game_modes/rogue/combat/rogue_combat_multiplayer_coordinator.gd",
	]:
		var source := FileAccess.get_file_as_string(source_path)
		_expect(
			source.contains(
				"UNDERGROUND_CHURCH_COMBAT_CONFIG_ID := &\"underground_church_01\""
			)
			and source.contains(
				"UNDERGROUND_CHURCH_GUNNER_BULLET_POOL_CAPACITY := 240"
			)
			and source.contains(
				"CombatRuntimeBase.register_combat_robot_gunner_bullet_pool("
			),
			"%s 必须只为地下教会覆盖普通枪手弹丸池为240。" % source_path
		)


func _assert_recycled_metrics(pool: SessionObjectPool, context: String) -> void:
	var metrics := pool.get_metrics(BULLET_SCENE.resource_path)
	_expect(
		int(metrics.get("created", -1)) == CHURCH_POOL_CAPACITY
		and int(metrics.get("inactive", -1)) == CHURCH_POOL_CAPACITY
		and int(metrics.get("retained_capacity", -1)) == CHURCH_POOL_CAPACITY
		and int(metrics.get("in_use", -1)) == 0
		and int(metrics.get("pending_release", -1)) == 0
		and int(metrics.get("overflow", -1)) == 0
		and int(metrics.get("dropped", -1)) == 0,
		"%s后对象池必须完整保留240枚弹丸且无溢出或丢弃。" % context
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
