extends SceneTree

## Structural closure for the exact CapooSniper family. Behavioral parity is
## owned by capoo_sniper_layered_semantics_regression.gd; established target,
## presentation and damage backends remain covered by the retained old smokes.

const LAYERED_RANGED_SCRIPT := preload(
	"res://scene/enemy/layered_ranged_enemy.gd"
)
const CAPOO_RANGED_SCRIPT := preload(
	"res://scene/enemy/capoo_ranged_enemy.gd"
)
const SIMPLE_CHASE_SCRIPT := preload(
	"res://scene/enemy/simple_chase_layered_enemy.gd"
)
const SNIPER_CONFIG := preload(
	"res://resources/config/enemies/capoo_sniper.tres"
)
const STONE_SNIPER_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_sniper.tres"
)
const UNMIGRATED_DERIVED_SCRIPT := preload(
	"res://dev_tools/fixtures/capoo_sniper_unmigrated_derived_fixture.gd"
)

const EXISTING_CLOSURE_PATHS: PackedStringArray = [
	"res://dev_tools/capoo_variant_smoke_test.gd",
	"res://dev_tools/enemy_attack_state_consistency_smoke_test.gd",
	"res://dev_tools/enemy_attack_faction_migration_smoke_test.gd",
	"res://dev_tools/enemy_plant_combat_smoke_test.gd",
	"res://dev_tools/simple_fence_contact_combat_matrix_smoke_test.gd",
	"res://dev_tools/enemy_scene_contract_smoke_test.gd",
	"res://dev_tools/mp_enemy_coordinator_smoke_test.gd",
	"res://dev_tools/multiplayer_load_smoke_test.gd",
	"res://dev_tools/capoo_sniper_lock_visual_performance_ab.gd",
	"res://dev_tools/stone_eroded_enemy_smoke_test.gd",
]
const REQUIRED_FAMILY_METHODS: Array[StringName] = [
	&"_run_authoritative_physics_step",
	&"_advance_layered_ranged_event_phase",
	&"_try_consume_layered_ranged_decision_phase",
	&"_layered_ranged_attack_state_allows_motion",
	&"_try_consume_sniper_chase_decision",
	&"_advance_lock_state",
	&"_resolve_expired_lock",
	&"_is_frozen_lock_target_valid",
	&"_has_frozen_lock_combat_line",
	&"_fire_locked_shot",
	&"_make_lock_damage_request",
	&"play_multiplayer_enemy_target_action",
	&"apply_multiplayer_target_presentation_state",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_two_config_resource_closure()
	for config in [SNIPER_CONFIG, STONE_SNIPER_CONFIG]:
		_verify_migrated_config(config)
	_verify_inheritance_fail_closed()
	_verify_existing_backend_and_network_closure()

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"migrated_config_count": 2,
		"existing_closure": EXISTING_CLOSURE_PATHS,
		"failures": failures.duplicate(),
	}
	print("CAPOO_SNIPER_LAYERED_CONTRACT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_SNIPER_LAYERED_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_resource_closure() -> void:
	_expect(
		SNIPER_CONFIG.attack_damage == 200
		and STONE_SNIPER_CONFIG.attack_damage == 200
		and is_equal_approx(SNIPER_CONFIG.move_speed, 80.0)
		and is_equal_approx(STONE_SNIPER_CONFIG.move_speed, 80.0)
		and is_equal_approx(SNIPER_CONFIG.attack_range, 720.0)
		and is_equal_approx(STONE_SNIPER_CONFIG.attack_range, 720.0)
		and is_equal_approx(SNIPER_CONFIG.lock_duration, 3.0)
		and is_equal_approx(STONE_SNIPER_CONFIG.lock_duration, 3.0)
		and is_equal_approx(SNIPER_CONFIG.attack_interval, 4.5)
		and is_equal_approx(STONE_SNIPER_CONFIG.attack_interval, 4.5)
		and SNIPER_CONFIG.home_damage == 2
		and STONE_SNIPER_CONFIG.home_damage == 2
		and SNIPER_CONFIG.xirang_kill_reward == 35
		and STONE_SNIPER_CONFIG.xirang_kill_reward == 35,
		"Normal and stone-eroded Sniper configs must retain one shared weapon contract."
	)
	_expect(
		SNIPER_CONFIG.max_health == 100
		and SNIPER_CONFIG.physical_defense == 20
		and STONE_SNIPER_CONFIG.max_health == 200
		and STONE_SNIPER_CONFIG.physical_defense == 150
		and STONE_SNIPER_CONFIG.category_tags.has("stone_eroded"),
		"Stone-eroded Sniper must differ only through its authored durability/variant contract."
	)
	_expect(
		SNIPER_CONFIG.attack_audio_stream != null
		and STONE_SNIPER_CONFIG.attack_audio_stream != null
		and SNIPER_CONFIG.attack_audio_stream.resource_path
		== STONE_SNIPER_CONFIG.attack_audio_stream.resource_path,
		"Both Sniper variants must retain the shared fire-audio asset while warnings remain service-owned."
	)


func _verify_migrated_config(config: CapooSniperConfig) -> void:
	var sniper := config.enemy_scene.instantiate() as CapooSniper
	_expect(
		sniper != null,
		"%s must instantiate the shared CapooSniper runner."
		% config.resource_path
	)
	if sniper == null:
		return
	var implementation := sniper.get_script() as Script
	_expect(
		implementation != null
		and implementation.get_base_script() == LAYERED_RANGED_SCRIPT
		and _inherits_script(implementation, CAPOO_RANGED_SCRIPT)
		and _inherits_script(implementation, SIMPLE_CHASE_SCRIPT),
		"%s must preserve SimpleChase -> CapooRanged -> LayeredRanged -> Sniper inheritance."
		% config.resource_path
	)
	_expect(
		sniper.supports_centralized_authoritative_simulation()
		and sniper.supports_layered_area_authoritative_simulation()
		and sniper.supports_layered_contact_authoritative_simulation()
		and sniper.supports_dynamic_enemy_targeting()
		and sniper.supports_indexed_touch_authority()
		and sniper.uses_layered_area_physics_phase_decisions()
		and sniper.uses_trusted_layered_phase_entrypoints()
		and not bool(sniper.call(&"_uses_inherited_touch_damage")),
		"%s must explicitly publish centralized/AREA/contact/indexed ranged capability without inherited touch damage."
		% config.resource_path
	)
	_expect(
		sniper.get_layered_area_decision_interval_frames() == 1
		and bool(sniper.call(&"_layered_area_touch_damage_precedes_family_event")),
		"%s must retain exact 60 Hz decisions and touch-before-lock event order."
		% config.resource_path
	)
	for method_name in REQUIRED_FAMILY_METHODS:
		_expect(
			_script_declares_method(implementation, method_name),
			"%s must declare %s in the Sniper family script."
			% [config.resource_path, method_name]
		)
	_verify_single_capsule_geometry(sniper, config.resource_path)
	sniper.free()


func _verify_single_capsule_geometry(
	sniper: CapooSniper,
	label: String
) -> void:
	var body_shape := sniper.get_node_or_null(
		"CollisionShape2D"
	) as CollisionShape2D
	var touch_area := sniper.get_node_or_null("TouchDamageArea") as Area2D
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
		and body_shape.shape is CapsuleShape2D
		and touch_area != null
		and touch_shapes.size() == 1
		and touch_shape != null
		and touch_shape.shape is CapsuleShape2D,
		"%s indexed/contact admission requires one body and one touch capsule."
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
		"%s body/touch capsules must share one root-relative envelope."
		% label
	)
	var authored_areas: Array[Node] = sniper.find_children(
		"*",
		"Area2D",
		true,
		false
	)
	_expect(
		authored_areas.size() == 1 and authored_areas[0] == touch_area,
		"%s must not hide a second attack Area behind indexed admission."
		% label
	)


func _verify_inheritance_fail_closed() -> void:
	var derived := UNMIGRATED_DERIVED_SCRIPT.new() as CapooSniper
	_expect(
		derived != null,
		"The authored Sniper derived fail-close probe must instantiate."
	)
	if derived == null:
		return
	_expect(
		derived.supports_centralized_authoritative_simulation()
		and not derived.supports_layered_area_authoritative_simulation()
		and not derived.supports_layered_contact_authoritative_simulation()
		and not derived.supports_indexed_touch_authority(),
		"A script-derived Sniper must remain COMPAT-only until independently migrated."
	)
	derived.free()


func _verify_existing_backend_and_network_closure() -> void:
	for test_path in EXISTING_CLOSURE_PATHS:
		_expect(
			FileAccess.file_exists(test_path),
			"The migrated Sniper closure must retain %s." % test_path
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
