extends SceneTree

## Structural closure for the SMG layered migration. Behavioral backend and
## proxy checks remain owned by the established focused tests listed below;
## this contract makes that closure explicit without duplicating their worlds.

const LAYERED_RANGED_SCRIPT := preload(
	"res://scene/enemy/layered_ranged_enemy.gd"
)
const CAPOO_RANGED_SCRIPT := preload(
	"res://scene/enemy/capoo_ranged_enemy.gd"
)
const SIMPLE_CHASE_SCRIPT := preload(
	"res://scene/enemy/simple_chase_layered_enemy.gd"
)
const SMG_CONFIG := preload(
	"res://resources/config/enemies/capoo_smg.tres"
)
const STONE_SMG_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_smg.tres"
)
const UNMIGRATED_DERIVED_SCRIPT := preload(
	"res://dev_tools/fixtures/capoo_smg_unmigrated_derived_fixture.gd"
)

const EXISTING_CLOSURE_PATHS: PackedStringArray = [
	"res://dev_tools/capoo_variant_smoke_test.gd",
	"res://dev_tools/immediate_hitscan_resolver_smoke_test.gd",
	"res://dev_tools/authoritative_pooled_projectile_lifecycle_smoke_test.gd",
	"res://dev_tools/enemy_attack_state_consistency_smoke_test.gd",
	"res://dev_tools/enemy_attack_faction_migration_smoke_test.gd",
]
const REQUIRED_FAMILY_METHODS: Array[StringName] = [
	&"_run_authoritative_physics_step",
	&"_advance_layered_ranged_event_phase",
	&"_try_consume_layered_ranged_decision_phase",
	&"_simulate_layered_area_decision_body",
	&"_simulate_layered_area_motion_body",
	&"_try_fire_scatter",
	&"_fire_bullet",
	&"_fire_hitscan",
	&"play_multiplayer_enemy_action",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	for config in [SMG_CONFIG, STONE_SMG_CONFIG]:
		_verify_migrated_config(config)
	_verify_inheritance_fail_closed()
	_verify_existing_backend_and_network_closure()

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"migrated_config_count": 2,
		"existing_closure": EXISTING_CLOSURE_PATHS,
		"failures": failures.duplicate(),
	}
	print("CAPOO_SMG_LAYERED_CONTRACT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_SMG_LAYERED_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_migrated_config(config: CapooSMGConfig) -> void:
	var smg := config.enemy_scene.instantiate() as CapooSMG
	_expect(
		smg != null,
		"%s must instantiate the shared CapooSMG runner."
		% config.resource_path
	)
	if smg == null:
		return
	var implementation := smg.get_script() as Script
	_expect(
		implementation != null
		and implementation.get_base_script() == LAYERED_RANGED_SCRIPT
		and _inherits_script(implementation, CAPOO_RANGED_SCRIPT)
		and _inherits_script(implementation, SIMPLE_CHASE_SCRIPT),
		"%s must preserve SimpleChase -> CapooRanged -> LayeredRanged -> SMG inheritance."
		% config.resource_path
	)
	_expect(
		smg.supports_centralized_authoritative_simulation()
		and smg.supports_layered_area_authoritative_simulation()
		and smg.supports_layered_contact_authoritative_simulation()
		and smg.supports_dynamic_enemy_targeting()
		and smg.supports_indexed_touch_authority()
		and smg.uses_layered_area_physics_phase_decisions()
		and smg.uses_trusted_layered_phase_entrypoints()
		and not bool(smg.call(&"_uses_inherited_touch_damage")),
		"%s must explicitly publish centralized/AREA/contact/indexed ranged capability without inherited touch damage."
		% config.resource_path
	)
	_expect(
		smg.get_layered_area_decision_interval_frames() == 1
		and bool(smg.call(&"_layered_area_touch_damage_precedes_family_event")),
		"%s must retain exact 60 Hz short-range decisions and authored touch-before-timer ordering."
		% config.resource_path
	)
	for method_name in REQUIRED_FAMILY_METHODS:
		_expect(
			_script_declares_method(implementation, method_name),
			"%s must declare %s in the SMG family script."
			% [config.resource_path, method_name]
		)
	_verify_single_capsule_geometry(smg, config.resource_path)
	smg.free()


func _verify_single_capsule_geometry(smg: CapooSMG, label: String) -> void:
	var body_shape := smg.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var touch_area := smg.get_node_or_null("TouchDamageArea") as Area2D
	var touch_shapes: Array[CollisionShape2D] = []
	if touch_area != null:
		for child in touch_area.get_children():
			var shape := child as CollisionShape2D
			if shape != null and not shape.disabled and shape.shape != null:
				touch_shapes.append(shape)
	var touch_shape := (
		touch_shapes[0]
		if touch_shapes.size() == 1
		else null
	)
	_expect(
		body_shape != null
		and not body_shape.disabled
		and body_shape.shape is CapsuleShape2D
		and touch_area != null
		and touch_shapes.size() == 1
		and touch_shape != null
		and touch_shape.shape is CapsuleShape2D,
		"%s indexed/contact admission requires exactly one authored body capsule and one touch capsule."
		% label
	)
	if body_shape == null or touch_shape == null:
		return
	var body_capsule := body_shape.shape as CapsuleShape2D
	var touch_capsule := touch_shape.shape as CapsuleShape2D
	_expect(
		is_equal_approx(body_capsule.radius, touch_capsule.radius)
		and is_equal_approx(body_capsule.height, touch_capsule.height)
		and body_shape.transform == touch_area.transform * touch_shape.transform,
		"%s body/touch capsule geometry must share one root-relative envelope."
		% label
	)
	var authored_areas: Array[Node] = smg.find_children(
		"*",
		"Area2D",
		true,
		false
	)
	_expect(
		authored_areas.size() == 1 and authored_areas[0] == touch_area,
		"%s must not hide a second weapon Area behind indexed touch admission."
		% label
	)


func _verify_inheritance_fail_closed() -> void:
	var derived := UNMIGRATED_DERIVED_SCRIPT.new() as CapooSMG
	_expect(derived != null, "The authored SMG derived fail-close probe must instantiate.")
	if derived == null:
		return
	_expect(
		derived.supports_centralized_authoritative_simulation()
		and not derived.supports_layered_area_authoritative_simulation()
		and not derived.supports_layered_contact_authoritative_simulation()
		and not derived.supports_indexed_touch_authority(),
		"A script-derived SMG must remain COMPAT-only until independently migrated."
	)
	derived.free()


func _verify_existing_backend_and_network_closure() -> void:
	for test_path in EXISTING_CLOSURE_PATHS:
		_expect(
			FileAccess.file_exists(test_path),
			"The migrated SMG closure must retain %s." % test_path
		)
	_expect(
		CapooSMG.TARGET_REFRESH_HZ > 0.0,
		"SMG migration must retain the production short-range hitscan refresh cadence."
	)


func _inherits_script(instance_script: Script, expected_script: Script) -> bool:
	var current_script := instance_script
	while current_script != null:
		if current_script == expected_script:
			return true
		current_script = current_script.get_base_script()
	return false


func _script_declares_method(script: Script, method_name: StringName) -> bool:
	if script == null:
		return false
	for method_info in script.get_script_method_list():
		if StringName(method_info.get("name", &"")) == method_name:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
