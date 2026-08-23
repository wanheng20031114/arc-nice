extends SceneTree

const MpProjectileCoordinator := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const LINGLAN_SCENE := preload("res://scene/boss/linglan/linglan_boss.tscn")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const SKILL3_CONFIG := preload("res://resources/config/bosses/linglan_skill3.tres")
const SKILL4_CONFIG := preload("res://resources/config/bosses/linglan_skill4.tres")
const LASER_FIELD_SCENE := preload("res://scene/boss/linglan/linglan_skill4_laser_field.tscn")
const ORB_SCENE := preload("res://scene/boss/linglan/linglan_skill4_light_orb.tscn")
const LASER_FIELD_SCRIPT := preload("res://scene/boss/linglan/linglan_skill4_laser_field.gd")
const ORB_SCRIPT := preload("res://scene/boss/linglan/linglan_skill4_light_orb.gd")
const ORB_SCRIPT_PATH := "res://scene/boss/linglan/linglan_skill4_light_orb.gd"
const ORB_SCENE_PATH := "res://scene/boss/linglan/linglan_skill4_light_orb.tscn"
const ORB_SHADER_PATH := "res://scene/boss/linglan/linglan_skill3_light_orb.gdshader"
const GAME_SCENE := preload("res://scene/game_modes/standard/standard_game.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const TEST_RUNTIME_SCRIPT := preload(
	"res://dev_tools/fixtures/linglan_combat_test_runtime.gd"
)


class Skill4Host:
	extends "res://dev_tools/fixtures/linglan_combat_test_runtime.gd"

	var target_position := Vector2(104.0, 32.0)
	var requested_target_cells: Array[Array] = []
	var laser_bounds_calls: Array[Array] = []
	var orb_spawn_calls: Array[Dictionary] = []
	var projectile_records: Array[Dictionary] = []
	var action_records: Array[Dictionary] = []
	var laser_bounds := {
		"start_min": Vector2(-48.0, -16.0),
		"start_max": Vector2(288.0, 256.0),
		"final_min": Vector2(32.0, 64.0),
		"final_max": Vector2(208.0, 176.0),
	}

	func get_linglan_skill4_target_global_position(
		target_cell_a: Vector2i,
		target_cell_b: Vector2i
	) -> Vector2:
		requested_target_cells.append([target_cell_a, target_cell_b])
		return target_position

	func get_linglan_skill4_laser_bounds(
		left_cell_x: int,
		right_cell_x: int,
		top_cell_y: int,
		bottom_cell_y: int,
		inward_cell_distance: int
	) -> Dictionary:
		laser_bounds_calls.append([
			left_cell_x,
			right_cell_x,
			top_cell_y,
			bottom_cell_y,
			inward_cell_distance,
		])
		return laser_bounds

	func get_linglan_skill4_orb_spawn_global_position(x_cell: int, y_cell: int) -> Vector2:
		orb_spawn_calls.append({"x_cell": x_cell, "y_cell": y_cell})
		return Vector2(float(x_cell) * 16.0, float(y_cell) * 16.0)

	func register_local_projectile(
		projectile: Node,
		projectile_type: StringName,
		owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		speed: float,
		lifetime: float,
		pierces_enemies: bool = false,
		target_peer_id: int = 0,
		_target_enemy_net_id: int = 0,
		damage_source_snapshot: DamageSourceSnapshot = null
	) -> void:
		projectile_records.append({
			"projectile": projectile,
			"projectile_type": projectile_type,
			"owner_peer_id": owner_peer_id,
			"spawn_position": spawn_position,
			"direction": direction,
			"damage": damage,
			"speed": speed,
			"lifetime": lifetime,
			"pierces_enemies": pierces_enemies,
			"target_peer_id": target_peer_id,
			"damage_source_snapshot": damage_source_snapshot,
		})

	func broadcast_enemy_action(
		net_id: int,
		action_name: StringName,
		direction: Vector2,
		action_position: Vector2,
		action_id: int
	) -> void:
		action_records.append({
			"net_id": net_id,
			"action_name": action_name,
			"direction": direction,
			"action_position": action_position,
			"action_id": action_id,
		})


class LaserDamageReportHost:
	extends "res://dev_tools/fixtures/linglan_combat_test_runtime.gd"

	var damage_reports: Array[Dictionary] = []

	func request_multiplayer_player_damage(
		source_id: int,
		target_peer_id: int,
		damage: int,
		source_type: StringName,
		damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		_source_direction: Vector2 = Vector2.ZERO,
		_is_ranged: bool = false,
		_contact_preconsumed: bool = false,
		source_snapshot: DamageSourceSnapshot = null
	) -> bool:
		damage_reports.append({
			"source_id": source_id,
			"target_peer_id": target_peer_id,
			"damage": damage,
			"source_type": source_type,
			"damage_type": damage_type,
			"source_snapshot": source_snapshot,
		})
		return true


var failures: Array[String] = []
var test_root: CombatRuntimeBase


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = TEST_RUNTIME_SCRIPT.new()
	test_root.name = "LinglanSkill4SmokeTest"
	root.add_child(test_root)

	_test_skill4_config()
	_test_skill4_gpu_pulse_contract()
	await _test_skill4_scene_contract()
	await _test_laser_and_orb_damage()
	await _test_laser_overlap_tracking_and_multiplayer_event_ids()
	await _test_game_helpers()
	await _test_skill_rotation_policy()
	await _test_boss_skill4_schedule()
	await _test_multiplayer_proxy_skill4_has_no_laser()
	_test_multiplayer_projectile_instantiation()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("LINGLAN_SKILL4_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_skill4_config() -> void:
	_expect(SKILL4_CONFIG.skill_name == &"linglan_skill4", "Skill4 name mismatch.")
	_expect(SKILL4_CONFIG.target_cell_a == Vector2i(6, 2), "Skill4 target cell A mismatch.")
	_expect(SKILL4_CONFIG.target_cell_b == Vector2i(7, 2), "Skill4 target cell B mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.move_speed, 120.0), "Skill4 move speed mismatch.")
	_expect(SKILL4_CONFIG.laser_start_left_cell_x == -3, "Skill4 left laser cell mismatch.")
	_expect(SKILL4_CONFIG.laser_start_right_cell_x == 18, "Skill4 right laser cell mismatch.")
	_expect(SKILL4_CONFIG.laser_start_top_cell_y == -1, "Skill4 top laser cell mismatch.")
	_expect(SKILL4_CONFIG.laser_start_bottom_cell_y == 16, "Skill4 bottom laser cell mismatch.")
	_expect(SKILL4_CONFIG.laser_inward_cell_distance == 5, "Skill4 inward distance mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.laser_warning_duration, 1.6), "Skill4 laser warning duration mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.laser_shrink_duration, 3.0), "Skill4 laser shrink duration mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_start_delay, 0.5), "Skill4 orb start delay mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.laser_core_width, 6.0), "Skill4 laser core width mismatch.")
	_expect(SKILL4_CONFIG.laser_damage == 50, "Skill4 laser damage mismatch.")
	_expect(SKILL4_CONFIG.orb_candidate_min_y == 0, "Skill4 orb min row mismatch.")
	_expect(SKILL4_CONFIG.orb_candidate_max_y == 15, "Skill4 orb max row mismatch.")
	_expect(SKILL4_CONFIG.orb_count_per_side == 7, "Skill4 orb count mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_spawn_interval, 2.0), "Skill4 orb interval mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_spawn_duration, 14.0), "Skill4 orb duration mismatch.")
	_expect(SKILL4_CONFIG.get_orb_wave_count() == 7, "Skill4 must spawn seven orb waves.")
	_expect(is_equal_approx(SKILL4_CONFIG.get_orb_start_time(), 0.5), "Skill4 orb delay must be measured from skill start.")
	_expect(is_equal_approx(SKILL4_CONFIG.get_total_duration(), 14.5), "Skill4 total duration mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_speed, 40.0), "Skill4 orb speed mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_lifetime, 12.0), "Skill4 orb active lifetime mismatch.")
	_expect(SKILL4_CONFIG.orb_damage == 50, "Skill4 orb damage mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_radius, 8.0), "Skill4 orb radius mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_damage_radius, 6.0), "Skill4 orb damage radius mismatch.")
	_expect(SKILL4_CONFIG.laser_field_scene == null, "Skill4 must not configure a laser field scene.")
	_expect(SKILL4_CONFIG.orb_scene == ORB_SCENE, "Skill4 orb scene mismatch.")

	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = 2468
	var rows := SKILL4_CONFIG.get_random_orb_rows(random_generator)
	_expect(rows.size() == 7, "Skill4 must pick 7 orb rows.")
	var seen_rows: Dictionary = {}
	for row in rows:
		_expect(row >= 0 and row <= 15, "Skill4 picked an orb row outside 0..15.")
		_expect(not seen_rows.has(row), "Skill4 picked a duplicate orb row.")
		seen_rows[row] = true


func _test_skill4_gpu_pulse_contract() -> void:
	var shader_source := FileAccess.get_file_as_string(ORB_SHADER_PATH)
	var vertex_start := shader_source.find("void vertex()")
	var fragment_start := shader_source.find("void fragment()")
	_expect(
		vertex_start >= 0 and fragment_start > vertex_start,
		"Shared Linglan orb shader must expose inspectable vertex and fragment stages."
	)
	if vertex_start >= 0 and fragment_start > vertex_start:
		var vertex_source := shader_source.substr(vertex_start, fragment_start - vertex_start)
		var fragment_source := shader_source.substr(fragment_start)
		_expect(
			vertex_source.contains("TIME")
			and vertex_source.contains("gpu_pulse_frequency")
			and vertex_source.contains("gpu_pulse_min")
			and vertex_source.contains("gpu_pulse_max")
			and vertex_source.contains("gpu_pulse_phase")
			and vertex_source.contains("sin("),
			"Skill4 pulse must be calculated once per vertex from GPU TIME and configurable frequency/range/phase."
		)
		_expect(
			not fragment_source.contains("sin(")
			and fragment_source.contains("resolved_pulse"),
			"Linglan orb fragments must consume the interpolated pulse without recalculating its sine per pixel."
		)
	_expect(
		shader_source.contains("uniform bool gpu_pulse_enabled = false;")
		and shader_source.contains("instance uniform float gpu_pulse_phase = 0.0;"),
		"The shared shader must keep GPU pulse disabled by default so Skill3 retains manual pulse control."
	)

	var orb_script_source := FileAccess.get_file_as_string(ORB_SCRIPT_PATH)
	var physics_process_start := orb_script_source.find("func _physics_process")
	var physics_process_end := orb_script_source.find("\nfunc ", physics_process_start + 1)
	var physics_process_source := orb_script_source.substr(
		physics_process_start,
		physics_process_end - physics_process_start
	)
	_expect(
		not orb_script_source.contains("set_shader_parameter")
		and not orb_script_source.contains("_update_visual_pulse")
		and not orb_script_source.contains("_duplicate_polygon_materials"),
		"Skill4 orb scripts must not traverse or mutate five visual materials every physics frame."
	)
	_expect(
		physics_process_start >= 0
		and physics_process_end > physics_process_start
		and not physics_process_source.contains("shader_parameter"),
		"Skill4 orb physics ticks must not perform any CPU shader-parameter writes."
	)

	var orb_scene_source := FileAccess.get_file_as_string(ORB_SCENE_PATH)
	var material_start := orb_scene_source.find("[sub_resource type=\"ShaderMaterial\"")
	var node_start := orb_scene_source.find("[node name=", material_start)
	_expect(
		material_start >= 0
		and node_start > material_start
		and not orb_scene_source.substr(material_start, node_start - material_start).contains("resource_local_to_scene = true"),
		"Immutable Skill4 ShaderMaterials must be shared instead of duplicated for every orb instance."
	)


func _test_skill4_scene_contract() -> void:
	var field := LASER_FIELD_SCENE.instantiate() as LASER_FIELD_SCRIPT
	_expect(field != null, "Skill4 laser field scene must instantiate.")
	if field == null:
		return
	field.set_damage_source_snapshot(
		_make_linglan_source_snapshot(&"linglan_skill4_laser")
	)
	test_root.add_child(field)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(field)
	field.setup(
		Vector2(-48.0, -16.0),
		Vector2(288.0, 256.0),
		Vector2(32.0, 64.0),
		Vector2(208.0, 176.0),
		50,
		6.0,
		3.0
	)
	field.set_physics_process(false)
	await process_frame
	_expect(field.collision_layer == 128, "Skill4 laser must use EnemyProjectile collision layer.")
	_expect(field.collision_mask == 2, "Skill4 laser must only collide with Player.")
	_expect(is_equal_approx(field.get_laser_progress(), 0.0), "Skill4 laser progress must start at zero.")
	_expect(field.is_warning_active(), "Skill4 laser must start in warning mode.")
	var top_shape := field.get_node_or_null("TopShape") as CollisionShape2D
	var left_shape := field.get_node_or_null("LeftShape") as CollisionShape2D
	var top_core_line := field.get_node_or_null("VisualRoot/TopCore") as Line2D
	_expect(top_shape != null and top_shape.shape is RectangleShape2D, "Skill4 top laser must use a rectangle core.")
	_expect(left_shape != null and left_shape.shape is RectangleShape2D, "Skill4 left laser must use a rectangle core.")
	if top_shape != null and top_shape.shape is RectangleShape2D:
		_expect(is_equal_approx((top_shape.shape as RectangleShape2D).size.y, 1.5), "Skill4 warning horizontal laser core must be thin.")
	if left_shape != null and left_shape.shape is RectangleShape2D:
		_expect(is_equal_approx((left_shape.shape as RectangleShape2D).size.x, 1.5), "Skill4 warning vertical laser core must be thin.")
	for node_name in ["TopGlow", "TopCore", "TopCenter", "LeftGlow", "LeftCore", "LeftCenter"]:
		var line := field.get_node_or_null("VisualRoot/%s" % node_name) as Line2D
		_expect(line != null, "Skill4 laser visual missing %s." % node_name)
		if node_name.ends_with("Core") and line != null:
			_expect(line.width < 6.0, "Skill4 warning core visual must be thinner than active laser.")
	var initial_geometry_update_count := int(field.get("_geometry_update_count"))
	field.call("_physics_process", 0.5)
	_expect(
		int(field.get("_geometry_update_count")) == initial_geometry_update_count,
		"Skill4 laser must not rewrite static warning geometry every physics frame."
	)
	var warning_bounds := field.get_current_bounds()
	_expect(warning_bounds.position.is_equal_approx(Vector2(-48.0, -16.0)), "Skill4 warning min bounds must stay at start.")
	_expect(warning_bounds.end.is_equal_approx(Vector2(288.0, 256.0)), "Skill4 warning max bounds must stay at start.")
	field.call("_physics_process", 1.1)
	_expect(not field.is_warning_active(), "Skill4 laser warning must end before shrink starts.")
	if top_shape != null and top_shape.shape is RectangleShape2D:
		_expect(is_equal_approx((top_shape.shape as RectangleShape2D).size.y, 6.0), "Skill4 active horizontal laser core must be 6px high.")
	if left_shape != null and left_shape.shape is RectangleShape2D:
		_expect(is_equal_approx((left_shape.shape as RectangleShape2D).size.x, 6.0), "Skill4 active vertical laser core must be 6px wide.")
	field.call("_physics_process", 1.5)
	var mid_bounds := field.get_current_bounds()
	_expect(mid_bounds.position.is_equal_approx(Vector2(-8.0, 24.0)), "Skill4 laser midpoint min bounds mismatch.")
	_expect(mid_bounds.end.is_equal_approx(Vector2(248.0, 216.0)), "Skill4 laser midpoint max bounds mismatch.")
	if top_core_line != null:
		_expect(
			top_core_line.points.size() == 2
			and top_core_line.points[0].is_equal_approx(Vector2(-8.0, 24.0))
			and top_core_line.points[1].is_equal_approx(Vector2(248.0, 24.0)),
			"Skill4 laser midpoint must update the rendered top line."
		)
	if top_shape != null and top_shape.shape is RectangleShape2D:
		_expect(
			top_shape.position.is_equal_approx(Vector2(120.0, 24.0))
			and (top_shape.shape as RectangleShape2D).size.is_equal_approx(Vector2(256.0, 6.0)),
			"Skill4 laser midpoint must update the top collision rectangle."
		)
	if left_shape != null and left_shape.shape is RectangleShape2D:
		_expect(
			left_shape.position.is_equal_approx(Vector2(-8.0, 120.0))
			and (left_shape.shape as RectangleShape2D).size.is_equal_approx(Vector2(6.0, 192.0)),
			"Skill4 laser midpoint must update the left collision rectangle."
		)
	field.call("_physics_process", 1.5)
	var final_bounds := field.get_current_bounds()
	_expect(final_bounds.position.is_equal_approx(Vector2(32.0, 64.0)), "Skill4 laser final min bounds mismatch.")
	_expect(final_bounds.end.is_equal_approx(Vector2(208.0, 176.0)), "Skill4 laser final max bounds mismatch.")
	if top_core_line != null:
		_expect(
			top_core_line.points.size() == 2
			and top_core_line.points[0].is_equal_approx(Vector2(32.0, 64.0))
			and top_core_line.points[1].is_equal_approx(Vector2(208.0, 64.0)),
			"Skill4 laser final geometry must update the rendered top line."
		)
	if top_shape != null and top_shape.shape is RectangleShape2D:
		_expect(
			top_shape.position.is_equal_approx(Vector2(120.0, 64.0))
			and (top_shape.shape as RectangleShape2D).size.is_equal_approx(Vector2(176.0, 6.0)),
			"Skill4 laser final geometry must update the top collision rectangle."
		)
	var final_geometry_update_count := int(field.get("_geometry_update_count"))
	field.call("_physics_process", 0.75)
	_expect(
		int(field.get("_geometry_update_count")) == final_geometry_update_count,
		"Skill4 laser must stop rewriting geometry after shrink reaches its final bounds."
	)
	field.setup_multiplayer_visual_only()
	_expect(field.collision_layer == 0 and field.collision_mask == 0, "Skill4 proxy laser must disable collision layers.")
	if top_shape != null:
		_expect(top_shape.disabled, "Skill4 proxy laser must disable shape collision.")
	field.queue_free()
	await physics_frame

	var orb := ORB_SCENE.instantiate() as ORB_SCRIPT
	_expect(orb != null, "Skill4 orb scene must instantiate.")
	if orb != null:
		test_root.add_child(orb)
		(test_root as LinglanCombatTestRuntime).bind_linglan_node(orb)
		await process_frame
		_expect(orb.collision_layer == 128, "Skill4 orb must use EnemyProjectile collision layer.")
		_expect(orb.collision_mask == 2, "Skill4 orb must only collide with Player.")
		var orb_shape := orb.get_node_or_null("CollisionShape2D") as CollisionShape2D
		_expect(orb_shape != null and orb_shape.shape is CircleShape2D, "Skill4 orb must expose a circle collision shape.")
		if orb_shape != null and orb_shape.shape is CircleShape2D:
			_expect(is_equal_approx((orb_shape.shape as CircleShape2D).radius, 6.0), "Skill4 orb collision radius must be smaller than its visual radius.")
		var core := orb.get_node_or_null("VisualRoot/Core") as Polygon2D
		_expect(core != null and core.material is ShaderMaterial, "Skill4 orb core must use shader glow material.")
		if core != null and core.material is ShaderMaterial:
			var core_material := core.material as ShaderMaterial
			_expect(core_material.get_shader_parameter(&"gpu_pulse_enabled") == true, "Skill4 orb materials must enable GPU pulse.")
			_expect(is_equal_approx(float(core_material.get_shader_parameter(&"gpu_pulse_frequency")), 3.5), "Skill4 GPU pulse frequency changed.")
			_expect(is_equal_approx(float(core_material.get_shader_parameter(&"gpu_pulse_min")), 0.9), "Skill4 GPU pulse minimum changed.")
			_expect(is_equal_approx(float(core_material.get_shader_parameter(&"gpu_pulse_max")), 1.12), "Skill4 GPU pulse maximum changed.")
			var first_phase := float(core.get_instance_shader_parameter(&"gpu_pulse_phase"))
			_expect(
				is_equal_approx(first_phase, orb.gpu_pulse_phase),
				"Skill4 GPU pulse phase must be written once through the CanvasItem instance uniform."
			)
			var origin_shader_time := fmod(
				float(orb.gpu_pulse_origin_msec) * 0.001,
				orb.SHADER_TIME_ROLLOVER_SECONDS
			)
			_expect(
				absf(sin(origin_shader_time * TAU * orb.GPU_PULSE_FREQUENCY + first_phase)) < 0.0001,
				"Every Skill4 orb must begin its GPU pulse at the authored local-time midpoint."
			)
			await create_timer(0.05).timeout
			var comparison_orb := ORB_SCENE.instantiate() as ORB_SCRIPT
			test_root.add_child(comparison_orb)
			(test_root as LinglanCombatTestRuntime).bind_linglan_node(
				comparison_orb
			)
			await process_frame
			var comparison_core := comparison_orb.get_node_or_null("VisualRoot/Core") as Polygon2D
			_expect(
				comparison_core != null and comparison_core.material == core.material,
				"Skill4 orb instances must share immutable visual materials."
			)
			if comparison_core != null:
				var comparison_phase := float(
					comparison_core.get_instance_shader_parameter(&"gpu_pulse_phase")
				)
				_expect(
					not is_equal_approx(comparison_phase, first_phase),
					"Skill4 orbs born at different times must keep independent local pulse phases."
				)
			comparison_orb.queue_free()
		orb.queue_free()
	await process_frame
	await physics_frame


func _test_laser_and_orb_damage() -> void:
	var laser_player := _spawn_player(test_root, Vector2(0.0, -16.0), 1, 200)
	laser_player.physical_defense = 0
	laser_player.magic_defense = 50
	laser_player._base_magic_defense = 50
	var field := LASER_FIELD_SCENE.instantiate() as LASER_FIELD_SCRIPT
	field.set_damage_source_snapshot(
		_make_linglan_source_snapshot(&"linglan_skill4_laser")
	)
	test_root.add_child(field)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(field)
	field.setup(
		Vector2(-48.0, -16.0),
		Vector2(288.0, 256.0),
		Vector2(32.0, 64.0),
		Vector2(208.0, 176.0),
		50,
		6.0,
		3.0
	)
	field.set_physics_process(false)
	await process_frame
	await physics_frame
	await physics_frame
	_expect(
		field.overlapping_players.has(laser_player.get_instance_id()),
		"Skill4 laser must track a player already overlapping when the field enters the scene."
	)
	field.call("_physics_process", 0.016)
	_expect(
		laser_player.current_health == 175,
		"Skill4 laser warning line must use magic damage and respect 50 magic defense, health=%d." % laser_player.current_health
	)
	field.call("_physics_process", 0.016)
	_expect(
		laser_player.current_health == 175,
		"Skill4 laser must respect contact damage cooldown, health=%d." % laser_player.current_health
	)
	field.call("_physics_process", 1.6)
	_expect(
		laser_player.current_health == 150,
		"Skill4 laser must keep contact damage after warning, health=%d." % laser_player.current_health
	)
	laser_player.global_position = Vector2(500.0, 500.0)
	await physics_frame
	await physics_frame
	_expect(
		not field.overlapping_players.has(laser_player.get_instance_id()),
		"Skill4 laser must stop tracking a player after body_exited."
	)
	field.call("_physics_process", field.contact_damage_interval + 0.1)
	_expect(
		laser_player.current_health == 150,
		"Skill4 laser must not damage a player after body_exited."
	)
	field.queue_free()
	laser_player.queue_free()
	await process_frame

	var invulnerable_player := _spawn_player(test_root, Vector2(500.0, 500.0), 3, 200)
	invulnerable_player.magic_defense = 0
	invulnerable_player._base_magic_defense = 0
	var retry_field := LASER_FIELD_SCENE.instantiate() as LASER_FIELD_SCRIPT
	retry_field.set_damage_source_snapshot(
		_make_linglan_source_snapshot(&"linglan_skill4_laser")
	)
	test_root.add_child(retry_field)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(retry_field)
	retry_field.set_physics_process(false)
	invulnerable_player.invincibility_time_left = 1.0
	retry_field.call("_on_body_entered", invulnerable_player)
	_expect(
		invulnerable_player.current_health == 200,
		"Skill4 laser must respect an invulnerable player's rejected contact pulse."
	)
	invulnerable_player.invincibility_time_left = 0.0
	retry_field.call("_physics_process", retry_field.contact_damage_interval * 0.5)
	_expect(
		invulnerable_player.current_health == 200,
		"Rejected Skill4 laser pulses must still retain the authored contact cooldown."
	)
	retry_field.call("_physics_process", retry_field.contact_damage_interval * 0.5)
	_expect(
		invulnerable_player.current_health == 150,
		"Skill4 laser must retry after the rejected pulse's contact cooldown expires."
	)
	retry_field.queue_free()
	invulnerable_player.queue_free()
	await process_frame

	var orb_player := _spawn_player(test_root, Vector2(4.0, 0.0), 2, 200)
	orb_player.physical_defense = 0
	orb_player.magic_defense = 50
	orb_player._base_magic_defense = 50
	await physics_frame
	var orb := ORB_SCENE.instantiate() as ORB_SCRIPT
	orb.set_damage_source_snapshot(
		_make_linglan_source_snapshot(&"linglan_skill4_orb")
	)
	test_root.add_child(orb)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(orb)
	orb.global_position = Vector2.ZERO
	orb.setup(Vector2.RIGHT, 50, 0.0, 10.0, 8.0)
	await physics_frame
	await process_frame
	orb.call("_physics_process", 0.016)
	_expect(orb_player.current_health == 175, "Skill4 orb must use magic damage and respect 50 magic defense.")
	orb.call("_physics_process", 0.016)
	_expect(orb_player.current_health == 175, "Skill4 orb must not damage the same player twice.")
	orb.queue_free()
	orb_player.queue_free()
	await process_frame

	var moving_orb := ORB_SCENE.instantiate() as ORB_SCRIPT
	test_root.add_child(moving_orb)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(moving_orb)
	moving_orb.global_position = Vector2.ZERO
	moving_orb.setup(Vector2.LEFT, 1, 40.0, 10.0, 8.0)
	moving_orb.call("_physics_process", 0.5)
	_expect(moving_orb.global_position.is_equal_approx(Vector2(-20.0, 0.0)), "Skill4 orb must move at configured speed.")
	moving_orb.queue_free()
	await process_frame


func _test_laser_overlap_tracking_and_multiplayer_event_ids() -> void:
	var report_host := LaserDamageReportHost.new()
	report_host.name = "LaserDamageReportHost"
	root.add_child(report_host)

	var field := LASER_FIELD_SCENE.instantiate() as LASER_FIELD_SCRIPT
	field.set_damage_source_snapshot(
		DamageSourceSnapshot.create(
			CombatRelationService.HOSTILE_WAVE,
			0,
			4400,
			0,
			&"linglan_skill4_laser"
		)
	)
	report_host.add_child(field)
	report_host.bind_linglan_node(field)
	field.setup(
		Vector2(-48.0, -16.0),
		Vector2(288.0, 256.0),
		Vector2(32.0, 64.0),
		Vector2(208.0, 176.0),
		50,
		6.0,
		3.0
	)
	_expect(
		field.damage_source_snapshot != null
		and field.damage_source_snapshot.source_faction_id
			== CombatRelationService.HOSTILE_WAVE,
		"Skill4 laser fixture must retain its configured frozen cast source."
	)
	field.set_physics_process(false)

	# Advance close to the former global query boundary before contact. Repeated damage
	# must still be timed from this player's own entry hit, not from a field-wide phase.
	field.call("_physics_process", 0.49)
	var player := _spawn_player(report_host, Vector2(500.0, 500.0), 77, 200)
	field.call("_on_body_entered", player)
	_expect(
		report_host.damage_reports.size() == 1,
		"Skill4 laser must damage a newly overlapping player immediately."
	)
	field.call("_on_body_exited", player)
	field.call("_on_body_entered", player)
	_expect(
		report_host.damage_reports.size() == 1,
		"Skill4 laser must preserve contact cooldown across a quick exit and re-entry."
	)
	field.call("_physics_process", 0.49)
	_expect(
		report_host.damage_reports.size() == 1,
		"Skill4 laser must preserve the entered player's full contact cooldown."
	)
	field.call("_physics_process", 0.02)
	_expect(
		report_host.damage_reports.size() == 2,
		"Skill4 laser must repeat damage about 0.5s after entry regardless of the old query phase."
	)
	if report_host.damage_reports.size() == 2:
		_expect(
			int(report_host.damage_reports[0]["source_id"])
			!= int(report_host.damage_reports[1]["source_id"]),
			"Repeated Skill4 laser pulses must use distinct multiplayer event IDs."
		)
		_expect(
			report_host.damage_reports[0]["source_type"] == &"linglan_skill4_laser"
			and report_host.damage_reports[1]["source_type"] == &"linglan_skill4_laser",
			"Skill4 laser event IDs must not change the authored damage source type."
		)
		for report in report_host.damage_reports:
			var source_snapshot := report.get("source_snapshot") as DamageSourceSnapshot
			var source_details := "null"
			if source_snapshot != null:
				source_details = "faction=%d type=%s" % [
					source_snapshot.source_faction_id,
					source_snapshot.source_type,
				]
			_expect(
				source_snapshot != null
				and source_snapshot.source_faction_id
					== CombatRelationService.HOSTILE_WAVE
				and source_snapshot.source_type == &"linglan_skill4_laser",
				"Skill4 laser pulses must retain the frozen hostile cast source: %s report=%s."
				% [source_details, report]
			)
	field.call("_on_body_exited", player)
	field.call("_physics_process", field.contact_damage_interval + 0.1)
	_expect(
		report_host.damage_reports.size() == 2,
		"Skill4 laser must stop repeated damage as soon as the player exits."
	)

	var malformed_field := LASER_FIELD_SCENE.instantiate() as LASER_FIELD_SCRIPT
	var malformed_source_accepted := malformed_field.set_damage_source_snapshot(
		DamageSourceSnapshot.create(
			CombatRelationService.HOSTILE_WAVE,
			0,
			4401,
			0,
			&""
		)
	)
	report_host.add_child(malformed_field)
	report_host.bind_linglan_node(malformed_field)
	malformed_field.setup(
		Vector2(-48.0, -16.0),
		Vector2(288.0, 256.0),
		Vector2(32.0, 64.0),
		Vector2(208.0, 176.0),
		50,
		6.0,
		3.0
	)
	malformed_field.set_physics_process(false)
	malformed_field.call("_on_body_entered", player)
	_expect(
		not malformed_source_accepted
		and not malformed_field.damage_enabled
		and malformed_field.collision_layer == 0
		and malformed_field.collision_mask == 0
		and report_host.damage_reports.size() == 2,
		"Skill4 laser must fail closed and emit zero requests for an empty source type."
	)

	report_host.queue_free()
	await process_frame
	await physics_frame


func _test_game_helpers() -> void:
	var game := GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame scene must instantiate for Skill4 helper checks.")
	if game == null:
		return
	game.auto_start_waves = false
	test_root.add_child(game)
	await process_frame
	await physics_frame
	var ground_layer := game.get_node("GroundTileMapLayer") as TileMapLayer
	var expected_target := (
		ground_layer.to_global(ground_layer.map_to_local(SKILL4_CONFIG.target_cell_a))
		+ ground_layer.to_global(ground_layer.map_to_local(SKILL4_CONFIG.target_cell_b))
	) * 0.5
	var actual_target := game.get_linglan_skill4_target_global_position(
		SKILL4_CONFIG.target_cell_a,
		SKILL4_CONFIG.target_cell_b
	)
	_expect(actual_target.is_equal_approx(expected_target), "StandardGame must resolve Skill4 midpoint through map_to_local().")
	var bounds := game.get_linglan_skill4_laser_bounds(-3, 18, -1, 16, 5)
	_expect(
		(bounds.get("start_min") as Vector2).is_equal_approx(ground_layer.to_global(ground_layer.map_to_local(Vector2i(-3, -1)))),
		"StandardGame Skill4 start min bounds mismatch."
	)
	_expect(
		(bounds.get("final_max") as Vector2).is_equal_approx(ground_layer.to_global(ground_layer.map_to_local(Vector2i(13, 11)))),
		"StandardGame Skill4 final max bounds mismatch."
	)
	var orb_position := game.get_linglan_skill4_orb_spawn_global_position(-3, 7)
	_expect(
		orb_position.is_equal_approx(ground_layer.to_global(ground_layer.map_to_local(Vector2i(-3, 7)))),
		"StandardGame Skill4 orb spawn position must use cell center."
	)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_skill_rotation_policy() -> void:
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan boss scene must instantiate for skill rotation checks.")
	if boss == null:
		return
	test_root.add_child(boss)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(boss)
	await process_frame

	var start_position := Vector2(123.0, -45.0)
	boss.global_position = start_position
	boss.call("_begin_skill1_attack")
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL1,
		"Skill1 must start as an in-place attack phase."
	)
	_expect(
		boss.global_position.is_equal_approx(start_position),
		"Skill1 must not move Linglan before attacking."
	)
	_expect(boss.velocity.is_equal_approx(Vector2.ZERO), "Skill1 must not assign movement velocity.")

	boss.call("_reset_skill_state")
	boss.skill_order_random.seed = 424242
	_expect(int(boss.call("_get_next_skill_number", 1)) == 2, "Opening order must continue Skill1 -> Skill2.")
	_expect(int(boss.call("_get_next_skill_number", 2)) == 3, "Opening order must continue Skill2 -> Skill3.")
	_expect(int(boss.call("_get_next_skill_number", 3)) == 4, "Opening order must continue Skill3 -> Skill4.")

	var previous_skill := 4
	var random_counts := {
		1: 0,
		2: 0,
		3: 0,
		4: 0,
	}
	for _index in range(40):
		var next_skill := int(boss.call("_get_next_skill_number", previous_skill))
		_expect(next_skill >= 1 and next_skill <= 4, "Random Skill%s must be ready." % next_skill)
		_expect(next_skill != previous_skill, "Random skills must not repeat consecutively.")
		random_counts[next_skill] = int(random_counts.get(next_skill, 0)) + 1
		previous_skill = next_skill

	var minimum_count := 2147483647
	var maximum_count := 0
	for count in random_counts.values():
		minimum_count = mini(minimum_count, int(count))
		maximum_count = maxi(maximum_count, int(count))
	_expect(
		maximum_count - minimum_count <= 1,
		"Random skill usage must stay relatively even: %s." % str(random_counts)
	)

	boss.queue_free()
	await process_frame
	await physics_frame


func _test_boss_skill4_schedule() -> void:
	var host := Skill4Host.new()
	host.name = "Skill4Host"
	root.add_child(host)

	var player := _spawn_player(host, Vector2(240.0, 0.0), 7, 200)
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan scene must instantiate for Skill4 schedule.")
	if boss == null:
		host.queue_free()
		return
	host.add_child(boss)
	host.bind_linglan_node(boss)
	await process_frame
	await physics_frame
	boss.global_position = Vector2(180.0, -72.0)
	boss.config = LINGLAN_CONFIG
	boss.activate_boss(player, null, host, host.linglan_boss_runtime_port)
	boss.boss_skill_phase = LinglanBoss.BossSkillPhase.SKILL3
	boss.skill3_elapsed = SKILL3_CONFIG.duration
	boss.skill3_shots_fired = SKILL3_CONFIG.get_shot_count()
	boss.call("_physics_process", 0.016)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.POST_SKILL_IDLE,
		"Skill3 completion must enter the 2s post-skill idle."
	)
	boss.call("_physics_process", 2.01)
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL4, "Post-skill idle must hand off to MOVE_TO_SKILL4.")
	_expect(
		host.requested_target_cells == [[SKILL4_CONFIG.target_cell_a, SKILL4_CONFIG.target_cell_b]],
		"Skill4 move must request target cells (6,2)/(7,2)."
	)

	var sprite := boss.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var saw_move_animation := false
	for _step in range(180):
		if boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL4 and sprite != null:
			saw_move_animation = saw_move_animation or sprite.animation == &"move"
		boss.call("_physics_process", 1.0 / 60.0)
		if boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL4:
			break
	_expect(saw_move_animation, "Skill4 movement phase must play Linglan move animation.")
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL4, "Linglan must enter Skill4 after reaching target.")
	_expect(boss.global_position.distance_to(host.target_position) <= 2.0, "Linglan did not arrive at Skill4 target.")
	_expect(host.laser_bounds_calls.is_empty(), "Skill4 must not request obsolete laser bounds.")
	_expect(_count_skill4_laser_fields(host) == 0, "Skill4 must not spawn a laser field.")
	_expect(host.action_records.size() == 1, "Skill4 must broadcast one start action.")
	if sprite != null:
		_expect(sprite.animation == &"attack", "Skill4 attack phase must play Linglan attack animation.")

	boss.call("_physics_process", 0.49)
	_expect(host.projectile_records.is_empty(), "Skill4 must wait 0.5s from skill start before orb waves.")
	boss.call("_physics_process", 0.02)
	_expect(host.projectile_records.size() == 14, "Skill4 first wave must spawn 7 orbs per side.")
	_expect(_first_wave_rows_are_unique_per_side(host), "Skill4 first wave rows must be unique per side.")
	for _step in range(900):
		boss.call("_physics_process", 1.0 / 60.0)
		if boss.boss_skill_phase == LinglanBoss.BossSkillPhase.POST_SKILL_IDLE:
			break
	var expected_projectile_total := (
		SKILL4_CONFIG.get_orb_wave_count()
		* SKILL4_CONFIG.orb_count_per_side
		* 2
	)
	_expect(host.projectile_records.size() == expected_projectile_total, "Skill4 must spawn exactly seven two-sided waves.")
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.POST_SKILL_IDLE,
		"Skill4 must enter post-skill idle after its 14.5s cycle."
	)
	_expect(boss.skill4_laser_field == null, "Skill4 must clear the laser field when the skill ends.")
	for record in host.projectile_records:
		_expect(record.get("projectile_type") == &"linglan_skill4_orb", "Skill4 registered wrong projectile type.")
		_expect(int(record.get("damage", 0)) == 50, "Skill4 registered wrong orb damage.")
		_expect(is_equal_approx(float(record.get("speed", 0.0)), 40.0), "Skill4 registered wrong orb speed.")
		_expect(is_equal_approx(float(record.get("lifetime", 0.0)), 12.0), "Skill4 registered wrong orb active lifetime.")
		var source_snapshot := record.get("damage_source_snapshot") as DamageSourceSnapshot
		_expect(
			source_snapshot != null
			and source_snapshot.source_faction_id == CombatRelationService.HOSTILE_WAVE
			and source_snapshot.source_type == &"linglan_skill4_orb",
			"Skill4 orb must freeze Linglan's hostile launch source."
		)

	host.queue_free()
	await process_frame
	await physics_frame


func _test_multiplayer_proxy_skill4_has_no_laser() -> void:
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan scene did not instantiate for proxy Skill4 laser-removal contract.")
	if boss == null:
		return
	test_root.add_child(boss)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(boss)
	await process_frame
	boss.configure_multiplayer_proxy()

	boss.play_multiplayer_enemy_action(&"linglan_skill4_start", Vector2.ZERO, 1)
	await process_frame
	_expect(
		_get_skill4_laser_fields(test_root).is_empty(),
		"Proxy Skill4 actions must not recreate the removed laser field."
	)

	if is_instance_valid(boss):
		boss.queue_free()
	await process_frame
	await physics_frame


func _test_multiplayer_projectile_instantiation() -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MP game scene must instantiate for Skill4 projectile registry.")
	if mp_game == null:
		return
	var coordinator := (
		mp_game.get_node("ProjectileCoordinator") as MpProjectileCoordinator
	)
	coordinator.bind_runtime(test_root)
	var registry_config := SKILL4_CONFIG.duplicate(true) as LinglanSkill4Config
	registry_config.orb_radius = 11.0
	registry_config.orb_damage_radius = 9.0
	coordinator.set("_linglan_skill4_config", registry_config)
	var projectile := coordinator.instantiate_projectile(
		&"linglan_skill4_orb",
		999999,
		Vector2.LEFT,
		50,
		40.0,
		12.0,
		false,
		0
	) as ORB_SCRIPT
	_expect(projectile != null, "Multiplayer registry must instantiate linglan_skill4_orb.")
	if projectile != null:
		_expect(projectile.direction.is_equal_approx(Vector2.LEFT), "Registry Skill4 orb direction mismatch.")
		_expect(projectile.damage == 50, "Registry Skill4 orb damage mismatch.")
		_expect(is_equal_approx(projectile.speed, 40.0), "Registry Skill4 orb speed mismatch.")
		_expect(is_equal_approx(projectile.remaining_lifetime, 12.0), "Registry Skill4 orb active lifetime mismatch.")
		_expect(is_equal_approx(projectile.orb_radius, 11.0), "Registry Skill4 orb must read radius from config.")
		_expect(is_equal_approx(projectile.damage_radius, 9.0), "Registry Skill4 orb must read damage radius from config.")
		projectile.free()
	coordinator.unbind_runtime(test_root)
	mp_game.free()


func _spawn_player(parent: Node, position: Vector2, peer_id: int, health: int) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	parent.add_child(player)
	player.global_position = position
	player.peer_id = peer_id
	player._base_max_health = health
	player.max_health = health
	player.current_health = health
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	if player.health_bar != null:
		player.health_bar.setup(player.max_health, player.current_health)
	return player


func _make_linglan_source_snapshot(source_type: StringName) -> DamageSourceSnapshot:
	return DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		9401,
		0,
		source_type
	)


func _count_skill4_laser_fields(parent: Node) -> int:
	return _get_skill4_laser_fields(parent).size()


func _get_skill4_laser_fields(parent: Node) -> Array[Node]:
	var fields: Array[Node] = []
	for child in parent.get_children():
		if child.get_script() == LASER_FIELD_SCRIPT:
			fields.append(child)
	return fields


func _first_wave_rows_are_unique_per_side(host: Skill4Host) -> bool:
	if host.orb_spawn_calls.size() < 14:
		return false
	var left_rows: Dictionary = {}
	var right_rows: Dictionary = {}
	for index in range(14):
		var call := host.orb_spawn_calls[index]
		var x_cell := int(call.get("x_cell", 0))
		var y_cell := int(call.get("y_cell", -999))
		if x_cell == SKILL4_CONFIG.laser_start_left_cell_x:
			if left_rows.has(y_cell):
				return false
			left_rows[y_cell] = true
		elif x_cell == SKILL4_CONFIG.laser_start_right_cell_x:
			if right_rows.has(y_cell):
				return false
			right_rows[y_cell] = true
	return left_rows.size() == 7 and right_rows.size() == 7


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
