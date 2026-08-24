extends SceneTree

const SIMPLE_CHASE_SCRIPT := preload(
	"res://scene/enemy/simple_chase_layered_enemy.gd"
)
const NINJA_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_ninja.tres"
)
const NINJA_ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_ninja_elite.tres"
)
const UNMIGRATED_DERIVED_SCRIPT := preload(
	"res://dev_tools/fixtures/combat_robot_ninja_unmigrated_derived_fixture.gd"
)

const REQUIRED_PHASE_METHODS: Array[StringName] = [
	&"simulate_trusted_layered_area_event_phase",
	&"simulate_trusted_layered_area_decision_phase",
	&"simulate_trusted_layered_area_motion_phase",
	&"prepare_layered_area_authoritative_simulation",
	&"get_layered_area_planned_displacement",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	for config in [NINJA_CONFIG, NINJA_ELITE_CONFIG]:
		await _verify_migrated_config(config)
	_verify_inheritance_fail_closed()

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"migrated_config_count": 2,
		"shared_contact_promoted": true,
		"dynamic_blade_union": true,
		"failures": failures.duplicate(),
	}
	print("COMBAT_ROBOT_NINJA_LAYERED_CONTRACT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("COMBAT_ROBOT_NINJA_LAYERED_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_migrated_config(config: EnemyConfig) -> void:
	var enemy := config.enemy_scene.instantiate() as CombatRobotNinja
	_expect(
		enemy != null,
		"%s must instantiate CombatRobotNinja." % config.resource_path
	)
	if enemy == null:
		return
	var implementation := enemy.get_script() as Script
	_expect(
		implementation != null
		and implementation.get_base_script() == SIMPLE_CHASE_SCRIPT,
		"%s must directly reuse SimpleChaseLayeredEnemy." % config.resource_path
	)
	_expect(
		enemy.supports_centralized_authoritative_simulation()
		and enemy.supports_layered_area_authoritative_simulation()
		and enemy.supports_layered_contact_authoritative_simulation()
		and enemy.supports_dynamic_enemy_targeting()
		and not enemy.supports_indexed_touch_authority()
		and enemy.uses_layered_area_physics_phase_decisions()
		and enemy.uses_trusted_layered_phase_entrypoints()
		and enemy.get_layered_area_decision_interval_frames() > 1,
		"%s must publish AREA/contact/dynamic capability while indexed Player/Plant authority stays closed."
		% config.resource_path
	)
	for method_name in REQUIRED_PHASE_METHODS:
		_expect(
			enemy.has_method(method_name),
			"%s must expose %s." % [config.resource_path, method_name]
		)
	root.add_child(enemy)
	enemy.setup(config, null, null)
	var initial_revision := enemy.get_contact_shape_revision()
	_expect(
		_authored_enabled_blade_names(enemy)
		== PackedStringArray([
			"MoveFrontBladeCollisionShape2D",
			"MoveRearBladeCollisionShape2D",
		]),
		"%s must author exactly the moving blade pair before boost."
		% config.resource_path
	)
	var started := bool(enemy.call(&"_try_start_damage_boost"))
	_expect(
		started
		and enemy.get_contact_shape_revision() > initial_revision
		and _authored_enabled_blade_names(enemy)
		== PackedStringArray([
			"BoostLowerBladeCollisionShape2D",
			"BoostUpperBladeCollisionShape2D",
		]),
		"%s boost must atomically publish the alternate compound blade union."
		% config.resource_path
	)
	var boost_revision := enemy.get_contact_shape_revision()
	enemy.call(&"_cancel_damage_boost", true, false)
	_expect(
		enemy.get_contact_shape_revision() > boost_revision
		and _authored_enabled_blade_names(enemy)
		== PackedStringArray([
			"MoveFrontBladeCollisionShape2D",
			"MoveRearBladeCollisionShape2D",
		]),
		"%s interruption must restore the authored moving blade union."
		% config.resource_path
	)
	enemy.queue_free()
	await process_frame


func _verify_inheritance_fail_closed() -> void:
	var derived := UNMIGRATED_DERIVED_SCRIPT.new() as CombatRobotNinja
	_expect(derived != null, "The Ninja derived fail-close fixture must instantiate.")
	if derived == null:
		return
	_expect(
		derived.supports_centralized_authoritative_simulation()
		and not derived.supports_layered_area_authoritative_simulation()
		and not derived.supports_layered_contact_authoritative_simulation()
		and not derived.supports_indexed_touch_authority(),
		"A derived Ninja script must remain COMPAT-only until independently migrated."
	)
	derived.free()


func _authored_enabled_blade_names(
	enemy: CombatRobotNinja
) -> PackedStringArray:
	var names := PackedStringArray()
	for shape in enemy.call(&"_get_blade_contact_shapes"):
		var shape_node := shape as CollisionShape2D
		if (
			shape_node != null
			and enemy.is_touch_damage_shape_authored_enabled(shape_node)
		):
			names.append(String(shape_node.name))
	names.sort()
	return names


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
