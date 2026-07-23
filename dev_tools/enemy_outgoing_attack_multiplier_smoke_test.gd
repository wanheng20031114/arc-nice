extends SceneTree

const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const BASE_ATTACK_DAMAGE := 10
const HYDRANGEA_MULTIPLIER := 0.8

var failures: Array[String] = []
var test_root: Node2D
var scheduler: Node


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "EnemyOutgoingAttackMultiplierSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	scheduler = root.get_node("EnemyCollectibleStatusScheduler")
	scheduler.call("clear_all")

	await _test_same_source_refreshes_three_second_duration()
	await _test_overlapping_sources_use_lowest_multiplier()
	await _test_cleanup_removes_modifier_and_scheduler_state()

	scheduler.call("clear_all")
	test_root.queue_free()
	await process_frame
	if failures.is_empty():
		print("ENEMY OUTGOING ATTACK MULTIPLIER SMOKE TEST PASSED")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_same_source_refreshes_three_second_duration() -> void:
	var enemy := _spawn_enemy()
	_expect(
		enemy.get_effective_attack_damage(BASE_ATTACK_DAMAGE) == BASE_ATTACK_DAMAGE,
		"An enemy without the status must retain its base attack damage."
	)
	_apply_hydrangea_reduction(enemy, 91001, 3.0)
	_expect_reduced(enemy, "A 20% reduction must convert 10 attack damage to 8.")

	scheduler.call("advance_for_test", 2.5)
	_apply_hydrangea_reduction(enemy, 91001, 3.0)
	scheduler.call("advance_for_test", 0.6)
	_expect_reduced(
		enemy,
		"Same-source reapplication must refresh the three-second duration."
	)
	scheduler.call("advance_for_test", 2.39)
	_expect_reduced(
		enemy,
		"The refreshed reduction must remain active until its new deadline."
	)
	scheduler.call("advance_for_test", 0.01)
	_expect_restored(
		enemy,
		"The refreshed reduction must expire exactly three seconds after reapplication."
	)
	enemy.queue_free()
	await process_frame


func _test_overlapping_sources_use_lowest_multiplier() -> void:
	var enemy := _spawn_enemy()
	_apply_hydrangea_reduction(enemy, 92001, 1.0)
	_apply_hydrangea_reduction(enemy, 92002, 2.0)
	_expect(
		is_equal_approx(enemy.get_outgoing_attack_damage_multiplier(), 0.8)
		and enemy.get_effective_attack_damage(BASE_ATTACK_DAMAGE) == 8,
		"Two concurrent 20% sources must remain at 0.8 instead of multiplying to 0.64."
	)

	scheduler.call("advance_for_test", 1.0)
	_expect(
		not enemy.collectible_status_effects.has("92001:hydrangea_attack_reduction")
		and enemy.collectible_status_effects.has("92002:hydrangea_attack_reduction")
		and is_equal_approx(enemy.get_outgoing_attack_damage_multiplier(), 0.8)
		and enemy.get_effective_attack_damage(BASE_ATTACK_DAMAGE) == 8,
		"Expiry of the first source must preserve the second source at 0.8."
	)
	scheduler.call("advance_for_test", 1.0)
	_expect_restored(
		enemy,
		"Expiry of the final source must restore the base attack damage."
	)
	_expect(
		int(scheduler.call("get_active_target_count")) == 0,
		"Staged expiry must remove the enemy from the shared status scheduler."
	)
	enemy.queue_free()
	await process_frame


func _test_cleanup_removes_modifier_and_scheduler_state() -> void:
	var enemy := _spawn_enemy()
	_apply_hydrangea_reduction(enemy, 93001, 20.0)
	enemy.clear_collectible_statuses()
	_expect_cleanup_state(
		enemy,
		"Explicit status cleanup must not leak an outgoing attack modifier."
	)

	_apply_hydrangea_reduction(enemy, 93002, 20.0)
	enemy.setup(BASIC_CONFIG, null, null)
	enemy.set_physics_process(false)
	_expect_cleanup_state(
		enemy,
		"Enemy setup/reuse must clear outgoing attack modifiers from the previous life."
	)

	_apply_hydrangea_reduction(enemy, 93003, 20.0)
	enemy.current_health = 1
	enemy.apply_damage(1)
	_expect(
		enemy.is_dead,
		"The cleanup death probe must kill the enemy."
	)
	_expect_cleanup_state(
		enemy,
		"Enemy death must clear outgoing attack modifiers and scheduler ownership."
	)
	enemy.queue_free()
	await process_frame


func _apply_hydrangea_reduction(
	enemy: Enemy,
	source_id: int,
	duration: float
) -> void:
	enemy.apply_collectible_status(
		&"hydrangea_attack_reduction",
		source_id,
		duration,
		0,
		0.5,
		EnemyConfig.DamageType.MAGIC,
		1.0,
		0,
		1.0,
		HYDRANGEA_MULTIPLIER
	)


func _spawn_enemy() -> Enemy:
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.setup(BASIC_CONFIG, null, null)
	enemy.set_physics_process(false)
	return enemy


func _expect_reduced(enemy: Enemy, message: String) -> void:
	_expect(
		is_equal_approx(
			enemy.get_outgoing_attack_damage_multiplier(),
			HYDRANGEA_MULTIPLIER
		)
		and enemy.get_effective_attack_damage(BASE_ATTACK_DAMAGE) == 8,
		message
	)


func _expect_restored(enemy: Enemy, message: String) -> void:
	_expect(
		enemy.collectible_status_effects.is_empty()
		and enemy.outgoing_attack_damage_multiplier_modifiers.is_empty()
		and is_equal_approx(enemy.get_outgoing_attack_damage_multiplier(), 1.0)
		and enemy.get_effective_attack_damage(BASE_ATTACK_DAMAGE) == BASE_ATTACK_DAMAGE,
		message
	)


func _expect_cleanup_state(enemy: Enemy, message: String) -> void:
	_expect(
		enemy.collectible_status_effects.is_empty()
		and enemy.outgoing_attack_damage_multiplier_modifiers.is_empty()
		and is_equal_approx(enemy.get_outgoing_attack_damage_multiplier(), 1.0)
		and int(scheduler.call("get_active_target_count")) == 0,
		message
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
