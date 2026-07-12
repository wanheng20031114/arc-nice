extends SceneTree

# This probe requires a real rendering driver. It isolates the persistent visual
# and physics costs owned by enemy variants while keeping the camera, map, enemy
# count, placement and base body registration stable across each A/B pair.
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const GREEN_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_green_shell.tres"
)
const GUARDIAN_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_guardian.tres"
)
const TOWER_WAVE_04 := preload(
	"res://resources/config/campaigns/tower_defense/singleplayer/wave_04.tres"
)
const TOWER_WAVE_05 := preload(
	"res://resources/config/campaigns/tower_defense/singleplayer/wave_05.tres"
)

const DEFAULT_ENEMY_COUNT := 300
const DEFAULT_WARMUP_FRAMES := 60
const DEFAULT_SAMPLE_FRAMES := 180
const DEFAULT_SEED := 20260713

const ENEMY_COLUMNS := 20
const ENEMY_SPACING := Vector2(14.0, 13.0)
const FIXTURE_CENTER := Vector2(512.0, 352.0)
const CLEANUP_SETTLE_FRAMES := 6

var failures: Array[String] = []
var game: GameTowerDefense = null
var enemies: Array[Enemy] = []
var viewport_rid := RID()

var enemy_count := DEFAULT_ENEMY_COUNT
var warmup_frames := DEFAULT_WARMUP_FRAMES
var sample_frames := DEFAULT_SAMPLE_FRAMES
var fixed_seed := DEFAULT_SEED
var current_cohort := &"none"


func _init() -> void:
	_parse_user_arguments()
	call_deferred("_run")


func _run() -> void:
	seed(fixed_seed)
	game = TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Enemy VFX probe must instantiate tower defense.")
	if game == null:
		await _finish()
		return

	game.auto_start_waves = false
	game.random_generator.seed = fixed_seed
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	viewport_rid = game.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	_stop_background_gameplay()
	_prepare_camera_fixture()

	print(
		(
			"ENEMY_VFX_RENDER_FIXTURE enemies=%d samples=%d warmup=%d seed=%d "
			+ "window=%s viewport=%s renderer=%s driver=%s gpu=%s"
		)
		% [
			enemy_count,
			sample_frames,
			warmup_frames,
			fixed_seed,
			str(DisplayServer.window_get_size()),
			str(game.get_viewport().get_visible_rect().size),
			RenderingServer.get_current_rendering_method(),
			RenderingServer.get_current_rendering_driver_name(),
			RenderingServer.get_video_adapter_name(),
		]
	)

	await _run_basic_cohort()
	await _run_green_cohort()
	await _run_guardian_cohort()
	await _run_realistic_wave_cohort(TOWER_WAVE_04, "realistic_wave04_mix_full")
	await _run_realistic_wave_cohort(TOWER_WAVE_05, "realistic_wave05_mix_full")
	await _finish()


func _parse_user_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--enemies="):
			enemy_count = maxi(int(argument.get_slice("=", 1)), 1)
		elif argument.begins_with("--samples="):
			sample_frames = maxi(int(argument.get_slice("=", 1)), 10)
		elif argument.begins_with("--warmup="):
			warmup_frames = maxi(int(argument.get_slice("=", 1)), 2)
		elif argument.begins_with("--seed="):
			fixed_seed = int(argument.get_slice("=", 1))


func _stop_background_gameplay() -> void:
	game.set_process(false)
	game.set_physics_process(false)
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()
	if game.player != null:
		game.player.velocity = Vector2.ZERO
		game.player.set_process(false)
		game.player.set_physics_process(false)


func _prepare_camera_fixture() -> void:
	if game.player != null:
		game.player.global_position = FIXTURE_CENTER
		game.player.velocity = Vector2.ZERO
		game.player.reset_physics_interpolation()
	if game.map_camera != null:
		game.map_camera.position = Vector2.ZERO
		game.map_camera.position_smoothing_enabled = false
		game.map_camera.enabled = true
		game.map_camera.reset_physics_interpolation()


func _run_basic_cohort() -> void:
	var setup_ms := await _replace_with_uniform_cohort(BASIC_CONFIG, &"basic")
	await _measure_phase("basic", setup_ms)
	var counts := _get_vfx_counts()
	_expect(int(counts["green"]) == 0, "Basic cohort must contain no green enemies.")
	_expect(int(counts["guardian"]) == 0, "Basic cohort must contain no guardians.")
	_expect(
		int(counts["aura_particle_emitters"]) == 0,
		"Basic cohort must contain no active aura emitters."
	)


func _run_green_cohort() -> void:
	var setup_ms := await _replace_with_uniform_cohort(GREEN_CONFIG, &"green")
	_configure_green_visuals(true, true, true)
	await _measure_phase("green_full", setup_ms)
	_assert_green_state(enemy_count, enemy_count, enemy_count)

	_configure_green_visuals(false, true, true)
	await _measure_phase("green_particles_off", 0.0)
	_assert_green_state(0, enemy_count, enemy_count)

	# Restore particles so this phase isolates only Polygon2D/Line2D range geometry.
	_configure_green_visuals(true, false, true)
	await _measure_phase("green_range_geometry_off", 0.0)
	_assert_green_state(enemy_count, 0, enemy_count)

	_configure_green_visuals(false, false, true)
	await _measure_phase("green_all_visuals_off_keep_area", 0.0)
	_assert_green_state(0, 0, enemy_count)


func _run_guardian_cohort() -> void:
	var setup_ms := await _replace_with_uniform_cohort(GUARDIAN_CONFIG, &"guardian")
	_configure_guardian_light(true)
	_configure_guardian_area(true)
	await _measure_phase("guardian_full", setup_ms)
	_assert_guardian_state(enemy_count, enemy_count)

	_configure_guardian_light(false)
	_configure_guardian_area(true)
	await _measure_phase("guardian_light_off", 0.0)
	_assert_guardian_state(0, enemy_count)

	# Restore the light so this phase isolates the guardian Area2D broadphase.
	_configure_guardian_light(true)
	_configure_guardian_area(false)
	await _measure_phase("guardian_area_off", 0.0)
	_assert_guardian_state(enemy_count, 0)


func _run_realistic_wave_cohort(
	wave_config: WaveConfig,
	phase_label: String
) -> void:
	var setup_ms := await _replace_with_wave_cohort(wave_config, StringName(phase_label))
	await _measure_phase(phase_label, setup_ms)
	_expect(
		enemies.size() == enemy_count,
		"%s must scale its wave composition to exactly %d enemies."
		% [phase_label, enemy_count]
	)
	var counts := _get_vfx_counts()
	if int(counts["guardian"]) > 0:
		_expect(
			int(counts["point_lights"])
			<= YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_LIGHTS,
			"Realistic waves must respect the guardian PointLight2D budget."
		)
		_expect(
			int(counts["guardian_halos"]) == int(counts["guardian"]),
			"Budgeted guardians must retain every lightweight halo sprite."
		)


func _replace_with_uniform_cohort(
	enemy_config: EnemyConfig,
	cohort_name: StringName
) -> float:
	await _clear_enemies()
	current_cohort = cohort_name
	var configs: Array[EnemyConfig] = []
	for _enemy_index in range(enemy_count):
		configs.append(enemy_config)
	return await _spawn_cohort(configs)


func _replace_with_wave_cohort(
	wave_config: WaveConfig,
	cohort_name: StringName
) -> float:
	await _clear_enemies()
	current_cohort = cohort_name
	var configs := _build_scaled_wave_configs(wave_config)
	return await _spawn_cohort(configs)


func _build_scaled_wave_configs(wave_config: WaveConfig) -> Array[EnemyConfig]:
	var configs: Array[EnemyConfig] = []
	if wave_config == null:
		_expect(false, "Realistic VFX cohort requires a WaveConfig.")
		return configs

	var total_weight := 0
	for entry in wave_config.enemy_entries:
		if entry != null and entry.enemy_config != null:
			total_weight += maxi(entry.count, 0)
	if total_weight <= 0:
		_expect(false, "Realistic VFX cohort requires a non-empty wave.")
		return configs

	# Cumulative rounding preserves the authored proportions while guaranteeing
	# that the final cohort has exactly enemy_count entries.
	var cumulative_exact := 0.0
	var assigned_count := 0
	for entry in wave_config.enemy_entries:
		if entry == null or entry.enemy_config == null or entry.count <= 0:
			continue
		cumulative_exact += (
			float(entry.count) * float(enemy_count) / float(total_weight)
		)
		var cumulative_target := mini(roundi(cumulative_exact), enemy_count)
		var scaled_count := maxi(cumulative_target - assigned_count, 0)
		for _scaled_index in range(scaled_count):
			configs.append(entry.enemy_config)
		assigned_count += scaled_count

	while configs.size() < enemy_count:
		configs.append(wave_config.enemy_entries[0].enemy_config)
	if configs.size() > enemy_count:
		configs.resize(enemy_count)

	var shuffle_rng := RandomNumberGenerator.new()
	shuffle_rng.seed = fixed_seed + wave_config.resource_path.hash()
	for source_index in range(configs.size() - 1, 0, -1):
		var target_index := shuffle_rng.randi_range(0, source_index)
		var temporary := configs[source_index]
		configs[source_index] = configs[target_index]
		configs[target_index] = temporary
	return configs


func _spawn_cohort(configs: Array[EnemyConfig]) -> float:
	enemies.clear()
	var row_count := ceili(float(configs.size()) / float(ENEMY_COLUMNS))
	var grid_size := Vector2(
		float(mini(configs.size(), ENEMY_COLUMNS) - 1) * ENEMY_SPACING.x,
		float(maxi(row_count - 1, 0)) * ENEMY_SPACING.y
	)
	var grid_origin := FIXTURE_CENTER - grid_size * 0.5
	var setup_started_usec := Time.get_ticks_usec()
	for enemy_index in range(configs.size()):
		var enemy_config := configs[enemy_index]
		if enemy_config == null or enemy_config.enemy_scene == null:
			_expect(false, "Every VFX fixture entry must provide an enemy scene.")
			continue
		var enemy := enemy_config.enemy_scene.instantiate() as Enemy
		_expect(enemy != null, "Every VFX fixture enemy must instantiate as Enemy.")
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.setup(enemy_config, game.player, null)
		_freeze_enemy_for_vfx_probe(enemy)
		enemy.global_position = grid_origin + Vector2(
			float(enemy_index % ENEMY_COLUMNS) * ENEMY_SPACING.x,
			float(enemy_index / ENEMY_COLUMNS) * ENEMY_SPACING.y
		)
		enemy.reset_physics_interpolation()
		enemies.append(enemy)
	var setup_ms := float(Time.get_ticks_usec() - setup_started_usec) / 1000.0

	for _settle_index in range(CLEANUP_SETTLE_FRAMES):
		await process_frame
		await physics_frame
	_expect(
		enemies.size() == configs.size(),
		"VFX probe failed to instantiate the complete cohort."
	)
	_expect(
		_count_enemies_inside_camera() == enemies.size(),
		"Every VFX fixture enemy must remain inside the measured camera rectangle."
	)
	return setup_ms


func _freeze_enemy_for_vfx_probe(enemy: Enemy) -> void:
	enemy.velocity = Vector2.ZERO
	enemy.set_process(false)
	enemy.set_physics_process(false)
	# Keep each body registered on the authored enemy layer so guardian AuraAreas
	# still see realistic body candidates, but remove body-vs-world movement work.
	enemy.collision_layer = 4
	enemy.collision_mask = 0

	# Touch damage is common to every enemy and is not part of this VFX/Aura A/B.
	var touch_area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	if touch_area != null:
		touch_area.collision_layer = 0
		touch_area.collision_mask = 0
		touch_area.set_deferred("monitoring", false)
		touch_area.set_deferred("monitorable", false)
		var touch_shape := touch_area.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if touch_shape != null:
			touch_shape.set_deferred("disabled", true)


func _configure_green_visuals(
	particles_enabled: bool,
	range_geometry_enabled: bool,
	aura_area_enabled: bool
) -> void:
	for enemy in enemies:
		if not _is_green_enemy(enemy):
			continue
		var aura_particles := enemy.get_node_or_null("AuraParticles") as GPUParticles2D
		if aura_particles != null:
			if particles_enabled:
				aura_particles.process_mode = Node.PROCESS_MODE_INHERIT
				aura_particles.restart()
				aura_particles.emitting = true
			else:
				aura_particles.emitting = false
				aura_particles.process_mode = Node.PROCESS_MODE_DISABLED
		var range_fill := enemy.get_node_or_null("AuraRangeFill") as Polygon2D
		if range_fill != null:
			range_fill.visible = range_geometry_enabled
		var range_outline := enemy.get_node_or_null("AuraRangeOutline") as Line2D
		if range_outline != null:
			range_outline.visible = range_geometry_enabled
		_set_aura_area_enabled(enemy, aura_area_enabled)


func _configure_guardian_light(enabled: bool) -> void:
	for enemy in enemies:
		if not _is_guardian_enemy(enemy):
			continue
		var guardian_light := enemy.get_node_or_null("GuardianLight") as PointLight2D
		if guardian_light != null:
			guardian_light.enabled = enabled


func _configure_guardian_area(enabled: bool) -> void:
	for enemy in enemies:
		if _is_guardian_enemy(enemy):
			_set_aura_area_enabled(enemy, enabled)


func _set_aura_area_enabled(enemy: Enemy, enabled: bool) -> void:
	var aura_area := enemy.get_node_or_null("AuraArea") as Area2D
	if aura_area == null:
		return
	var aura_shape := aura_area.get_node_or_null("CollisionShape2D") as CollisionShape2D
	aura_area.visible = enabled
	aura_area.set_deferred("monitoring", enabled)
	aura_area.set_deferred("monitorable", enabled)
	if aura_shape != null:
		aura_shape.set_deferred("disabled", not enabled)


func _measure_phase(label: String, setup_ms: float) -> void:
	var pipeline_canvas_before := _get_pipeline_compilation_count(
		RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS
	)
	var pipeline_draw_before := _get_pipeline_compilation_count(
		RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW
	)
	var transition_max_ms := await _warmup_phase()
	var summary := await _sample_monitor_window()
	var pipeline_canvas_delta := maxi(
		_get_pipeline_compilation_count(
			RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS
		) - pipeline_canvas_before,
		0
	)
	var pipeline_draw_delta := maxi(
		_get_pipeline_compilation_count(
			RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW
		) - pipeline_draw_before,
		0
	)
	_print_phase_summary(
		label,
		summary,
		setup_ms,
		transition_max_ms,
		pipeline_canvas_delta,
		pipeline_draw_delta
	)

	var draw_summary := summary["canvas_draw_calls"] as Dictionary
	var render_cpu_summary := summary["render_cpu"] as Dictionary
	var render_gpu_summary := summary["render_gpu"] as Dictionary
	_expect(float(draw_summary["p50"]) > 0.0, "%s requires a real render loop." % label)
	_expect(
		float(render_cpu_summary["p50"]) > 0.0,
		"%s must expose non-zero viewport render CPU time." % label
	)
	_expect(
		float(render_gpu_summary["p50"]) > 0.0,
		"%s must expose non-zero viewport GPU time; do not run headless." % label
	)


func _warmup_phase() -> float:
	var previous_tick_usec := Time.get_ticks_usec()
	var maximum_ms := 0.0
	for _frame_index in range(warmup_frames):
		await process_frame
		var now_usec := Time.get_ticks_usec()
		maximum_ms = maxf(
			maximum_ms,
			float(now_usec - previous_tick_usec) / 1000.0
		)
		previous_tick_usec = now_usec
	return maximum_ms


func _sample_monitor_window() -> Dictionary:
	var wall_samples: Array[float] = []
	var process_samples: Array[float] = []
	var physics_samples: Array[float] = []
	var frame_setup_samples: Array[float] = []
	var render_cpu_samples: Array[float] = []
	var render_gpu_samples: Array[float] = []
	var render_total_cpu_samples: Array[float] = []
	var draw_call_samples: Array[float] = []
	var render_object_samples: Array[float] = []
	var primitive_samples: Array[float] = []
	var canvas_draw_call_samples: Array[float] = []
	var canvas_object_samples: Array[float] = []
	var canvas_primitive_samples: Array[float] = []
	var collision_pair_samples: Array[float] = []
	var vram_samples_mib: Array[float] = []
	var node_count_samples: Array[float] = []
	var previous_tick_usec := Time.get_ticks_usec()
	var last_sampled_physics_frame := -1

	for _frame_index in range(sample_frames):
		await process_frame
		var now_usec := Time.get_ticks_usec()
		wall_samples.append(float(now_usec - previous_tick_usec) / 1000.0)
		previous_tick_usec = now_usec
		process_samples.append(
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		)
		var current_physics_frame := Engine.get_physics_frames()
		if current_physics_frame != last_sampled_physics_frame:
			last_sampled_physics_frame = current_physics_frame
			physics_samples.append(
				Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			)

		var frame_setup_ms := RenderingServer.get_frame_setup_time_cpu()
		var viewport_render_cpu_ms := (
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		)
		frame_setup_samples.append(frame_setup_ms)
		render_cpu_samples.append(viewport_render_cpu_ms)
		render_gpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		)
		render_total_cpu_samples.append(frame_setup_ms + viewport_render_cpu_ms)
		draw_call_samples.append(
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		)
		render_object_samples.append(
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		)
		primitive_samples.append(
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		)
		canvas_draw_call_samples.append(
			RenderingServer.viewport_get_render_info(
				viewport_rid,
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS,
				RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
			)
		)
		canvas_object_samples.append(
			RenderingServer.viewport_get_render_info(
				viewport_rid,
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS,
				RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME
			)
		)
		canvas_primitive_samples.append(
			RenderingServer.viewport_get_render_info(
				viewport_rid,
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS,
				RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME
			)
		)
		collision_pair_samples.append(
			Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)
		)
		vram_samples_mib.append(
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
			/ (1024.0 * 1024.0)
		)
		node_count_samples.append(
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
		)

	return {
		"wall": _summarize(wall_samples),
		"process": _summarize(process_samples),
		"physics": _summarize(physics_samples),
		"frame_setup": _summarize(frame_setup_samples),
		"render_cpu": _summarize(render_cpu_samples),
		"render_gpu": _summarize(render_gpu_samples),
		"render_total_cpu": _summarize(render_total_cpu_samples),
		"draw_calls": _summarize(draw_call_samples),
		"render_objects": _summarize(render_object_samples),
		"primitives": _summarize(primitive_samples),
		"canvas_draw_calls": _summarize(canvas_draw_call_samples),
		"canvas_objects": _summarize(canvas_object_samples),
		"canvas_primitives": _summarize(canvas_primitive_samples),
		"collision_pairs": _summarize(collision_pair_samples),
		"vram_mib": _summarize(vram_samples_mib),
		"nodes": _summarize(node_count_samples),
	}


func _print_phase_summary(
	label: String,
	summary: Dictionary,
	setup_ms: float,
	transition_max_ms: float,
	pipeline_canvas_delta: int,
	pipeline_draw_delta: int
) -> void:
	var vfx_counts := _get_vfx_counts()
	var parts := PackedStringArray([
		"phase=%s" % label,
		"cohort=%s" % String(current_cohort),
		"composition=%s" % _get_composition_label(),
		"enemies=%d" % enemies.size(),
		"green=%d" % int(vfx_counts["green"]),
		"guardian=%d" % int(vfx_counts["guardian"]),
		"aura_emitters=%d" % int(vfx_counts["aura_particle_emitters"]),
		"range_fills=%d" % int(vfx_counts["range_fills"]),
		"range_outlines=%d" % int(vfx_counts["range_outlines"]),
		"point_lights=%d" % int(vfx_counts["point_lights"]),
		"guardian_halos=%d" % int(vfx_counts["guardian_halos"]),
		"aura_areas=%d" % int(vfx_counts["aura_areas"]),
		"setup_ms=%.3f" % setup_ms,
		"transition_max_ms=%.3f" % transition_max_ms,
		"pipeline_canvas_delta=%d" % pipeline_canvas_delta,
		"pipeline_draw_delta=%d" % pipeline_draw_delta,
	])
	_append_summary_parts(parts, "wall_ms", summary["wall"] as Dictionary)
	_append_summary_parts(parts, "process_ms", summary["process"] as Dictionary)
	_append_summary_parts(parts, "physics_ms", summary["physics"] as Dictionary)
	_append_summary_parts(parts, "frame_setup_ms", summary["frame_setup"] as Dictionary)
	_append_summary_parts(parts, "render_cpu_ms", summary["render_cpu"] as Dictionary)
	_append_summary_parts(parts, "render_gpu_ms", summary["render_gpu"] as Dictionary)
	_append_summary_parts(
		parts,
		"render_total_cpu_ms",
		summary["render_total_cpu"] as Dictionary
	)
	_append_summary_parts(parts, "draw_calls", summary["draw_calls"] as Dictionary)
	_append_summary_parts(parts, "render_objects", summary["render_objects"] as Dictionary)
	_append_summary_parts(parts, "primitives", summary["primitives"] as Dictionary)
	_append_summary_parts(
		parts,
		"canvas_draw_calls",
		summary["canvas_draw_calls"] as Dictionary
	)
	_append_summary_parts(parts, "canvas_objects", summary["canvas_objects"] as Dictionary)
	_append_summary_parts(
		parts,
		"canvas_primitives",
		summary["canvas_primitives"] as Dictionary
	)
	_append_summary_parts(
		parts,
		"collision_pairs",
		summary["collision_pairs"] as Dictionary
	)
	_append_summary_parts(parts, "vram_mib", summary["vram_mib"] as Dictionary)
	_append_summary_parts(parts, "nodes", summary["nodes"] as Dictionary)
	print("ENEMY_VFX_RENDER_PROBE %s" % " ".join(parts))


func _get_vfx_counts() -> Dictionary:
	var counts := {
		"green": 0,
		"guardian": 0,
		"aura_particle_emitters": 0,
		"range_fills": 0,
		"range_outlines": 0,
		"point_lights": 0,
		"guardian_halos": 0,
		"aura_areas": 0,
	}
	for enemy in enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		if _is_green_enemy(enemy):
			counts["green"] += 1
		if _is_guardian_enemy(enemy):
			counts["guardian"] += 1

		var aura_particles := enemy.get_node_or_null("AuraParticles") as GPUParticles2D
		if aura_particles != null and aura_particles.emitting:
			counts["aura_particle_emitters"] += 1
		var range_fill := enemy.get_node_or_null("AuraRangeFill") as Polygon2D
		if range_fill != null and range_fill.is_visible_in_tree():
			counts["range_fills"] += 1
		var range_outline := enemy.get_node_or_null("AuraRangeOutline") as Line2D
		if range_outline != null and range_outline.is_visible_in_tree():
			counts["range_outlines"] += 1
		var point_light := enemy.get_node_or_null("GuardianLight") as PointLight2D
		if point_light != null and point_light.enabled and point_light.is_visible_in_tree():
			counts["point_lights"] += 1
		var guardian_halo := enemy.get_node_or_null("GuardianLightHalo") as Sprite2D
		if guardian_halo != null and guardian_halo.is_visible_in_tree():
			counts["guardian_halos"] += 1
		var aura_area := enemy.get_node_or_null("AuraArea") as Area2D
		if aura_area != null and aura_area.monitoring:
			var aura_shape := aura_area.get_node_or_null("CollisionShape2D") as CollisionShape2D
			if aura_shape == null or not aura_shape.disabled:
				counts["aura_areas"] += 1
	return counts


func _assert_green_state(
	expected_emitters: int,
	expected_range_geometry: int,
	expected_areas: int
) -> void:
	var counts := _get_vfx_counts()
	_expect(int(counts["green"]) == enemy_count, "Green cohort size changed during A/B.")
	_expect(
		int(counts["aura_particle_emitters"]) == expected_emitters,
		"Green A/B has the wrong active aura emitter count."
	)
	_expect(
		int(counts["range_fills"]) == expected_range_geometry
		and int(counts["range_outlines"]) == expected_range_geometry,
		"Green A/B has the wrong visible range geometry count."
	)
	_expect(
		int(counts["aura_areas"]) == expected_areas,
		"Green A/B has the wrong active AuraArea count."
	)


func _assert_guardian_state(expected_lights: int, expected_areas: int) -> void:
	var counts := _get_vfx_counts()
	_expect(
		int(counts["guardian"]) == enemy_count,
		"Guardian cohort size changed during A/B."
	)
	_expect(
		int(counts["point_lights"]) == expected_lights,
		"Guardian A/B has the wrong enabled PointLight2D count."
	)
	_expect(
		int(counts["guardian_halos"]) == enemy_count,
		"Guardian A/B must retain every lightweight halo sprite."
	)
	_expect(
		int(counts["aura_areas"]) == expected_areas,
		"Guardian A/B has the wrong active AuraArea count."
	)


func _is_green_enemy(enemy: Enemy) -> bool:
	return enemy != null and enemy.config is YuanshiInsectGreenShellConfig


func _is_guardian_enemy(enemy: Enemy) -> bool:
	return enemy != null and enemy.config is YuanshiInsectGuardianConfig


func _get_composition_label() -> String:
	var counts: Dictionary = {}
	for enemy in enemies:
		if enemy == null or not is_instance_valid(enemy) or enemy.config == null:
			continue
		var config_name := enemy.config.resource_path.get_file().get_basename()
		if config_name.is_empty():
			config_name = enemy.config.display_name.replace(" ", "_")
		counts[config_name] = int(counts.get(config_name, 0)) + 1
	var names := PackedStringArray()
	for config_name in counts:
		names.append(str(config_name))
	names.sort()
	var parts := PackedStringArray()
	for config_name in names:
		parts.append("%s:%d" % [config_name, int(counts[config_name])])
	return ",".join(parts)


func _count_enemies_inside_camera() -> int:
	var viewport_size := Vector2(game.get_viewport().get_visible_rect().size)
	var zoom := Vector2.ONE
	if game.map_camera != null:
		zoom = game.map_camera.zoom.abs()
	zoom.x = maxf(zoom.x, 0.001)
	zoom.y = maxf(zoom.y, 0.001)
	var world_size := Vector2(viewport_size.x / zoom.x, viewport_size.y / zoom.y)
	var camera_rect := Rect2(FIXTURE_CENTER - world_size * 0.5, world_size)
	var visible_count := 0
	for enemy in enemies:
		if (
			enemy != null
			and is_instance_valid(enemy)
			and enemy.is_visible_in_tree()
			and camera_rect.has_point(enemy.global_position)
		):
			visible_count += 1
	return visible_count


func _get_pipeline_compilation_count(info: RenderingServer.RenderingInfo) -> int:
	return RenderingServer.get_rendering_info(info)


func _append_summary_parts(
	parts: PackedStringArray,
	label: String,
	summary: Dictionary
) -> void:
	parts.append("%s_p50=%.3f" % [label, float(summary["p50"])])
	parts.append("%s_p95=%.3f" % [label, float(summary["p95"])])
	parts.append("%s_p99=%.3f" % [label, float(summary["p99"])])
	parts.append("%s_max=%.3f" % [label, float(summary["max"])])


func _summarize(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"p50": _nearest_rank(sorted, 0.50),
		"p95": _nearest_rank(sorted, 0.95),
		"p99": _nearest_rank(sorted, 0.99),
		"max": sorted.back(),
	}


func _nearest_rank(sorted: Array[float], percentile: float) -> float:
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted.size())
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _clear_enemies() -> void:
	for enemy in enemies:
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy is YuanshiInsectAura and enemy.has_method("_stop_aura"):
			enemy.call("_stop_aura")
		enemy.queue_free()
	enemies.clear()
	for _cleanup_index in range(CLEANUP_SETTLE_FRAMES):
		await process_frame
		await physics_frame


func _finish() -> void:
	await _clear_enemies()
	if viewport_rid.is_valid():
		RenderingServer.viewport_set_measure_render_time(viewport_rid, false)
	current_scene = null
	if game != null and is_instance_valid(game):
		game.queue_free()
	for _cleanup_index in range(10):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("ENEMY_VFX_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
