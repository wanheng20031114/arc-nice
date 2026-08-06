extends SceneTree

const BASIC_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const MOTION_STATUS_SHADER_PATH := "res://scene/combat/feedback/shaders/entity_motion_status.gdshader"
const ELECTRIC_OVERLAY_PARAMETER := &"electric_attachment_overlay_strength"
const ZONE_A_ID := 91_001
const ZONE_B_ID := 91_002
const OTHER_SLOW_SOURCE_ID := 91_003
const FLOAT_EPSILON := 0.0001

var failures: Array[String] = []
var fixture: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "EnemyElectricStatusSmokeTest"
	root.add_child(fixture)
	current_scene = fixture

	_test_shader_contract()
	await _test_attachment_and_visual_mask()
	await _test_non_stacking_zone_slow_sources()
	await _test_lifecycle_and_proxy_visual_cleanup()

	current_scene = null
	fixture.queue_free()
	await process_frame

	if failures.is_empty():
		print("ENEMY_ELECTRIC_STATUS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_shader_contract() -> void:
	var shader_file := FileAccess.open(MOTION_STATUS_SHADER_PATH, FileAccess.READ)
	_expect(shader_file != null, "Electric status shader must be readable.")
	if shader_file == null:
		return
	var shader_source := shader_file.get_as_text()
	_expect(
		shader_source.contains(
			"instance uniform float electric_attachment_overlay_strength"
		),
		"Electric attachment strength must be a per-enemy instance uniform."
	)
	var electric_block_start := shader_source.find(
		"if (electric_attachment_overlay_strength"
	)
	var burn_block_start := shader_source.find("if (burn_overlay_strength")
	_expect(
		electric_block_start >= 0 and burn_block_start > electric_block_start,
		"Electric attachment must have a dedicated cyan overlay block."
	)
	if electric_block_start >= 0 and burn_block_start > electric_block_start:
		var electric_block := shader_source.substr(
			electric_block_start,
			burn_block_start - electric_block_start
		)
		_expect(
			electric_block.contains("TIME")
			and electric_block.contains("texture_color.a > 0.0"),
			"Electric animation must stay GPU-driven and inside existing sprite pixels."
		)


func _test_attachment_and_visual_mask() -> void:
	var enemy := _spawn_enemy()
	var sprite := enemy.animated_sprite
	_expect(
		not enemy.has_electric_element_attachment(),
		"A fresh enemy must not inherit an electric attachment."
	)
	_expect(
		enemy.apply_electric_element_attachment(),
		"The first electric attachment must be accepted."
	)
	_expect(
		enemy.has_electric_element_attachment(),
		"The accepted electric attachment must be queryable in O(1)."
	)
	_expect(
		(
			enemy.get_collectible_visual_status_mask()
			& Enemy.ELECTRIC_ATTACHMENT_VISUAL_STATUS_MASK
		) != 0,
		"Electric attachment must occupy enemy visual status bit 16."
	)
	_expect(
		sprite.material != null
		and _is_close(
			_get_instance_shader_float(sprite, ELECTRIC_OVERLAY_PARAMETER),
			Enemy.ELECTRIC_ATTACHMENT_OVERLAY_ACTIVE_STRENGTH
		),
		"An attached authoritative enemy must enable its cyan overlay once."
	)
	_expect(
		not enemy.apply_electric_element_attachment()
		and enemy.elemental_attachment_mask == Enemy.ELEMENTAL_ATTACHMENT_ELECTRIC,
		"Repeated attachment must be idempotent without accumulating state."
	)

	var unrelated_element_mask := 1 << 1
	enemy.elemental_attachment_mask |= unrelated_element_mask
	enemy.clear_electric_surge_state()
	_expect(
		not enemy.has_electric_element_attachment()
		and enemy.elemental_attachment_mask == unrelated_element_mask
		and (
			enemy.get_collectible_visual_status_mask()
			& Enemy.ELECTRIC_ATTACHMENT_VISUAL_STATUS_MASK
		) == 0,
		"Electric cleanup must clear only its permanent elemental attachment bit."
	)
	_expect(
		_is_close(
			_get_instance_shader_float(sprite, ELECTRIC_OVERLAY_PARAMETER),
			0.0
		),
		"Clearing the attachment must disable its shader instance parameter."
	)
	await _free_enemy(enemy)


func _test_non_stacking_zone_slow_sources() -> void:
	var enemy := _spawn_enemy()
	enemy.add_move_speed_modifier(OTHER_SLOW_SOURCE_ID, 0.8)
	_expect(
		not enemy.add_electric_surge_slow_source(0),
		"Zone id zero must not create an unremovable electric slow source."
	)
	_expect(
		enemy.add_electric_surge_slow_source(ZONE_A_ID)
		and enemy.get_electric_surge_slow_source_count() == 1
		and _is_close(
			enemy.get_effective_move_speed_multiplier(),
			0.8 * Enemy.ELECTRIC_SURGE_MOVE_SPEED_MULTIPLIER
		),
		"The first zone must combine one 35% slow with unrelated modifiers."
	)
	_expect(
		not enemy.add_electric_surge_slow_source(ZONE_A_ID)
		and enemy.get_electric_surge_slow_source_count() == 1,
		"Repeated entry into the same zone must be idempotent."
	)
	_expect(
		enemy.add_electric_surge_slow_source(ZONE_B_ID)
		and enemy.get_electric_surge_slow_source_count() == 2
		and _is_close(
			enemy.get_effective_move_speed_multiplier(),
			0.8 * Enemy.ELECTRIC_SURGE_MOVE_SPEED_MULTIPLIER
		)
		and enemy.move_speed_modifiers.has(
			Enemy.ELECTRIC_SURGE_MOVE_SPEED_SOURCE_ID
		),
		"Overlapping Tango zones must retain one non-stacking electric slow."
	)
	_expect(
		enemy.remove_electric_surge_slow_source(ZONE_A_ID)
		and enemy.get_electric_surge_slow_source_count() == 1
		and _is_close(
			enemy.get_effective_move_speed_multiplier(),
			0.8 * Enemy.ELECTRIC_SURGE_MOVE_SPEED_MULTIPLIER
		),
		"Leaving one overlap must keep the remaining zone's slow."
	)
	_expect(
		enemy.remove_electric_surge_slow_source(ZONE_B_ID)
		and enemy.get_electric_surge_slow_source_count() == 0
		and _is_close(enemy.get_effective_move_speed_multiplier(), 0.8)
		and not enemy.move_speed_modifiers.has(
			Enemy.ELECTRIC_SURGE_MOVE_SPEED_SOURCE_ID
		),
		"Leaving the final zone must remove only the electric slow."
	)
	_expect(
		not enemy.remove_electric_surge_slow_source(ZONE_B_ID),
		"Repeated zone exit must not mutate movement state."
	)
	enemy.remove_move_speed_modifier(OTHER_SLOW_SOURCE_ID)
	await _free_enemy(enemy)


func _test_lifecycle_and_proxy_visual_cleanup() -> void:
	var enemy := _spawn_enemy()
	enemy.apply_electric_element_attachment()
	enemy.add_electric_surge_slow_source(ZONE_A_ID)
	enemy.setup(BASIC_ENEMY_CONFIG, null, null)
	_expect(
		not enemy.has_electric_element_attachment()
		and enemy.get_electric_surge_slow_source_count() == 0
		and _is_close(enemy.get_effective_move_speed_multiplier(), 1.0),
		"Enemy setup must clear attachment and zone sources from a prior lifecycle."
	)
	await _free_enemy(enemy)

	var proxy := _spawn_enemy()
	proxy.configure_multiplayer_proxy()
	proxy.apply_multiplayer_visual_status_mask(
		Enemy.ELECTRIC_ATTACHMENT_VISUAL_STATUS_MASK
	)
	_expect(
		proxy.network_visual_status_mask
		== Enemy.ELECTRIC_ATTACHMENT_VISUAL_STATUS_MASK
		and _is_close(
			_get_instance_shader_float(
				proxy.animated_sprite,
				ELECTRIC_OVERLAY_PARAMETER
			),
			Enemy.ELECTRIC_ATTACHMENT_OVERLAY_ACTIVE_STRENGTH
		),
		"A proxy must reconstruct bit-16 electric visuals without gameplay state."
	)
	_expect(
		not proxy.apply_electric_element_attachment()
		and not proxy.add_electric_surge_slow_source(ZONE_A_ID),
		"A multiplayer proxy must reject authoritative attachment and slow state."
	)
	proxy.apply_multiplayer_visual_status_mask(0)
	_expect(
		proxy.network_visual_status_mask == 0
		and _is_close(
			_get_instance_shader_float(
				proxy.animated_sprite,
				ELECTRIC_OVERLAY_PARAMETER
			),
			0.0
		),
		"Clearing the proxy mask must remove the cyan attachment overlay."
	)
	await _free_enemy(proxy)


func _spawn_enemy() -> Enemy:
	var enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	fixture.add_child(enemy)
	enemy.setup(BASIC_ENEMY_CONFIG, null, null)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.hit_audio.stream = null
	enemy.death_audio.stream = null
	return enemy


func _free_enemy(enemy: Enemy) -> void:
	if enemy != null and is_instance_valid(enemy):
		enemy.queue_free()
	await process_frame


func _get_instance_shader_float(
	canvas_item: CanvasItem,
	parameter_name: StringName
) -> float:
	if canvas_item == null:
		return 0.0
	var value: Variant = canvas_item.get_instance_shader_parameter(parameter_name)
	return float(value) if value != null else 0.0


func _is_close(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= FLOAT_EPSILON


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
