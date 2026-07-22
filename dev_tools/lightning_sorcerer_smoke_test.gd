extends SceneTree

const LIGHTNING_SCENE := preload(
	"res://scene/enemy/lightning_sorcerer.tscn"
)
const LIGHTNING_CONFIG := preload(
	"res://resources/config/enemies/lightning_sorcerer.tres"
)
const FIRE_SCENE := preload("res://scene/enemy/fire_sorcerer.tscn")
const FROST_CONFIG := preload(
	"res://resources/config/enemies/frost_sorcerer.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)

const TEST_HEALTH := 1000
const EXPECTED_ATTACK_RANGE := 7.0 * 16.0
const EXPECTED_CHAIN_RANGE := 3.0 * 16.0


class TargetRuntime:
	extends Node2D

	var candidates: Array[Node2D] = []
	var query_count := 0

	func find_nearest_enemy_attack_target(
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
		_expect(
			sprite != null and pivot != null and marker != null,
			"Lightning scene must author its sprite, cast pivot, and staff marker."
		)
		if sprite != null:
			_expect(
				sprite.position == Vector2(3.0, -7.0)
				and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
				"Lightning sprite must reuse the Sorcerer pixel placement and nearest filter."
			)
			var frames := sprite.sprite_frames
			for animation_name in [&"move", &"windup", &"attack", &"death"]:
				_expect(
					frames.has_animation(animation_name)
					and frames.get_frame_count(animation_name) == 4,
					"Every Lightning Sorcerer animation must contain four 40 px frames."
				)
			var texture := frames.get_frame_texture(&"move", 0) as AtlasTexture
			_expect(
				texture != null
				and texture.region.size == Vector2(40.0, 40.0)
				and texture.atlas.get_size() == Vector2(160.0, 160.0),
				"Lightning character atlas must be 160x160 with native 40x40 cells."
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
		"res://scene/enemy/lightning_sorcerer.gd"
	)
	_expect(
		not enemy_source.contains("projectile_scene")
		and not enemy_source.contains("intersect_shape")
		and enemy_source.contains("request_multiplayer_player_damage"),
		"Lightning must resolve direct authoritative damage without a projectile or AOE query."
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
	enemy.initial_attack_stagger_left = 0.0
	var projectiles_before := get_nodes_in_group(&"runtime_projectiles").size()
	_expect(
		bool(enemy.call("_try_start_windup", primary, LIGHTNING_CONFIG)),
		"An unobstructed target inside seven cells must start the Lightning windup."
	)
	enemy.call("_update_windup", LIGHTNING_CONFIG.windup_duration + 0.01)
	_expect(
		primary.current_health == TEST_HEALTH - 50,
		"Completing the windup must directly apply one full magic hit."
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
	runtime.queue_free()
	await process_frame


func _create_runtime(runtime_name: String) -> TargetRuntime:
	var runtime := TargetRuntime.new()
	runtime.name = runtime_name
	fixture.add_child(runtime)
	var pathfinder := Node.new()
	pathfinder.name = "GridPathfinder"
	runtime.add_child(pathfinder)
	return runtime


func _spawn_enemy(runtime: TargetRuntime, target: Player) -> LightningSorcerer:
	var enemy := LIGHTNING_SCENE.instantiate() as LightningSorcerer
	runtime.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(LIGHTNING_CONFIG, target, runtime.get_node("GridPathfinder"))
	enemy.set_physics_process(false)
	return enemy


func _spawn_player(runtime: TargetRuntime, position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
