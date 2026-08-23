extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const BULLET_SCENE := preload("res://scene/enemy/capoo/capoo_smg_bullet.tscn")
const MOTION_SYSTEM_SCENE := preload(
	"res://scene/enemy/capoo/capoo_projectile_motion_system.tscn"
)
const WORLD_COLLISION_MASK := 1

var failures: Array[String] = []
var game: TowerDefenseGame = null


class PhysicsSetupDriver:
	extends Node

	var batched_projectile: CapooAK47Bullet = null
	var individual_projectile: CapooAK47Bullet = null
	var pathfinder: GridPathfinder = null
	var motion_system: Node = null
	var did_setup := false

	func _physics_process(_delta: float) -> void:
		if did_setup:
			return
		did_setup = true
		batched_projectile.setup(
			Vector2.RIGHT,
			1,
			30.0,
			0.5,
			pathfinder,
			motion_system
		)
		individual_projectile.setup(
			Vector2.RIGHT,
			1,
			30.0,
			0.5,
			pathfinder,
			null
		)
		set_physics_process(false)


class PhysicsMotionObserver:
	extends Node

	var driver: PhysicsSetupDriver = null
	var batched_projectile: CapooAK47Bullet = null
	var individual_projectile: CapooAK47Bullet = null
	var batched_positions := PackedVector2Array()
	var individual_positions := PackedVector2Array()

	func _physics_process(_delta: float) -> void:
		if driver == null or not driver.did_setup:
			return
		batched_positions.append(batched_projectile.global_position)
		individual_positions.append(individual_projectile.global_position)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	game = TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Tower-defense fixture must instantiate.")
	if game == null:
		await _finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var pathfinder := game.grid_pathfinder as GridPathfinder
	_expect(
		game.get_node_or_null(^"CapooProjectileMotionSystem") == null,
		"Tower-defense production must not mount the retired Capoo motion system."
	)
	var motion_system := MOTION_SYSTEM_SCENE.instantiate()
	motion_system.name = "LegacyCapooProjectileMotionFixture"
	game.add_child(motion_system)
	_expect(pathfinder != null and pathfinder.is_built, "GridPathfinder must be built.")
	_expect(
		motion_system != null,
		"The isolated legacy projectile fixture must provide its own motion system."
	)
	if pathfinder == null or not pathfinder.is_built:
		await _finish()
		return

	var open_cell := _find_guarded_open_cell(pathfinder)
	var blocked_pair := _find_open_to_blocked_pair(pathfinder)
	_expect(open_cell != Vector2i.MAX, "Fixture needs one guarded open cell.")
	_expect(not blocked_pair.is_empty(), "Fixture needs one open-to-obstacle cell pair.")
	if open_cell == Vector2i.MAX or blocked_pair.is_empty():
		await _finish()
		return

	var open_center := pathfinder.call("_map_to_global", open_cell) as Vector2
	var open_from := open_center + Vector2(-2.0, 0.0)
	var open_to := open_center + Vector2(2.0, 0.0)
	_expect(
		not pathfinder.world_collision_layer_exclusive_to_authored_tiles
		and not pathfinder.is_world_collision_segment_certified_clear(
			open_from,
			open_to
		),
		"Production scenes with supplemental World bodies must not issue a tile-only certificate."
	)
	_expect(
		not _physics_world_ray_hits(open_from, open_to),
		"Open fixture segment must be clear in Physics2D."
	)

	var blocked_from := pathfinder.call(
		"_map_to_global",
		blocked_pair["open"]
	) as Vector2
	var blocked_to := pathfinder.call(
		"_map_to_global",
		blocked_pair["blocked"]
	) as Vector2
	_expect(
		not pathfinder.is_world_collision_segment_certified_clear(
			blocked_from,
			blocked_to
		),
		"Segment entering an authored obstacle must never be certified clear."
	)
	_expect(
		_physics_world_ray_hits(blocked_from, blocked_to),
		"Blocked fixture segment must hit the authored world collision layer."
	)

	var bullet := BULLET_SCENE.instantiate() as CapooAK47Bullet
	_expect(bullet != null, "SMG bullet scene must instantiate CapooAK47Bullet.")
	if bullet != null:
		game.add_child(bullet)
		bullet.setup(
			Vector2.RIGHT,
			1,
			190.0,
			0.18,
			pathfinder,
			motion_system
		)
		_expect(
			motion_system != null
			and bool(motion_system.call("has_projectile", bullet))
			and bullet.batched_motion_system == motion_system,
			"Batched setup must register the projectile with the shared system."
		)
		_expect(
			not bullet.is_physics_processing(),
			"A registered projectile must not retain its individual physics callback."
		)
		CapooAK47Bullet.performance_metrics_enabled = true

		var supplemental_body := StaticBody2D.new()
		var supplemental_shape_node := CollisionShape2D.new()
		var supplemental_shape := CircleShape2D.new()
		supplemental_shape.radius = 2.0
		supplemental_shape_node.shape = supplemental_shape
		supplemental_body.add_child(supplemental_shape_node)
		game.add_child(supplemental_body)
		supplemental_body.global_position = open_center
		await physics_frame
		CapooAK47Bullet.world_collision_certificate_enabled = true
		CapooAK47Bullet.reset_performance_metrics()
		var supplemental_hit: bool = bullet.call(
			"_will_hit_world",
			open_from,
			open_to
		)
		var supplemental_metrics := CapooAK47Bullet.get_performance_metrics()
		_expect(
			supplemental_hit
			and int(supplemental_metrics["physics_ray_calls"]) == 1
			and int(supplemental_metrics["physics_ray_hits"]) == 1
			and int(supplemental_metrics["certified_clear_calls"]) == 0,
			(
				"A non-TileMap World StaticBody2D must force the exact ray even "
				+ "when the experimental bullet certificate switch is enabled."
			)
		)
		supplemental_body.queue_free()
		await physics_frame

		# The fast branch remains available only to isolated fixtures that can
		# prove the World layer is authored exclusively by this TileMap.
		pathfinder.world_collision_layer_exclusive_to_authored_tiles = true
		CapooAK47Bullet.reset_performance_metrics()
		var certified_hit: bool = bullet.call(
			"_will_hit_world",
			open_from,
			open_to
		)
		var certified_metrics := CapooAK47Bullet.get_performance_metrics()
		_expect(not certified_hit, "Certified open bullet segment must stay clear.")
		_expect(
			int(certified_metrics["certified_clear_calls"]) == 1
			and int(certified_metrics["physics_ray_calls"]) == 0,
			"Open bullet segment must skip the Physics2D ray exactly once."
		)

		CapooAK47Bullet.reset_performance_metrics()
		var blocked_hit: bool = bullet.call(
			"_will_hit_world",
			blocked_from,
			blocked_to
		)
		var blocked_metrics := CapooAK47Bullet.get_performance_metrics()
		_expect(blocked_hit, "Uncertified blocked bullet segment must retain its hit.")
		_expect(
			int(blocked_metrics["physics_ray_calls"]) == 1
			and int(blocked_metrics["physics_ray_hits"]) == 1,
			"Blocked bullet segment must use and hit the exact Physics2D ray."
		)

		CapooAK47Bullet.world_collision_certificate_enabled = false
		pathfinder.world_collision_layer_exclusive_to_authored_tiles = false
		CapooAK47Bullet.reset_performance_metrics()
		var legacy_open_hit: bool = bullet.call(
			"_will_hit_world",
			open_from,
			open_to
		)
		var legacy_metrics := CapooAK47Bullet.get_performance_metrics()
		_expect(not legacy_open_hit, "Legacy open Physics2D ray must stay clear.")
		_expect(
			int(legacy_metrics["physics_ray_calls"]) == 1
			and int(legacy_metrics["certified_clear_calls"]) == 0,
			"Disabled certificate A/B branch must always use the legacy ray."
		)
		bullet.retire(false)
		_expect(
			motion_system == null
			or not bool(motion_system.call("has_projectile", bullet)),
			"Retiring a projectile must synchronously unregister it from the batch."
		)

	if motion_system != null:
		_test_batched_motion_equivalence(
			pathfinder,
			motion_system,
			open_center
		)
		await _test_real_physics_schedule(
			pathfinder,
			motion_system,
			open_center
		)
		await _test_batched_natural_expiry(
			pathfinder,
			motion_system,
			open_center
		)
	await _test_interleaved_world_ray_schedule(pathfinder, open_center)
	await _test_interleaved_thin_wall_guards(pathfinder, open_center)

	CapooAK47Bullet.performance_metrics_enabled = false
	CapooAK47Bullet.world_collision_certificate_enabled = false
	await _finish()


func _test_batched_motion_equivalence(
	pathfinder: GridPathfinder,
	motion_system: Node,
	start_position: Vector2
) -> void:
	var batched := BULLET_SCENE.instantiate() as CapooAK47Bullet
	var individual := BULLET_SCENE.instantiate() as CapooAK47Bullet
	_expect(
		batched != null and individual != null,
		"Motion A/B requires two Capoo projectile instances."
	)
	if batched == null or individual == null:
		return
	game.add_child(batched)
	game.add_child(individual)
	batched.global_position = start_position
	individual.global_position = start_position
	batched.setup(Vector2.RIGHT, 1, 30.0, 0.5, pathfinder, motion_system)
	individual.setup(Vector2.RIGHT, 1, 30.0, 0.5, pathfinder, null)
	individual.set_physics_process(false)

	var test_delta := 1.0 / 60.0
	batched.advance_batched(test_delta)
	individual.call("_advance_projectile", test_delta)
	_expect(
		batched.global_position.is_equal_approx(individual.global_position),
		"Batched and individual motion must produce the same one-tick position."
	)
	_expect(
		is_equal_approx(
			batched.remaining_lifetime,
			individual.remaining_lifetime
		),
		"Batched and individual motion must consume the same lifetime."
	)
	batched.retire(false)
	individual.retire(false)


func _test_real_physics_schedule(
	pathfinder: GridPathfinder,
	motion_system: Node,
	start_position: Vector2
) -> void:
	var batched := BULLET_SCENE.instantiate() as CapooAK47Bullet
	var individual := BULLET_SCENE.instantiate() as CapooAK47Bullet
	if batched == null or individual == null:
		_expect(false, "Real scheduling A/B requires two projectile instances.")
		return
	game.add_child(batched)
	game.add_child(individual)
	batched.global_position = start_position
	individual.global_position = start_position
	batched.set_physics_process(false)
	individual.set_physics_process(false)

	var driver := PhysicsSetupDriver.new()
	driver.batched_projectile = batched
	driver.individual_projectile = individual
	driver.pathfinder = pathfinder
	driver.motion_system = motion_system
	driver.process_physics_priority = 0
	var observer := PhysicsMotionObserver.new()
	observer.driver = driver
	observer.batched_projectile = batched
	observer.individual_projectile = individual
	observer.process_physics_priority = 10
	game.add_child(driver)
	game.add_child(observer)

	while observer.batched_positions.size() < 2:
		await physics_frame
		await process_frame

	_expect(
		observer.batched_positions[0].is_equal_approx(start_position)
		and observer.individual_positions[0].is_equal_approx(start_position),
		"Both paths must defer a projectile configured inside physics until the next tick."
	)
	_expect(
		observer.batched_positions[1].is_equal_approx(
			observer.individual_positions[1]
		)
		and observer.batched_positions[1].x > start_position.x,
		"Real batched and individual callbacks must advance exactly once on the next tick."
	)
	batched.retire(false)
	individual.retire(false)
	driver.queue_free()
	observer.queue_free()


func _test_batched_natural_expiry(
	pathfinder: GridPathfinder,
	motion_system: Node,
	start_position: Vector2
) -> void:
	var active_before := int(motion_system.call("get_active_projectile_count"))
	var unparented := BULLET_SCENE.instantiate() as CapooAK47Bullet
	_expect(unparented != null, "Unparented lifecycle fixture must instantiate.")
	if unparented != null:
		unparented.setup(
			Vector2.RIGHT,
			1,
			0.0,
			0.02,
			pathfinder,
			motion_system
		)
		_expect(
			unparented.batched_motion_system == null
			and int(motion_system.call("get_active_projectile_count")) == active_before,
			"An unparented projectile must defer registration and leave no stale slot."
		)
		unparented.free()

	var expiring := BULLET_SCENE.instantiate() as CapooAK47Bullet
	if expiring == null:
		_expect(false, "Natural-expiry fixture must instantiate.")
		return
	game.add_child(expiring)
	expiring.global_position = start_position
	var finish_count := [0]
	expiring.projectile_finished.connect(
		func(_projectile_id: int, _projectile: Node) -> void:
			finish_count[0] = int(finish_count[0]) + 1
	)
	expiring.setup(
		Vector2.RIGHT,
		1,
		0.0,
		0.02,
		pathfinder,
		motion_system
	)
	for _frame_index in range(6):
		await physics_frame
		await process_frame
		if (
			int(finish_count[0]) == 1
			and int(motion_system.call("get_active_projectile_count")) == active_before
		):
			break
	_expect(
		int(finish_count[0]) == 1,
		"A naturally expired batched projectile must emit exactly one completion signal."
	)
	_expect(
		int(motion_system.call("get_active_projectile_count")) == active_before,
		"Natural expiry must return the motion-system slot to its prior count."
	)


func _test_interleaved_world_ray_schedule(
	pathfinder: GridPathfinder,
	start_position: Vector2
) -> void:
	var phase_zero := BULLET_SCENE.instantiate() as CapooAK47Bullet
	var phase_one := BULLET_SCENE.instantiate() as CapooAK47Bullet
	_expect(
		phase_zero != null and phase_one != null,
		"Interleaved World-ray fixture requires two projectiles."
	)
	if phase_zero == null or phase_one == null:
		return
	game.add_child(phase_zero)
	game.add_child(phase_one)
	for bullet in [phase_zero, phase_one]:
		bullet.global_position = start_position
		bullet.setup(Vector2.RIGHT, 1, 0.0, 10.0, pathfinder, null)
		bullet.set_physics_process(false)
	phase_zero.world_collision_check_phase = 0
	phase_one.world_collision_check_phase = 1

	CapooAK47Bullet.world_collision_certificate_enabled = false
	CapooAK47Bullet.performance_metrics_enabled = true
	CapooAK47Bullet.reset_performance_metrics()
	const TEST_TICKS := 120
	var test_delta := 1.0 / 60.0
	for tick_index in range(TEST_TICKS):
		phase_zero.call("_advance_projectile", test_delta)
		phase_one.call("_advance_projectile", test_delta)
		var tick_metrics := CapooAK47Bullet.get_performance_metrics()
		_expect(
			int(tick_metrics["world_segment_calls"]) == tick_index + 1,
			(
				"Opposite projectile phases must distribute exactly one World ray "
				+ "per physics tick (tick=%d calls=%d)."
			)
			% [tick_index, int(tick_metrics["world_segment_calls"])]
		)
	var metrics := CapooAK47Bullet.get_performance_metrics()
	_expect(
		int(metrics["world_segment_calls"]) == TEST_TICKS
		and int(metrics["physics_ray_calls"]) == TEST_TICKS,
		(
			"Two 60 Hz projectiles over %d ticks must issue %d interleaved "
			+ "World rays instead of %d."
		)
		% [TEST_TICKS, TEST_TICKS, TEST_TICKS * 2]
	)
	_expect(
		is_equal_approx(phase_zero.remaining_lifetime, 8.0)
		and is_equal_approx(phase_one.remaining_lifetime, 8.0),
		"World-ray interleaving must not reduce 60 Hz projectile lifetime updates."
	)
	phase_zero.retire(false)
	phase_one.retire(false)
	await process_frame


func _test_interleaved_thin_wall_guards(
	pathfinder: GridPathfinder,
	open_center: Vector2
) -> void:
	var start_position := open_center + Vector2(-4.0, 0.0)
	var wall_position := start_position + Vector2(1.0, 0.0)
	var thin_wall := StaticBody2D.new()
	thin_wall.collision_layer = WORLD_COLLISION_MASK
	thin_wall.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 0.25
	shape_node.shape = shape
	thin_wall.add_child(shape_node)
	game.add_child(thin_wall)
	thin_wall.global_position = wall_position
	await physics_frame

	var scheduled_bullet := BULLET_SCENE.instantiate() as CapooAK47Bullet
	_expect(scheduled_bullet != null, "Thin-wall schedule fixture must instantiate.")
	if scheduled_bullet != null:
		game.add_child(scheduled_bullet)
		scheduled_bullet.global_position = start_position
		scheduled_bullet.setup(Vector2.RIGHT, 1, 120.0, 1.0, pathfinder, null)
		scheduled_bullet.set_physics_process(false)
		scheduled_bullet.world_collision_check_phase = 1
		CapooAK47Bullet.reset_performance_metrics()
		scheduled_bullet.call("_advance_projectile", 1.0 / 60.0)
		_expect(
			not scheduled_bullet.has_hit
			and scheduled_bullet.global_position.is_equal_approx(
				start_position + Vector2(2.0, 0.0)
			),
			"The interleaved tick must retain the authored 60 Hz projectile movement."
		)
		scheduled_bullet.call("_advance_projectile", 1.0 / 60.0)
		var scheduled_metrics := CapooAK47Bullet.get_performance_metrics()
		_expect(
			scheduled_bullet.has_hit
			and scheduled_bullet.global_position.distance_to(wall_position) <= 0.5,
			"The next 30 Hz check must sweep the accumulated segment into a thin wall."
		)
		_expect(
			int(scheduled_metrics["physics_ray_calls"]) == 1
			and int(scheduled_metrics["physics_ray_hits"]) == 1,
			"An accumulated two-tick thin-wall collision must use one exact World ray."
		)

	var guarded_bullet := BULLET_SCENE.instantiate() as CapooAK47Bullet
	_expect(guarded_bullet != null, "Thin-wall damage guard fixture must instantiate.")
	if guarded_bullet != null:
		game.add_child(guarded_bullet)
		guarded_bullet.global_position = start_position
		guarded_bullet.setup(Vector2.RIGHT, 7, 120.0, 1.0, pathfinder, null)
		guarded_bullet.set_physics_process(false)
		guarded_bullet.world_collision_check_phase = 1
		CapooAK47Bullet.reset_performance_metrics()
		guarded_bullet.call("_advance_projectile", 1.0 / 60.0)
		var player_health_before := game.player.current_health
		guarded_bullet.call("_on_body_entered", game.player)
		var guard_metrics := CapooAK47Bullet.get_performance_metrics()
		_expect(
			guarded_bullet.has_hit
			and game.player.current_health == player_health_before,
			"A damage contact on the skipped tick must not hit a player behind a wall."
		)
		_expect(
			int(guard_metrics["physics_ray_calls"]) == 1
			and int(guard_metrics["physics_ray_hits"]) == 1,
			"Damage preflight must validate exactly the unchecked World suffix."
		)
		_expect(
			guarded_bullet.global_position.distance_to(wall_position) <= 0.5,
			"A blocked damage contact must place its hit at the World intersection."
		)

	thin_wall.queue_free()
	await physics_frame
	await process_frame


func _find_guarded_open_cell(pathfinder: GridPathfinder) -> Vector2i:
	var region := pathfinder.raw_navigation_snapshot_region
	for y in range(region.position.y + 1, region.end.y - 1):
		for x in range(region.position.x + 1, region.end.x - 1):
			var center := Vector2i(x, y)
			var guarded_open := true
			for offset_y in range(-1, 2):
				for offset_x in range(-1, 2):
					if bool(pathfinder.call(
						"_is_obstacle_cell_blocked",
						center + Vector2i(offset_x, offset_y)
					)):
						guarded_open = false
						break
				if not guarded_open:
					break
			if guarded_open:
				return center
	return Vector2i.MAX


func _find_open_to_blocked_pair(pathfinder: GridPathfinder) -> Dictionary:
	var region := pathfinder.raw_navigation_snapshot_region
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var blocked := Vector2i(x, y)
			if not bool(pathfinder.call("_is_obstacle_cell_blocked", blocked)):
				continue
			for direction in [
				Vector2i.RIGHT,
				Vector2i.LEFT,
				Vector2i.DOWN,
				Vector2i.UP,
			]:
				var open: Vector2i = blocked + direction
				if (
					region.has_point(open)
					and not bool(pathfinder.call("_is_obstacle_cell_blocked", open))
				):
					return {"open": open, "blocked": blocked}
	return {}


func _physics_world_ray_hits(from_position: Vector2, to_position: Vector2) -> bool:
	var query := PhysicsRayQueryParameters2D.create(
		from_position,
		to_position,
		WORLD_COLLISION_MASK
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return not game.get_world_2d().direct_space_state.intersect_ray(query).is_empty()


func _finish() -> void:
	current_scene = null
	var game_to_free := game
	game = null
	if game_to_free != null:
		game_to_free.queue_free()
	for _frame_index in range(4):
		await process_frame
		await physics_frame
	_expect(
		game_to_free == null or not is_instance_valid(game_to_free),
		"The production runtime and isolated legacy fixture must teardown cleanly."
	)
	if failures.is_empty():
		print("CAPOO_PROJECTILE_WORLD_CERTIFICATE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
