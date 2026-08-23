extends SceneTree

const LIGHTNING_SCENE := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer.tscn"
)
const LIGHTNING_CONFIG := preload(
	"res://resources/config/enemies/lightning_sorcerer.tres"
)
const FIRE_SCENE := preload("res://scene/enemy/sorcerer/fire_sorcerer.tscn")
const FROST_CONFIG := preload(
	"res://resources/config/enemies/frost_sorcerer.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TargetWarningScript := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer_target_warning.gd"
)

const TEST_HEALTH := 1000
const EXPECTED_ATTACK_RANGE := 7.0 * 16.0
const EXPECTED_CHAIN_RANGE := 3.0 * 16.0
const LIGHTNING_MOVE_TEXTURE_PATH := (
	"res://resources/texture/enemy/sorcerer/lightning_sorcerer_move.png"
)
const MOVE_FRAME_COUNT := 8
const MOVE_ANIMATION_SPEED := 12.0
const MOVE_GROUND_Y := 38
const MAX_MOVE_CENTROID_X_DRIFT := 1.0


class TargetRuntime:
	extends PlayerTestCombatRuntime

	var candidates: Array[Node2D] = []
	var query_count := 0

	func find_nearest_enemy_attack_target_world(
		from_position: Vector2,
		max_distance: float,
		excluded_instance_ids: Dictionary = {}
	) -> Node2D:
		query_count += 1
		var nearest: Node2D = null
		var nearest_distance_squared := max_distance * max_distance
		var nearest_instance_id := 0
		for candidate in candidates:
			if candidate == null or not is_instance_valid(candidate):
				continue
			var instance_id := int(candidate.get_instance_id())
			if excluded_instance_ids.has(instance_id):
				continue
			var player := candidate as Player
			if player != null and player.is_dead:
				continue
			var plant := candidate as PlantDefense
			if plant != null and (plant.is_dead or plant.is_removing):
				continue
			if player == null and plant == null:
				continue
			var distance_squared := from_position.distance_squared_to(
				candidate.global_position
			)
			if distance_squared > nearest_distance_squared:
				continue
			if (
				nearest == null
				or distance_squared < nearest_distance_squared
				or (
					is_equal_approx(distance_squared, nearest_distance_squared)
					and instance_id < nearest_instance_id
				)
			):
				nearest = candidate
				nearest_distance_squared = distance_squared
				nearest_instance_id = instance_id
		return nearest


	func find_nearest_hostile_enemy_attack_target_world(
		from_position: Vector2,
		max_distance: float,
		_source_faction_id: int,
		excluded_instance_ids: Dictionary = {}
	) -> Node2D:
		return find_nearest_enemy_attack_target_world(
			from_position,
			max_distance,
			excluded_instance_ids
		)


var failures: Array[String] = []
var fixture: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "LightningSorcererSmokeTest"
	root.add_child(fixture)
	current_scene = fixture

	_test_resource_and_scene_contract()
	await _test_five_target_chain_and_exact_boundary()
	await _test_chain_stops_past_three_cells()
	await _test_windup_direct_hit_and_cooldown()

	current_scene = null
	fixture.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("LIGHTNING_SORCERER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_and_scene_contract() -> void:
	_expect(
		LIGHTNING_CONFIG is LightningSorcererConfig,
		"Lightning Sorcerer must use LightningSorcererConfig."
	)
	_expect(
		LIGHTNING_CONFIG.display_name == "雷电术士"
		and LIGHTNING_CONFIG.enemy_scene == LIGHTNING_SCENE,
		"Lightning Sorcerer config must own its independent named scene."
	)
	_expect(
		LIGHTNING_CONFIG.max_health == FROST_CONFIG.max_health
		and LIGHTNING_CONFIG.max_health == 200
		and LIGHTNING_CONFIG.attack_damage == FROST_CONFIG.attack_damage
		and LIGHTNING_CONFIG.attack_damage == 50,
		"Lightning health and damage must exactly match the normal Frost Sorcerer."
	)
	_expect(
		is_equal_approx(LIGHTNING_CONFIG.attack_range, EXPECTED_ATTACK_RANGE)
		and is_equal_approx(LIGHTNING_CONFIG.chain_range, EXPECTED_CHAIN_RANGE)
		and LIGHTNING_CONFIG.max_chain_bounces == 4,
		"Lightning range must be seven 16 px cells with four three-cell bounces."
	)
	_expect(
		is_equal_approx(LIGHTNING_CONFIG.attack_interval, 3.0)
		and is_equal_approx(LIGHTNING_CONFIG.windup_duration, 0.6),
		"Lightning attack timing must keep the normal Sorcerer cadence."
	)

	var enemy := LIGHTNING_SCENE.instantiate() as LightningSorcerer
	var fire_enemy := FIRE_SCENE.instantiate() as Node2D
	_expect(enemy != null, "Lightning scene must instantiate LightningSorcerer.")
	if enemy != null:
		var sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		var pivot := enemy.get_node_or_null("CastPivot") as Node2D
		var marker := enemy.get_node_or_null("CastPivot/StaffTip") as Marker2D
		var target_warning := enemy.get_node_or_null(
			"TargetWarning"
		) as TargetWarningScript
		_expect(
			sprite != null and pivot != null and marker != null,
			"Lightning scene must author its sprite, cast pivot, and staff marker."
		)
		_expect(
			target_warning != null
			and not target_warning.visible
			and not target_warning.is_processing()
			and not target_warning.is_warning_active(),
			"Lightning scene must prebuild one hidden, idle target warning."
		)
		if sprite != null:
			_expect(
				sprite.position == Vector2(3.0, -7.0)
				and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
				"Lightning sprite must reuse the Sorcerer pixel placement and nearest filter."
			)
			var frames := sprite.sprite_frames
			_expect_character_animation_contract(
				frames,
				LIGHTNING_MOVE_TEXTURE_PATH,
				"Lightning Sorcerer"
			)
		if pivot != null and marker != null:
			_expect(
				pivot.position == Vector2(0.0, -6.0)
				and marker.position == Vector2(24.0, 1.0),
				"Lightning must start at the authored Sorcerer staff endpoint."
			)
		if fire_enemy != null:
			for path in [
				NodePath("AnimatedSprite2D"),
				NodePath("CollisionShape2D"),
				NodePath("TouchDamageArea/CollisionShape2D"),
			]:
				var lightning_node := enemy.get_node_or_null(path) as Node2D
				var fire_node := fire_enemy.get_node_or_null(path) as Node2D
				_expect(
					lightning_node != null
					and fire_node != null
					and lightning_node.transform.is_equal_approx(fire_node.transform),
					"Lightning Sorcerer geometry must match Fire Sorcerer at %s." % path
				)
		enemy.free()
	if fire_enemy != null:
		fire_enemy.free()

	var enemy_source := FileAccess.get_file_as_string(
		"res://scene/enemy/sorcerer/lightning_sorcerer.gd"
	)
	_expect(
		not enemy_source.contains("projectile_scene")
		and not enemy_source.contains("intersect_shape")
		and enemy_source.contains("request_player_damage")
		and enemy_source.contains("apply_combat_damage"),
		"Lightning must resolve typed direct authoritative damage without a projectile or AOE query."
	)


func _test_five_target_chain_and_exact_boundary() -> void:
	var runtime := _create_runtime("FiveTargetChain")
	var primary := _spawn_player(runtime, Vector2(100.0, 0.0))
	var plant := _spawn_plant(runtime, Vector2(148.0, 0.0))
	var player_two := _spawn_player(runtime, Vector2(196.0, 0.0))
	var player_three := _spawn_player(runtime, Vector2(244.0, 0.0))
	var player_four := _spawn_player(runtime, Vector2(292.0, 0.0))
	var player_five := _spawn_player(runtime, Vector2(340.0, 0.0))
	runtime.candidates.assign([
		primary,
		plant,
		player_two,
		player_three,
		player_four,
		player_five,
	])
	var enemy := _spawn_enemy(runtime, primary)
	var world_path := enemy.call(
		"_resolve_chain_hits",
		primary,
		LIGHTNING_CONFIG,
		enemy.call("_get_multiplayer_damage_source_id", 1)
	) as PackedVector2Array

	_expect(
		world_path.size() == 6,
		"Initial hit plus four bounces must produce at most five hit points."
	)
	_expect(
		world_path[0].is_equal_approx(enemy.staff_tip.global_position),
		"The chain path must begin at the authored staff tip."
	)
	for path_index in range(2, world_path.size()):
		_expect(
			is_equal_approx(
				world_path[path_index - 1].distance_to(world_path[path_index]),
				EXPECTED_CHAIN_RANGE
			),
			"A target exactly three cells away must remain chainable."
		)
	_expect(
		primary.current_health == TEST_HEALTH - 50
		and plant.current_health == TEST_HEALTH - 50
		and player_two.current_health == TEST_HEALTH - 50
		and player_three.current_health == TEST_HEALTH - 50
		and player_four.current_health == TEST_HEALTH - 50,
		"Every selected player/plant in the five-target chain must take full magic damage."
	)
	_expect(
		player_five.current_health == TEST_HEALTH,
		"The sixth candidate must remain untouched after the fourth bounce."
	)
	_expect(
		runtime.query_count == 4,
		"One completed five-target chain must perform exactly four local follow-up queries."
	)
	runtime.queue_free()
	await process_frame


func _test_chain_stops_past_three_cells() -> void:
	var runtime := _create_runtime("OutOfRangeChain")
	var primary := _spawn_player(runtime, Vector2(100.0, 0.0))
	var too_far := _spawn_player(runtime, Vector2(148.25, 0.0))
	runtime.candidates.assign([primary, too_far])
	var enemy := _spawn_enemy(runtime, primary)
	var world_path := enemy.call(
		"_resolve_chain_hits",
		primary,
		LIGHTNING_CONFIG,
		enemy.call("_get_multiplayer_damage_source_id", 2)
	) as PackedVector2Array
	_expect(
		world_path.size() == 2
		and primary.current_health == TEST_HEALTH - 50
		and too_far.current_health == TEST_HEALTH,
		"A target even slightly beyond three cells must stop the chain."
	)
	runtime.queue_free()
	await process_frame


func _test_windup_direct_hit_and_cooldown() -> void:
	var runtime := _create_runtime("WindupDirectHit")
	var primary := _spawn_player(runtime, Vector2(100.0, 0.0))
	runtime.candidates.append(primary)
	var enemy := _spawn_enemy(runtime, primary)
	var target_warning := enemy.get_node_or_null(
		"TargetWarning"
	) as TargetWarningScript
	var authored_child_count := enemy.get_child_count()
	var warning_instance_id := (
		int(target_warning.get_instance_id()) if target_warning != null else 0
	)
	enemy.initial_attack_stagger_left = 0.0
	var projectiles_before := get_nodes_in_group(&"runtime_projectiles").size()
	_expect(
		bool(enemy.call("_try_start_windup", primary, LIGHTNING_CONFIG)),
		"An unobstructed target inside seven cells must start the Lightning windup."
	)
	_expect(
		primary.current_health == TEST_HEALTH,
		"Starting the warning must not deal damage before the windup completes."
	)
	_expect(
		target_warning != null
		and target_warning.visible
		and not target_warning.is_processing()
		and target_warning.is_warning_active()
		and is_zero_approx(target_warning.get_progress_ratio())
		and is_equal_approx(
			target_warning.get_chain_danger_radius(),
			EXPECTED_CHAIN_RANGE
		)
		and target_warning.global_position.is_equal_approx(primary.global_position),
		"Windup start must show a zero-progress warning with the configured first-hop radius and no per-node process loop."
	)

	primary.global_position = Vector2(104.0, 8.0)
	enemy.call("_update_windup", 0.2)
	_expect(
		target_warning != null
		and target_warning.get_progress_ratio() > 0.0
		and target_warning.get_progress_ratio() < 1.0
		and target_warning.global_position.is_equal_approx(primary.global_position),
		"The active warning must advance and follow a moving target."
	)

	primary.global_position = Vector2(EXPECTED_ATTACK_RANGE + 0.25, 0.0)
	enemy.call("_update_windup", 0.01)
	_expect(
		primary.current_health == TEST_HEALTH
		and enemy.combat_state == LightningSorcerer.CombatState.CHASE,
		"Leaving the seven-cell range during windup must cancel without damage."
	)
	_expect(
		target_warning != null
		and not target_warning.visible
		and not target_warning.is_processing()
		and not target_warning.is_warning_active(),
		"A cancelled windup must clear and idle the target warning immediately."
	)

	primary.global_position = Vector2(100.0, 0.0)
	_expect(
		bool(enemy.call("_try_start_windup", primary, LIGHTNING_CONFIG)),
		"A cancelled Lightning attack must be able to start a new windup."
	)
	_expect(
		enemy.get_child_count() == authored_child_count
		and target_warning != null
		and int(target_warning.get_instance_id()) == warning_instance_id,
		"Repeated attacks must reuse the authored warning instead of adding nodes."
	)
	enemy.call("_update_windup", LIGHTNING_CONFIG.windup_duration + 0.01)
	_expect(
		primary.current_health == TEST_HEALTH - 50,
		"Completing the windup must directly apply one full magic hit."
	)
	_expect(
		target_warning != null
		and not target_warning.visible
		and not target_warning.is_processing()
		and not target_warning.is_warning_active(),
		"The warning must clear in the same frame that the direct hit commits."
	)
	_expect(
		enemy.combat_state == LightningSorcerer.CombatState.CHASE
		and is_equal_approx(
			enemy.attack_cooldown_left,
			LIGHTNING_CONFIG.attack_interval
		),
		"The three-second cooldown must begin at instant-hit commit time."
	)
	_expect(
		get_nodes_in_group(&"runtime_projectiles").size() == projectiles_before,
		"Lightning attacks must never spawn a projectile node."
	)

	enemy.attack_cooldown_left = 0.0
	_expect(
		bool(enemy.call("_try_start_windup", primary, LIGHTNING_CONFIG))
		and target_warning != null
		and target_warning.is_warning_active(),
		"The authored warning must remain reusable after a completed strike."
	)
	enemy.call("_die")
	_expect(
		enemy.is_dead
		and target_warning != null
		and not target_warning.visible
		and not target_warning.is_processing()
		and not target_warning.is_warning_active(),
		"Death during windup must clear and idle the target warning."
	)
	_expect(
		enemy.get_child_count() == authored_child_count
		and target_warning != null
		and int(target_warning.get_instance_id()) == warning_instance_id,
		"Cancel, strike, and death paths must never replace the authored warning."
	)
	runtime.queue_free()
	await process_frame


func _create_runtime(runtime_name: String) -> TargetRuntime:
	var runtime := TargetRuntime.new()
	runtime.name = runtime_name
	fixture.add_child(runtime)
	return runtime


func _spawn_enemy(runtime: TargetRuntime, target: Player) -> LightningSorcerer:
	var enemy := LIGHTNING_SCENE.instantiate() as LightningSorcerer
	runtime.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(
		LIGHTNING_CONFIG,
		target,
		runtime.get_node("GridPathfinder"),
		runtime
	)
	enemy.set_physics_process(false)
	return enemy


func _spawn_player(runtime: TargetRuntime, position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	player.bind_combat_runtime(runtime)
	player.global_position = position
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.magic_defense = 0
	player.set("_base_max_health", TEST_HEALTH)
	player.max_health = TEST_HEALTH
	player.current_health = TEST_HEALTH
	player.health_bar.setup(TEST_HEALTH, TEST_HEALTH)
	player.set_physics_process(false)
	player.set_process(false)
	return player


func _spawn_plant(runtime: TargetRuntime, position: Vector2) -> PlantDefense:
	var plant := PlantDefense.new()
	plant.max_health = TEST_HEALTH
	plant.current_health = TEST_HEALTH
	plant.magic_defense = 0
	plant.physical_defense = 999
	runtime.add_child(plant)
	plant.global_position = position
	return plant


func _expect_character_animation_contract(
	frames: SpriteFrames,
	move_texture_path: String,
	label: String
) -> void:
	_expect(frames != null, "%s SpriteFrames resource is missing." % label)
	if frames == null:
		return

	_expect(frames.has_animation(&"move"), "%s move animation is missing." % label)
	if frames.has_animation(&"move"):
		_expect(
			frames.get_frame_count(&"move") == MOVE_FRAME_COUNT,
			"%s move animation must contain eight authored frames." % label
		)
		_expect(
			is_equal_approx(
				frames.get_animation_speed(&"move"),
				MOVE_ANIMATION_SPEED
			)
			and frames.get_animation_loop(&"move"),
			"%s move animation must loop at 12 fps." % label
		)
		var centroid_x_values: Array[float] = []
		var frame_zero_metrics: Dictionary = {}
		var move_frame_metrics: Array[Dictionary] = []
		for frame_index in range(frames.get_frame_count(&"move")):
			var texture := frames.get_frame_texture(
				&"move",
				frame_index
			) as AtlasTexture
			var has_unit_duration := is_equal_approx(
				frames.get_frame_duration(&"move", frame_index),
				1.0
			)
			_expect(
				texture != null
				and texture.get_size() == Vector2(40.0, 40.0)
				and texture.atlas != null
				and texture.atlas.get_size() == Vector2(320.0, 40.0)
				and texture.atlas.resource_path == move_texture_path
				and texture.region == Rect2(
					float(frame_index * 40),
					0.0,
					40.0,
					40.0
				)
				and has_unit_duration,
				"%s move frame %d must use cell %d of the independent 320x40 strip."
				% [label, frame_index, frame_index]
			)
			if texture == null or texture.atlas == null:
				continue
			var metrics := _atlas_alpha_metrics(texture)
			move_frame_metrics.append(metrics)
			_expect(
				int(metrics.get("visible_pixels", 0)) > 0,
				"%s move frame %d must not be empty." % [label, frame_index]
			)
			_expect(
				int(metrics.get("bottom_y", -1)) == MOVE_GROUND_Y,
				"%s move frame %d must share foot baseline y=%d."
				% [label, frame_index, MOVE_GROUND_Y]
			)
			if int(metrics.get("visible_pixels", 0)) > 0:
				centroid_x_values.append(float(metrics["centroid_x"]))
			if frame_index == 0:
				frame_zero_metrics = metrics
		if centroid_x_values.size() == MOVE_FRAME_COUNT:
			var minimum_centroid_x := centroid_x_values[0]
			var maximum_centroid_x := centroid_x_values[0]
			for centroid_x in centroid_x_values:
				minimum_centroid_x = minf(minimum_centroid_x, centroid_x)
				maximum_centroid_x = maxf(maximum_centroid_x, centroid_x)
			_expect(
				maximum_centroid_x - minimum_centroid_x
				<= MAX_MOVE_CENTROID_X_DRIFT + 0.001,
				(
					"%s move alpha centroid must drift no more than %.1f px "
					+ "horizontally; saw %.3f px."
				)
				% [
					label,
					MAX_MOVE_CENTROID_X_DRIFT,
					maximum_centroid_x - minimum_centroid_x,
				]
			)
		if not frame_zero_metrics.is_empty():
			_expect(
				int(frame_zero_metrics.get("ground_contact_groups", 0)) >= 2
				and int(frame_zero_metrics.get("ground_contact_pixels", 0)) >= 6
				and int(frame_zero_metrics.get("ground_contact_span", 0)) >= 8,
				(
					"%s move frame 0 must be a naturally grounded contact pose "
					+ "with two separated feet."
				)
				% label
			)
		if move_frame_metrics.size() == MOVE_FRAME_COUNT:
			var pass_right_contacts: PackedInt32Array = move_frame_metrics[2].get(
				"ground_contact_lengths",
				PackedInt32Array()
			)
			var down_left_contacts: PackedInt32Array = move_frame_metrics[5].get(
				"ground_contact_lengths",
				PackedInt32Array()
			)
			var pass_left_contacts: PackedInt32Array = move_frame_metrics[6].get(
				"ground_contact_lengths",
				PackedInt32Array()
			)
			_expect(
				pass_right_contacts.size() == 1
				and pass_left_contacts.size() == 1,
				"%s passing poses F2/F6 must each have one planted sole."
				% label
			)
			_expect(
				down_left_contacts.size() == 2
				and down_left_contacts[0] >= 5
				and down_left_contacts[1] <= 3,
				(
					"%s F5 must transfer weight to the screen-left sole "
					+ "while the screen-right foot keeps toe contact only."
				)
				% label
			)

	for animation_name in [&"windup", &"attack", &"death"]:
		_expect(
			frames.has_animation(animation_name)
			and frames.get_frame_count(animation_name) == 4,
			"%s %s animation must contain four frames."
			% [label, String(animation_name)]
		)
		if not frames.has_animation(animation_name):
			continue
		for frame_index in range(frames.get_frame_count(animation_name)):
			var texture := frames.get_frame_texture(
				animation_name,
				frame_index
			) as AtlasTexture
			_expect(
				texture != null
				and texture.get_size() == Vector2(40.0, 40.0)
				and texture.atlas != null
				and texture.atlas.get_size() == Vector2(160.0, 160.0)
				and _atlas_alpha_metrics(texture).get("visible_pixels", 0) > 0,
				(
					"%s %s frame %d must remain a nonempty native 40x40 "
					+ "cell in the 160x160 character atlas."
				)
				% [label, String(animation_name), frame_index]
			)


func _atlas_alpha_metrics(texture: AtlasTexture) -> Dictionary:
	var atlas_image := texture.atlas.get_image()
	if atlas_image == null:
		return {}
	var region := Rect2i(
		Vector2i(
			roundi(texture.region.position.x),
			roundi(texture.region.position.y)
		),
		Vector2i(
			roundi(texture.region.size.x),
			roundi(texture.region.size.y)
		)
	)
	if (
		region.position.x < 0
		or region.position.y < 0
		or region.end.x > atlas_image.get_width()
		or region.end.y > atlas_image.get_height()
	):
		return {}
	var alpha_total := 0.0
	var weighted_x := 0.0
	var visible_pixels := 0
	var bottom_y := -1
	for local_y in range(region.size.y):
		for local_x in range(region.size.x):
			var alpha := atlas_image.get_pixel(
				region.position.x + local_x,
				region.position.y + local_y
			).a
			if alpha <= 0.0:
				continue
			visible_pixels += 1
			alpha_total += alpha
			weighted_x += float(local_x) * alpha
			bottom_y = maxi(bottom_y, local_y)
	if alpha_total <= 0.0:
		return {
			"visible_pixels": 0,
			"bottom_y": -1,
		}

	var ground_contact_groups := 0
	var ground_contact_pixels := 0
	var ground_min_x := region.size.x
	var ground_max_x := -1
	var previous_was_visible := false
	var current_contact_length := 0
	var ground_contact_lengths := PackedInt32Array()
	for local_x in range(region.size.x):
		var is_visible := atlas_image.get_pixel(
			region.position.x + local_x,
			region.position.y + bottom_y
		).a > 0.0
		if is_visible:
			ground_contact_pixels += 1
			current_contact_length += 1
			ground_min_x = mini(ground_min_x, local_x)
			ground_max_x = maxi(ground_max_x, local_x)
			if not previous_was_visible:
				ground_contact_groups += 1
		elif previous_was_visible:
			ground_contact_lengths.append(current_contact_length)
			current_contact_length = 0
		previous_was_visible = is_visible
	if previous_was_visible:
		ground_contact_lengths.append(current_contact_length)
	return {
		"visible_pixels": visible_pixels,
		"centroid_x": weighted_x / alpha_total,
		"bottom_y": bottom_y,
		"ground_contact_groups": ground_contact_groups,
		"ground_contact_pixels": ground_contact_pixels,
		"ground_contact_span": (
			ground_max_x - ground_min_x + 1 if ground_max_x >= 0 else 0
		),
		"ground_contact_lengths": ground_contact_lengths,
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
