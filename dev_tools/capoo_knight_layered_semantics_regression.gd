extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/capoo_knight_layered_semantic_runtime.tscn"
)
const KNIGHT_CONFIG := preload(
	"res://resources/config/enemies/capoo_knight.tres"
)
const KNIGHT_ELITE_CONFIG := preload(
	"res://resources/config/enemies/capoo_knight_elite.tres"
)
const STONE_KNIGHT_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_knight.tres"
)
const STONE_KNIGHT_ELITE_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_knight_elite.tres"
)
const CARDBOARD_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const CARDBOARD_LARGE_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster_large.tres"
)
const STONE_GOLEM_CONFIG := preload(
	"res://resources/config/enemies/stone_golem.tres"
)
const STONE_GOLEM_ELITE_CONFIG := preload(
	"res://resources/config/enemies/stone_golem_elite.tres"
)
const SWORDSMAN_CONFIG := preload(
	"res://resources/config/enemies/capoo_swordsman.tres"
)
const STONE_SWORDSMAN_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_swordsman.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 18
const ROLLBACK_TICK := 16
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 91_001
const PREFERRED_TARGET_NET_ID := 91_002
const OBJECTIVE_DECOY_NET_ID := 91_003
const TEST_MODES: Array[int] = [
	POLICY.Mode.LEGACY,
	POLICY.Mode.COMPAT_60,
	POLICY.Mode.LAYERED_AREA,
	POLICY.Mode.LAYERED_CONTACT,
]
const GAMEPLAY_FIELDS: PackedStringArray = [
	"tick",
	"state",
	"position_x",
	"position_y",
	"velocity_x",
	"velocity_y",
	"cooldown",
	"windup_left",
	"slash_left",
	"damage_left",
	"slash_done",
	"direction_x",
	"direction_y",
	"committed_target",
	"objective_target",
	"action_sequence",
	"action_names",
	"action_ticks",
	"action_directions",
	"attack_start_ticks",
	"attack_targets",
	"slash_start_ticks",
	"slash_damage_ticks",
	"damage_snapshots",
	"movement_submissions",
	"navigation_clears",
	"slash_effects",
	"touch_updates",
	"behavior_rng",
	"drop_rng",
]

var failures: Array[String] = []
var completed_mode_count := 0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_config_closure_and_contact_capabilities()
	_verify_production_target_priority()
	await _verify_derived_event_order()
	await _verify_mixed_contact_capability_boundary()
	await _verify_compound_contact_recapture_and_rollback()
	await _verify_production_decision_cadence()

	var runs: Dictionary = {}
	for simulation_mode in TEST_MODES:
		runs[simulation_mode] = await _run_mode(simulation_mode)
	_expect(
		completed_mode_count == TEST_MODES.size(),
		"Every Knight policy coroutine must reach its completion sentinel."
	)
	_compare_mode_traces(runs)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"fixed_seed": FIXED_SEED,
		"ticks": TEST_TICKS,
		"modes": _mode_names(),
		"trace_digests": _trace_digests(runs),
		"failures": failures.duplicate(),
	}
	print("CAPOO_KNIGHT_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_KNIGHT_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_config_closure_and_contact_capabilities() -> void:
	var knight_configs: Array = [
		KNIGHT_CONFIG,
		KNIGHT_ELITE_CONFIG,
		STONE_KNIGHT_CONFIG,
		STONE_KNIGHT_ELITE_CONFIG,
	]
	for config_variant in knight_configs:
		var config := config_variant as EnemyConfig
		var enemy := _instantiate_config_enemy(config)
		if enemy == null:
			failures.append("%s must instantiate an Enemy." % config.resource_path)
			continue
		_expect(
			enemy is CapooKnight
			and not (enemy is CardboardMonster)
			and not (enemy is StoneGolem)
			and not (enemy is CapooSwordsman),
			"%s must close over the plain CapooKnight runner."
			% config.resource_path
		)
		_verify_common_layered_capabilities(enemy, config.resource_path)
		_expect(
			enemy.supports_layered_contact_authoritative_simulation()
			and not enemy.supports_indexed_touch_authority()
			and _count_authored_enabled_touch_shapes(enemy) == 2,
			"%s must publish compound shared contact while retaining authored Player/Plant Area authority."
			% config.resource_path
		)
		enemy.free()

	var derived_configs: Array = [
		{
			"config": CARDBOARD_CONFIG,
			"class": &"cardboard",
			"source_type": &"cardboard_monster_slash",
		},
		{
			"config": CARDBOARD_LARGE_CONFIG,
			"class": &"cardboard",
			"source_type": &"cardboard_monster_large_slash",
		},
		{
			"config": STONE_GOLEM_CONFIG,
			"class": &"stone",
			"source_type": &"stone_golem_slam",
		},
		{
			"config": STONE_GOLEM_ELITE_CONFIG,
			"class": &"stone",
			"source_type": &"stone_golem_elite_slam",
		},
	]
	for record in derived_configs:
		var config := record["config"] as EnemyConfig
		var enemy := _instantiate_config_enemy(config)
		if enemy == null:
			failures.append("%s must instantiate an Enemy." % config.resource_path)
			continue
		var expected_branch := StringName(record["class"])
		var branch_matches := false
		if expected_branch == &"cardboard":
			branch_matches = enemy is CardboardMonster
		else:
			branch_matches = enemy is StoneGolem
		_expect(
			branch_matches,
			"%s must remain in its authored Knight-derived branch."
			% config.resource_path
		)
		_verify_common_layered_capabilities(enemy, config.resource_path)
		_expect(
			_count_authored_enabled_touch_shapes(enemy) == 1,
			"%s must retain the single authored touch shape required by the future contact promotion."
			% config.resource_path
		)
		_expect(
			StringName(enemy.call(&"_get_slash_damage_source_type"))
			== StringName(record["source_type"]),
			"%s must preserve its derived slash/SLAM DamageSourceSnapshot type."
			% config.resource_path
		)
		_expect(
			enemy.supports_layered_contact_authoritative_simulation()
			and enemy.supports_indexed_touch_authority(),
			"%s must publish its verified production shared/indexed contact capability."
			% config.resource_path
		)
		enemy.free()

	for excluded_config_variant in [SWORDSMAN_CONFIG, STONE_SWORDSMAN_CONFIG]:
		var excluded_config := excluded_config_variant as EnemyConfig
		var excluded := _instantiate_config_enemy(excluded_config)
		if excluded == null:
			failures.append(
				"%s must instantiate an Enemy." % excluded_config.resource_path
			)
			continue
		_expect(
			excluded is CapooSwordsman
			and excluded.supports_centralized_authoritative_simulation()
			and excluded.supports_layered_area_authoritative_simulation()
			and excluded.supports_layered_contact_authoritative_simulation()
			and not excluded.supports_indexed_touch_authority(),
			"%s must publish its independently migrated compound contact boundary."
			% excluded_config.resource_path
		)
		excluded.free()

	var cadence_enemy := _instantiate_config_enemy(KNIGHT_CONFIG) as CapooKnight
	if cadence_enemy == null:
		failures.append("Knight cadence fixture must instantiate CapooKnight.")
		return
	var previous_throttling := Enemy.combat_sense_throttling_enabled
	Enemy.combat_sense_throttling_enabled = true
	var expected_interval := mini(
		cadence_enemy.layered_area_decision_interval_frames,
		cadence_enemy.combat_sense_update_interval_frames
	)
	_expect(
		cadence_enemy.get_layered_area_decision_interval_frames()
		== maxi(expected_interval, 1),
		"Knight layered decision cadence must preserve the authored combat-sense upper bound."
	)
	Enemy.combat_sense_throttling_enabled = false
	_expect(
		cadence_enemy.get_layered_area_decision_interval_frames() == 1,
		"Disabling combat-sense throttling must restore exact 60 Hz Knight decisions."
	)
	Enemy.combat_sense_throttling_enabled = previous_throttling
	cadence_enemy.free()


func _verify_common_layered_capabilities(
	enemy: Enemy,
	resource_path: String
) -> void:
	_expect(
		enemy != null
		and enemy.supports_centralized_authoritative_simulation()
		and enemy.supports_layered_area_authoritative_simulation()
		and enemy.supports_dynamic_enemy_targeting(),
		"%s must publish centralized LAYERED_AREA and dynamic-target capability."
		% resource_path
	)


func _verify_production_target_priority() -> void:
	var source := _instantiate_config_enemy(KNIGHT_CONFIG) as CapooKnight
	var designated := _instantiate_config_enemy(TARGET_CONFIG)
	var automatic := _instantiate_config_enemy(TARGET_CONFIG)
	if source == null or designated == null or automatic == null:
		failures.append("Production target-priority probe must instantiate authored enemies.")
		if source != null:
			source.free()
		if designated != null:
			designated.free()
		if automatic != null:
			automatic.free()
		return
	source.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 1, true)
	designated.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	automatic.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	source.set_objective_target(designated)
	_expect(
		source.call(&"_get_preferred_ranged_combat_target") == designated
		and source.get_resolved_combat_target(automatic) == designated,
		"Production Knight target resolution must keep the designated objective above an automatic hostile enemy."
	)
	source.set_objective_target(null)
	_expect(
		source.get_resolved_combat_target(automatic) == automatic,
		"Production Knight target resolution must fall back to the automatic hostile enemy."
	)
	automatic.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 2, true)
	_expect(
		source.get_resolved_combat_target(automatic) == null,
		"Production Knight target resolution must reject an automatic target that turns friendly."
	)
	source.free()
	designated.free()
	automatic.free()


func _verify_derived_event_order() -> void:
	var runtime := _instantiate_runtime(POLICY.Mode.LEGACY)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var knight: Variant = runtime.get_node("EnemyContainer/KnightSource")
	var cardboard: Variant = runtime.get_node("EnemyContainer/CardboardSource")
	var stone: Variant = runtime.get_node("EnemyContainer/StoneSource")
	var target := runtime.get_node("EnemyContainer/PreferredTarget") as Enemy
	_setup_enemy(
		knight,
		KNIGHT_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		92_001
	)
	_setup_enemy(
		cardboard,
		CARDBOARD_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		92_002
	)
	_setup_enemy(
		stone,
		STONE_GOLEM_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		92_003
	)
	_setup_target(target, runtime, 92_004)
	_disable_automatic_callbacks(
		coordinator,
		knight,
		[cardboard, stone, target]
	)

	var cardboard_whole: Array = cardboard.call(
		&"run_whole_event_probe",
		PHYSICS_DELTA,
		target,
		3
	)
	var cardboard_layered: Array = cardboard.call(
		&"run_layered_event_probe",
		PHYSICS_DELTA,
		target,
		3
	)
	var expected_cardboard_order: Array[StringName] = [
		&"touch", &"knight",
		&"touch", &"knight",
		&"touch", &"knight",
	]
	_expect(
		cardboard_whole == expected_cardboard_order
		and cardboard_layered == cardboard_whole
		and bool(cardboard.call(&"_advances_layered_area_touch_damage_event")),
		"Cardboard must preserve touch-before-Knight event ordering across consecutive ticks in both runners."
	)

	var stone_whole: Array = stone.call(
		&"run_whole_event_probe",
		PHYSICS_DELTA,
		target,
		3
	)
	var stone_layered: Array = stone.call(
		&"run_layered_event_probe",
		PHYSICS_DELTA,
		target,
		3
	)
	var expected_stone_order: Array[StringName] = [
		&"knight", &"stone_visual",
		&"knight", &"stone_visual",
		&"knight",
	]
	_expect(
		stone_whole == expected_stone_order
		and stone_layered == stone_whole
		and not bool(stone.call(&"_advances_layered_area_touch_damage_event")),
		"StoneGolem must preserve Knight-before-SLAM visual ordering and its exact two-tick deadline without inventing touch ticks."
	)
	_expect(
		not bool(knight.call(&"_advances_layered_area_touch_damage_event")),
		"Plain Knight must not gain a touch-damage event absent from its authored runner."
	)

	runtime.queue_free()
	await process_frame


func _verify_mixed_contact_capability_boundary() -> void:
	var runtime := _instantiate_runtime(POLICY.Mode.LAYERED_CONTACT)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var contact_service := runtime.get_enemy_contact_service()
	var knight: Variant = runtime.get_node("EnemyContainer/KnightSource")
	var cardboard: Variant = runtime.get_node("EnemyContainer/CardboardSource")
	var cardboard_proxy_only: Variant = runtime.get_node(
		"EnemyContainer/CardboardProxyOnly"
	)
	var stone: Variant = runtime.get_node("EnemyContainer/StoneSource")
	var preferred := runtime.get_node("EnemyContainer/PreferredTarget") as Enemy
	var decoy := runtime.get_node("EnemyContainer/ObjectiveDecoy") as Enemy
	_setup_enemy(
		knight,
		KNIGHT_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		93_001
	)
	_setup_enemy(
		cardboard,
		CARDBOARD_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		93_002
	)
	_setup_enemy(
		cardboard_proxy_only,
		CARDBOARD_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		93_003
	)
	_setup_enemy(
		stone,
		STONE_GOLEM_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		93_004
	)
	_setup_target(preferred, runtime, 93_005)
	_setup_target(decoy, runtime, 93_006)
	knight.set_objective_target(preferred)
	cardboard.set_objective_target(preferred)
	cardboard_proxy_only.set_objective_target(preferred)
	stone.set_objective_target(preferred)
	preferred.set_authoritative_simulation_enabled(false)
	decoy.set_authoritative_simulation_enabled(false)
	var knight_authored_area := _capture_touch_area_state(knight)
	var cardboard_authored_area := _capture_touch_area_state(cardboard)
	var cardboard_proxy_only_authored_area := _capture_touch_area_state(
		cardboard_proxy_only
	)
	var stone_authored_area := _capture_touch_area_state(stone)
	_expect(
		_is_authored_touch_area_state(knight_authored_area, 2)
		and _is_authored_touch_area_state(cardboard_authored_area, 1)
		and _is_authored_touch_area_state(
			cardboard_proxy_only_authored_area,
			1
		)
		and _is_authored_touch_area_state(stone_authored_area, 1),
		"Mixed CONTACT fixtures must begin with their complete authored layer/mask/monitoring/shape state."
	)

	await _advance_coordinator_tick(
		coordinator,
		knight,
		[cardboard, cardboard_proxy_only, stone, preferred, decoy]
	)
	await process_frame
	_disable_automatic_callbacks(
		coordinator,
		knight,
		[cardboard, cardboard_proxy_only, stone, preferred, decoy]
	)
	_expect(
		knight.is_centrally_simulated()
		and cardboard.is_centrally_simulated()
		and cardboard_proxy_only.is_centrally_simulated()
		and stone.is_centrally_simulated(),
		"Mixed CONTACT cohort must keep compound and single-shape families centrally layered."
	)
	_expect(
		contact_service.owns_enemy(knight)
		and contact_service.owns_enemy(cardboard)
		and contact_service.owns_enemy(cardboard_proxy_only)
		and contact_service.owns_enemy(stone),
		"CONTACT proxy admission must include both compound and single-shape families."
	)
	_expect(
		not knight.is_indexed_touch_authority_enabled()
		and _capture_touch_area_state(knight) == knight_authored_area,
		"Compound Knight must retain its complete Player/Plant Area while shared enemy contact owns its proxy."
	)
	_expect(
		not cardboard_proxy_only.is_indexed_touch_authority_enabled()
		and _capture_touch_area_state(cardboard_proxy_only)
			== cardboard_proxy_only_authored_area,
		"A contact-capable but non-indexed family must publish its enemy proxy while retaining Player/Plant Area authority."
	)
	_expect(
		cardboard.is_indexed_touch_authority_enabled()
		and stone.is_indexed_touch_authority_enabled()
		and _is_disabled_indexed_touch_area_state(
			_capture_touch_area_state(cardboard),
			1
		)
		and _is_disabled_indexed_touch_area_state(
			_capture_touch_area_state(stone),
			1
		),
		"An indexed-capable family may close its single authored Area only after indexed authority is live."
	)

	var before_area := _capture_family_transition_state(knight)
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	var after_area := _capture_family_transition_state(knight)
	await process_frame
	_disable_automatic_callbacks(
		coordinator,
		knight,
		[cardboard, cardboard_proxy_only, stone, preferred, decoy]
	)
	_expect(
		before_area == after_area
		and knight.is_centrally_simulated()
		and cardboard.is_centrally_simulated()
		and cardboard_proxy_only.is_centrally_simulated()
		and stone.is_centrally_simulated()
		and not contact_service.owns_enemy(knight)
		and not contact_service.owns_enemy(cardboard)
		and not contact_service.owns_enemy(cardboard_proxy_only)
		and not contact_service.owns_enemy(stone),
		"CONTACT to AREA must preserve gameplay state/ownership while releasing every shared proxy."
	)
	_expect(
		not knight.is_indexed_touch_authority_enabled()
		and not cardboard.is_indexed_touch_authority_enabled()
		and not cardboard_proxy_only.is_indexed_touch_authority_enabled()
		and not stone.is_indexed_touch_authority_enabled()
		and _capture_touch_area_state(knight) == knight_authored_area
		and _capture_touch_area_state(cardboard) == cardboard_authored_area
		and _capture_touch_area_state(cardboard_proxy_only)
			== cardboard_proxy_only_authored_area
		and _capture_touch_area_state(stone) == stone_authored_area,
		"AREA transition must restore every authored TouchDamageArea."
	)

	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	await _advance_coordinator_tick(
		coordinator,
		knight,
		[cardboard, cardboard_proxy_only, stone, preferred, decoy]
	)
	_expect(
		contact_service.owns_enemy(knight)
		and contact_service.owns_enemy(cardboard)
		and contact_service.owns_enemy(cardboard_proxy_only)
		and contact_service.owns_enemy(stone),
		"AREA to CONTACT must re-admit both compound and single-shape proxies at the next activation boundary."
	)
	var before_legacy := _capture_family_transition_state(knight)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	var after_legacy := _capture_family_transition_state(knight)
	await process_frame
	_expect(
		before_legacy == after_legacy
		and not knight.is_centrally_simulated()
		and not cardboard.is_centrally_simulated()
		and not cardboard_proxy_only.is_centrally_simulated()
		and not stone.is_centrally_simulated()
		and not contact_service.owns_enemy(knight)
		and not contact_service.owns_enemy(cardboard)
		and not contact_service.owns_enemy(cardboard_proxy_only)
		and not contact_service.owns_enemy(stone),
		"CONTACT to LEGACY rollback must preserve family state and release the mixed cohort."
	)
	_expect(
		not knight.is_indexed_touch_authority_enabled()
		and not cardboard.is_indexed_touch_authority_enabled()
		and not cardboard_proxy_only.is_indexed_touch_authority_enabled()
		and not stone.is_indexed_touch_authority_enabled()
		and _capture_touch_area_state(knight) == knight_authored_area
		and _capture_touch_area_state(cardboard) == cardboard_authored_area
		and _capture_touch_area_state(cardboard_proxy_only)
			== cardboard_proxy_only_authored_area
		and _capture_touch_area_state(stone) == stone_authored_area,
		"LEGACY rollback must restore authored Areas for every mixed-cohort member."
	)
	_disable_automatic_callbacks(
		coordinator,
		knight,
		[cardboard, cardboard_proxy_only, stone, preferred, decoy]
	)
	runtime.queue_free()
	await process_frame


func _verify_compound_contact_recapture_and_rollback() -> void:
	var runtime := _instantiate_runtime(POLICY.Mode.LAYERED_CONTACT)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var contact_service := runtime.get_enemy_contact_service()
	var knight := runtime.get_node("EnemyContainer/KnightSource") as CapooKnight
	var target := runtime.get_node("EnemyContainer/PreferredTarget") as Enemy
	_setup_enemy(
		knight,
		KNIGHT_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		94_001
	)
	_setup_target(target, runtime, 94_002)
	knight.set_objective_target(target)
	target.set_authoritative_simulation_enabled(false)
	var authored_area := _capture_touch_area_state(knight)
	await _advance_coordinator_tick(coordinator, knight, [target])
	await process_frame
	_disable_automatic_callbacks(coordinator, knight, [target])
	_expect(
		contact_service.owns_enemy(knight)
		and not knight.is_indexed_touch_authority_enabled()
		and _capture_touch_area_state(knight) == authored_area,
		"Compound coordinator admission must register Knight while retaining its authored Player/Plant Area."
	)
	if knight.touch_damage_shapes.size() < 2:
		failures.append("Compound recapture fixture must expose both authored Knight touch shapes.")
		runtime.queue_free()
		await process_frame
		return
	var second_shape := knight.touch_damage_shapes[1]
	var shape_updates_before := int(
		contact_service.get_metrics().get("shape_proxy_updates_total", 0)
	)
	# Move only the second authored child and dirty the coordinator directly: the
	# unchanged contact revision forces the local-transform signature to prove it
	# captured every child rather than only the legacy primary shape.
	second_shape.position += Vector2(3.0, 0.0)
	second_shape.rotation += 0.25
	coordinator.mark_enemy_contact_geometry_dirty(
		knight,
		knight.enemy_simulation_token
	)
	await _advance_coordinator_tick(coordinator, knight, [target])
	var shape_updates_after_local := int(
		contact_service.get_metrics().get("shape_proxy_updates_total", 0)
	)
	_expect(
		shape_updates_after_local == shape_updates_before + 1
		and contact_service.owns_enemy(knight)
		and coordinator.mode == POLICY.Mode.LAYERED_CONTACT,
		"A secondary-child local transform change must atomically recapture the compound proxy."
	)

	# Replace only the second resource without bumping contact_shape_revision.
	# Resource-ID signatures must independently force another atomic recapture.
	var replacement := RectangleShape2D.new()
	var previous_rectangle := second_shape.shape as RectangleShape2D
	if previous_rectangle != null:
		replacement.size = previous_rectangle.size
	second_shape.shape = replacement
	coordinator.mark_enemy_contact_geometry_dirty(
		knight,
		knight.enemy_simulation_token
	)
	await _advance_coordinator_tick(coordinator, knight, [target])
	var shape_updates_after_resource := int(
		contact_service.get_metrics().get("shape_proxy_updates_total", 0)
	)
	_expect(
		shape_updates_after_resource == shape_updates_after_local + 1
		and contact_service.owns_enemy(knight),
		"A secondary-child Shape2D resource replacement must invalidate the compound signature."
	)

	# One unsupported enabled child invalidates the entire union. The current tick
	# drops stale shared authority and commits the verified COMPAT rollback only at
	# its boundary, restoring the authored Area as one mode transition.
	second_shape.shape = WorldBoundaryShape2D.new()
	coordinator.mark_enemy_contact_geometry_dirty(
		knight,
		knight.enemy_simulation_token
	)
	await _advance_coordinator_tick(coordinator, knight, [target])
	await process_frame
	_disable_automatic_callbacks(coordinator, knight, [target])
	_expect(
		coordinator.mode == POLICY.Mode.COMPAT_60
		and not contact_service.owns_enemy(knight)
		and not knight.is_indexed_touch_authority_enabled()
		and _capture_touch_area_state(knight) == authored_area,
		"An unsupported compound child must fail the whole capture closed and roll back at the tick boundary."
	)
	runtime.queue_free()
	await process_frame


func _verify_production_decision_cadence() -> void:
	var previous_throttling := Enemy.combat_sense_throttling_enabled
	Enemy.combat_sense_throttling_enabled = true
	var runtime := _instantiate_runtime(POLICY.Mode.LAYERED_AREA)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var source: Variant = runtime.get_node("EnemyContainer/KnightSource")
	var cardboard: Variant = runtime.get_node("EnemyContainer/CardboardSource")
	var stone: Variant = runtime.get_node("EnemyContainer/StoneSource")
	var preferred := runtime.get_node("EnemyContainer/PreferredTarget") as Enemy
	var decoy := runtime.get_node("EnemyContainer/ObjectiveDecoy") as Enemy
	source.use_forced_decision_interval = false
	source.use_forced_combat_sense_due = false
	_setup_enemy(
		source,
		KNIGHT_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		94_001
	)
	_setup_enemy(
		cardboard,
		CARDBOARD_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		94_002
	)
	_setup_enemy(
		stone,
		STONE_GOLEM_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		94_003
	)
	_setup_target(preferred, runtime, 94_004)
	_setup_target(decoy, runtime, 94_005)
	cardboard.set_authoritative_simulation_enabled(false)
	stone.set_authoritative_simulation_enabled(false)
	preferred.set_authoritative_simulation_enabled(false)
	decoy.set_authoritative_simulation_enabled(false)
	_reset_trace_source(source, preferred, decoy)
	source.use_forced_decision_interval = false
	source.use_forced_combat_sense_due = false
	source.forced_start_range = false
	source.forced_move_direction = Vector2.ZERO
	source.family_decision_ticks.clear()
	source.family_decision_physics_frames.clear()
	_disable_automatic_callbacks(
		coordinator,
		source,
		[cardboard, stone, preferred, decoy]
	)

	var interval: int = source.get_layered_area_decision_interval_frames()
	var cadence_tick_count := interval * 5 + 2
	for cadence_tick in range(1, cadence_tick_count + 1):
		source.contract_tick = cadence_tick
		await _advance_coordinator_tick(
			coordinator,
			source,
			[cardboard, stone, preferred, decoy]
		)
	var decision_frames: Array = source.family_decision_physics_frames
	var every_post_urgent_decision_is_due := true
	for decision_index in range(1, decision_frames.size()):
		if not source.is_layered_area_decision_due_for_physics_frame(
			int(decision_frames[decision_index])
		):
			every_post_urgent_decision_is_due = false
			break
	var fixed_post_urgent_gaps := true
	for decision_index in range(2, decision_frames.size()):
		if (
			int(decision_frames[decision_index])
			- int(decision_frames[decision_index - 1])
			!= interval
		):
			fixed_post_urgent_gaps = false
			break
	_expect(
		interval > 1
		and decision_frames.size() >= 4
		and decision_frames.size() < cadence_tick_count
		and every_post_urgent_decision_is_due
		and fixed_post_urgent_gaps,
		"Production Knight must execute one urgent decision and then remain on its deterministic phase-offset cadence without per-tick family polling."
	)
	_expect(
		source.attack_start_ticks.is_empty(),
		"The cadence probe's out-of-range target must not commit an attack."
	)
	Enemy.combat_sense_throttling_enabled = previous_throttling
	runtime.queue_free()
	await process_frame


func _run_mode(simulation_mode: int) -> Dictionary:
	var mode_name := POLICY.mode_to_name(simulation_mode)
	var runtime := _instantiate_runtime(simulation_mode)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var contact_service := runtime.get_enemy_contact_service()
	var source: Variant = runtime.get_node("EnemyContainer/KnightSource")
	var cardboard: Variant = runtime.get_node("EnemyContainer/CardboardSource")
	var stone: Variant = runtime.get_node("EnemyContainer/StoneSource")
	var preferred := runtime.get_node("EnemyContainer/PreferredTarget") as Enemy
	var decoy := runtime.get_node("EnemyContainer/ObjectiveDecoy") as Enemy

	var source_config := KNIGHT_CONFIG.duplicate(true) as CapooKnightConfig
	source_config.attack_range = 64.0
	source_config.attack_windup = PHYSICS_DELTA * 2.5
	source_config.attack_interval = PHYSICS_DELTA * 10.5
	source_config.slash_damage_delay = PHYSICS_DELTA * 1.5
	source_config.slash_duration = PHYSICS_DELTA * 3.5
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	_setup_enemy(source, source_config, runtime, SOURCE_NET_ID)
	_setup_enemy(
		cardboard,
		CARDBOARD_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		91_010
	)
	_setup_enemy(
		stone,
		STONE_GOLEM_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		91_011
	)
	_setup_target(preferred, runtime, PREFERRED_TARGET_NET_ID)
	_setup_target(decoy, runtime, OBJECTIVE_DECOY_NET_ID)
	cardboard.set_authoritative_simulation_enabled(false)
	stone.set_authoritative_simulation_enabled(false)
	preferred.set_authoritative_simulation_enabled(false)
	decoy.set_authoritative_simulation_enabled(false)
	_disable_automatic_callbacks(
		coordinator,
		source,
		[cardboard, stone, preferred, decoy]
	)
	_reset_trace_source(source, preferred, decoy)

	_expect(
		source.supports_layered_area_authoritative_simulation()
		and source.supports_layered_contact_authoritative_simulation()
		and not source.supports_indexed_touch_authority(),
		"%s plain Knight must expose compound shared contact but retain authored Player/Plant Area authority."
		% mode_name
	)
	if simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY must keep Knight on its individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s must keep Knight centrally scheduled." % mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"preferred": preferred,
		"decoy": decoy,
		"rollback_preserved": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"contact_proxy_only": simulation_mode != POLICY.Mode.LAYERED_CONTACT,
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		await _advance_one_tick(
			coordinator,
			source,
			[cardboard, stone, preferred, decoy]
		)
		if (
			tick_index == 1
			and simulation_mode == POLICY.Mode.LAYERED_CONTACT
		):
			context["contact_proxy_only"] = (
				contact_service.owns_enemy(source)
				and not source.is_indexed_touch_authority_enabled()
				and _count_authored_enabled_touch_shapes(source) == 2
				and source.touch_damage_area.monitoring
			)
		if tick_index == ROLLBACK_TICK and simulation_mode != POLICY.Mode.LEGACY:
			var before_rollback := _capture_rollback_state(source, preferred, decoy)
			coordinator.set_mode(POLICY.Mode.LEGACY)
			context["rollback_preserved"] = (
				_capture_rollback_state(source, preferred, decoy)
				== before_rollback
			)
			context["rollback_restored"] = (
				not source.is_centrally_simulated()
				and source.is_physics_processing()
				and not source.is_indexed_touch_authority_enabled()
			)
			source.set_physics_process(false)
			coordinator.set_physics_process(false)
		snapshots.append(
			_capture_snapshot(tick_index, source, preferred, decoy)
		)

	_validate_mode_invariants(mode_name, simulation_mode, snapshots, context)
	var run_result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_trace_lines(snapshots),
	}
	runtime.queue_free()
	await process_frame
	completed_mode_count += 1
	return run_result


func _reset_trace_source(
	source: Variant,
	preferred: Enemy,
	decoy: Enemy
) -> void:
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	source.combat_state = CapooKnight.CombatState.CHASE
	source.attack_cooldown_left = 0.0
	source.windup_time_left = 0.0
	source.slash_time_left = 0.0
	source.slash_damage_time_left = 0.0
	source.slash_direction = Vector2.RIGHT
	source.slash_damage_done = false
	source.action_sequence = 0
	source.committed_attack_target = null
	source.slash_damage_source_snapshot = null
	source.layered_knight_motion_blocked_physics_frame = -1
	source.forced_preferred_target = preferred
	source.forced_combat_sense_due = true
	source.use_forced_combat_sense_due = true
	source.forced_start_range = false
	source.forced_world_line_clear = true
	source.forced_move_direction = Vector2.RIGHT
	source.forced_decision_interval_frames = 1
	source.use_forced_decision_interval = true
	source.contract_tick = 0
	source.phase_context = &""
	for array_name in [
		&"attack_start_ticks",
		&"attack_start_phases",
		&"attack_target_ids",
		&"slash_start_ticks",
		&"slash_start_phases",
		&"slash_damage_ticks",
		&"slash_damage_phases",
		&"slash_damage_snapshots",
		&"action_names",
		&"action_ticks",
		&"action_phases",
		&"action_directions",
		&"cooldown_update_deltas",
		&"family_decision_ticks",
		&"family_decision_physics_frames",
	]:
		var trace_array: Array = source.get(array_name)
		trace_array.clear()
	source.movement_submission_count = 0
	source.navigation_clear_count = 0
	source.slash_effect_count = 0
	source.touch_update_count = 0
	source.random_generator.seed = FIXED_SEED
	source.material_drop_random_generator.seed = FIXED_SEED + 1
	preferred.global_position = Vector2(24.0, 0.0)
	preferred.is_dead = false
	preferred.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)
	decoy.global_position = Vector2(240.0, 0.0)
	decoy.is_dead = false
	decoy.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)
	source.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)
	source.set_objective_target(decoy)
	source.request_layered_area_urgent_decision()


func _apply_pre_tick_script(tick_index: int, context: Dictionary) -> void:
	var source: Variant = context["source"]
	var preferred: Enemy = context["preferred"]
	source.contract_tick = tick_index
	if tick_index == 1:
		source.forced_start_range = false
		source.forced_world_line_clear = true
	elif tick_index == 2:
		source.forced_start_range = true
		source.forced_world_line_clear = false
	elif tick_index == 3:
		source.forced_start_range = true
		source.forced_world_line_clear = true
	elif tick_index == 4:
		preferred.global_position = Vector2(0.0, 24.0)
	elif tick_index == 5:
		preferred.global_position = Vector2(-24.0, 0.0)
	elif tick_index == 12:
		source.attack_cooldown_left = 0.0
		preferred.global_position = Vector2(24.0, 0.0)
	elif tick_index == 13:
		preferred.is_dead = true
	elif tick_index == 14:
		preferred.is_dead = false
		source.attack_cooldown_left = 0.0
	elif tick_index == 15:
		preferred.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			2,
			true
		)
	elif tick_index == 16:
		preferred.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			3,
			true
		)
		source.attack_cooldown_left = 0.0
	source.request_layered_area_urgent_decision()


func _advance_one_tick(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array
) -> void:
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, other_nodes)
	if source == null or not is_instance_valid(source) or source.is_dead:
		return
	if source.is_centrally_simulated():
		coordinator.call(&"_physics_process", PHYSICS_DELTA)
		coordinator.set_physics_process(false)
		return
	source.call(&"_run_authoritative_physics_step", PHYSICS_DELTA)
	source.set_physics_process(false)


func _advance_coordinator_tick(
	coordinator: EnemySimulationCoordinator,
	primary_source: Variant,
	other_nodes: Array
) -> void:
	await physics_frame
	_disable_automatic_callbacks(coordinator, primary_source, other_nodes)
	coordinator.call(&"_physics_process", PHYSICS_DELTA)
	coordinator.set_physics_process(false)


func _capture_snapshot(
	tick_index: int,
	source: Variant,
	preferred: Enemy,
	decoy: Enemy
) -> Dictionary:
	return {
		"tick": tick_index,
		"state": source.combat_state,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"cooldown": _quantize(source.attack_cooldown_left),
		"windup_left": _quantize(source.windup_time_left),
		"slash_left": _quantize(source.slash_time_left),
		"damage_left": _quantize(source.slash_damage_time_left),
		"slash_done": 1 if source.slash_damage_done else 0,
		"direction_x": _quantize(source.slash_direction.x),
		"direction_y": _quantize(source.slash_direction.y),
		"committed_target": _target_label(
			source.committed_attack_target,
			preferred,
			decoy
		),
		"objective_target": _target_label(
			source.objective_target,
			preferred,
			decoy
		),
		"action_sequence": source.action_sequence,
		"action_names": _string_name_array(source.action_names),
		"action_ticks": source.action_ticks.duplicate(),
		"action_directions": _quantized_directions(source.action_directions),
		"attack_start_ticks": source.attack_start_ticks.duplicate(),
		"attack_targets": _stable_attack_target_labels(
			source.attack_target_ids,
			preferred
		),
		"slash_start_ticks": source.slash_start_ticks.duplicate(),
		"slash_damage_ticks": source.slash_damage_ticks.duplicate(),
		"damage_snapshots": source.slash_damage_snapshots.duplicate(true),
		"movement_submissions": source.movement_submission_count,
		"navigation_clears": source.navigation_clear_count,
		"slash_effects": source.slash_effect_count,
		"touch_updates": source.touch_update_count,
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"indexed_touch": (
			1 if source.is_indexed_touch_authority_enabled() else 0
		),
		"touch_area_monitoring": (
			1 if source.touch_damage_area.monitoring else 0
		),
	}


func _capture_rollback_state(
	source: Variant,
	preferred: Enemy,
	decoy: Enemy
) -> Dictionary:
	var snapshot: DamageSourceSnapshot = (
		source.slash_damage_source_snapshot as DamageSourceSnapshot
	)
	return {
		"state": source.combat_state,
		"cooldown": source.attack_cooldown_left,
		"windup": source.windup_time_left,
		"slash": source.slash_time_left,
		"damage": source.slash_damage_time_left,
		"slash_done": source.slash_damage_done,
		"direction": source.slash_direction,
		"target": _target_label(
			source.committed_attack_target,
			preferred,
			decoy
		),
		"action_sequence": source.action_sequence,
		"rng": source.random_generator.state,
		"snapshot_faction": (
			snapshot.source_faction_id if snapshot != null else -1
		),
		"snapshot_instigator": (
			snapshot.instigator_entity_id if snapshot != null else -1
		),
		"snapshot_event": snapshot.event_source_id if snapshot != null else -1,
		"snapshot_type": String(snapshot.source_type) if snapshot != null else "",
		"warning_visible": source.windup_warning.visible,
		"warning_rotation": source.windup_warning.rotation,
		"warning_scale": source.windup_warning.scale,
		"warning_color": source.windup_warning.color,
	}


func _capture_family_transition_state(source: Variant) -> Dictionary:
	return {
		"state": source.combat_state,
		"cooldown": source.attack_cooldown_left,
		"windup": source.windup_time_left,
		"slash": source.slash_time_left,
		"damage": source.slash_damage_time_left,
		"direction": source.slash_direction,
		"action_sequence": source.action_sequence,
		"rng": source.random_generator.state,
		"target": source.committed_attack_target,
	}


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	if snapshots.size() != TEST_TICKS:
		failures.append("%s must capture every Knight tick." % mode_name)
		return
	var expected_states: Array[int] = [
		CapooKnight.CombatState.CHASE,
		CapooKnight.CombatState.CHASE,
		CapooKnight.CombatState.WINDUP,
		CapooKnight.CombatState.WINDUP,
		CapooKnight.CombatState.WINDUP,
		CapooKnight.CombatState.SLASH,
		CapooKnight.CombatState.SLASH,
		CapooKnight.CombatState.SLASH,
		CapooKnight.CombatState.SLASH,
		CapooKnight.CombatState.CHASE,
		CapooKnight.CombatState.CHASE,
		CapooKnight.CombatState.WINDUP,
		CapooKnight.CombatState.CHASE,
		CapooKnight.CombatState.WINDUP,
		CapooKnight.CombatState.CHASE,
		CapooKnight.CombatState.WINDUP,
		CapooKnight.CombatState.WINDUP,
		CapooKnight.CombatState.WINDUP,
	]
	for tick_index in range(TEST_TICKS):
		_expect(
			int(snapshots[tick_index]["state"]) == expected_states[tick_index],
			"%s tick %d must preserve CHASE/WINDUP/SLASH transition timing."
			% [mode_name, tick_index + 1]
		)

	var source: Variant = context["source"]
	var preferred: Enemy = context["preferred"]
	_expect(
		source.action_ticks == [3, 6, 12, 14, 16]
		and source.action_names
		== [&"windup", &"slash", &"windup", &"windup", &"windup"]
		and source.attack_start_ticks == [3, 12, 14, 16]
		and source.slash_start_ticks == [6]
		and source.slash_damage_ticks == [8]
		and source.action_sequence == 5,
		"%s must preserve exact attack commits, slash tick, damage tick and action sequence."
		% mode_name
	)
	_expect(
		source.attack_target_ids.size() == 4
		and source.attack_target_ids.all(
			func(instance_id: int) -> bool: return instance_id == preferred.get_instance_id()
		),
		"%s must commit every scripted decision to the same deterministic hostile candidate."
		% mode_name
	)
	_expect(
		source.action_directions.size() >= 2
		and source.action_directions[1].x < -0.99
		and absf(source.action_directions[1].y) < 0.01,
		"%s WINDUP must track the moving target and freeze the leftward SLASH direction."
		% mode_name
	)
	_expect(
		source.slash_damage_snapshots.size() == 1
		and int(source.slash_damage_snapshots[0]["source_faction_id"])
		== CombatRelationService.HOSTILE_WAVE
		and int(source.slash_damage_snapshots[0]["instigator_entity_id"])
		== SOURCE_NET_ID
		and int(source.slash_damage_snapshots[0]["event_source_id"])
		== SOURCE_NET_ID * 1_000_000 + 1
		and String(source.slash_damage_snapshots[0]["source_type"])
		== "capoo_knight_slash",
		"%s slash must retain its launch-time DamageSourceSnapshot."
		% mode_name
	)
	_expect(
		int(snapshots[0]["action_sequence"]) == 0
		and int(snapshots[1]["action_sequence"]) == 0,
		"%s range and LOS rejection must prevent early attack commits."
		% mode_name
	)
	_expect(
		int(snapshots[9]["movement_submissions"])
		== int(snapshots[8]["movement_submissions"])
		and int(snapshots[10]["movement_submissions"])
		> int(snapshots[9]["movement_submissions"])
		and source.movement_submission_count == 5,
		"%s slash-finish tick must stay motion-blocked and resume on the next CHASE tick."
		% mode_name
	)
	_expect(
		source.touch_update_count == 0
		and source.slash_effect_count == 1
		and source.navigation_clear_count == 4,
		"%s must not invent Knight touch events and must keep one slash effect/four windup path clears."
		% mode_name
	)
	_expect(
		source.cooldown_update_deltas.size() == TEST_TICKS
		and _all_deltas_equal(source.cooldown_update_deltas, PHYSICS_DELTA),
		"%s every executed Knight event callback must consume exactly one 60 Hz delta."
		% mode_name
	)
	var expected_attack_phase := (
		&"decision"
		if simulation_mode in [POLICY.Mode.LAYERED_AREA, POLICY.Mode.LAYERED_CONTACT]
		else &"whole"
	)
	var expected_slash_phase := (
		&"event"
		if simulation_mode in [POLICY.Mode.LAYERED_AREA, POLICY.Mode.LAYERED_CONTACT]
		else &"whole"
	)
	var expected_action_phases: Array[StringName] = [
		expected_attack_phase,
		expected_slash_phase,
		expected_attack_phase,
		expected_attack_phase,
		expected_attack_phase,
	]
	_expect(
		_all_phases_equal(source.attack_start_phases, expected_attack_phase)
		and _all_phases_equal(source.slash_start_phases, expected_slash_phase)
		and _all_phases_equal(source.slash_damage_phases, expected_slash_phase)
		and source.action_phases == expected_action_phases,
		"%s must commit attacks only in decision and slash/damage only in event phase."
		% mode_name
	)
	_expect(
		bool(context["rollback_preserved"])
		and bool(context["rollback_restored"]),
		"%s rollback must preserve WINDUP state/RNG/snapshot and restore the individual runner."
		% mode_name
	)
	_expect(
		bool(context["contact_proxy_only"]),
		"%s CONTACT must register Knight's compound enemy proxy without taking indexed Player/Plant authority."
		% mode_name
	)
	_expect(
		int(snapshots[ROLLBACK_TICK - 2]["central_owned"])
		== (0 if simulation_mode == POLICY.Mode.LEGACY else 1)
		and int(snapshots[ROLLBACK_TICK - 1]["central_owned"]) == 0,
		"%s must transfer ownership exactly at rollback tick %d."
		% [mode_name, ROLLBACK_TICK]
	)


func _compare_mode_traces(runs: Dictionary) -> void:
	var legacy_run: Dictionary = runs.get(POLICY.Mode.LEGACY, {})
	var legacy_snapshots: Array = legacy_run.get("snapshots", [])
	for comparison_mode in [
		POLICY.Mode.COMPAT_60,
		POLICY.Mode.LAYERED_AREA,
		POLICY.Mode.LAYERED_CONTACT,
	]:
		var mode_name := POLICY.mode_to_name(comparison_mode)
		var comparison_run: Dictionary = runs.get(comparison_mode, {})
		var comparison_snapshots: Array = comparison_run.get("snapshots", [])
		if comparison_snapshots.size() != legacy_snapshots.size():
			failures.append("%s trace length differs from LEGACY." % mode_name)
			continue
		var mismatch_count := 0
		for tick_index in range(legacy_snapshots.size()):
			var legacy_snapshot: Dictionary = legacy_snapshots[tick_index]
			var comparison_snapshot: Dictionary = comparison_snapshots[tick_index]
			for field_name in GAMEPLAY_FIELDS:
				if legacy_snapshot.get(field_name) == comparison_snapshot.get(field_name):
					continue
				failures.append(
					"%s diverged from LEGACY at tick %d field %s: legacy=%s comparison=%s"
					% [
						mode_name,
						tick_index + 1,
						field_name,
						str(legacy_snapshot.get(field_name)),
						str(comparison_snapshot.get(field_name)),
					]
				)
				mismatch_count += 1
				if mismatch_count >= 10:
					break
			if mismatch_count >= 10:
				break


func _instantiate_runtime(simulation_mode: int) -> EnemyGameplayGatewayTestRuntime:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	coordinator.set_mode(simulation_mode)
	root.add_child(runtime)
	coordinator.set_physics_process(false)
	return runtime


func _instantiate_config_enemy(config: EnemyConfig) -> Enemy:
	if config == null or config.enemy_scene == null:
		return null
	return config.enemy_scene.instantiate() as Enemy


func _setup_enemy(
	enemy: Variant,
	config: EnemyConfig,
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int
) -> void:
	enemy.set_meta(&"net_id", net_id)
	enemy.setup(config, null, null, runtime)
	runtime.register_network_enemy(net_id, enemy)
	enemy.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)


func _setup_target(
	target: Enemy,
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int
) -> void:
	var target_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	target_config.drop_table = null
	target_config.xirang_kill_reward = 0
	target.set_meta(&"net_id", net_id)
	target.setup(target_config, null, null, runtime)
	runtime.register_network_enemy(net_id, target)
	target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)


func _disable_automatic_callbacks(
	coordinator: EnemySimulationCoordinator,
	primary_source: Variant,
	other_nodes: Array
) -> void:
	coordinator.set_physics_process(false)
	if primary_source != null and is_instance_valid(primary_source):
		primary_source.set_process(false)
		primary_source.set_physics_process(false)
	for node_variant in other_nodes:
		if node_variant == null or not is_instance_valid(node_variant):
			continue
		var node := node_variant as Node
		node.set_process(false)
		node.set_physics_process(false)


func _count_authored_enabled_touch_shapes(enemy: Enemy) -> int:
	if enemy == null:
		return 0
	var area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	if area == null:
		return 0
	var count := 0
	for child in area.find_children("*", "CollisionShape2D", true, false):
		var shape := child as CollisionShape2D
		if shape != null and not shape.disabled:
			count += 1
	return count


func _capture_touch_area_state(source: Variant) -> Dictionary:
	if source == null or not is_instance_valid(source):
		return {}
	var area := source.touch_damage_area as Area2D
	if area == null or not is_instance_valid(area):
		return {}
	var shape_states := PackedStringArray()
	for child in area.find_children("*", "CollisionShape2D", true, false):
		var shape := child as CollisionShape2D
		if shape == null:
			continue
		shape_states.append(
			"%s=%d"
			% [String(area.get_path_to(shape)), int(shape.disabled)]
		)
	shape_states.sort()
	return {
		"collision_layer": area.collision_layer,
		"collision_mask": area.collision_mask,
		"monitoring": area.monitoring,
		"monitorable": area.monitorable,
		"shape_states": shape_states,
	}


func _is_authored_touch_area_state(
	state: Dictionary,
	expected_shape_count: int
) -> bool:
	var shape_states: PackedStringArray = state.get(
		"shape_states",
		PackedStringArray()
	)
	if (
		int(state.get("collision_layer", -1)) != 8
		or int(state.get("collision_mask", -1)) != 514
		or not bool(state.get("monitoring", false))
		or not bool(state.get("monitorable", false))
		or shape_states.size() != expected_shape_count
	):
		return false
	for shape_state in shape_states:
		if not shape_state.ends_with("=0"):
			return false
	return true


func _is_disabled_indexed_touch_area_state(
	state: Dictionary,
	expected_shape_count: int
) -> bool:
	var shape_states: PackedStringArray = state.get(
		"shape_states",
		PackedStringArray()
	)
	if (
		int(state.get("collision_layer", -1)) != 0
		or int(state.get("collision_mask", -1)) != 0
		or bool(state.get("monitoring", true))
		or bool(state.get("monitorable", true))
		or shape_states.size() != expected_shape_count
	):
		return false
	for shape_state in shape_states:
		if not shape_state.ends_with("=1"):
			return false
	return true


func _target_label(
	target: Node2D,
	preferred: Enemy,
	decoy: Enemy
) -> String:
	if target == preferred:
		return "preferred"
	if target == decoy:
		return "decoy"
	return "none"


func _string_name_array(values: Array) -> PackedStringArray:
	var result := PackedStringArray()
	for value in values:
		result.append(String(value))
	return result


func _stable_attack_target_labels(
	instance_ids: Array,
	preferred: Enemy
) -> PackedStringArray:
	var result := PackedStringArray()
	var preferred_instance_id := preferred.get_instance_id()
	for instance_id_variant in instance_ids:
		result.append(
			"preferred"
			if int(instance_id_variant) == preferred_instance_id
			else "unexpected"
		)
	return result


func _quantized_directions(values: Array) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for value_variant in values:
		var value: Vector2 = value_variant
		result.append(Vector2i(_quantize(value.x), _quantize(value.y)))
	return result


func _all_phases_equal(phases: Array, expected_phase: StringName) -> bool:
	for phase_variant in phases:
		if StringName(phase_variant) != expected_phase:
			return false
	return true


func _all_deltas_equal(deltas: Array, expected_delta: float) -> bool:
	for delta_variant in deltas:
		if not is_equal_approx(float(delta_variant), expected_delta):
			return false
	return true


func _canonical_trace_lines(
	snapshots: Array[Dictionary]
) -> PackedStringArray:
	var result := PackedStringArray()
	for snapshot in snapshots:
		var canonical := {}
		for field_name in GAMEPLAY_FIELDS:
			canonical[field_name] = snapshot.get(field_name)
		result.append(JSON.stringify(canonical))
	return result


func _trace_digests(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var lines: PackedStringArray = run.get(
			"trace_lines",
			PackedStringArray()
		)
		result[POLICY.mode_to_name(simulation_mode)] = (
			"\n".join(lines).sha256_text()
		)
	return result


func _mode_names() -> PackedStringArray:
	var result := PackedStringArray()
	for simulation_mode in TEST_MODES:
		result.append(POLICY.mode_to_name(simulation_mode))
	return result


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
