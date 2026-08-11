extends SceneTree

## Focused performance/lifecycle probe for the active-only enemy hit-flash path.
## The thresholds are deliberately generous: structural regressions should fail,
## while ordinary debug-build and CI timing variance should remain diagnostic.
const SLIME_CONFIG := preload("res://resources/config/enemies/slime.tres")
const IDLE_ENEMY_COUNT := 1000
const SMALL_ACTIVE_COUNT := 250
const FULL_ACTIVE_COUNT := 1000
const RAPID_REHIT_ROUNDS := 10
const NETWORK_ENEMY_COUNT := 1000
const NETWORK_HITS_PER_ENEMY := 5
const NETWORK_RECORDS_PER_PACKET := 40
const MAX_SINGLE_STAGE_USEC := 500_000
const MAX_LINEAR_SCALE_WITH_SLACK := 8.0
const LINEAR_SCALE_FIXED_SLACK_USEC := 5_000

var failures: Array[String] = []
var metrics := {}
var test_root: Node2D
var hit_flash_scheduler: Node
var enemies: Array[Enemy] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "EnemyHitFlashPerformanceSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	hit_flash_scheduler = root.get_node_or_null("EnemyHitFlashScheduler")
	_expect(hit_flash_scheduler != null, "EnemyHitFlashScheduler autoload must exist.")
	if hit_flash_scheduler == null:
		await _finish()
		return
	hit_flash_scheduler.call("clear_all")

	await _spawn_idle_cohort()
	if enemies.size() == IDLE_ENEMY_COUNT:
		_test_idle_fast_path()
		_test_active_scaling_and_uniform_path()
		_test_rapid_rehit_state_reuse()
		await _test_weakref_and_exit_cleanup()
	_test_multiplayer_feedback_aggregation()
	await _finish()


func _spawn_idle_cohort() -> void:
	var started_usec := Time.get_ticks_usec()
	var shared_material: ShaderMaterial = null
	for _index in range(IDLE_ENEMY_COUNT):
		var enemy := SLIME_CONFIG.enemy_scene.instantiate() as Enemy
		if enemy == null:
			break
		test_root.add_child(enemy)
		enemy.setup(SLIME_CONFIG, null)
		enemy.set_process(false)
		enemy.set_physics_process(false)
		enemies.append(enemy)
		if shared_material == null:
			shared_material = enemy.status_visual_material
		_expect(
			enemy.status_visual_material == shared_material,
			"Every idle enemy must cache the same shared ShaderMaterial."
		)
		_expect(
			enemy.animated_sprite.material == null,
			"Idle enemies must keep the shared material detached."
		)
	metrics["spawn_1000_usec"] = Time.get_ticks_usec() - started_usec
	_expect(
		enemies.size() == IDLE_ENEMY_COUNT,
		"The performance fixture must instantiate all 1000 enemies."
	)


func _test_idle_fast_path() -> void:
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == 0
		and not hit_flash_scheduler.is_processing(),
		"1000 idle enemies must create zero scheduler work."
	)
	var started_usec := Time.get_ticks_usec()
	for _index in range(1000):
		hit_flash_scheduler.call("_advance", 1.0 / 60.0, false)
	metrics["idle_1000_manual_advances_usec"] = Time.get_ticks_usec() - started_usec
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == 0
		and not hit_flash_scheduler.is_processing(),
		"Repeated empty advances must remain constant-time and keep processing off."
	)


func _test_active_scaling_and_uniform_path() -> void:
	var small_trigger_usec := _trigger_cohort(SMALL_ACTIVE_COUNT)
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == SMALL_ACTIVE_COUNT,
		"The small cohort must allocate exactly one state per target."
	)
	var small_advance_usec := _advance_and_measure(0.005)
	hit_flash_scheduler.call("clear_all")

	var full_trigger_usec := _trigger_cohort(FULL_ACTIVE_COUNT)
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == FULL_ACTIVE_COUNT,
		"1000 simultaneous hits must allocate exactly 1000 states."
	)
	var full_advance_usec := _advance_and_measure(0.005)
	metrics["trigger_250_usec"] = small_trigger_usec
	metrics["advance_250_usec"] = small_advance_usec
	metrics["trigger_1000_usec"] = full_trigger_usec
	metrics["advance_1000_usec"] = full_advance_usec
	_expect_stage_budget("trigger_1000", full_trigger_usec)
	_expect_stage_budget("advance_1000", full_advance_usec)
	_expect_linear_scaling("trigger", small_trigger_usec, full_trigger_usec)
	_expect_linear_scaling("advance", small_advance_usec, full_advance_usec)

	var shared_material := enemies[0].status_visual_material
	for enemy in enemies:
		_expect(
			enemy.animated_sprite.material == shared_material,
			"Every active enemy must bind the same shared material, not a duplicate."
		)
	var finish_started_usec := Time.get_ticks_usec()
	hit_flash_scheduler.call("advance_for_test", 0.065)
	metrics["finish_1000_usec"] = Time.get_ticks_usec() - finish_started_usec
	_expect_stage_budget("finish_1000", int(metrics["finish_1000_usec"]))
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == 0
		and not hit_flash_scheduler.is_processing(),
		"The full active cohort must drain without leaving scheduler work."
	)
	for enemy in enemies:
		_expect(
			enemy.animated_sprite.material == null,
			"Finishing the flash must restore every enemy to the detached material path."
		)


func _test_rapid_rehit_state_reuse() -> void:
	_trigger_cohort(FULL_ACTIVE_COUNT)
	var started_usec := Time.get_ticks_usec()
	for _round_index in range(RAPID_REHIT_ROUNDS):
		for enemy in enemies:
			enemy.play_multiplayer_damage_feedback(
				Vector2.ZERO,
				CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
			)
	metrics["rapid_rehit_10000_usec"] = Time.get_ticks_usec() - started_usec
	_expect_stage_budget("rapid_rehit_10000", int(metrics["rapid_rehit_10000_usec"]))
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == FULL_ACTIVE_COUNT,
		"Ten rapid re-hits must reuse 1000 states instead of stacking 10000 states."
	)
	hit_flash_scheduler.call("clear_all")


func _test_weakref_and_exit_cleanup() -> void:
	_trigger_cohort(FULL_ACTIVE_COUNT)
	for index in range(0, FULL_ACTIVE_COUNT, 2):
		enemies[index].queue_free()
	await process_frame
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == FULL_ACTIVE_COUNT / 2,
		"Enemy _exit_tree cleanup must remove every freed active target immediately."
	)
	var stale_cleanup_started_usec := Time.get_ticks_usec()
	hit_flash_scheduler.call("advance_for_test", 0.01)
	metrics["weakref_remaining_500_advance_usec"] = (
		Time.get_ticks_usec() - stale_cleanup_started_usec
	)
	for index in range(1, FULL_ACTIVE_COUNT, 2):
		enemies[index].queue_free()
	await process_frame
	_expect(
		int(hit_flash_scheduler.call("get_active_target_count")) == 0
		and not hit_flash_scheduler.is_processing(),
		"Freeing the remaining active targets must leave no WeakRef states behind."
	)
	enemies.clear()


func _test_multiplayer_feedback_aggregation() -> void:
	var coordinator := MpEnemyCoordinator.new()
	test_root.add_child(coordinator)
	var started_usec := Time.get_ticks_usec()
	for enemy_net_id in range(1, NETWORK_ENEMY_COUNT + 1):
		for hit_index in range(NETWORK_HITS_PER_ENEMY):
			var flags := CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
			if hit_index == NETWORK_HITS_PER_ENEMY - 1:
				flags |= CombatTypes.DamageFeedbackFlag.HIT_PARTICLES
			coordinator.queue_damage_feedback(
				enemy_net_id,
				100 - NETWORK_HITS_PER_ENEMY,
				hit_index + 1,
				1,
				Vector2.RIGHT,
				EnemyConfig.DamageType.PHYSICAL,
				flags
			)
	metrics["network_queue_5000_hits_usec"] = Time.get_ticks_usec() - started_usec
	var drain_started_usec := Time.get_ticks_usec()
	var batches: Array[MpEnemyCoordinator.DamageFeedbackBatch] = (
		coordinator.drain_damage_feedback_batches()
	)
	metrics["network_drain_1000_enemies_usec"] = Time.get_ticks_usec() - drain_started_usec
	_expect_stage_budget(
		"network_queue_5000_hits",
		int(metrics["network_queue_5000_hits_usec"])
	)
	_expect_stage_budget(
		"network_drain_1000_enemies",
		int(metrics["network_drain_1000_enemies_usec"])
	)
	_expect(
		batches.size() == ceili(
			float(NETWORK_ENEMY_COUNT) / float(NETWORK_RECORDS_PER_PACKET)
		),
		"The 50 ms aggregate must chunk 1000 unique enemies into 25 packets."
	)
	var record_count := 0
	for batch in batches:
		_expect(
			batch.net_ids.size() <= NETWORK_RECORDS_PER_PACKET,
			"No combat feedback packet may exceed the 40-record contract."
		)
		for record_index in range(batch.net_ids.size()):
			record_count += 1
			_expect(
				batch.damage_values[record_index] == NETWORK_HITS_PER_ENEMY,
				"Five hits on one enemy must aggregate into one summed damage record."
			)
			_expect(
				batch.presentation_flags[record_index]
				== (
					CombatTypes.DamageFeedbackFlag.HIT_PARTICLES
					| CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
				),
				"The aggregate must OR direct-flash and particle presentation bits."
			)
	_expect(
		record_count == NETWORK_ENEMY_COUNT,
		"5000 hits must drain as one record for each of 1000 unique enemies."
	)
	_expect(
		coordinator.pending_enemy_damage_feedback.is_empty(),
		"Draining the 50 ms aggregate must release all pending dictionaries."
	)
	coordinator.queue_free()


func _trigger_cohort(count: int) -> int:
	var started_usec := Time.get_ticks_usec()
	for index in range(count):
		enemies[index].play_multiplayer_damage_feedback(
			Vector2.ZERO,
			CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
		)
	return Time.get_ticks_usec() - started_usec


func _advance_and_measure(delta: float) -> int:
	var started_usec := Time.get_ticks_usec()
	hit_flash_scheduler.call("advance_for_test", delta)
	return Time.get_ticks_usec() - started_usec


func _expect_linear_scaling(label: String, small_usec: int, full_usec: int) -> void:
	var allowed_usec := (
		float(maxi(small_usec, 1)) * MAX_LINEAR_SCALE_WITH_SLACK
		+ LINEAR_SCALE_FIXED_SLACK_USEC
	)
	_expect(
		float(full_usec) <= allowed_usec,
		"%s path must remain approximately O(active targets): 250=%dus, 1000=%dus."
		% [label, small_usec, full_usec]
	)


func _expect_stage_budget(label: String, elapsed_usec: int) -> void:
	_expect(
		elapsed_usec <= MAX_SINGLE_STAGE_USEC,
		"%s exceeded the generous %dus debug smoke budget: %dus."
		% [label, MAX_SINGLE_STAGE_USEC, elapsed_usec]
	)


func _finish() -> void:
	if hit_flash_scheduler != null:
		hit_flash_scheduler.call("clear_all")
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.queue_free()
	enemies.clear()
	current_scene = null
	if test_root != null:
		test_root.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	print("ENEMY_HIT_FLASH_PERFORMANCE_METRICS=%s" % JSON.stringify(metrics))
	if failures.is_empty():
		print("ENEMY_HIT_FLASH_PERFORMANCE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
