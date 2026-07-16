extends SceneTree

const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const DAMAGE_NUMBER_POOL_SCRIPT := preload("res://scene/damage_number_pool.gd")


class DamageNumberOwner:
	extends Node2D

	var damage_number_pool: Node = null

	func show_damage_number(
		amount: int,
		spawn_position: Vector2,
		impact_direction: Vector2 = Vector2.ZERO,
		damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
	) -> bool:
		if damage_number_pool == null:
			return false
		return damage_number_pool.call("show_damage_number", amount, spawn_position, impact_direction, damage_type) == true

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var owner := DamageNumberOwner.new()
	test_root = owner
	test_root.name = "DamageNumberSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	var damage_number_pool := DAMAGE_NUMBER_POOL_SCRIPT.new() as DamageNumberPool
	_expect(damage_number_pool != null, "DamageNumberPool should instantiate.")
	if damage_number_pool != null:
		damage_number_pool.name = "DamageNumberPool"
		test_root.add_child(damage_number_pool)
		owner.damage_number_pool = damage_number_pool
	await process_frame

	if damage_number_pool != null:
		_expect(
			int(damage_number_pool.call("get_slot_capacity"))
				== int(damage_number_pool.get("pool_size")),
			"DamageNumberPool should preallocate its configured slot capacity."
		)
		_expect(
			damage_number_pool.get_child_count() == 0,
			"DamageNumberPool must batch its visuals without per-number child nodes."
		)
		_expect(
			damage_number_pool.slot_text_lines.size() == damage_number_pool.pool_size,
			"Every fixed slot must own one persistent TextLine shaping cache."
		)

	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "Enemy scene must instantiate.")
	test_root.add_child(enemy)
	enemy.global_position = Vector2(64.0, 64.0)
	enemy.setup(ENEMY_CONFIG, null, null)
	var enemy_hit_audio := enemy.get_node("HitAudio") as AudioStreamPlayer2D
	if enemy_hit_audio != null:
		enemy_hit_audio.stream = null

	var before_count := int(damage_number_pool.call("get_active_count"))
	var damaged := enemy.apply_damage(10, Vector2.RIGHT)
	_expect(damaged, "Enemy damage should apply.")
	_expect(enemy.last_damage_taken > 0, "Enemy must record confirmed final damage.")
	await process_frame
	var after_count := int(damage_number_pool.call("get_active_count"))
	_expect(after_count == before_count + 1, "DamageNumber should be spawned after confirmed damage.")
	var physical_snapshot: Dictionary = damage_number_pool.call(
		"get_first_active_debug_snapshot",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(not physical_snapshot.is_empty(), "Spawned physical damage slot should be inspectable.")
	_test_damage_number_style(damage_number_pool, physical_snapshot)
	if damage_number_pool != null:
		_expect(
			damage_number_pool.call(
				"show_damage_number",
				7,
				Vector2(92.0, 64.0),
				Vector2.LEFT,
				EnemyConfig.DamageType.MAGIC
			) == true,
			"DamageNumberPool should accept a magic damage type."
		)
		var magic_snapshot: Dictionary = damage_number_pool.call(
			"get_first_active_debug_snapshot",
			EnemyConfig.DamageType.MAGIC
		)
		_expect(not magic_snapshot.is_empty(), "Magic damage slot should be inspectable.")
		_test_magic_damage_number_style(magic_snapshot)
	if damage_number_pool != null:
		await physics_frame
		_test_damage_number_pool_budget(damage_number_pool)
		await physics_frame
		await _test_offscreen_budget_priority(damage_number_pool)
		await physics_frame
		await _test_full_pool_replacement_and_lifecycle(damage_number_pool)

	_stop_audio_players(test_root)
	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame
	if failures.is_empty():
		print("DAMAGE_NUMBER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_damage_number_style(damage_number_pool: Node2D, snapshot: Dictionary) -> void:
	_expect(
		DamageNumberPool.DAMAGE_FONT.resource_path
			== "res://resources/font/ResourceHanRoundedCN-Medium.ttf",
		"DamageNumber should use the rounded font instead of the pixel font."
	)
	_expect(DamageNumberPool.FONT_SIZE == 9, "DamageNumber font should stay at its authored size.")
	_expect(DamageNumberPool.OUTLINE_SIZE == 2, "DamageNumber outline should stay readable.")
	_expect(DamageNumberPool.BASE_SIZE.y >= 20.0, "DamageNumber draw box must leave vertical room.")
	_expect(DamageNumberPool.BASE_SIZE.x >= 38.0, "DamageNumber draw box must leave horizontal room.")
	_expect(
		damage_number_pool.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR,
		"DamageNumber batch should use linear texture filtering."
	)
	var font_color := snapshot.get("font_color", Color.TRANSPARENT) as Color
	_expect(font_color.r > 0.9 and font_color.g < 0.25 and font_color.b < 0.2, "DamageNumber should be red.")
	var outline_color := snapshot.get("outline_color", Color.TRANSPARENT) as Color
	_expect(outline_color.r > outline_color.g and outline_color.r > outline_color.b, "DamageNumber outline should be dark red.")


func _test_magic_damage_number_style(snapshot: Dictionary) -> void:
	var font_color := snapshot.get("font_color", Color.TRANSPARENT) as Color
	_expect(font_color.b > 0.9 and font_color.r > 0.55 and font_color.g < 0.5, "Magic DamageNumber should be purple.")
	var outline_color := snapshot.get("outline_color", Color.TRANSPARENT) as Color
	_expect(outline_color.b > outline_color.r and outline_color.b > outline_color.g, "Magic DamageNumber outline should be dark purple.")


func _test_damage_number_pool_budget(damage_number_pool: DamageNumberPool) -> void:
	var child_count_before := damage_number_pool.get_child_count()
	var max_per_frame := int(damage_number_pool.get("max_numbers_per_frame"))
	var shown_count := 0
	for index in range(max_per_frame + 1):
		if damage_number_pool.call(
			"show_damage_number",
			1 + index,
			Vector2(80.0 + float(index), 80.0),
			Vector2.RIGHT
		) == true:
			shown_count += 1
	_expect(shown_count == max_per_frame, "DamageNumberPool should enforce the per-frame display budget.")
	_expect(damage_number_pool.get_child_count() == child_count_before, "DamageNumberPool should reuse fixed data slots.")


func _test_offscreen_budget_priority(damage_number_pool: DamageNumberPool) -> void:
	var camera := Camera2D.new()
	camera.enabled = true
	test_root.add_child(camera)
	camera.global_position = Vector2(64.0, 64.0)
	await process_frame

	damage_number_pool.set("max_numbers_per_frame", 2)
	damage_number_pool.set("budget_frame", Engine.get_process_frames())
	damage_number_pool.set("shown_this_frame", 0)
	damage_number_pool.set("budget_second_started_msec", Time.get_ticks_msec())
	damage_number_pool.set("shown_this_second", 0)
	var skipped_before := int(damage_number_pool.get("offscreen_requests_skipped"))
	_expect(
		not bool(damage_number_pool.call(
			"show_damage_number",
			99,
			Vector2(100000.0, 100000.0),
			Vector2.RIGHT
		)),
		"A far-offscreen damage number must be skipped."
	)
	_expect(
		int(damage_number_pool.get("offscreen_requests_skipped")) == skipped_before + 1,
		"Offscreen damage-number skips must be observable for performance audits."
	)
	_expect(
		bool(damage_number_pool.call(
			"show_damage_number",
			1,
			Vector2(64.0, 64.0),
			Vector2.RIGHT
		))
		and bool(damage_number_pool.call(
			"show_damage_number",
			2,
			Vector2(72.0, 64.0),
			Vector2.RIGHT
		)),
		"Offscreen requests must not consume either visible slot in the frame budget."
	)
	_expect(
		not bool(damage_number_pool.call(
			"show_damage_number",
			3,
			Vector2(80.0, 64.0),
			Vector2.RIGHT
		)),
		"Visible requests must still obey the configured per-frame ceiling."
	)
	camera.queue_free()


func _test_full_pool_replacement_and_lifecycle(
	damage_number_pool: DamageNumberPool
) -> void:
	# Expiring a full production batch in one update must clear every slot and
	# disable the only remaining process callback.
	damage_number_pool._process(DamageNumberPool.LIFETIME)
	_expect(
		damage_number_pool.get_active_count() == 0,
		"All damage-number slots must expire after the authored lifetime."
	)
	_expect(
		not damage_number_pool.is_processing(),
		"The shared batch process must stop once its final slot expires."
	)

	var replacement_pool := DAMAGE_NUMBER_POOL_SCRIPT.new() as DamageNumberPool
	replacement_pool.pool_size = 2
	replacement_pool.max_numbers_per_frame = 3
	replacement_pool.max_numbers_per_second = 3
	test_root.add_child(replacement_pool)
	await process_frame
	_expect(replacement_pool.show_damage_number(1, Vector2(64.0, 64.0)), "Slot 1 must activate.")
	_expect(replacement_pool.show_damage_number(2, Vector2(64.0, 64.0)), "Slot 2 must activate.")
	replacement_pool.slot_elapsed[0] = 0.1
	replacement_pool.slot_elapsed[1] = 0.2
	_expect(
		replacement_pool.show_damage_number(3, Vector2(64.0, 64.0)),
		"A full pool must recycle its oldest visual slot."
	)
	_expect(
		replacement_pool.get_active_count() == 2
		and replacement_pool.has_active_text("1")
		and replacement_pool.has_active_text("3")
		and not replacement_pool.has_active_text("2"),
		"Oldest-slot replacement must keep capacity and active_count stable."
	)
	for text_line in replacement_pool.slot_text_lines:
		_expect(
			text_line != null and text_line.get_size().x > 0.0,
			"Every active replacement slot must retain shaped TextLine data."
		)
	replacement_pool.queue_free()


func _stop_audio_players(node: Node) -> void:
	if node == null:
		return
	if node is AudioStreamPlayer:
		var audio_player := node as AudioStreamPlayer
		audio_player.stop()
		audio_player.stream = null
	elif node is AudioStreamPlayer2D:
		var audio_player_2d := node as AudioStreamPlayer2D
		audio_player_2d.stop()
		audio_player_2d.stream = null
	elif node is AudioStreamPlayer3D:
		var audio_player_3d := node as AudioStreamPlayer3D
		audio_player_3d.stop()
		audio_player_3d.stream = null
	for child in node.get_children():
		_stop_audio_players(child)
