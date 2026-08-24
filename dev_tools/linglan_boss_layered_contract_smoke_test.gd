extends SceneTree

## Structural closure for Linglan's exact production script. Behavioral parity
## is owned by linglan_boss_layered_semantics_regression.gd; the existing skill,
## runtime-port, multiplayer and damage tests retain their established backends.

const LINGLAN_SCRIPT_PATH := "res://scene/boss/linglan/linglan_boss.gd"
const LINGLAN_CONFIG := preload(
	"res://resources/config/enemies/linglan_boss.tres"
)
const UNMIGRATED_DERIVED_SCRIPT := preload(
	"res://dev_tools/fixtures/linglan_boss_unmigrated_derived_fixture.gd"
)

const REQUIRED_PHASE_METHODS: Array[StringName] = [
	&"_run_authoritative_physics_step",
	&"_advance_layered_event_body",
	&"_advance_layered_motion_body",
	&"simulate_trusted_layered_area_event_phase",
	&"simulate_trusted_layered_area_decision_phase",
	&"simulate_trusted_layered_area_motion_phase",
	&"should_execute_layered_area_motion_phase",
]
const EXISTING_CLOSURE_PATHS: PackedStringArray = [
	"res://dev_tools/linglan_boss_smoke_test.gd",
	"res://dev_tools/linglan_goal_smoke_test.gd",
	"res://dev_tools/linglan_skill1_smoke_test.gd",
	"res://dev_tools/linglan_skill1_network_batch_smoke_test.gd",
	"res://dev_tools/linglan_skill2_smoke_test.gd",
	"res://dev_tools/linglan_skill3_smoke_test.gd",
	"res://dev_tools/linglan_skill4_smoke_test.gd",
	"res://dev_tools/enemy_boss_dynamic_target_smoke_test.gd",
	"res://dev_tools/multiplayer_load_smoke_test.gd",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_exact_production_contract()
	_verify_inheritance_fail_closed()
	_verify_existing_closure()

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"migrated_config_count": 1,
		"shared_contact_promoted": false,
		"authored_area_retained": true,
		"failures": failures.duplicate(),
	}
	print("LINGLAN_BOSS_LAYERED_CONTRACT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("LINGLAN_BOSS_LAYERED_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_exact_production_contract() -> void:
	var boss := LINGLAN_CONFIG.enemy_scene.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan config must instantiate LinglanBoss.")
	if boss == null:
		return
	var implementation := boss.get_script() as Script
	_expect(
		implementation != null
		and implementation.resource_path == LINGLAN_SCRIPT_PATH,
		"Linglan config must use the exact migrated production script."
	)
	_expect(
		boss.supports_centralized_authoritative_simulation()
		and not boss.uses_anchored_compat_simulation()
		and boss.supports_layered_area_authoritative_simulation()
		and not boss.supports_layered_contact_authoritative_simulation()
		and not boss.supports_indexed_touch_authority()
		and boss.uses_trusted_layered_phase_entrypoints(),
		"Linglan must publish layered phases while keeping shared/indexed contact closed."
	)
	for method_name in REQUIRED_PHASE_METHODS:
		_expect(
			_script_declares_method(implementation, method_name),
			"Linglan production script must declare %s." % method_name
		)
	var body_shape := boss.get_node_or_null(
		"CollisionShape2D"
	) as CollisionShape2D
	var touch_area := boss.get_node_or_null("TouchDamageArea") as Area2D
	var touch_shape := boss.get_node_or_null(
		"TouchDamageArea/CollisionShape2D"
	) as CollisionShape2D
	_expect(
		body_shape != null
		and body_shape.shape is CapsuleShape2D
		and touch_area != null
		and touch_shape != null
		and touch_shape.shape is CapsuleShape2D,
		"Linglan must retain its authored body and TouchDamageArea capsules."
	)
	_expect(
		boss.get_node_or_null("EnemySimulationPhaseAnchor") == null,
		"Linglan must use ordinary coordinator ownership without a scene-local anchor."
	)
	boss.free()


func _verify_inheritance_fail_closed() -> void:
	var derived := UNMIGRATED_DERIVED_SCRIPT.new() as LinglanBoss
	_expect(
		derived != null,
		"The Linglan derived fail-close fixture must instantiate."
	)
	if derived == null:
		return
	_expect(
		derived.supports_centralized_authoritative_simulation()
		and not derived.supports_layered_area_authoritative_simulation()
		and not derived.supports_layered_contact_authoritative_simulation()
		and not derived.supports_indexed_touch_authority(),
		"A derived Linglan script must remain COMPAT-only until independently migrated."
	)
	derived.free()


func _verify_existing_closure() -> void:
	for test_path in EXISTING_CLOSURE_PATHS:
		_expect(
			FileAccess.file_exists(test_path),
			"Linglan migration must retain %s." % test_path
		)


func _script_declares_method(
	script: Script,
	method_name: StringName
) -> bool:
	if script == null:
		return false
	for method_info in script.get_script_method_list():
		if StringName(method_info.get("name", &"")) == method_name:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
