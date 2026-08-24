extends SceneTree

## Fail-closed contract for the ranged layered template. Migrated families must
## inherit it directly and pass explicit capability gates; shared Enemy contact
## and indexed Player/Plant touch remain independent fail-closed admissions.

const SIMPLE_CHASE_SCRIPT := preload(
	"res://scene/enemy/simple_chase_layered_enemy.gd"
)
const CAPOO_RANGED_SCRIPT := preload(
	"res://scene/enemy/capoo_ranged_enemy.gd"
)
const LAYERED_RANGED_SCRIPT := preload(
	"res://scene/enemy/layered_ranged_enemy.gd"
)
const CONTRACT_FIXTURE := preload(
	"res://dev_tools/fixtures/layered_ranged_enemy_contract_fixture.tscn"
)

const MIGRATED_MAGE_SCENES := [
	preload("res://scene/enemy/capoo/capoo_mage.tscn"),
	preload("res://scene/enemy/stone_eroded/stone_eroded_capoo_mage.tscn"),
]
const MIGRATED_RPG_SCENES := [
	preload("res://scene/enemy/capoo/capoo_rpg.tscn"),
	preload("res://scene/enemy/stone_eroded/stone_eroded_capoo_rpg.tscn"),
]
const MIGRATED_FROST_SCENES := [
	preload("res://scene/enemy/sorcerer/frost_sorcerer.tscn"),
	preload("res://scene/enemy/sorcerer/frost_sorcerer_elite.tscn"),
]
const MIGRATED_FIRE_SCENES := [
	preload("res://scene/enemy/sorcerer/fire_sorcerer.tscn"),
	preload("res://scene/enemy/sorcerer/fire_sorcerer_elite.tscn"),
]
const MIGRATED_LIGHTNING_SCENES := [
	preload("res://scene/enemy/sorcerer/lightning_sorcerer.tscn"),
	preload("res://scene/enemy/sorcerer/lightning_sorcerer_elite.tscn"),
]
const MIGRATED_SMG_SCENES := [
	preload("res://scene/enemy/capoo/capoo_smg.tscn"),
	preload("res://scene/enemy/stone_eroded/stone_eroded_capoo_smg.tscn"),
]
const MIGRATED_SNIPER_SCENES := [
	preload("res://scene/enemy/capoo/capoo_sniper.tscn"),
	preload("res://scene/enemy/stone_eroded/stone_eroded_capoo_sniper.tscn"),
]
const TEST_DELTA := 1.0 / 60.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_migrated_mage_contracts()
	_verify_migrated_rpg_contracts()
	_verify_migrated_frost_contracts()
	_verify_migrated_fire_contracts()
	_verify_migrated_lightning_contracts()
	_verify_migrated_smg_contracts()
	_verify_migrated_sniper_contracts()
	_verify_template_opt_in_and_hooks()

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"migrated_mage_count": MIGRATED_MAGE_SCENES.size(),
		"migrated_rpg_count": MIGRATED_RPG_SCENES.size(),
		"migrated_frost_count": MIGRATED_FROST_SCENES.size(),
		"migrated_fire_count": MIGRATED_FIRE_SCENES.size(),
		"migrated_lightning_count": MIGRATED_LIGHTNING_SCENES.size(),
		"migrated_smg_count": MIGRATED_SMG_SCENES.size(),
		"migrated_sniper_count": MIGRATED_SNIPER_SCENES.size(),
		"unmigrated_family_count": 0,
		"failures": failures.duplicate(),
	}
	print("LAYERED_RANGED_ENEMY_CONTRACT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("LAYERED_RANGED_ENEMY_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_migrated_mage_contracts() -> void:
	for scene_variant in MIGRATED_MAGE_SCENES:
		var scene := scene_variant as PackedScene
		var mage := scene.instantiate() as CapooMage
		_expect(mage != null, "Migrated Mage scene must instantiate CapooMage.")
		if mage == null:
			continue
		var family_script := mage.get_script() as Script
		_expect(
			family_script.get_base_script() == LAYERED_RANGED_SCRIPT
			and _inherits_script(family_script, CAPOO_RANGED_SCRIPT)
			and _inherits_script(family_script, SIMPLE_CHASE_SCRIPT),
			"Migrated Mage must preserve the SimpleChase -> Capoo -> Layered chain."
		)
		_expect(
			mage.supports_centralized_authoritative_simulation()
			and mage.supports_layered_area_authoritative_simulation()
			and mage.supports_layered_contact_authoritative_simulation()
			and mage.supports_dynamic_enemy_targeting()
			and mage.supports_indexed_touch_authority()
			and not bool(mage.call(&"_uses_inherited_touch_damage")),
			"Migrated Mage must pass every explicit ranged capability gate."
		)
		_expect(
			_script_declares_method(
				family_script,
				&"_run_authoritative_physics_step"
			),
			"Migrated Mage must retain its authored LEGACY/COMPAT runner."
		)
		mage.free()


func _verify_migrated_rpg_contracts() -> void:
	for scene_variant in MIGRATED_RPG_SCENES:
		var scene := scene_variant as PackedScene
		var rpg := scene.instantiate() as CapooRPG
		_expect(rpg != null, "Migrated RPG scene must instantiate CapooRPG.")
		if rpg == null:
			continue
		var family_script := rpg.get_script() as Script
		_expect(
			family_script.get_base_script() == LAYERED_RANGED_SCRIPT
			and _inherits_script(family_script, CAPOO_RANGED_SCRIPT)
			and _inherits_script(family_script, SIMPLE_CHASE_SCRIPT),
			"Migrated RPG must preserve the SimpleChase -> Capoo -> Layered chain."
		)
		_expect(
			rpg.supports_centralized_authoritative_simulation()
			and rpg.supports_layered_area_authoritative_simulation()
			and rpg.supports_layered_contact_authoritative_simulation()
			and rpg.supports_dynamic_enemy_targeting()
			and rpg.supports_indexed_touch_authority()
			and not bool(rpg.call(&"_uses_inherited_touch_damage")),
			"Migrated RPG must pass each explicit ranged capability gate."
		)
		_expect(
			_script_declares_method(
				family_script,
				&"_run_authoritative_physics_step"
			),
			"Migrated RPG must retain its authored LEGACY/COMPAT runner."
		)
		rpg.free()


func _verify_migrated_frost_contracts() -> void:
	for scene_variant in MIGRATED_FROST_SCENES:
		var scene := scene_variant as PackedScene
		var frost := scene.instantiate() as FrostSorcerer
		_expect(
			frost != null,
			"Migrated Frost scene must instantiate FrostSorcerer."
		)
		if frost == null:
			continue
		var family_script := frost.get_script() as Script
		_expect(
			family_script.get_base_script() == LAYERED_RANGED_SCRIPT
			and _inherits_script(family_script, CAPOO_RANGED_SCRIPT)
			and _inherits_script(family_script, SIMPLE_CHASE_SCRIPT),
			"Migrated Frost must preserve the SimpleChase -> Capoo -> Layered chain."
		)
		_expect(
			frost.supports_centralized_authoritative_simulation()
			and frost.supports_layered_area_authoritative_simulation()
			and frost.supports_layered_contact_authoritative_simulation()
			and frost.supports_dynamic_enemy_targeting()
			and frost.supports_indexed_touch_authority()
			and not bool(frost.call(&"_uses_inherited_touch_damage")),
			"Migrated Frost must pass each explicit ranged capability gate."
		)
		var authored_areas: Array[Node] = frost.find_children(
			"*",
			"Area2D",
			true,
			false
		)
		_expect(
			authored_areas.size() == 1
			and authored_areas[0] == frost.get_node("TouchDamageArea"),
			"Migrated Frost indexed authority must replace only TouchDamageArea."
		)
		_expect(
			_script_declares_method(
				family_script,
				&"_run_authoritative_physics_step"
			),
			"Migrated Frost must retain its authored LEGACY/COMPAT runner."
		)
		frost.free()


func _verify_migrated_fire_contracts() -> void:
	for scene_variant in MIGRATED_FIRE_SCENES:
		var scene := scene_variant as PackedScene
		var fire := scene.instantiate() as FireSorcerer
		_expect(
			fire != null,
			"Migrated Fire scene must instantiate FireSorcerer."
		)
		if fire == null:
			continue
		var family_script := fire.get_script() as Script
		_expect(
			family_script.get_base_script() == LAYERED_RANGED_SCRIPT
			and _inherits_script(family_script, CAPOO_RANGED_SCRIPT)
			and _inherits_script(family_script, SIMPLE_CHASE_SCRIPT),
			"Migrated Fire must preserve the SimpleChase -> Capoo -> Layered chain."
		)
		_expect(
			fire.supports_centralized_authoritative_simulation()
			and fire.supports_layered_area_authoritative_simulation()
			and fire.supports_layered_contact_authoritative_simulation()
			and fire.supports_dynamic_enemy_targeting()
			and fire.supports_indexed_touch_authority()
			and not bool(fire.call(&"_uses_inherited_touch_damage")),
			"Migrated Fire must pass each explicit ranged capability gate."
		)
		var authored_areas: Array[Node] = fire.find_children(
			"*",
			"Area2D",
			true,
			false
		)
		_expect(
			authored_areas.size() == 1
			and authored_areas[0] == fire.get_node("TouchDamageArea"),
			"Migrated Fire indexed authority must replace only TouchDamageArea."
		)
		_expect(
			_script_declares_method(
				family_script,
				&"_run_authoritative_physics_step"
			),
			"Migrated Fire must retain its authored LEGACY/COMPAT runner."
		)
		fire.free()


func _verify_migrated_lightning_contracts() -> void:
	for scene_variant in MIGRATED_LIGHTNING_SCENES:
		var scene := scene_variant as PackedScene
		var lightning := scene.instantiate() as LightningSorcerer
		_expect(
			lightning != null,
			"Migrated Lightning scene must instantiate LightningSorcerer."
		)
		if lightning == null:
			continue
		var family_script := lightning.get_script() as Script
		_expect(
			family_script.get_base_script() == LAYERED_RANGED_SCRIPT
			and _inherits_script(family_script, CAPOO_RANGED_SCRIPT)
			and _inherits_script(family_script, SIMPLE_CHASE_SCRIPT),
			"Migrated Lightning must preserve the SimpleChase -> Capoo -> Layered chain."
		)
		_expect(
			lightning.supports_centralized_authoritative_simulation()
			and lightning.supports_layered_area_authoritative_simulation()
			and lightning.supports_layered_contact_authoritative_simulation()
			and lightning.supports_dynamic_enemy_targeting()
			and lightning.supports_indexed_touch_authority()
			and not bool(lightning.call(&"_uses_inherited_touch_damage")),
			"Migrated Lightning must pass each explicit ranged capability gate."
		)
		var authored_areas: Array[Node] = lightning.find_children(
			"*",
			"Area2D",
			true,
			false
		)
		_expect(
			authored_areas.size() == 1
			and authored_areas[0] == lightning.get_node("TouchDamageArea"),
			"Migrated Lightning indexed authority must replace only TouchDamageArea."
		)
		_expect(
			_script_declares_method(
				family_script,
				&"_run_authoritative_physics_step"
			),
			"Migrated Lightning must retain its authored LEGACY/COMPAT runner."
		)
		lightning.free()


func _verify_migrated_smg_contracts() -> void:
	for scene_variant in MIGRATED_SMG_SCENES:
		var scene := scene_variant as PackedScene
		var smg := scene.instantiate() as CapooSMG
		_expect(smg != null, "Migrated SMG scene must instantiate CapooSMG.")
		if smg == null:
			continue
		var family_script := smg.get_script() as Script
		_expect(
			family_script.get_base_script() == LAYERED_RANGED_SCRIPT
			and _inherits_script(family_script, CAPOO_RANGED_SCRIPT)
			and _inherits_script(family_script, SIMPLE_CHASE_SCRIPT),
			"Migrated SMG must preserve the SimpleChase -> Capoo -> Layered chain."
		)
		_expect(
			smg.supports_centralized_authoritative_simulation()
			and smg.supports_layered_area_authoritative_simulation()
			and smg.supports_layered_contact_authoritative_simulation()
			and smg.supports_dynamic_enemy_targeting()
			and smg.supports_indexed_touch_authority()
			and not bool(smg.call(&"_uses_inherited_touch_damage")),
			"Migrated SMG must pass each explicit ranged capability gate."
		)
		var authored_areas: Array[Node] = smg.find_children(
			"*",
			"Area2D",
			true,
			false
		)
		_expect(
			authored_areas.size() == 1
			and authored_areas[0] == smg.get_node("TouchDamageArea"),
			"Migrated SMG indexed authority must replace only TouchDamageArea."
		)
		_expect(
			_script_declares_method(
				family_script,
				&"_run_authoritative_physics_step"
			),
			"Migrated SMG must retain its authored LEGACY/COMPAT runner."
		)
		smg.free()


func _verify_migrated_sniper_contracts() -> void:
	for scene_variant in MIGRATED_SNIPER_SCENES:
		var scene := scene_variant as PackedScene
		var sniper := scene.instantiate() as CapooSniper
		_expect(
			sniper != null,
			"Migrated Sniper scene must instantiate CapooSniper."
		)
		if sniper == null:
			continue
		var family_script := sniper.get_script() as Script
		_expect(
			family_script.get_base_script() == LAYERED_RANGED_SCRIPT
			and _inherits_script(family_script, CAPOO_RANGED_SCRIPT)
			and _inherits_script(family_script, SIMPLE_CHASE_SCRIPT),
			"Migrated Sniper must preserve the SimpleChase -> Capoo -> Layered chain."
		)
		_expect(
			sniper.supports_centralized_authoritative_simulation()
			and sniper.supports_layered_area_authoritative_simulation()
			and sniper.supports_layered_contact_authoritative_simulation()
			and sniper.supports_dynamic_enemy_targeting()
			and sniper.supports_indexed_touch_authority()
			and not bool(sniper.call(&"_uses_inherited_touch_damage")),
			"Migrated Sniper must pass each explicit ranged capability gate."
		)
		var authored_areas: Array[Node] = sniper.find_children(
			"*",
			"Area2D",
			true,
			false
		)
		_expect(
			authored_areas.size() == 1
			and authored_areas[0] == sniper.get_node("TouchDamageArea"),
			"Migrated Sniper indexed authority must replace only TouchDamageArea."
		)
		_expect(
			_script_declares_method(
				family_script,
				&"_run_authoritative_physics_step"
			),
			"Migrated Sniper must retain its authored LEGACY/COMPAT runner."
		)
		sniper.free()


func _verify_template_opt_in_and_hooks() -> void:
	var fixture := CONTRACT_FIXTURE.instantiate()
	var default_enemy := fixture.get_node("DefaultDisabled") as Enemy
	var opted_enemy := fixture.get_node("ExplicitOptIn") as Enemy
	var indexed_only := fixture.get_node("IndexedOnly") as Enemy
	var contact_only := fixture.get_node("ContactOnly") as Enemy
	var objective := fixture.get_node("ContractObjective") as Node2D
	_expect(
		default_enemy != null
		and opted_enemy != null
		and indexed_only != null
		and contact_only != null
		and objective != null,
		"The authored ranged contract fixture must expose every gate probe and its objective."
	)
	if (
		default_enemy == null
		or opted_enemy == null
		or indexed_only == null
		or contact_only == null
		or objective == null
	):
		fixture.free()
		return

	_expect(
		(default_enemy.get_script() as Script).get_base_script()
		== LAYERED_RANGED_SCRIPT
		and _inherits_script(
			default_enemy.get_script() as Script,
			CAPOO_RANGED_SCRIPT
		)
		and _inherits_script(
			default_enemy.get_script() as Script,
			SIMPLE_CHASE_SCRIPT
		),
		"The harness must preserve the SimpleChase -> Capoo -> Layered chain."
	)
	_expect(
		not default_enemy.supports_centralized_authoritative_simulation()
		and not default_enemy.supports_layered_area_authoritative_simulation()
		and not default_enemy.supports_layered_contact_authoritative_simulation()
		and not default_enemy.supports_indexed_touch_authority(),
		"LayeredRangedEnemy must remain fail-closed without explicit capability opt-in."
	)
	_expect(
		opted_enemy.supports_centralized_authoritative_simulation()
		and opted_enemy.supports_layered_area_authoritative_simulation()
		and opted_enemy.supports_layered_contact_authoritative_simulation()
		and opted_enemy.supports_indexed_touch_authority(),
		"A test family explicitly passing every gate must receive layered/contact/indexed authority."
	)
	_expect(
		indexed_only.supports_layered_area_authoritative_simulation()
		and not indexed_only.supports_layered_contact_authoritative_simulation()
		and indexed_only.supports_indexed_touch_authority()
		and contact_only.supports_layered_area_authoritative_simulation()
		and contact_only.supports_layered_contact_authoritative_simulation()
		and not contact_only.supports_indexed_touch_authority(),
		"Shared Enemy contact and indexed Player/Plant authority must remain independent gates."
	)

	var harness: Variant = opted_enemy
	var hook_probe := harness.run_contract_hook_order_probe(objective) as Dictionary
	_expect(
		hook_probe.get("order", []) == [&"event", &"decision", &"motion"]
		and not bool(hook_probe.get("decision_consumed", true))
		and bool(hook_probe.get("motion_allowed", false)),
		"The template must route ranged event, decision and motion hooks in phase order."
	)

	harness.contract_decision_consumed = true
	_expect(
		bool(harness.call(
			&"_try_consume_layered_area_family_decision_phase",
			TEST_DELTA
		)),
		"The ranged decision hook must be able to consume motion for an attack commit."
	)
	harness.contract_motion_allowed = false
	_expect(
		not bool(harness.call(&"_can_run_layered_area_motion")),
		"The ranged attack-state gate must be able to suppress motion."
	)
	harness.contract_event_sleep_allowed = false
	_expect(
		not harness.get_contract_family_event_sleep_allowed(),
		"A ranged event that requires polling must prevent sparse event sleep."
	)

	var current_physics_frame := Engine.get_physics_frames()
	harness.touched_plant = objective
	harness.touch_damage_cooldown_left = 0.5
	harness.contract_event_deadline_physics_frame = current_physics_frame + 2
	_expect(
		harness.get_contract_merged_event_deadline(TEST_DELTA)
		== current_physics_frame + 2,
		"The ranged event deadline must win when it is earlier than touch cooldown."
	)
	harness.contract_event_deadline_physics_frame = -1
	_expect(
		harness.get_contract_merged_event_deadline(TEST_DELTA)
		> current_physics_frame,
		"The inherited touch deadline must remain active without a ranged deadline."
	)

	_verify_template_rollback_reset(harness, objective)
	fixture.free()


func _verify_template_rollback_reset(harness: Variant, objective: Node2D) -> void:
	harness.objective_target = objective
	harness.layered_area_planned_move_direction = Vector2(3.0, -4.0)
	harness.layered_area_last_can_move = true
	harness.layered_area_motion_state_known = true
	harness.layered_area_decision_urgent = false
	harness.layered_area_last_event_tick = 91
	harness.layered_area_event_phase_sleeping = true
	harness.layered_area_event_sleep_until_physics_frame = 123
	harness.layered_touch_damage_projected_ticks_since_event = 7
	harness.layered_area_motion_phase_due = true
	harness.contract_event_deadline_physics_frame = 140
	harness.contract_event_sleep_allowed = false
	harness.contract_decision_consumed = true
	harness.contract_motion_allowed = false
	var prepare_count_before := int(harness.contract_prepare_count)

	harness.prepare_layered_area_authoritative_simulation()
	_expect(
		harness.objective_target == objective
		and harness.layered_area_planned_move_direction == Vector2.ZERO
		and not harness.layered_area_last_can_move
		and not harness.layered_area_motion_state_known
		and harness.layered_area_decision_urgent
		and harness.layered_area_last_event_tick == -1
		and not harness.layered_area_event_phase_sleeping
		and harness.layered_area_event_sleep_until_physics_frame == -1
		and harness.layered_touch_damage_projected_ticks_since_event == 0
		and not harness.layered_area_motion_phase_due,
		"Rollback preparation must reset shared layered state without discarding the objective."
	)
	_expect(
		int(harness.contract_prepare_count) == prepare_count_before + 1
		and harness.contract_event_deadline_physics_frame == -1
		and harness.contract_event_sleep_allowed
		and not harness.contract_decision_consumed
		and harness.contract_motion_allowed
		and harness.contract_hook_order == [&"prepare"],
		"Rollback preparation must route through the ranged family reset hook exactly once."
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
