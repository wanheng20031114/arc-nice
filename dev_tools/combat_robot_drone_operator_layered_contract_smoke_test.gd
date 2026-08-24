extends SceneTree

const SIMPLE_CHASE_SCRIPT := preload(
	"res://scene/enemy/simple_chase_layered_enemy.gd"
)
const OPERATOR_SCRIPT_PATH := (
	"res://scene/enemy/mechanical_life/combat_robot_drone_operator.gd"
)
const NORMAL_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator.tres"
)
const ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator_elite.tres"
)
const UNMIGRATED_DERIVED_SCRIPT := preload(
	"res://dev_tools/fixtures/combat_robot_drone_operator_unmigrated_derived_fixture.gd"
)

const REQUIRED_PHASE_METHODS: Array[StringName] = [
	&"simulate_trusted_layered_area_event_phase",
	&"simulate_trusted_layered_area_decision_phase",
	&"simulate_trusted_layered_area_motion_phase",
	&"prepare_layered_area_authoritative_simulation",
	&"get_layered_area_planned_displacement",
	&"get_layered_area_contact_target",
]
const REQUIRED_OPERATOR_METHODS: Array[StringName] = [
	&"_advance_layered_area_family_event_phase",
	&"_simulate_layered_area_decision_body",
	&"_simulate_layered_area_motion_body",
	&"_spawn_committed_drone",
	&"play_multiplayer_enemy_action",
	&"play_multiplayer_enemy_action_with_context",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	for config in [NORMAL_CONFIG, ELITE_CONFIG]:
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
		"COMBAT_ROBOT_DRONE_OPERATOR_LAYERED_CONTRACT_JSON %s"
		% JSON.stringify(result)
	)
	if failures.is_empty():
		print("COMBAT_ROBOT_DRONE_OPERATOR_LAYERED_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_migrated_config(config: EnemyConfig) -> void:
	var operator := config.enemy_scene.instantiate() as CombatRobotDroneOperator
	_expect(
		operator != null,
		"%s must instantiate CombatRobotDroneOperator." % config.resource_path
	)
	if operator == null:
		return
	var implementation := operator.get_script() as Script
	_expect(
		implementation != null
		and implementation.resource_path == OPERATOR_SCRIPT_PATH
		and implementation.get_base_script() == SIMPLE_CHASE_SCRIPT,
		"%s must share the exact SimpleChase production script."
		% config.resource_path
	)
	_expect(
		operator.supports_centralized_authoritative_simulation()
		and operator.supports_layered_area_authoritative_simulation()
		and operator.supports_layered_contact_authoritative_simulation()
		and operator.supports_dynamic_enemy_targeting()
		and operator.uses_layered_area_physics_phase_decisions()
		and operator.uses_trusted_layered_phase_entrypoints(),
		"%s must publish the trusted AREA/CONTACT/dynamic phase contract."
		% config.resource_path
	)
	_expect(
		not operator.supports_indexed_touch_authority()
		and bool(operator.call(&"_uses_inherited_touch_damage"))
		and operator.get_layered_area_decision_interval_frames() == 1,
		"%s must retain authored touch Areas and 60 Hz tracking."
		% config.resource_path
	)
	for method_name in REQUIRED_PHASE_METHODS:
		_expect(
			operator.has_method(method_name),
			"%s must expose phase method %s."
			% [config.resource_path, method_name]
		)
	for method_name in REQUIRED_OPERATOR_METHODS:
		_expect(
			operator.has_method(method_name),
			"%s must retain operator method %s."
			% [config.resource_path, method_name]
		)
	_verify_authored_shape_and_timer_contract(operator, config.resource_path)
	var operator_config := config as CombatRobotDroneOperatorConfig
	_expect(
		operator_config != null
		and operator_config.drone_scene != null
		and not operator_config.projectile_type.is_empty()
		and operator_config.deploy_delay > 0.0
		and operator_config.attack_cooldown > 0.0
		and operator_config.blocked_retry_interval > 0.0
		and operator_config.drone_speed > 0.0,
		"%s must retain its authored drone/timer profile."
		% config.resource_path
	)
	operator.free()


func _verify_authored_shape_and_timer_contract(
	operator: CombatRobotDroneOperator,
	config_path: String
) -> void:
	var touch_area := operator.get_node_or_null("TouchDamageArea") as Area2D
	var touch_shape := operator.get_node_or_null(
		"TouchDamageArea/CollisionShape2D"
	) as CollisionShape2D
	var sense_area := operator.get_node_or_null("AttackSenseArea") as Area2D
	var sense_shape := operator.get_node_or_null(
		"AttackSenseArea/CollisionShape2D"
	) as CollisionShape2D
	var touch_rectangle: RectangleShape2D = (
		touch_shape.shape as RectangleShape2D
		if touch_shape != null
		else null
	)
	var sense_circle: CircleShape2D = (
		sense_shape.shape as CircleShape2D
		if sense_shape != null
		else null
	)
	_expect(
		touch_area != null
		and touch_rectangle != null
		and touch_rectangle.size == Vector2(8.0, 17.0),
		"%s must retain its independent authored 8x17 touch rectangle."
		% config_path
	)
	_expect(
		sense_area != null
		and sense_area.collision_mask == 518
		and sense_circle != null
		and is_equal_approx(sense_circle.radius, 80.0),
		"%s must retain the Player/Plant/Enemy AttackSenseArea."
		% config_path
	)
	for timer_name in [&"DeployTimer", &"CooldownTimer", &"BlockedRetryTimer"]:
		var timer := operator.get_node_or_null(String(timer_name)) as Timer
		_expect(
			timer != null
			and timer.one_shot
			and timer.process_callback == Timer.TIMER_PROCESS_PHYSICS,
			"%s must retain authored physics Timer %s."
			% [config_path, timer_name]
		)


func _verify_inheritance_fail_closed() -> void:
	var derived := UNMIGRATED_DERIVED_SCRIPT.new() as CombatRobotDroneOperator
	_expect(
		derived != null,
		"The DroneOperator derived fail-close fixture must instantiate."
	)
	if derived == null:
		return
	_expect(
		derived.supports_centralized_authoritative_simulation()
		and not derived.supports_layered_area_authoritative_simulation()
		and not derived.supports_layered_contact_authoritative_simulation()
		and not derived.supports_indexed_touch_authority(),
		"A derived DroneOperator must remain COMPAT-only until independently migrated."
	)
	derived.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
