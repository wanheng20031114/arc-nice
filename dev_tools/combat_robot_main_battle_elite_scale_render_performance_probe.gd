extends SceneTree

# Production-scene render and resource-sharing certificate for the high-resolution
# main-battle robot atlas. Run without --headless: the probe intentionally keeps
# the authored scene/resources, freezes gameplay, and renders only the production
# AnimatedSprite2D so atlas cost is separated from combat AI/physics cost. The
# cohort is staggered across all 53 authored frames rather than cloning one UV.
#
# Example:
#   Godot_console.exe --windowed --resolution 1280x720 --rendering-method forward_plus \
#       --path . --script res://dev_tools/combat_robot_main_battle_elite_scale_render_performance_probe.gd \
#       -- --counts=0,1,8,100,500 --warmup=120 --samples=180 --max-fps=60

const SCENE_PATH := (
	"res://scene/enemy/mechanical_life/combat_robot_main_battle_elite.tscn"
)
const ANIMATION_PATH := (
	"res://resources/animation/combat_robot_main_battle_elite.tres"
)
const TEXTURE_PATH := (
	"res://resources/texture/enemy/mechanical_life/combat_robot_main_battle_elite.png"
)
const EXPECTED_ANIMATION_COUNT := 8
const EXPECTED_FRAME_RESOURCE_COUNT := 53
const EXPECTED_ATLAS_WIDTH := 3216
const EXPECTED_ATLAS_HEIGHT := 2909
const EXPECTED_RUNTIME_SCALE := Vector2(0.125, 0.125)
const BYTES_PER_MIB := 1024.0 * 1024.0
const CLEANUP_FRAMES := 10
const TEXTURE_PLATEAU_TOLERANCE_MIB := 1.0
const MAX_STATIC_SPRITE_DRAW_CALL_DELTA := 2.0

var requested_counts: Array[int] = [0, 1, 8, 100, 500]
var warmup_frames := 120
var sample_frames := 180
var requested_max_fps := 60
var requested_window_size := Vector2i.ZERO

var failures: Array[String] = []
var fixture: Node2D = null
var production_scene: PackedScene = null
var instances: Array[Node2D] = []
var viewport_rid := RID()
var original_max_fps := 0
var original_vsync_mode := DisplayServer.VSYNC_ENABLED


func _init() -> void:
	_parse_user_arguments()
	call_deferred("_run")


func _parse_user_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--counts="):
			requested_counts.clear()
			for raw_count in argument.get_slice("=", 1).split(",", false):
				requested_counts.append(maxi(int(raw_count.strip_edges()), 0))
		elif argument.begins_with("--warmup="):
			warmup_frames = maxi(int(argument.get_slice("=", 1)), 2)
		elif argument.begins_with("--samples="):
			sample_frames = maxi(int(argument.get_slice("=", 1)), 30)
		elif argument.begins_with("--max-fps="):
			requested_max_fps = maxi(int(argument.get_slice("=", 1)), 0)
		elif argument.begins_with("--window-size="):
			var components := argument.get_slice("=", 1).to_lower().split("x", false)
			if components.size() == 2:
				requested_window_size = Vector2i(
					maxi(int(components[0]), 1),
					maxi(int(components[1]), 1)
				)


func _run() -> void:
	original_max_fps = Engine.max_fps
	original_vsync_mode = DisplayServer.window_get_vsync_mode()
	Engine.max_fps = requested_max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	_validate_requested_counts()
	_expect(
		DisplayServer.get_name() != "headless",
		"Render/VRAM certificate must run in a real window, not headless."
	)
	if not failures.is_empty():
		await _finish({})
		return
	if requested_window_size != Vector2i.ZERO:
		DisplayServer.window_set_size(requested_window_size)
		root.size = requested_window_size
		await process_frame
		await process_frame

	fixture = Node2D.new()
	fixture.name = "CombatRobotMainBattleEliteScaleRenderFixture"
	root.add_child(fixture)
	current_scene = fixture
	await process_frame
	await process_frame

	viewport_rid = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	var initial_cache_state := {
		"scene": ResourceLoader.has_cached(SCENE_PATH),
		"animation": ResourceLoader.has_cached(ANIMATION_PATH),
		"texture": ResourceLoader.has_cached(TEXTURE_PATH),
	}
	var initial_object_state := _capture_object_state()
	var stages: Array[Dictionary] = []
	for requested_count in requested_counts:
		var setup_started_usec := Time.get_ticks_usec()
		await _grow_to_count(requested_count)
		if instances.size() != requested_count:
			break
		var setup_ms := float(Time.get_ticks_usec() - setup_started_usec) / 1000.0
		var sharing := _audit_resource_contract()
		var stage := await _measure_stage(requested_count, setup_ms, sharing)
		stages.append(stage)

	_validate_stage_contract(stages)
	var result := {
		"probe": "combat_robot_main_battle_elite_scale_render",
		"mode": "production_scene_staggered_sprite_frames",
		"scene_path": SCENE_PATH,
		"animation_path": ANIMATION_PATH,
		"texture_path": TEXTURE_PATH,
		"counts": requested_counts,
		"warmup_frames": warmup_frames,
		"sample_frames": sample_frames,
		"max_fps": Engine.max_fps,
		"requested_window_size": [requested_window_size.x, requested_window_size.y],
		"renderer": RenderingServer.get_current_rendering_method(),
		"render_driver": RenderingServer.get_current_rendering_driver_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"display_server": DisplayServer.get_name(),
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"viewport_size": [root.get_visible_rect().size.x, root.get_visible_rect().size.y],
		"initial_cache_state": initial_cache_state,
		"initial_object_state": initial_object_state,
		"stages": stages,
		"failures": failures.duplicate(),
	}
	await _finish(result)


func _validate_requested_counts() -> void:
	_expect(not requested_counts.is_empty(), "At least one instance count is required.")
	_expect(
		requested_max_fps > 0
		and warmup_frames >= requested_max_fps
		and sample_frames >= 60,
		"Certificate runs require at least one paced warmup second and 60 samples."
	)
	_expect(
		requested_counts.size() >= 3
		and requested_counts.front() == 0
		and requested_counts[1] == 1
		and requested_counts.back() >= EXPECTED_FRAME_RESOURCE_COUNT
		and requested_counts.back() <= 500,
		(
			"Certificate counts must begin with 0,1 and end between 53 and 500 "
			+ "so every authored frame is visible within the fixed grid."
		)
	)
	var previous_count := -1
	for requested_count in requested_counts:
		_expect(
			requested_count > previous_count,
			"Instance counts must be strictly increasing."
		)
		previous_count = requested_count


func _grow_to_count(target_count: int) -> void:
	if target_count <= instances.size():
		return
	if production_scene == null:
		production_scene = load(SCENE_PATH) as PackedScene
		_expect(production_scene != null, "Production enemy scene must load.")
		if production_scene == null:
			return

	var grid_columns := 25
	var grid_rows := 20
	var viewport_size := root.get_visible_rect().size
	var horizontal_margin := 40.0
	var vertical_margin := 48.0
	var horizontal_step := (
		(viewport_size.x - horizontal_margin * 2.0)
		/ float(maxi(grid_columns - 1, 1))
	)
	var vertical_step := (
		(viewport_size.y - vertical_margin * 2.0)
		/ float(maxi(grid_rows - 1, 1))
	)
	for instance_index in range(instances.size(), target_count):
		var enemy := production_scene.instantiate() as Node2D
		_expect(enemy != null, "Every requested production enemy must instantiate.")
		if enemy == null:
			continue
		fixture.add_child(enemy)
		enemy.position = Vector2(
			horizontal_margin + float(instance_index % grid_columns) * horizontal_step,
			vertical_margin + float(instance_index / grid_columns) * vertical_step
		)
		enemy.set_process(false)
		enemy.set_physics_process(false)
		enemy.process_mode = Node.PROCESS_MODE_DISABLED
		_configure_static_visual(enemy, instance_index)
		instances.append(enemy)

	await process_frame
	await physics_frame
	_expect(instances.size() == target_count, "The full requested visual cohort must exist.")


func _configure_static_visual(enemy: Node2D, instance_index: int) -> void:
	for hidden_path in [
		"GroundShadow",
		"AttackWarning",
		"Skill1WarningLine",
		"Skill1CircleRing",
		"Skill2CrossMarker",
		"Skill2FanWarning",
		"FanSlashVFX",
	]:
		var canvas_item := enemy.get_node_or_null(hidden_path) as CanvasItem
		if canvas_item != null:
			canvas_item.visible = false
	var sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite != null, "Production instance must retain AnimatedSprite2D.")
	if sprite == null:
		return
	sprite.visible = true
	sprite.stop()
	var remaining_frame_index := instance_index % EXPECTED_FRAME_RESOURCE_COUNT
	for animation_name in sprite.sprite_frames.get_animation_names():
		var animation_frame_count := sprite.sprite_frames.get_frame_count(animation_name)
		if remaining_frame_index < animation_frame_count:
			sprite.animation = animation_name
			sprite.frame = remaining_frame_index
			break
		remaining_frame_index -= animation_frame_count
	sprite.frame_progress = 0.0


func _audit_resource_contract() -> Dictionary:
	if instances.is_empty():
		return {
			"instances": 0,
			"sprite_frames_unique": 0,
			"frame_resource_unique": 0,
			"base_texture_unique": 0,
			"base_texture_rid_unique": 0,
			"atlas_texture_rid_unique": 0,
			"body_and_touch_shape_unique": 0,
			"body_and_touch_shape_rid_unique": 0,
			"sprite_canvas_item_rid_unique": 0,
		}

	var sprite_frame_ids := {}
	var frame_resource_ids := {}
	var visible_frame_resource_ids := {}
	var base_texture_ids := {}
	var base_texture_rids := {}
	var atlas_texture_rids := {}
	var shape_ids := {}
	var shape_rids := {}
	var sprite_canvas_item_rids := {}
	var total_frame_references := 0
	var local_frame_resource_count := 0
	var runtime_scale_matches := true
	var runtime_filter_matches := true
	var atlas_width := 0
	var atlas_height := 0
	var animation_count := 0
	var frames_per_instance := 0

	for enemy in instances:
		var sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if sprite == null or sprite.sprite_frames == null:
			continue
		var frames := sprite.sprite_frames
		_expect(
			sprite.get_canvas_item().is_valid(),
			"Every visible sprite must own a valid CanvasItem RID."
		)
		var visible_frame_texture := frames.get_frame_texture(
			sprite.animation,
			sprite.frame
		)
		if visible_frame_texture != null:
			visible_frame_resource_ids[visible_frame_texture.get_instance_id()] = true
		runtime_scale_matches = runtime_scale_matches and sprite.scale.is_equal_approx(
			EXPECTED_RUNTIME_SCALE
		)
		runtime_filter_matches = (
			runtime_filter_matches
			and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR
		)
		sprite_frame_ids[frames.get_instance_id()] = true
		sprite_canvas_item_rids[sprite.get_canvas_item().get_id()] = true
		_expect(
			not frames.resource_local_to_scene,
			"SpriteFrames must remain shared, not local to each scene instance."
		)
		animation_count = frames.get_animation_names().size()
		var current_frame_count := 0
		for animation_name in frames.get_animation_names():
			for frame_index in range(frames.get_frame_count(animation_name)):
				current_frame_count += 1
				total_frame_references += 1
				var frame_texture := frames.get_frame_texture(
					animation_name,
					frame_index
				) as AtlasTexture
				_expect(
					frame_texture != null,
					"Every authored animation frame must remain an AtlasTexture."
				)
				if frame_texture == null:
					continue
				_expect(
					frame_texture.get_rid().is_valid(),
					"Every AtlasTexture must expose a valid texture RID."
				)
				frame_resource_ids[frame_texture.get_instance_id()] = true
				atlas_texture_rids[frame_texture.get_rid().get_id()] = true
				if frame_texture.resource_local_to_scene:
					local_frame_resource_count += 1
				var base_texture := frame_texture.atlas
				_expect(base_texture != null, "Every frame must retain its base atlas.")
				if base_texture == null:
					continue
				_expect(
					base_texture.get_rid().is_valid(),
					"The shared base texture must expose a valid GPU RID."
				)
				base_texture_ids[base_texture.get_instance_id()] = true
				base_texture_rids[base_texture.get_rid().get_id()] = true
				atlas_width = base_texture.get_width()
				atlas_height = base_texture.get_height()
		frames_per_instance = current_frame_count

		for shape_path in ["CollisionShape2D", "TouchDamageArea/CollisionShape2D"]:
			var collision_shape := enemy.get_node_or_null(shape_path) as CollisionShape2D
			_expect(
				collision_shape != null and collision_shape.shape != null,
				"Both production collision Shape2D resources must exist."
			)
			if collision_shape == null or collision_shape.shape == null:
				continue
			var shape := collision_shape.shape
			_expect(shape.get_rid().is_valid(), "Every local Shape2D RID must be valid.")
			shape_ids[shape.get_instance_id()] = true
			shape_rids[shape.get_rid().get_id()] = true
			_expect(
				shape.resource_local_to_scene,
				"Body and touch Shape2D resources must remain local to each instance."
			)

	var instance_count := instances.size()
	_expect(sprite_frame_ids.size() == 1, "All instances must share one SpriteFrames.")
	_expect(
		frame_resource_ids.size() == EXPECTED_FRAME_RESOURCE_COUNT,
		"All instances must share the same 53 AtlasTexture frame resources."
	)
	_expect(
		visible_frame_resource_ids.size()
		== mini(instance_count, EXPECTED_FRAME_RESOURCE_COUNT),
		"Visible instances must deterministically cover the authored frame set."
	)
	_expect(base_texture_ids.size() == 1, "All frames/instances must share one Texture2D.")
	_expect(base_texture_rids.size() == 1, "All instances must share one base texture RID.")
	_expect(
		atlas_texture_rids.size() == 1,
		"Every AtlasTexture RID must forward to the one shared base texture RID."
	)
	if base_texture_rids.size() == 1 and atlas_texture_rids.size() == 1:
		_expect(
			base_texture_rids.keys()[0] == atlas_texture_rids.keys()[0],
			"AtlasTexture and base Texture2D must expose the same GPU RID."
		)
	_expect(
		shape_ids.size() == instance_count * 2,
		"The two local collision Shape2D resources must be unique per instance."
	)
	_expect(
		shape_rids.size() == instance_count * 2,
		"The two collision Shape2D server RIDs must be unique per instance."
	)
	_expect(
		sprite_canvas_item_rids.size() == instance_count,
		"Each AnimatedSprite2D must keep its own CanvasItem RID."
	)
	_expect(animation_count == EXPECTED_ANIMATION_COUNT, "Animation count drifted.")
	_expect(frames_per_instance == EXPECTED_FRAME_RESOURCE_COUNT, "Frame count drifted.")
	_expect(local_frame_resource_count == 0, "AtlasTexture frames must not be local.")
	_expect(runtime_scale_matches, "The approved 0.125 runtime sprite scale drifted.")
	_expect(runtime_filter_matches, "The approved linear texture filter drifted.")
	_expect(
		atlas_width == EXPECTED_ATLAS_WIDTH and atlas_height == EXPECTED_ATLAS_HEIGHT,
		"The approved high-resolution atlas dimensions drifted."
	)
	return {
		"instances": instance_count,
		"animation_count": animation_count,
		"frames_per_instance": frames_per_instance,
		"total_frame_references": total_frame_references,
		"sprite_frames_unique": sprite_frame_ids.size(),
		"frame_resource_unique": frame_resource_ids.size(),
		"visible_frame_resource_unique": visible_frame_resource_ids.size(),
		"base_texture_unique": base_texture_ids.size(),
		"base_texture_rid_unique": base_texture_rids.size(),
		"atlas_texture_rid_unique": atlas_texture_rids.size(),
		"body_and_touch_shape_unique": shape_ids.size(),
		"body_and_touch_shape_rid_unique": shape_rids.size(),
		"sprite_canvas_item_rid_unique": sprite_canvas_item_rids.size(),
		"local_frame_resource_count": local_frame_resource_count,
		"runtime_scale_matches": runtime_scale_matches,
		"runtime_filter_matches": runtime_filter_matches,
		"atlas_width": atlas_width,
		"atlas_height": atlas_height,
		"atlas_rgba8_mib": (
			float(atlas_width * atlas_height * 4) / BYTES_PER_MIB
		),
		"texture_resource_path": TEXTURE_PATH,
	}


func _measure_stage(
	instance_count: int,
	setup_ms: float,
	sharing: Dictionary
) -> Dictionary:
	for _warmup_index in range(warmup_frames):
		await process_frame
	var pipeline_canvas_before := _get_rendering_info(
		RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS
	)
	var pipeline_draw_before := _get_rendering_info(
		RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW
	)

	var wall_samples: Array[float] = []
	var process_samples: Array[float] = []
	var frame_setup_samples: Array[float] = []
	var viewport_cpu_samples: Array[float] = []
	var gpu_samples: Array[float] = []
	var render_total_cpu_samples: Array[float] = []
	var canvas_draw_call_samples: Array[float] = []
	var canvas_object_samples: Array[float] = []
	var canvas_primitive_samples: Array[float] = []
	var static_memory_samples: Array[float] = []
	var video_memory_samples: Array[float] = []
	var texture_memory_samples: Array[float] = []
	var buffer_memory_samples: Array[float] = []
	var server_video_memory_samples: Array[float] = []
	var server_texture_memory_samples: Array[float] = []
	var server_buffer_memory_samples: Array[float] = []
	var node_count_samples: Array[float] = []
	var resource_count_samples: Array[float] = []
	var object_count_samples: Array[float] = []
	var previous_tick_usec := Time.get_ticks_usec()
	for _sample_index in range(sample_frames):
		await process_frame
		var now_usec := Time.get_ticks_usec()
		wall_samples.append(float(now_usec - previous_tick_usec) / 1000.0)
		previous_tick_usec = now_usec
		process_samples.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		var frame_setup_ms := RenderingServer.get_frame_setup_time_cpu()
		var viewport_cpu_ms := (
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		)
		frame_setup_samples.append(frame_setup_ms)
		viewport_cpu_samples.append(viewport_cpu_ms)
		gpu_samples.append(
			RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		)
		render_total_cpu_samples.append(frame_setup_ms + viewport_cpu_ms)
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
		static_memory_samples.append(_get_performance_mib(Performance.MEMORY_STATIC))
		video_memory_samples.append(
			_get_performance_mib(Performance.RENDER_VIDEO_MEM_USED)
		)
		texture_memory_samples.append(
			_get_performance_mib(Performance.RENDER_TEXTURE_MEM_USED)
		)
		buffer_memory_samples.append(
			_get_performance_mib(Performance.RENDER_BUFFER_MEM_USED)
		)
		server_video_memory_samples.append(
			_get_rendering_info_mib(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)
		)
		server_texture_memory_samples.append(
			_get_rendering_info_mib(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
		)
		server_buffer_memory_samples.append(
			_get_rendering_info_mib(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)
		)
		node_count_samples.append(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		resource_count_samples.append(
			Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
		)
		object_count_samples.append(Performance.get_monitor(Performance.OBJECT_COUNT))

	var stage := {
		"instances": instance_count,
		"setup_ms": setup_ms,
		"sharing": sharing,
		"wall_ms": _summarize(wall_samples),
		"process_ms": _summarize(process_samples),
		"frame_setup_ms": _summarize(frame_setup_samples),
		"viewport_render_cpu_ms": _summarize(viewport_cpu_samples),
		"render_total_cpu_ms": _summarize(render_total_cpu_samples),
		"render_gpu_ms": _summarize(gpu_samples),
		"canvas_draw_calls": _summarize(canvas_draw_call_samples),
		"canvas_objects": _summarize(canvas_object_samples),
		"canvas_primitives": _summarize(canvas_primitive_samples),
		"static_memory_mib": _summarize(static_memory_samples),
		"video_memory_mib": _summarize(video_memory_samples),
		"texture_memory_mib": _summarize(texture_memory_samples),
		"buffer_memory_mib": _summarize(buffer_memory_samples),
		"rendering_server_video_memory_mib": _summarize(server_video_memory_samples),
		"rendering_server_texture_memory_mib": _summarize(server_texture_memory_samples),
		"rendering_server_buffer_memory_mib": _summarize(server_buffer_memory_samples),
		"node_count": _summarize(node_count_samples),
		"resource_count": _summarize(resource_count_samples),
		"object_count": _summarize(object_count_samples),
		"pipeline_canvas_compilations_delta": maxi(
			_get_rendering_info(
				RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS
			) - pipeline_canvas_before,
			0
		),
		"pipeline_draw_compilations_delta": maxi(
			_get_rendering_info(
				RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW
			) - pipeline_draw_before,
			0
		),
	}
	print(
		"COMBAT_ROBOT_MAIN_BATTLE_ELITE_SCALE_STAGE %s"
		% JSON.stringify(stage)
	)
	return stage


func _validate_stage_contract(stages: Array[Dictionary]) -> void:
	if stages.is_empty():
		return
	var baseline: Dictionary = stages.front()
	var nonzero_texture_p50: Array[float] = []
	var nonzero_buffer_p50: Array[float] = []
	var nonzero_video_p50: Array[float] = []
	for stage in stages:
		var instance_count := int(stage["instances"])
		if instance_count > 0:
			nonzero_texture_p50.append(
				float((stage["texture_memory_mib"] as Dictionary)["p50"])
			)
			nonzero_buffer_p50.append(
				float((stage["buffer_memory_mib"] as Dictionary)["p50"])
			)
			nonzero_video_p50.append(
				float((stage["video_memory_mib"] as Dictionary)["p50"])
			)
		_expect(
			absf(
				float((stage["texture_memory_mib"] as Dictionary)["p50"])
				- float(
					(stage["rendering_server_texture_memory_mib"] as Dictionary)["p50"]
				)
			) <= 0.01,
			"Performance and RenderingServer texture-memory monitors must agree."
		)
		_expect(
			absf(
				float((stage["video_memory_mib"] as Dictionary)["p50"])
				- float(
					(stage["rendering_server_video_memory_mib"] as Dictionary)["p50"]
				)
			) <= 0.01,
			"Performance and RenderingServer video-memory monitors must agree."
		)
	_expect(
		float((stages.back()["render_gpu_ms"] as Dictionary)["p50"]) > 0.0,
		"The real-window run must expose non-zero GPU timing."
	)
	if nonzero_texture_p50.size() >= 2:
		nonzero_texture_p50.sort()
		nonzero_buffer_p50.sort()
		nonzero_video_p50.sort()
		_expect(
			nonzero_texture_p50.back() - nonzero_texture_p50.front()
			<= TEXTURE_PLATEAU_TOLERANCE_MIB,
			"Texture memory must plateau after the first visible instance."
		)
		_expect(
			nonzero_buffer_p50.back() - nonzero_buffer_p50.front()
			<= TEXTURE_PLATEAU_TOLERANCE_MIB,
			"Dormant production nodes must not allocate per-instance GPU buffers."
		)
		_expect(
			nonzero_video_p50.back() - nonzero_video_p50.front()
			<= TEXTURE_PLATEAU_TOLERANCE_MIB,
			"Total video memory must plateau in the visual-only fixture."
		)
	var baseline_draw_calls := float(
		(baseline["canvas_draw_calls"] as Dictionary)["p50"]
	)
	var baseline_canvas_objects := float(
		(baseline["canvas_objects"] as Dictionary)["p50"]
	)
	var baseline_canvas_primitives := float(
		(baseline["canvas_primitives"] as Dictionary)["p50"]
	)
	var maximum_instance_stage: Dictionary = stages.back()
	var maximum_instance_count := int(maximum_instance_stage["instances"])
	_expect(
		float(
			(maximum_instance_stage["canvas_draw_calls"] as Dictionary)["p50"]
		) - baseline_draw_calls <= MAX_STATIC_SPRITE_DRAW_CALL_DELTA,
		"Static sprites sharing one atlas must batch into at most two extra draw calls."
	)
	_expect(
		absf(
			float(
				(maximum_instance_stage["canvas_objects"] as Dictionary)["p50"]
			) - baseline_canvas_objects - float(maximum_instance_count)
		) <= 1.0,
		"Every visible instance must contribute exactly one Canvas object."
	)
	_expect(
		absf(
			float(
				(maximum_instance_stage["canvas_primitives"] as Dictionary)["p50"]
			) - baseline_canvas_primitives - float(maximum_instance_count * 2)
		) <= 1.0,
		"Every visible instance must contribute exactly two Canvas primitives."
	)
	for stage in stages:
		_expect(
			int(stage["pipeline_canvas_compilations_delta"]) == 0
			and int(stage["pipeline_draw_compilations_delta"]) == 0,
			"No measured stage may compile a new render pipeline after warmup."
		)


func _capture_object_state() -> Dictionary:
	return {
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"orphans": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"static_memory_mib": _get_performance_mib(Performance.MEMORY_STATIC),
		"video_memory_mib": _get_performance_mib(Performance.RENDER_VIDEO_MEM_USED),
		"texture_memory_mib": _get_performance_mib(
			Performance.RENDER_TEXTURE_MEM_USED
		),
		"buffer_memory_mib": _get_performance_mib(Performance.RENDER_BUFFER_MEM_USED),
	}


func _get_performance_mib(monitor: Performance.Monitor) -> float:
	return Performance.get_monitor(monitor) / BYTES_PER_MIB


func _get_rendering_info(info: RenderingServer.RenderingInfo) -> int:
	return int(RenderingServer.get_rendering_info(info))


func _get_rendering_info_mib(info: RenderingServer.RenderingInfo) -> float:
	return float(_get_rendering_info(info)) / BYTES_PER_MIB


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


func _finish(result: Dictionary) -> void:
	if viewport_rid.is_valid():
		RenderingServer.viewport_set_measure_render_time(viewport_rid, false)
	instances.clear()
	production_scene = null
	current_scene = null
	if fixture != null and is_instance_valid(fixture):
		fixture.queue_free()
	for _cleanup_index in range(CLEANUP_FRAMES):
		await process_frame
		await physics_frame
	var cleanup_object_state := _capture_object_state()
	_expect(
		int(cleanup_object_state["orphans"]) == 0,
		"Visual certificate cleanup must leave no orphan nodes."
	)
	result["cleanup_object_state"] = cleanup_object_state
	result["failures"] = failures.duplicate()
	Engine.max_fps = original_max_fps
	DisplayServer.window_set_vsync_mode(original_vsync_mode)
	if not result.is_empty():
		print(
			"COMBAT_ROBOT_MAIN_BATTLE_ELITE_SCALE_RESULT %s"
			% JSON.stringify(result)
		)
	if failures.is_empty():
		print("COMBAT_ROBOT_MAIN_BATTLE_ELITE_SCALE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	if not failures.has(message):
		failures.append(message)
