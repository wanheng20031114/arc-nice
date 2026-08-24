extends SceneTree

## Long-running acceptance gate for the shared enemy-to-enemy contact shadow.
##
## This deliberately compares two independent engines over 100,000 enemy-ticks:
## Godot Physics2D maintains each authored TouchDamageArea/body overlap, while
## EnemyContactService predicts the same directed contact from immutable shape
## proxies and CombatTargetIndex broad phase. The observed Area stream then
## drives an independent stop/target/damage oracle; production Yuanshi contact
## predicates and damage cooldowns consume the SHADOW snapshot.

const RELATIONS := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)
const CONTACT_PROXY := preload(
	"res://scene/combat/contact/combat_contact_shape_proxy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const FAST_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)

const COHORT_SIZE := 200
const GROUP_SIZE := 4
const GROUP_COUNT := 50
const GROUP_COLUMNS := 10
const GROUP_SPACING := Vector2(160.0, 128.0)
const MEASURED_TICKS := 500
const REQUIRED_ENEMY_TICKS := 100_000
const FIXED_DELTA := 1.0 / 60.0
const CONTACT_CYCLE_TICKS := 24
const OBJECTIVE_ROTATION_TICKS := 37
const FACTION_MUTATION_START_TICK := 200
const FACTION_MUTATION_END_TICK := 240
const MAX_RECORDED_MISMATCHES := 16
const PRIMARY_TARGET_ROLES := [1, 0, 3, 2]
const ALTERNATE_TARGET_ROLES := [3, 2, 1, 0]

var failures: Array[String] = []
var _runtime: EnemyGameplayGatewayTestRuntime
var _service: EnemyContactService
var _relations: CombatRelationService
var _test_config: YuanshiInsectConfig
var _enemies: Array[YuanshiInsect] = []
var _groups: Array = []
var _query_scratch: Array[Enemy] = []
var _simulation_id_by_instance_id: Dictionary[int, int] = {}
var _enemy_by_simulation_id: Dictionary[int, YuanshiInsect] = {}
var _area_by_instance_id: Dictionary[int, Area2D] = {}
var _observed_contact_ids_by_source: Dictionary = {}
var _oracle_cooldown_by_source: Dictionary[int, float] = {}
var _oracle_health_by_target: Dictionary[int, int] = {}
var _event_counts_predicted: Dictionary[int, int] = {}
var _event_counts_observed: Dictionary[int, int] = {}
var _recorded_mismatches: Array[String] = []
var _mismatch_count := 0
var _area_provider_calls := 0
var _area_contact_samples := 0
var _observed_stop_enemy_ticks := 0
var _shadow_stop_enemy_ticks := 0
var _oracle_damage_claims := 0
var _faction_mutation_active := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(
		COHORT_SIZE * MEASURED_TICKS >= REQUIRED_ENEMY_TICKS,
		"The acceptance cohort must cover at least 100,000 enemy-ticks."
	)
	await _build_fixture()
	if _runtime == null or _service == null or _enemies.size() != COHORT_SIZE:
		await _finish()
		return

	# Establish an initial separated/current Physics2D snapshot without counting
	# it toward the formal measured window. The service retains this snapshot so
	# the first measured tick can legitimately emit STAY or EXIT as appropriate.
	_update_positions(0)
	_assign_objectives(0)
	await physics_frame
	await physics_frame
	await physics_frame
	await process_frame
	_service.request_mode(EnemyContactService.Mode.SHADOW)
	_service.step(0)
	_service.reset_metrics()
	_area_provider_calls = 0
	_area_contact_samples = 0
	_observed_contact_ids_by_source.clear()

	for physics_tick in range(1, MEASURED_TICKS + 1):
		_update_faction_mutation(physics_tick)
		_assign_objectives(physics_tick)
		_update_positions(physics_tick)
		# CharacterBody2D transform publication and Area2D overlap-pair refresh are
		# separated by one server step when a test writes transforms between ticks.
		# Three unchanged physics boundaries therefore expose the authored geometry's
		# current overlap set without using PhysicsServer2D.sync() or proxy math.
		await physics_frame
		await physics_frame
		await physics_frame
		await process_frame
		_observed_contact_ids_by_source.clear()
		_service.step(physics_tick)
		_compare_event_streams(physics_tick)
		_advance_and_compare_outcomes(physics_tick)

	_verify_acceptance_totals()
	await _finish()


func _build_fixture() -> void:
	_runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(_runtime)
	await process_frame
	_runtime.enable_singleplayer_combat_target_index(true)
	_service = _runtime.get_enemy_contact_service()
	_relations = _runtime.get_combat_relation_service()
	_expect(
		_service != null and _relations != null,
		"The authored runtime fixture must expose contact and relation services."
	)
	if _service == null or _relations == null:
		return

	_service.request_mode(EnemyContactService.Mode.DISABLED)
	_service.step(-1)
	_service.clear()
	_service.capture_event_streams = true
	_service.capture_candidate_order = false
	_service.set_relation_service(_relations)
	_service.set_hostile_aabb_query(_query_hostile_aabb)
	_service.set_observed_contacts_provider(_provide_area_contacts)

	_test_config = FAST_CONFIG.duplicate(true) as YuanshiInsectConfig
	_test_config.max_health = 1_000_000
	_test_config.attack_damage = 1
	_test_config.physical_defense = 0
	_test_config.magic_defense = 0
	_test_config.move_speed = 0.0

	for group_index in range(GROUP_COUNT):
		var group: Array[YuanshiInsect] = []
		for role in range(GROUP_SIZE):
			var enemy := _test_config.enemy_scene.instantiate() as YuanshiInsect
			var simulation_id := group_index * GROUP_SIZE + role + 1
			enemy.global_position = _position_for_role(group_index, role, 0)
			enemy.set_meta(&"net_id", simulation_id)
			_runtime.enemy_container.add_child(enemy)
			enemy.setup(
				_test_config,
				null,
				_runtime.grid_pathfinder,
				_runtime
			)
			if role == 1 or role == 3:
				enemy.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
			enemy.set_physics_process(false)
			enemy.set_process(false)
			enemy.hit_audio.stream = null

			var touch_area := enemy.touch_damage_area
			# This test-only mask lets the authored Area observe the production
			# layer-4 enemy hit body. Production keeps this Area on Player/Plant;
			# the comparison concerns identical authored geometry, not layer policy.
			touch_area.collision_layer = 0
			touch_area.collision_mask = 4
			touch_area.monitorable = false
			touch_area.monitoring = true

			var attacker_proxy := CONTACT_PROXY.from_collision_shape(
				enemy.touch_damage_shape
			)
			var body_proxy := CONTACT_PROXY.from_collision_shape(
				enemy.collision_shape
			)
			var registered := _service.register_enemy(
				enemy,
				simulation_id,
				enemy.get_combat_faction_id(),
				attacker_proxy,
				body_proxy,
				Callable(enemy.touch_damage_shape, &"get_global_position"),
				Callable(enemy.collision_shape, &"get_global_position")
			)
			_expect(
				registered,
				"Contact fixture %d must register both authored shape proxies."
				% simulation_id
			)
			_enemies.append(enemy)
			group.append(enemy)
			var instance_id := enemy.get_instance_id()
			_simulation_id_by_instance_id[instance_id] = simulation_id
			_enemy_by_simulation_id[simulation_id] = enemy
			_area_by_instance_id[instance_id] = touch_area
			_oracle_cooldown_by_source[simulation_id] = 0.0
			_oracle_health_by_target[simulation_id] = enemy.current_health
		_groups.append(group)

	_expect(
		int(_service.get_metrics().get("registered_count", 0)) == COHORT_SIZE,
		"Every acceptance enemy must be owned by the SHADOW service."
	)


func _query_hostile_aabb(
	world_aabb: Rect2,
	source_faction_id: int,
	excluded_entity: Node2D,
	result: Array[Node2D]
) -> void:
	result.clear()
	_query_scratch.clear()
	_runtime.combat_target_index.query_hostile_world_aabb_unordered_into(
		world_aabb,
		source_faction_id,
		_query_scratch,
		excluded_entity as Enemy,
		_relations
	)
	for candidate in _query_scratch:
		result.append(candidate)


func _provide_area_contacts(source: Node2D, result: Array) -> void:
	result.clear()
	_area_provider_calls += 1
	if source == null or not is_instance_valid(source):
		return
	var source_instance_id := source.get_instance_id()
	var source_simulation_id := int(
		_simulation_id_by_instance_id.get(source_instance_id, 0)
	)
	var touch_area := _area_by_instance_id.get(source_instance_id) as Area2D
	var observed_ids: Array[int] = []
	if touch_area == null or source_simulation_id <= 0:
		_observed_contact_ids_by_source[source_simulation_id] = observed_ids
		return
	var source_enemy := source as Enemy
	for body in touch_area.get_overlapping_bodies():
		var target := body as Enemy
		if (
			target == null
			or target == source_enemy
			or not is_instance_valid(target)
			or target.is_dead
		):
			continue
		var target_simulation_id := int(
			_simulation_id_by_instance_id.get(target.get_instance_id(), 0)
		)
		if (
			target_simulation_id <= 0
			or not _relations.is_hostile(
				source_enemy.get_combat_faction_id(),
				target.get_combat_faction_id()
			)
		):
			continue
		result.append(target)
		observed_ids.append(target_simulation_id)
	observed_ids.sort()
	_area_contact_samples += observed_ids.size()
	_observed_contact_ids_by_source[source_simulation_id] = observed_ids


func _update_positions(physics_tick: int) -> void:
	for group_index in range(_groups.size()):
		var group := _groups[group_index] as Array
		var phase := (physics_tick + group_index * 5) % CONTACT_CYCLE_TICKS
		for role in range(group.size()):
			var enemy := group[role] as YuanshiInsect
			enemy.global_position = _position_for_role(
				group_index,
				role,
				phase
			)


func _position_for_role(
	group_index: int,
	role: int,
	phase: int
) -> Vector2:
	var column := group_index % GROUP_COLUMNS
	var row := floori(float(group_index) / float(GROUP_COLUMNS))
	var anchor := Vector2(column, row) * GROUP_SPACING
	var gap := 28.0
	if phase >= 4 and phase <= 19:
		gap = 8.0

	var lane_y := -8.0 if role < 2 else 8.0
	var side_x := -gap * 0.5 if role % 2 == 0 else gap * 0.5
	return anchor + Vector2(side_x, lane_y)


func _assign_objectives(physics_tick: int) -> void:
	var objective_epoch := floori(
		float(physics_tick) / float(OBJECTIVE_ROTATION_TICKS)
	)
	for group_index in range(_groups.size()):
		var group := _groups[group_index] as Array
		for role in range(GROUP_SIZE):
			var source := group[role] as YuanshiInsect
			var use_alternate := (
				(objective_epoch + group_index + role) % 2 == 1
			)
			var primary_target_role: int = int(PRIMARY_TARGET_ROLES[role])
			var alternate_target_role: int = int(ALTERNATE_TARGET_ROLES[role])
			var target_role: int = (
				alternate_target_role
				if use_alternate
				else primary_target_role
			)
			source.set_objective_target(group[target_role] as YuanshiInsect)


func _update_faction_mutation(physics_tick: int) -> void:
	if (
		physics_tick == FACTION_MUTATION_START_TICK
		and not _faction_mutation_active
	):
		_faction_mutation_active = true
		_set_mutated_group_factions(true)
	elif (
		physics_tick == FACTION_MUTATION_END_TICK
		and _faction_mutation_active
	):
		_faction_mutation_active = false
		_set_mutated_group_factions(false)


func _set_mutated_group_factions(enabled: bool) -> void:
	# Mutate one target in every fifth quartet while geometry stays unchanged.
	# Raw Area overlap persists, but both relation-aware event streams must emit
	# the same EXIT/ENTER transition and damage must stop/resume on the same tick.
	for group_index in range(0, _groups.size(), 5):
		var group := _groups[group_index] as Array
		var enemy := group[3] as YuanshiInsect
		var previous_faction_id := enemy.get_combat_faction_id()
		var next_faction_id := (
			RELATIONS.HOSTILE_WAVE
			if enabled
			else RELATIONS.PLAYER_ALLIED
		)
		if previous_faction_id == next_faction_id:
			continue
		_expect(
			enemy.set_combat_faction_id(next_faction_id),
			"The runtime faction mutation must be accepted by the fixture enemy."
		)
		_expect(
			_service.update_faction(
				enemy,
				previous_faction_id,
				next_faction_id
			),
			"The SHADOW registry must observe every fixture faction revision."
		)


func _compare_event_streams(physics_tick: int) -> void:
	var predicted_events := _service.get_last_predicted_events()
	var observed_events := _service.get_last_observed_events()
	_accumulate_event_counts(predicted_events, _event_counts_predicted)
	_accumulate_event_counts(observed_events, _event_counts_observed)
	var predicted_signatures := _event_signatures(predicted_events)
	var observed_signatures := _event_signatures(observed_events)
	if predicted_signatures != observed_signatures:
		_record_mismatch(
			"tick %d event stream predicted=%s observed=%s"
			% [physics_tick, predicted_signatures, observed_signatures]
		)


func _advance_and_compare_outcomes(physics_tick: int) -> void:
	for source in _enemies:
		var source_simulation_id := int(
			_simulation_id_by_instance_id[source.get_instance_id()]
		)
		var objective := source.objective_target as YuanshiInsect
		var objective_simulation_id := 0
		if objective != null and is_instance_valid(objective):
			objective_simulation_id = int(
				_simulation_id_by_instance_id.get(objective.get_instance_id(), 0)
			)
		var observed_ids := (
			_observed_contact_ids_by_source.get(
				source_simulation_id,
				[]
			) as Array
		)
		var observed_target_contact := (
			objective_simulation_id > 0
			and observed_ids.has(objective_simulation_id)
		)
		var shadow_target_contact := (
			objective != null
			and _service.has_directed_contact(source, objective)
		)
		var production_stop := bool(source.call("_has_player_contact"))
		if observed_target_contact:
			_observed_stop_enemy_ticks += 1
		if production_stop:
			_shadow_stop_enemy_ticks += 1
		if (
			observed_target_contact != shadow_target_contact
			or observed_target_contact != production_stop
		):
			_record_mismatch(
				(
					"tick %d source %d target %d stop/target "
					+ "area=%s shadow=%s production=%s"
				) % [
					physics_tick,
					source_simulation_id,
					objective_simulation_id,
					observed_target_contact,
					shadow_target_contact,
					production_stop,
				]
			)

		var oracle_cooldown := maxf(
			float(_oracle_cooldown_by_source[source_simulation_id])
			- FIXED_DELTA,
			0.0
		)
		if observed_target_contact and oracle_cooldown <= 0.0:
			var outgoing_damage := source.get_effective_attack_damage(
				_test_config.attack_damage
			)
			_oracle_health_by_target[objective_simulation_id] = maxi(
				int(_oracle_health_by_target[objective_simulation_id])
				- outgoing_damage,
				0
			)
			oracle_cooldown = source.touch_damage_interval
			_oracle_damage_claims += 1
		_oracle_cooldown_by_source[source_simulation_id] = oracle_cooldown

		# This is the production contact cooldown and DamageRequest path. It reads
		# the service-owned SHADOW snapshot again inside _try_deal_touch_damage().
		source.call(
			"_update_touch_damage_unprofiled",
			FIXED_DELTA,
			shadow_target_contact
		)
		if not is_equal_approx(
			source.touch_damage_cooldown_left,
			oracle_cooldown
		):
			_record_mismatch(
				"tick %d source %d damage cooldown area=%.6f production=%.6f"
				% [
					physics_tick,
					source_simulation_id,
					oracle_cooldown,
					source.touch_damage_cooldown_left,
				]
			)

	# Compare after every attacker has settled so simultaneous contact damage is
	# validated per final target, independent of source iteration side effects.
	for target_simulation_id in _enemy_by_simulation_id:
		var target := _enemy_by_simulation_id[target_simulation_id]
		var expected_health := int(
			_oracle_health_by_target[target_simulation_id]
		)
		if target.current_health != expected_health:
			_record_mismatch(
				"tick %d target %d health area=%d production=%d"
				% [
					physics_tick,
					target_simulation_id,
					expected_health,
					target.current_health,
				]
			)


func _verify_acceptance_totals() -> void:
	var enemy_ticks := COHORT_SIZE * MEASURED_TICKS
	var metrics := _service.get_metrics()
	_expect(
		enemy_ticks >= REQUIRED_ENEMY_TICKS,
		"Measured contact coverage must remain at or above 100,000 enemy-ticks."
	)
	_expect(
		_area_provider_calls == enemy_ticks,
		"Every measured enemy-tick must read a real authored Area2D snapshot."
	)
	_expect(
		int(metrics.get("shadow_ticks", 0)) == MEASURED_TICKS,
		"Every measured physics tick must execute in SHADOW mode."
	)
	_expect(
		int(metrics.get("difference_buffer_size", -1)) == 0
		and _service.get_differences().is_empty(),
		"The full Area-vs-shadow event comparison must have zero differences."
	)
	for event_type in [
		EnemyContactService.ContactEvent.ENTER,
		EnemyContactService.ContactEvent.STAY,
		EnemyContactService.ContactEvent.EXIT,
	]:
		_expect(
			int(_event_counts_predicted.get(event_type, 0)) > 0,
			"The measured SHADOW stream must exercise %s."
			% EnemyContactService.event_to_name(event_type)
		)
		_expect(
			int(_event_counts_predicted.get(event_type, 0))
			== int(_event_counts_observed.get(event_type, -1)),
			"Predicted and real-Area %s totals must match exactly."
			% EnemyContactService.event_to_name(event_type)
		)
	_expect(
		_area_contact_samples > 0
		and _observed_stop_enemy_ticks > 0
		and _observed_stop_enemy_ticks < enemy_ticks
		and _observed_stop_enemy_ticks == _shadow_stop_enemy_ticks,
		"Target and stop outcomes must cover both moving and stopped ticks exactly."
	)
	_expect(
		_oracle_damage_claims > 0,
		"The real-Area oracle must produce accepted production damage claims."
	)
	_expect(
		_mismatch_count == 0,
		"Area-vs-shadow outcomes diverged %d times: %s"
		% [_mismatch_count, _recorded_mismatches]
	)
	if failures.is_empty():
		print(
			(
				"ENEMY_CONTACT_SHADOW_ACCEPTANCE_SMOKE_TEST_OK "
				+ "enemy_ticks=%d area_samples=%d stop_ticks=%d damage_claims=%d"
			) % [
				enemy_ticks,
				_area_contact_samples,
				_observed_stop_enemy_ticks,
				_oracle_damage_claims,
			]
		)


func _accumulate_event_counts(
	events: Array[Dictionary],
	counters: Dictionary[int, int]
) -> void:
	for event in events:
		var event_type := int(event.get(
			"event",
			EnemyContactService.ContactEvent.NONE
		))
		counters[event_type] = int(counters.get(event_type, 0)) + 1


func _event_signatures(events: Array[Dictionary]) -> Array[String]:
	var signatures: Array[String] = []
	for event in events:
		signatures.append(
			"%d>%d:%s" % [
				int(event["attacker_simulation_id"]),
				int(event["target_simulation_id"]),
				String(event["event_name"]),
			]
		)
	return signatures


func _record_mismatch(message: String) -> void:
	_mismatch_count += 1
	if _recorded_mismatches.size() < MAX_RECORDED_MISMATCHES:
		_recorded_mismatches.append(message)


func _finish() -> void:
	if _service != null and is_instance_valid(_service):
		_service.request_mode(EnemyContactService.Mode.DISABLED)
		_service.step(MEASURED_TICKS + 1)
		_service.clear()
	if _runtime != null and is_instance_valid(_runtime):
		_runtime.queue_free()
		await process_frame
		await physics_frame
	if failures.is_empty():
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
