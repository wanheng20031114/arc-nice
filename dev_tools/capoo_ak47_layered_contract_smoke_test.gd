extends SceneTree

## Structural closure for the normal and stone-eroded AK family. Existing
## projectile/backend/network tests remain the behavioral closure; this test
## proves that only the exact shared runner receives layered/contact authority.

const LAYERED_RANGED_SCRIPT := preload(
	"res://scene/enemy/layered_ranged_enemy.gd"
)
const CAPOO_RANGED_SCRIPT := preload(
	"res://scene/enemy/capoo_ranged_enemy.gd"
)
const SIMPLE_CHASE_SCRIPT := preload(
	"res://scene/enemy/simple_chase_layered_enemy.gd"
)
const AK_CONFIG := preload(
	"res://resources/config/enemies/capoo_ak47.tres"
)
const STONE_AK_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_ak47.tres"
)
const UNMIGRATED_DERIVED_SCRIPT := preload(
	"res://dev_tools/fixtures/capoo_ak47_unmigrated_derived_fixture.gd"
)

const EXISTING_CLOSURE_PATHS: PackedStringArray = [
	"res://dev_tools/capoo_ak47_smoke_test.gd",
	"res://dev_tools/capoo_ak47_data_backend_smoke_test.gd",
	"res://dev_tools/rapid_fire_simulation_service_kernel_smoke_test.gd",
	"res://dev_tools/rapid_fire_authoritative_collision_smoke_test.gd",
	"res://dev_tools/enemy_rapid_fire_network_codec_smoke_test.gd",
	"res://dev_tools/authoritative_pooled_projectile_lifecycle_smoke_test.gd",
	"res://dev_tools/enemy_attack_faction_migration_smoke_test.gd",
	"res://dev_tools/mp_enemy_coordinator_smoke_test.gd",
	"res://dev_tools/capoo_variant_smoke_test.gd",
]
const REQUIRED_FAMILY_METHODS: Array[StringName] = [
	&"_run_authoritative_physics_step",
	&"_advance_layered_ranged_event_phase",
	&"_try_consume_layered_ranged_decision_phase",
	&"_layered_ranged_attack_state_allows_motion",
	&"_try_consume_ak47_chase_decision",
	&"_try_start_windup",
	&"_update_windup",
	&"_start_burst",
	&"_update_burst",
	&"_fire_locked_bullet",
	&"_fire_data_projectile",
	&"play_multiplayer_enemy_action_with_context",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	for config in [AK_CONFIG, STONE_AK_CONFIG]:
		_verify_migrated_config(config)
	_verify_inheritance_fail_closed()
	_verify_existing_backend_and_network_closure()

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"migrated_config_count": 2,
		"existing_closure": EXISTING_CLOSURE_PATHS,
		"failures": failures.duplicate(),
	}
	print("CAPOO_AK47_LAYERED_CONTRACT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_AK47_LAYERED_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_migrated_config(config: CapooAK47Config) -> void:
	var ak := config.enemy_scene.instantiate() as CapooAK47
	_expect(
		ak != null,
		"%s must instantiate the shared CapooAK47 runner."
		% config.resource_path
	)
	if ak == null:
		return
	var implementation := ak.get_script() as Script
	_expect(
		implementation != null
		and implementation.get_base_script() == LAYERED_RANGED_SCRIPT
		and _inherits_script(implementation, CAPOO_RANGED_SCRIPT)
		and _inherits_script(implementation, SIMPLE_CHASE_SCRIPT),
		"%s must preserve SimpleChase -> CapooRanged -> LayeredRanged -> AK inheritance."
		% config.resource_path
	)
	_expect(
		ak.supports_centralized_authoritative_simulation()
		and ak.supports_layered_area_authoritative_simulation()
		and ak.supports_layered_contact_authoritative_simulation()
		and ak.supports_dynamic_enemy_targeting()
		and ak.supports_indexed_touch_authority()
		and ak.uses_layered_area_physics_phase_decisions()
		and ak.uses_trusted_layered_phase_entrypoints()
		and not bool(ak.call(&"_uses_inherited_touch_damage")),
		"%s must explicitly publish centralized/AREA/contact/indexed AK capability without inherited touch damage."
		% config.resource_path
	)
	_expect(
		ak.get_layered_area_decision_interval_frames() == 1
		and bool(ak.call(&"_layered_area_touch_damage_precedes_family_event")),
		"%s must retain exact chase decisions and authored touch-before-attack ordering."
		% config.resource_path
	)
	for method_name in REQUIRED_FAMILY_METHODS:
		_expect(
			_script_declares_method(implementation, method_name),
			"%s must declare %s in the AK family script."
			% [config.resource_path, method_name]
		)
	_verify_single_rectangle_geometry(ak, config.resource_path)
	ak.free()


func _verify_single_rectangle_geometry(ak: CapooAK47, label: String) -> void:
	var body_shape := ak.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var touch_area := ak.get_node_or_null("TouchDamageArea") as Area2D
	var touch_shapes: Array[CollisionShape2D] = []
	if touch_area != null:
		for child in touch_area.get_children():
			var shape := child as CollisionShape2D
			if shape != null and not shape.disabled and shape.shape != null:
				touch_shapes.append(shape)
	var touch_shape := touch_shapes[0] if touch_shapes.size() == 1 else null
	_expect(
		body_shape != null
		and not body_shape.disabled
		and body_shape.shape is RectangleShape2D
		and touch_area != null
		and touch_shapes.size() == 1
		and touch_shape != null
		and touch_shape.shape is RectangleShape2D,
		"%s indexed/contact admission requires one authored body rectangle and one touch rectangle."
		% label
	)
	if body_shape == null or touch_shape == null:
		return
	var body_rectangle := body_shape.shape as RectangleShape2D
	var touch_rectangle := touch_shape.shape as RectangleShape2D
	_expect(
		body_rectangle.size == touch_rectangle.size
		and body_shape.transform == touch_area.transform * touch_shape.transform,
		"%s body/touch rectangles must share one root-relative envelope."
		% label
	)
	var authored_areas: Array[Node] = ak.find_children(
		"*",
		"Area2D",
		true,
		false
	)
	_expect(
		authored_areas.size() == 1 and authored_areas[0] == touch_area,
		"%s must not hide a second weapon Area behind indexed authority."
		% label
	)


func _verify_inheritance_fail_closed() -> void:
	var derived := UNMIGRATED_DERIVED_SCRIPT.new() as CapooAK47
	_expect(derived != null, "The authored AK derived fail-close probe must instantiate.")
	if derived == null:
		return
	_expect(
		derived.supports_centralized_authoritative_simulation()
		and not derived.supports_layered_area_authoritative_simulation()
		and not derived.supports_layered_contact_authoritative_simulation()
		and not derived.supports_indexed_touch_authority(),
		"A script-derived AK family must remain COMPAT-only until independently migrated."
	)
	derived.free()


func _verify_existing_backend_and_network_closure() -> void:
	for test_path in EXISTING_CLOSURE_PATHS:
		_expect(
			FileAccess.file_exists(test_path),
			"The migrated AK closure must retain %s." % test_path
		)
	_expect(
		CapooAK47.attack_phase_stagger_enabled,
		"AK migration must retain production attack phase staggering."
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
