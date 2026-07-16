extends SceneTree

const DAMAGE_NUMBER_POOL_SCRIPT := preload("res://scene/damage_number_pool.gd")
const SLOT_COUNT := 96
const SAMPLE_PAIRS := 12
const STEPS_PER_SAMPLE := 320
const STEP_DELTA := 0.000001

var failures: Array[String] = []


class LegacyDamageNumber:
	extends Node2D

	const DAMAGE_FONT := preload("res://resources/font/ResourceHanRoundedCN-Medium.ttf")
	const BASE_SIZE := Vector2(38.0, 20.0)
	const LIFETIME := 0.72

	var label: Label
	var elapsed := 0.0
	var start_global_position := Vector2.ZERO
	var float_offset := Vector2(6.0, -14.0)


	func _init() -> void:
		label = Label.new()
		label.size = BASE_SIZE
		label.position = Vector2(-BASE_SIZE.x * 0.5, -BASE_SIZE.y * 0.5)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_override("font", DAMAGE_FONT)
		label.add_theme_font_size_override("font_size", 9)
		label.add_theme_color_override("font_color", Color(1.0, 0.12, 0.09, 1.0))
		label.add_theme_color_override("font_outline_color", Color(0.28, 0.02, 0.02, 0.98))
		label.add_theme_constant_override("outline_size", 2)
		label.text = "300"
		add_child(label)


	func benchmark_step(delta: float) -> void:
		elapsed += delta
		var progress := clampf(elapsed / LIFETIME, 0.0, 1.0)
		global_position = start_global_position + float_offset * sqrt(
			1.0 - pow(progress - 1.0, 2.0)
		)
		scale = Vector2.ONE
		if elapsed < 0.12:
			var pop_progress := clampf(elapsed / 0.12, 0.0, 1.0)
			const C1 := 1.70158
			const C3 := C1 + 1.0
			var eased := (
				1.0
				+ C3 * pow(pop_progress - 1.0, 3.0)
				+ C1 * pow(pop_progress - 1.0, 2.0)
			)
			label.modulate = Color.WHITE.lerp(Color(1.35, 1.35, 1.35, 1.0), eased)
		elif elapsed < 0.34:
			var settle_progress := clampf((elapsed - 0.12) / 0.22, 0.0, 1.0)
			label.modulate = Color(1.35, 1.35, 1.35, 1.0).lerp(
				Color.WHITE,
				sin((settle_progress * PI) * 0.5)
			)
		else:
			label.modulate = Color.WHITE


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Node2D.new()
	fixture.name = "DamageNumberBatchPerformanceAB"
	root.add_child(fixture)
	current_scene = fixture

	var legacy_root := Node2D.new()
	legacy_root.name = "Legacy96NodeBatch"
	fixture.add_child(legacy_root)
	var legacy_numbers: Array[LegacyDamageNumber] = []
	for index in range(SLOT_COUNT):
		var number := LegacyDamageNumber.new()
		number.start_global_position = Vector2(float(index), 0.0)
		legacy_root.add_child(number)
		legacy_numbers.append(number)

	var batched_pool := DAMAGE_NUMBER_POOL_SCRIPT.new() as DamageNumberPool
	batched_pool.pool_size = SLOT_COUNT
	batched_pool.max_numbers_per_frame = SLOT_COUNT
	batched_pool.max_numbers_per_second = SLOT_COUNT * 4
	batched_pool.important_frame_reserve = 0
	batched_pool.important_per_second_reserve = 0
	fixture.add_child(batched_pool)
	await process_frame
	batched_pool.set_process(false)
	for index in range(SLOT_COUNT):
		var number_kind := (
			DamageNumberPool.CombatNumberKind.HEALING
			if index % 2 == 1
			else DamageNumberPool.CombatNumberKind.DAMAGE
		)
		_expect(
			batched_pool.show_combat_number(
				300,
				Vector2(float(index), 0.0),
				number_kind
			),
			"Batched fixture could not activate every fixed slot."
		)
	batched_pool.set_process(false)
	_expect(
		batched_pool.get_active_count() == SLOT_COUNT,
		"Batched fixture must start with all slots active."
	)
	_expect(
		legacy_root.get_child_count() == SLOT_COUNT
		and _count_descendants(legacy_root) == SLOT_COUNT * 2,
		"Legacy fixture must model one Node2D plus one Label per slot."
	)
	_expect(
		batched_pool.get_child_count() == 0,
		"Production batch must use one CanvasItem and no per-number children."
	)
	var shaped_line_ids: Dictionary[int, bool] = {}
	for text_line in batched_pool.slot_text_lines:
		if text_line != null:
			shaped_line_ids[text_line.get_instance_id()] = true
	_expect(
		shaped_line_ids.size() == SLOT_COUNT,
		"Every batch slot must retain an independent shaped TextLine cache."
	)

	for _warmup in range(80):
		_step_legacy(legacy_numbers)
		batched_pool._process(STEP_DELTA)

	var legacy_samples: Array[float] = []
	var batched_samples: Array[float] = []
	for pair_index in range(SAMPLE_PAIRS):
		if pair_index % 2 == 0:
			legacy_samples.append(float(_measure_legacy(legacy_numbers)))
			batched_samples.append(float(_measure_batch(batched_pool)))
		else:
			batched_samples.append(float(_measure_batch(batched_pool)))
			legacy_samples.append(float(_measure_legacy(legacy_numbers)))

	legacy_samples.sort()
	batched_samples.sort()
	var legacy_median := legacy_samples[legacy_samples.size() / 2]
	var batched_median := batched_samples[batched_samples.size() / 2]
	var speedup := legacy_median / maxf(batched_median, 1.0)
	_expect(
		speedup >= 2.0,
		"Single-node combat-number updates should be materially faster. speedup=%.2fx"
		% speedup
	)
	print(
		(
			"DAMAGE_NUMBER_BATCH_AB slots=%d steps_per_sample=%d "
			+ "legacy_nodes=%d batch_nodes=1 legacy_median_usec=%.0f "
			+ "batch_median_usec=%.0f speedup=%.2fx shaped_lines=%d"
		)
		% [
			SLOT_COUNT,
			STEPS_PER_SAMPLE,
			_count_descendants(legacy_root),
			legacy_median,
			batched_median,
			speedup,
			shaped_line_ids.size(),
		]
	)

	current_scene = null
	fixture.queue_free()
	for _cleanup in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("DAMAGE_NUMBER_BATCH_PERFORMANCE_AB_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_legacy(numbers: Array[LegacyDamageNumber]) -> int:
	var started_usec := Time.get_ticks_usec()
	for _step in range(STEPS_PER_SAMPLE):
		_step_legacy(numbers)
	return Time.get_ticks_usec() - started_usec


func _measure_batch(pool: DamageNumberPool) -> int:
	var started_usec := Time.get_ticks_usec()
	for _step in range(STEPS_PER_SAMPLE):
		pool._process(STEP_DELTA)
	return Time.get_ticks_usec() - started_usec


func _step_legacy(numbers: Array[LegacyDamageNumber]) -> void:
	for number in numbers:
		number.benchmark_step(STEP_DELTA)


func _count_descendants(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		count += 1 + _count_descendants(child)
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
