extends SceneTree

const SIMPLE_CHASE_SCRIPT := preload(
	"res://scene/enemy/simple_chase_layered_enemy.gd"
)
const ROBOT_CONFIG := preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const ROBOT_ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_elite.tres"
)
const UNMIGRATED_DERIVED_SCRIPT := preload(
	"res://dev_tools/fixtures/combat_robot_unmigrated_derived_fixture.gd"
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
	for config in [ROBOT_CONFIG, ROBOT_ELITE_CONFIG]:
		_verify_migrated_config(config)
	_verify_inheritance_fail_closed()

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"migrated_config_count": 2,
		"shared_contact_promoted": true,
		"failures": failures.duplicate(),
	}
	print("COMBAT_ROBOT_LAYERED_CONTRACT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("COMBAT_ROBOT_LAYERED_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_migrated_config(config: EnemyConfig) -> void:
	var enemy := config.enemy_scene.instantiate() as CombatRobot
	_expect(
		enemy != null,
		"%s must instantiate CombatRobot." % config.resource_path
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
		and enemy.supports_dynamic_enemy_targeting()
		and enemy.uses_layered_area_physics_phase_decisions()
		and enemy.uses_trusted_layered_phase_entrypoints(),
		"%s must explicitly publish centralized AREA/dynamic phase capability."
		% config.resource_path
	)
	_expect(
		enemy.supports_layered_contact_authoritative_simulation()
		and not enemy.supports_indexed_touch_authority(),
		"%s must expose compound enemy contact while retaining indexed Player/Plant fail-close."
		% config.resource_path
	)
	for method_name in REQUIRED_PHASE_METHODS:
		_expect(
			enemy.has_method(method_name),
			"%s must expose %s." % [config.resource_path, method_name]
		)
	var touch_area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	var enabled_touch_shape_count := 0
	if touch_area != null:
		for child in touch_area.get_children():
			var shape := child as CollisionShape2D
			if shape != null and not shape.disabled and shape.shape != null:
				enabled_touch_shape_count += 1
	_expect(
		touch_area != null and enabled_touch_shape_count == 2,
		"%s must retain both authored touch rectangles." % config.resource_path
	)
	enemy.free()


func _verify_inheritance_fail_closed() -> void:
	var derived := UNMIGRATED_DERIVED_SCRIPT.new() as CombatRobot
	_expect(derived != null, "The derived fail-close fixture must instantiate.")
	if derived == null:
		return
	_expect(
		derived.supports_centralized_authoritative_simulation()
		and not derived.supports_layered_area_authoritative_simulation()
		and not derived.supports_layered_contact_authoritative_simulation()
		and not derived.supports_indexed_touch_authority(),
		"A derived CombatRobot script must remain COMPAT-only until independently migrated."
	)
	derived.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
