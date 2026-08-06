extends SceneTree

const PROJECTILE_CASES := [
	{
		"label": "player_bullet",
		"scene": preload("res://scene/combat/projectiles/bullet.tscn"),
		"expected_lifetime": 1.083,
		"expected_speed": 320.0,
		"view_bounded": true,
	},
	{
		"label": "tiyi_sniper_bullet",
		"scene": preload("res://scene/player/tiyi/tiyi_sniper_bullet.tscn"),
		"expected_lifetime": 0.181,
		"expected_speed": 1920.0,
		"view_bounded": true,
	},
	{
		"label": "tango_laser_bullet",
		"scene": preload("res://scene/player/tango/tango_laser_bullet.tscn"),
		"expected_lifetime": 0.722,
		"expected_speed": 480.0,
		"view_bounded": true,
	},
	{
		"label": "weishidaier_skill1_bomb",
		"scene": preload("res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn"),
		"expected_lifetime": 1.4,
	},
	{
		"label": "collectible_arrow",
		"scene": preload("res://scene/collectible_arrow_projectile.tscn"),
		"expected_lifetime": 1.8,
	},
	{
		"label": "agave_cannonball",
		"scene": preload("res://scene/plant_defense/agave_cannonball.tscn"),
		"expected_lifetime": 1.25,
	},
	{
		"label": "collectible_sakura_rocket",
		"scene": preload("res://scene/collectible_sakura_rocket.tscn"),
		"expected_lifetime": 5.0,
	},
	{
		"label": "fire_sorcerer_fireball_volley",
		"scene": preload(
			"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
		),
		"expected_lifetime": 7.0,
		"maximum_allowed_lifetime": 7.0,
		"retire_visual_delay": 0.5,
	},
	{
		"label": "fire_sorcerer_elite_fireball_volley",
		"scene": preload(
			"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn"
		),
		"expected_lifetime": 7.0,
		"maximum_allowed_lifetime": 7.0,
		"retire_visual_delay": 0.5,
	},
	{
		"label": "frost_sorcerer_ice_spike",
		"scene": preload(
			"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn"
		),
		"expected_lifetime": 7.0,
		"expected_speed": 100.0,
		"maximum_allowed_lifetime": 7.0,
		"retire_visual_delay": 0.5,
	},
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Node2D.new()
	fixture.name = "ProjectileLifetimeFixture"
	root.add_child(fixture)
	current_scene = fixture
	var envelope_parts: PackedStringArray = []
	for projectile_case in PROJECTILE_CASES:
		var case_data := projectile_case as Dictionary
		var label := str(case_data["label"])
		var projectile_scene := case_data["scene"] as PackedScene
		var expected_lifetime := float(case_data["expected_lifetime"])
		var maximum_allowed_lifetime := float(
			case_data.get("maximum_allowed_lifetime", 5.0)
		)
		var retire_visual_delay := float(
			case_data.get("retire_visual_delay", 0.0)
		)
		var projectile := projectile_scene.instantiate() as Node2D
		_expect(projectile != null, "%s must instantiate." % label)
		if projectile == null:
			continue
		projectile.set_physics_process(false)
		fixture.add_child(projectile)
		var configured_lifetime := float(projectile.get("max_lifetime"))
		var configured_speed := float(projectile.get("speed"))
		_expect(
			is_equal_approx(configured_lifetime, expected_lifetime),
			"%s lifetime must remain explicitly bounded at %.2fs." % [label, expected_lifetime]
		)
		_expect(
			configured_lifetime > 0.0
			and configured_lifetime <= maximum_allowed_lifetime,
			"%s must not exceed its explicit %.2fs projectile ceiling."
			% [label, maximum_allowed_lifetime]
		)
		if case_data.has("expected_speed"):
			var expected_speed := float(case_data["expected_speed"])
			_expect(
				is_equal_approx(configured_speed, expected_speed),
				"%s speed must remain explicitly authored at %.1fpx/s."
				% [label, expected_speed]
			)
		if bool(case_data.get("view_bounded", false)):
			var required_distance := Bullet.get_view_exit_distance()
			var configured_distance := configured_speed * configured_lifetime
			var calculated_lifetime := Bullet.calculate_view_bounded_lifetime(
				configured_speed
			)
			_expect(
				is_equal_approx(configured_lifetime, calculated_lifetime),
				(
					"%s lifetime must be derived from the tower-defense design "
					+ "viewport, camera zoom, one-tile exit margin, and projectile speed."
				) % label
			)
			_expect(
				configured_distance >= required_distance
				and configured_distance
				< required_distance
				+ configured_speed * Bullet.VIEW_BOUNDED_LIFETIME_PRECISION_SECONDS
				+ 0.001,
				(
					"%s must expire within one lifetime-precision step after "
					+ "crossing the farthest viewport corner plus its one-tile margin."
				) % label
			)
		envelope_parts.append(
			"%s=%.2fs/%.1fpx" % [
				label,
				configured_lifetime,
				configured_lifetime * configured_speed,
			]
		)
		var start_position := projectile.global_position
		projectile.call("_physics_process", configured_lifetime + 0.1)
		if bool(case_data.get("view_bounded", false)):
			var travelled_distance := projectile.global_position.distance_to(
				start_position
			)
			_expect(
				is_equal_approx(
					travelled_distance,
					configured_lifetime * configured_speed
				),
				(
					"%s must clamp its final physics step to remaining_lifetime "
					+ "instead of overshooting the authored view envelope."
				) % label
			)
		if (
			not projectile.is_queued_for_deletion()
			and retire_visual_delay > 0.0
		):
			projectile.call("_physics_process", retire_visual_delay)
		_expect(
			projectile.is_queued_for_deletion(),
			(
				"%s must reach queue_free after its lifetime and bounded "
				+ "retire visual are exhausted."
			) % label
		)
		await process_frame
		_expect(not is_instance_valid(projectile), "%s must leave the tree after release." % label)

	print("TRANSIENT_PROJECTILE_LIFETIMES %s" % " ".join(envelope_parts))
	current_scene = null
	fixture.queue_free()
	for _cleanup_index in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("TRANSIENT_PROJECTILE_LIFETIME_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
