extends SceneTree

const LAYERED_RANGED_SCRIPT := preload(
	"res://scene/enemy/layered_ranged_enemy.gd"
)
const GUNNER_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner.tres"
)
const GUNNER_ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner_elite.tres"
)
const UNMIGRATED_DERIVED_SCRIPT := preload(
	"res://dev_tools/fixtures/combat_robot_gunner_unmigrated_derived_fixture.gd"
)

const REQUIRED_PHASE_METHODS: Array[StringName] = [
	&"simulate_trusted_layered_area_event_phase",
	&"simulate_trusted_layered_area_decision_phase",
	&"simulate_trusted_layered_area_motion_phase",
	&"prepare_layered_area_authoritative_simulation",
	&"get_layered_area_planned_displacement",
	&"get_layered_area_contact_target",
]
const REQUIRED_NETWORK_METHODS: Array[StringName] = [
	&"play_multiplayer_enemy_action",
	&"play_multiplayer_enemy_action_with_context",
	&"resolve_multiplayer_rapid_fire_spawn_position",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	for config in [GUNNER_CONFIG, GUNNER_ELITE_CONFIG]:
		_verify_migrated_config(config)
	_verify_inheritance_fail_closed()

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"migrated_config_count": 2,
		"shared_contact_promoted": true,
		"indexed_touch_promoted": false,
		"failures": failures.duplicate(),
	}
	print(
		"COMBAT_ROBOT_GUNNER_LAYERED_CONTRACT_JSON %s"
		% JSON.stringify(result)
	)
	if failures.is_empty():
		print("COMBAT_ROBOT_GUNNER_LAYERED_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_migrated_config(config: EnemyConfig) -> void:
	var enemy := config.enemy_scene.instantiate() as CombatRobotGunner
	_expect(
		enemy != null,
		"%s must instantiate CombatRobotGunner." % config.resource_path
	)
	if enemy == null:
		return
	var implementation := enemy.get_script() as Script
	_expect(
		implementation != null
		and implementation.get_base_script() == LAYERED_RANGED_SCRIPT,
		"%s must directly reuse LayeredRangedEnemy." % config.resource_path
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
		"%s must publish shared Enemy contact while indexed Player/Plant stays closed."
		% config.resource_path
	)
	_expect(
		bool(enemy.call(&"_uses_inherited_touch_damage"))
		and enemy.get_layered_area_decision_interval_frames() == 1,
		"%s must retain physical touch damage and authored 60 Hz tracking."
		% config.resource_path
	)
	for method_name in REQUIRED_PHASE_METHODS:
		_expect(
			enemy.has_method(method_name),
			"%s must expose %s." % [config.resource_path, method_name]
		)
	for method_name in REQUIRED_NETWORK_METHODS:
		_expect(
			enemy.has_method(method_name),
			"%s must retain multiplayer method %s."
			% [config.resource_path, method_name]
		)
	_verify_authored_touch_shape(enemy, config.resource_path)
	var gunner_config := config as CombatRobotGunnerConfig
	_expect(
		gunner_config != null
		and not gunner_config.projectile_type.is_empty()
		and gunner_config.projectile_speed > 0.0
		and gunner_config.projectile_lifetime > 0.0
		and gunner_config.burst_count > 0
		and gunner_config.burst_fire_interval > 0.0,
		"%s must retain its authored data-projectile/burst profile."
		% config.resource_path
	)
	enemy.free()


func _verify_authored_touch_shape(enemy: Enemy, config_path: String) -> void:
	var touch_area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	var enabled_shapes: Array[CollisionShape2D] = []
	if touch_area != null:
		for child in touch_area.get_children():
			var shape := child as CollisionShape2D
			if shape != null and shape.shape != null and not shape.disabled:
				enabled_shapes.append(shape)
	_expect(
		touch_area != null and enabled_shapes.size() == 1,
		"%s must retain exactly one authored physical touch shape." % config_path
	)
	if enabled_shapes.size() != 1:
		return
	var rectangle := enabled_shapes[0].shape as RectangleShape2D
	_expect(
		rectangle != null and rectangle.size == Vector2(8.0, 17.0),
		"%s touch authority must retain the authored 8x17 rectangle."
		% config_path
	)


func _verify_inheritance_fail_closed() -> void:
	var derived := UNMIGRATED_DERIVED_SCRIPT.new() as CombatRobotGunner
	_expect(derived != null, "The Gunner derived fail-close fixture must instantiate.")
	if derived == null:
		return
	_expect(
		derived.supports_centralized_authoritative_simulation()
		and not derived.supports_layered_area_authoritative_simulation()
		and not derived.supports_layered_contact_authoritative_simulation()
		and not derived.supports_indexed_touch_authority(),
		"A derived Gunner script must remain COMPAT-only until independently migrated."
	)
	derived.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
