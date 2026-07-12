extends SceneTree

const PROJECTILE_CASES := [
	{
		"label": "player_bullet",
		"scene": preload("res://scene/bullet.tscn"),
		"expected_lifetime": 2.0,
	},
	{
		"label": "tiyi_sniper_bullet",
		"scene": preload("res://scene/player/tiyi/tiyi_sniper_bullet.tscn"),
		"expected_lifetime": 0.35,
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
		"scene": preload("res://scene/boss/linglan/linglan_skill2_sakura_rocket.tscn"),
		"expected_lifetime": 5.0,
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
			configured_lifetime > 0.0 and configured_lifetime <= 5.0,
			"%s must not exceed the current five-second projectile ceiling." % label
		)
		envelope_parts.append(
			"%s=%.2fs/%.1fpx" % [
				label,
				configured_lifetime,
				configured_lifetime * configured_speed,
			]
		)
		projectile.call("_physics_process", configured_lifetime + 0.1)
		_expect(
			projectile.is_queued_for_deletion(),
			"%s must reach queue_free when its lifetime is exhausted." % label
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
