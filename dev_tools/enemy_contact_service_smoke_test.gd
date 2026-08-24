extends SceneTree

const SERVICE := preload(
	"res://scene/combat/contact/enemy_contact_service.gd"
)
const PROXY := preload(
	"res://scene/combat/contact/combat_contact_shape_proxy.gd"
)
const RELATIONS := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)
const SERVICE_SCENE := preload(
	"res://scene/combat/contact/enemy_contact_service.tscn"
)

class FixtureEnemy extends Node2D:
	var fixture_name: StringName


var failures: Array[String] = []
var fixtures: Array[FixtureEnemy] = []
var proxy_by_instance_id: Dictionary[int, CombatContactShapeProxy] = {}
var faction_by_instance_id: Dictionary[int, int] = {}
var observed_by_instance_id: Dictionary[int, Array] = {}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_scene_contract()
	_test_same_faction_registry_skips_broad_phase()
	_test_relation_and_faction_cache_invalidations()
	_test_same_tick_relation_change_refreshes_current_positions()
	_test_stale_entry_pruned_after_relation_revision()
	_test_shadow_events_faction_sweep_and_order()
	_test_directed_attack_shell_uses_target_body()
	_test_planned_sweep_is_separate_from_current_contact()
	_test_uncommitted_target_plan_remains_shadow()
	_test_offset_body_anchor_is_kept_in_broad_phase()
	for fixture in fixtures:
		if is_instance_valid(fixture):
			fixture.free()
	if failures.is_empty():
		print("ENEMY_CONTACT_SERVICE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_scene_contract() -> void:
	var node := SERVICE_SCENE.instantiate() as EnemyContactService
	_expect(node != null, "The native EnemyContactService scene must instantiate.")
	if node != null:
		_expect(
			node.initial_mode == SERVICE.Mode.DISABLED,
			"The production scene must fail closed in DISABLED mode."
		)
		_expect(
			not node.capture_event_streams and not node.capture_candidate_order,
			"Production HYBRID contact must leave semantic allocation probes opt-in."
		)
		node.free()


func _test_same_faction_registry_skips_broad_phase() -> void:
	var service := SERVICE.new()
	service.automatic_physics_step = false
	var first := FixtureEnemy.new()
	var second := FixtureEnemy.new()
	first.position = Vector2.ZERO
	second.position = Vector2(4.0, 0.0)
	fixtures.append(first)
	fixtures.append(second)
	var circle := CircleShape2D.new()
	circle.radius = 3.0
	var proxy = PROXY.create(circle)
	_expect(
		service.register_enemy(
			first,
			1,
			RELATIONS.PLAYER_ALLIED,
			proxy,
			proxy
		)
		and service.register_enemy(
			second,
			2,
			RELATIONS.PLAYER_ALLIED,
			proxy,
			proxy
		),
		"Same-faction broad-phase fixtures must register."
	)
	var query_counter := {"value": 0}
	service.set_hostile_aabb_query(
		func(
			_world_aabb: Rect2,
			_source_faction_id: int,
			excluded_entity: Node2D,
			result: Array[Node2D]
		) -> void:
			query_counter["value"] = int(query_counter["value"]) + 1
			result.clear()
			result.append(second if excluded_entity == first else first)
	)
	service.request_mode(SERVICE.Mode.HYBRID_ENEMY_CONTACT)
	service.step(1)
	service.step_planned(1.0 / 60.0, 1)
	var metrics := service.get_metrics()
	_expect(
		int(query_counter["value"]) == 0
		and int(metrics["broad_phase_source_skips_total"]) == 2
		and int(metrics["planned_broad_phase_source_skips_total"]) == 2,
		"A registry with no hostile faction must skip every current and planned broad-phase query."
	)
	var first_stale_scan_count := int(metrics["stale_prune_scans_total"])
	var first_cache_hit_count := int(metrics["hostile_pair_cache_hits_total"])
	var first_empty_reuse_count := int(
		metrics["no_hostile_empty_contact_reuses_total"]
	)
	service.step(2)
	service.step_planned(1.0 / 60.0, 2)
	metrics = service.get_metrics()
	_expect(
		int(metrics["stale_prune_scans_total"]) == first_stale_scan_count
		and int(metrics["hostile_pair_cache_hits_total"])
			>= first_cache_hit_count + 2
		and int(metrics["no_hostile_stale_prune_skips_total"]) >= 3
		and int(metrics["no_hostile_empty_contact_reuses_total"])
			== first_empty_reuse_count + 1
		and int(metrics["current_position_refresh_steps_total"]) == 0
		and int(metrics["planned_position_refresh_steps_total"]) == 0,
		"A stable friendly-only registry must reuse the cached false relation without stale or position scans."
	)
	_expect(
		service.update_faction(
			second,
			RELATIONS.PLAYER_ALLIED,
			RELATIONS.HOSTILE_WAVE
		),
		"Introducing a hostile faction must update the presence mask."
	)
	service.step(3)
	service.step_planned(1.0 / 60.0, 3)
	_expect(
		int(query_counter["value"]) == 4
		and service.has_directed_contact(first, second)
		and service.has_directed_contact(second, first),
		"A runtime hostile faction must immediately restore both directed broad-phase queries."
	)
	service.clear()
	service.free()


func _test_relation_and_faction_cache_invalidations() -> void:
	const FIRST_FACTION := 3
	const SECOND_FACTION := 4
	var service := SERVICE.new()
	service.automatic_physics_step = false
	var relations := RELATIONS.new()
	service.set_relation_service(relations)
	var first := FixtureEnemy.new()
	var second := FixtureEnemy.new()
	first.position = Vector2.ZERO
	second.position = Vector2(2.0, 0.0)
	fixtures.append(first)
	fixtures.append(second)
	observed_by_instance_id[first.get_instance_id()] = []
	observed_by_instance_id[second.get_instance_id()] = []
	var circle := CircleShape2D.new()
	circle.radius = 3.0
	var proxy = PROXY.create(circle)
	_expect(
		service.register_enemy(first, 401, FIRST_FACTION, proxy, proxy)
		and service.register_enemy(second, 402, SECOND_FACTION, proxy, proxy),
		"Custom-relation cache fixtures must register."
	)
	var query_counter := {"value": 0}
	service.set_hostile_aabb_query(
		func(
			_world_aabb: Rect2,
			_source_faction_id: int,
			excluded_entity: Node2D,
			result: Array[Node2D]
		) -> void:
			query_counter["value"] = int(query_counter["value"]) + 1
			result.clear()
			result.append(second if excluded_entity == first else first)
	)
	service.set_observed_contacts_provider(
		func(source: Node2D, result: Array) -> void:
			result.clear()
			result.append_array(
				observed_by_instance_id.get(source.get_instance_id(), [])
			)
	)
	service.request_mode(SERVICE.Mode.SHADOW)
	service.step(1)
	service.step_planned(1.0 / 60.0, 1)
	var initial_metrics := service.get_metrics()
	service.step(2)
	service.step_planned(1.0 / 60.0, 2)
	var steady_metrics := service.get_metrics()
	_expect(
		int(query_counter["value"]) == 0
		and int(steady_metrics["stale_prune_scans_total"])
			== int(initial_metrics["stale_prune_scans_total"])
		and int(steady_metrics["no_hostile_stale_prune_skips_total"])
			>= int(initial_metrics["no_hostile_stale_prune_skips_total"]) + 2,
		"A stable two-faction but non-hostile registry must keep both contact phases on the cached fast path."
	)

	_expect(
		relations.set_hostile(FIRST_FACTION, SECOND_FACTION, true)
		and relations.set_hostile(SECOND_FACTION, FIRST_FACTION, true),
		"A relation-only mutation must be accepted without re-registering enemies."
	)
	_set_observed_pair(first, second, true)
	service.step(3)
	service.step_planned(1.0 / 60.0, 3)
	var relation_enter_events := _event_signatures(
		service.get_last_predicted_events()
	)
	_expect(
		int(query_counter["value"]) == 4
		and relation_enter_events == ["401>402:ENTER", "402>401:ENTER"]
		and service.get_differences().is_empty(),
		"A CombatRelationService revision must invalidate the false cache and produce ordered SHADOW ENTER events."
	)

	_expect(
		relations.set_hostile(FIRST_FACTION, SECOND_FACTION, false)
		and relations.set_hostile(SECOND_FACTION, FIRST_FACTION, false),
		"Removing both directed relations must advance the relation revision."
	)
	_set_observed_pair(first, second, false)
	service.step(4)
	service.step_planned(1.0 / 60.0, 4)
	_expect(
		_event_signatures(service.get_last_predicted_events())
			== ["401>402:EXIT", "402>401:EXIT"]
		and service.get_differences().is_empty()
		and not service.has_directed_contact(first, second),
		"The first no-hostile tick must reuse the persistent empty set while emitting each prior contact EXIT once."
	)
	var exit_metrics := service.get_metrics()
	service.step(5)
	service.step_planned(1.0 / 60.0, 5)
	var post_exit_metrics := service.get_metrics()
	_expect(
		service.get_last_predicted_events().is_empty()
		and service.get_last_observed_events().is_empty()
		and int(post_exit_metrics["stale_prune_scans_total"])
			== int(exit_metrics["stale_prune_scans_total"])
		and int(post_exit_metrics["no_hostile_empty_contact_reuses_total"])
			== int(exit_metrics["no_hostile_empty_contact_reuses_total"]) + 1,
		"After the one EXIT transition, steady no-hostile ticks must stay allocation-free and event-free."
	)

	_expect(
		service.update_faction(
			first,
			FIRST_FACTION,
			RELATIONS.PLAYER_ALLIED
		)
		and service.update_faction(
			second,
			SECOND_FACTION,
			RELATIONS.HOSTILE_WAVE
		),
		"Runtime faction changes must invalidate cached membership even without relation edits."
	)
	_set_observed_pair(first, second, true)
	service.step(6)
	service.step_planned(1.0 / 60.0, 6)
	_expect(
		service.has_directed_contact(first, second)
		and service.has_directed_contact(second, first)
		and service.get_differences().is_empty(),
		"Moving cached entries into the default hostile factions must restore contact immediately."
	)
	_expect(
		service.update_faction(
			second,
			RELATIONS.HOSTILE_WAVE,
			RELATIONS.PLAYER_ALLIED
		),
		"Moving the second entry back to the allied faction must be accepted."
	)
	_set_observed_pair(first, second, false)
	service.step(7)
	service.step_planned(1.0 / 60.0, 7)
	_expect(
		_event_signatures(service.get_last_predicted_events())
			== ["401>402:EXIT", "402>401:EXIT"]
		and service.get_differences().is_empty(),
		"A faction mutation to a friendly-only registry must take the same exact EXIT path."
	)

	var before_unregister := service.get_metrics()
	_expect(
		service.unregister_enemy(second, 402),
		"Explicit unregistration must invalidate the membership cache."
	)
	service.step(8)
	var after_unregister := service.get_metrics()
	_expect(
		int(after_unregister["registered_count"]) == 1
		and int(after_unregister["hostile_pair_cache_misses_total"])
			> int(before_unregister["hostile_pair_cache_misses_total"]),
		"The next step after unregistration must rebuild the cached relation result exactly once."
	)
	var replacement := FixtureEnemy.new()
	replacement.position = Vector2(3.0, 0.0)
	fixtures.append(replacement)
	_expect(
		service.register_enemy(
			replacement,
			403,
			RELATIONS.PLAYER_ALLIED,
			proxy,
			proxy
		),
		"A same-faction registration must still invalidate membership cache state."
	)
	var before_registration_step := service.get_metrics()
	service.step(9)
	var after_registration_step := service.get_metrics()
	_expect(
		int(after_registration_step["registered_count"]) == 2
		and int(after_registration_step["hostile_pair_cache_misses_total"])
			> int(before_registration_step["hostile_pair_cache_misses_total"]),
		"The next step after registration must refresh the cache even when the presence mask is unchanged."
	)
	service.clear()
	service.free()


func _test_same_tick_relation_change_refreshes_current_positions() -> void:
	const FIRST_FACTION := 3
	const SECOND_FACTION := 4
	const PHYSICS_TICK := 17
	var service := SERVICE.new()
	service.automatic_physics_step = false
	var relations := RELATIONS.new()
	service.set_relation_service(relations)
	var first := FixtureEnemy.new()
	var second := FixtureEnemy.new()
	first.position = Vector2.ZERO
	second.position = Vector2.ZERO
	fixtures.append(first)
	fixtures.append(second)
	var circle := CircleShape2D.new()
	circle.radius = 3.0
	var proxy = PROXY.create(circle)
	_expect(
		service.register_enemy(first, 451, FIRST_FACTION, proxy, proxy)
		and service.register_enemy(second, 452, SECOND_FACTION, proxy, proxy),
		"Same-tick relation fixtures must register."
	)
	service.set_hostile_aabb_query(
		func(
			_world_aabb: Rect2,
			_source_faction_id: int,
			excluded_entity: Node2D,
			result: Array[Node2D]
		) -> void:
			result.clear()
			result.append(second if excluded_entity == first else first)
	)
	service.request_mode(SERVICE.Mode.HYBRID_ENEMY_CONTACT)
	service.step(PHYSICS_TICK)
	var before_relation_metrics := service.get_metrics()
	_expect(
		int(before_relation_metrics["current_position_refresh_steps_total"]) == 0,
		"A no-hostile current step must avoid unnecessary position refresh work."
	)

	# The pair was overlapping at registration but separates before a relation
	# mutation in the same physics tick. step_planned() must not sweep from the old
	# overlap merely because step() already recorded this tick number.
	second.position = Vector2(100.0, 0.0)
	_expect(
		relations.set_hostile(FIRST_FACTION, SECOND_FACTION, true)
		and relations.set_hostile(SECOND_FACTION, FIRST_FACTION, true),
		"The same-tick fixture must establish both hostile directions."
	)
	service.step_planned(1.0 / 60.0, PHYSICS_TICK)
	var after_relation_metrics := service.get_metrics()
	_expect(
		int(after_relation_metrics["current_position_refresh_steps_total"]) == 1
		and int(after_relation_metrics["last_current_position_refresh_tick"])
			== PHYSICS_TICK
		and not service.has_planned_directed_contact(first, second)
		and not service.has_planned_directed_contact(second, first)
		and is_equal_approx(
			service.get_directed_safe_motion_fraction(first, second),
			1.0
		),
		"A same-tick no-hostile to hostile transition must refresh current positions before TOI."
	)
	service.clear()
	service.free()


func _test_stale_entry_pruned_after_relation_revision() -> void:
	const LIVE_FACTION := 5
	const STALE_FACTION := 6
	var service := SERVICE.new()
	service.automatic_physics_step = false
	var relations := RELATIONS.new()
	service.set_relation_service(relations)
	var live_enemy := FixtureEnemy.new()
	var stale_enemy := FixtureEnemy.new()
	fixtures.append(live_enemy)
	fixtures.append(stale_enemy)
	var circle := CircleShape2D.new()
	circle.radius = 2.0
	var proxy = PROXY.create(circle)
	_expect(
		service.register_enemy(
			live_enemy,
			501,
			LIVE_FACTION,
			proxy,
			proxy
		)
		and service.register_enemy(
			stale_enemy,
			502,
			STALE_FACTION,
			proxy,
			proxy
		),
		"Stale-cache fixtures must register before the false result is cached."
	)
	var query_counter := {"value": 0}
	service.set_hostile_aabb_query(
		func(
			_world_aabb: Rect2,
			_source_faction_id: int,
			_excluded_entity: Node2D,
			result: Array[Node2D]
		) -> void:
			query_counter["value"] = int(query_counter["value"]) + 1
			result.clear()
	)
	service.request_mode(SERVICE.Mode.HYBRID_ENEMY_CONTACT)
	service.step(1)
	service.step_planned(1.0 / 60.0, 1)
	var cached_metrics := service.get_metrics()
	stale_enemy.free()
	_expect(
		relations.set_hostile(LIVE_FACTION, STALE_FACTION, true),
		"Changing a relation after an entry becomes stale must advance the cache key."
	)
	service.step(2)
	service.step_planned(1.0 / 60.0, 2)
	var pruned_metrics := service.get_metrics()
	_expect(
		int(pruned_metrics["registered_count"]) == 1
		and int(pruned_metrics["stale_pruned_total"]) == 1
		and int(pruned_metrics["stale_prune_scans_total"])
			== int(cached_metrics["stale_prune_scans_total"]) + 1
		and int(pruned_metrics["current_position_refresh_steps_total"]) == 0
		and int(pruned_metrics["planned_position_refresh_steps_total"]) == 0
		and int(query_counter["value"]) == 0
		and not service.has_registered_hostile_pair(),
		"A relation revision must force one stale prune before re-entering the no-hostile fast path."
	)
	service.clear()
	service.free()


func _test_shadow_events_faction_sweep_and_order() -> void:
	var service := SERVICE.new()
	service.automatic_physics_step = false
	var attacker_30 := _make_fixture(&"attacker_30", Vector2.ZERO, RELATIONS.PLAYER_ALLIED)
	var hostile_10 := _make_fixture(&"hostile_10", Vector2(10.0, 0.0), RELATIONS.HOSTILE_WAVE)
	var hostile_20 := _make_fixture(&"hostile_20", Vector2(-10.0, 0.0), RELATIONS.HOSTILE_WAVE)
	var neutral_40 := _make_fixture(&"neutral_40", Vector2.ZERO, RELATIONS.NEUTRAL)
	var fixtures_by_id := {
		10: hostile_10,
		20: hostile_20,
		30: attacker_30,
		40: neutral_40,
	}
	# Deliberately register out of order. Dispatch and event ordering must still
	# follow stable simulation IDs rather than Dictionary or query order.
	for simulation_id in [30, 40, 20, 10]:
		var fixture: FixtureEnemy = fixtures_by_id[simulation_id]
		_expect(
			service.register_enemy(
				fixture,
				simulation_id,
				faction_by_instance_id[fixture.get_instance_id()],
				proxy_by_instance_id[fixture.get_instance_id()]
			),
			"Fixture %d must register exactly once." % simulation_id
		)
	_expect(
		not service.register_enemy(
			attacker_30,
			31,
			RELATIONS.PLAYER_ALLIED,
			proxy_by_instance_id[attacker_30.get_instance_id()]
		),
		"An entity must not register under two simulation IDs."
	)
	var unsupported := PROXY.create(WorldBoundaryShape2D.new())
	var rejected_fixture := FixtureEnemy.new()
	fixtures.append(rejected_fixture)
	_expect(
		not service.register_enemy(
			rejected_fixture,
			50,
			RELATIONS.HOSTILE_WAVE,
			unsupported
		),
		"Unsupported shape proxies must fail closed at registration."
	)

	service.set_hostile_aabb_query(
		func(
			world_aabb: Rect2,
			_source_faction_id: int,
			excluded_entity: Node2D,
			result: Array
		) -> void:
			result.clear()
			for fixture_index in range(fixtures.size() - 1, -1, -1):
				var fixture := fixtures[fixture_index]
				if fixture == excluded_entity or not is_instance_valid(fixture):
					continue
				var fixture_proxy: CombatContactShapeProxy = proxy_by_instance_id.get(
					fixture.get_instance_id()
				)
				if fixture_proxy == null:
					continue
				if world_aabb.intersects(
					fixture_proxy.get_world_aabb_at(fixture.position),
					true
				):
					result.append(fixture)
					result.append(fixture) # Duplicate broad-phase noise is canonicalized.
	)
	service.set_observed_contacts_provider(
		func(source: Node2D, result: Array) -> void:
			result.clear()
			result.append_array(
				observed_by_instance_id.get(source.get_instance_id(), [])
			)
	)

	_set_observed_pair(attacker_30, hostile_10, true)
	_set_observed_pair(attacker_30, hostile_20, true)
	service.request_mode(SERVICE.Mode.SHADOW)
	service.step(1)
	_expect(
		_event_signatures(service.get_last_predicted_events()) == [
			"10>30:ENTER",
			"20>30:ENTER",
			"30>10:ENTER",
			"30>20:ENTER",
		],
		"Simultaneous ENTER events must use stable attacker/target simulation-ID order."
	)
	_expect(
		service.get_last_candidate_order() == [
			Vector2i(10, 30),
			Vector2i(20, 30),
			Vector2i(30, 10),
			Vector2i(30, 20),
		],
		"Reversed duplicate broad-phase results must canonicalize to stable order."
	)
	_expect(
		service.get_differences().is_empty(),
		"Matching shadow ENTER observations must produce zero differences."
	)
	_expect(
		service.has_directed_contact(attacker_30, hostile_10)
		and not service.has_directed_contact(attacker_30, neutral_40),
		"Directed contact lookup must reuse the completed snapshot without allocating."
	)

	service.step(2)
	_expect(
		_event_signatures(service.get_last_predicted_events()) == [
			"10>30:STAY",
			"20>30:STAY",
			"30>10:STAY",
			"30>20:STAY",
		],
		"Persistent contacts must become deterministic STAY events."
	)
	_expect(
		service.get_differences().is_empty(),
		"Matching shadow STAY observations must produce zero differences."
	)

	# A runtime faction change invalidates both directed contacts on the next tick.
	_expect(
		service.update_faction(
			hostile_10,
			RELATIONS.HOSTILE_WAVE,
			RELATIONS.PLAYER_ALLIED
		),
		"Runtime faction migration must update an existing contact entry."
	)
	faction_by_instance_id[hostile_10.get_instance_id()] = RELATIONS.PLAYER_ALLIED
	_set_observed_pair(attacker_30, hostile_10, false)
	hostile_10.position = Vector2(100.0, 0.0)
	service.step(3)
	var faction_events := _event_signatures(service.get_last_predicted_events())
	_expect(
		faction_events.has("10>30:EXIT") and faction_events.has("30>10:EXIT"),
		"A target becoming friendly must emit both directed EXIT events."
	)
	_expect(
		service.get_differences().is_empty(),
		"Faction-change exits must remain comparable with legacy observations."
	)
	_expect(
		not service.has_directed_contact(attacker_30, hostile_10),
		"A faction-change EXIT must disappear from directed contact lookup."
	)

	# Current contact must follow the current transform immediately. A previous
	# frame's departure sweep is never retained as future-looking contact state.
	hostile_20.position = Vector2(-30.0, 0.0)
	_set_observed_pair(attacker_30, hostile_20, false)
	service.step(4)
	var separation_events := _event_signatures(service.get_last_predicted_events())
	_expect(
		separation_events.has("20>30:EXIT") and separation_events.has("30>20:EXIT"),
		"Current separation must emit deterministic EXIT events without a stale sweep."
	)
	_expect(
		service.get_differences().is_empty(),
		"Swept departure and subsequent exit must match supplied observations."
	)

	# Return to the closed current shell.
	hostile_20.position = Vector2(-10.0, 0.0)
	_set_observed_pair(attacker_30, hostile_20, true)
	service.step(5)
	var swept_events := _event_signatures(service.get_last_predicted_events())
	_expect(
		swept_events.has("20>30:ENTER") and swept_events.has("30>20:ENTER"),
		"Returning to the current shell must emit ENTER."
	)
	_expect(
		service.get_differences().is_empty(),
		"Matching swept ENTER observations must remain difference-free."
	)

	# Deliberately withhold observations long enough to prove the bounded ring.
	_set_observed_pair(attacker_30, hostile_20, false)
	for tick in range(6, 46):
		service.step(tick)
	var metrics: Dictionary = service.get_metrics()
	_expect(
		int(metrics["difference_buffer_size"]) == SERVICE.MAX_DIFFERENCES,
		"Shadow differences must retain at most 64 recent records."
	)
	_expect(
		int(metrics["difference_overflow_total"]) > 0
		and int(metrics["differences_total"]) > SERVICE.MAX_DIFFERENCES,
		"Difference overflow must be counted without growing the bounded buffer."
	)
	_expect(
		int(metrics["faction_updates_total"]) == 1
		and int(metrics["narrow_phase_tests_total"]) > 0,
		"Metrics must expose faction and current narrow-phase work."
	)

	service.request_mode(SERVICE.Mode.AUTHORITATIVE)
	service.step(46)
	_expect(
		service.mode == SERVICE.Mode.AUTHORITATIVE,
		"SHADOW to AUTHORITATIVE must apply on a tick boundary."
	)
	service.request_mode(SERVICE.Mode.DISABLED)
	service.step(47)
	_expect(
		service.mode == SERVICE.Mode.RESTORING,
		"Authoritative rollback must spend one full tick in RESTORING."
	)
	service.step(48)
	_expect(
		service.mode == SERVICE.Mode.DISABLED,
		"RESTORING must complete at the following tick boundary."
	)
	metrics = service.get_metrics()
	_expect(
		int(metrics["restorations_started"]) == 1
		and int(metrics["restorations_completed"]) == 1
		and int(metrics["restoring_ticks"]) == 1,
		"Rollback transition metrics must account for the complete restoring tick."
	)
	_expect(
		service.unregister_enemy(attacker_30, 30)
		and not service.unregister_enemy(attacker_30, 30),
		"Unregistration must validate ownership and be idempotently rejectable."
	)
	service.clear()
	_expect(
		int(service.get_metrics()["registered_count"]) == 0,
		"clear() must release the complete contact registry."
	)
	service.free()


func _test_directed_attack_shell_uses_target_body() -> void:
	var service := SERVICE.new()
	service.automatic_physics_step = false
	var attacker := FixtureEnemy.new()
	var target := FixtureEnemy.new()
	attacker.position = Vector2.ZERO
	target.position = Vector2(10.0, 0.0)
	fixtures.append(attacker)
	fixtures.append(target)

	var attacker_touch_shape := CircleShape2D.new()
	attacker_touch_shape.radius = 3.0
	var attacker_body_shape := CircleShape2D.new()
	attacker_body_shape.radius = 1.0
	var target_touch_shape := CircleShape2D.new()
	# A large target attack shell must never enlarge the attacker's directed
	# stop shell. The target body remains one pixel in radius.
	target_touch_shape.radius = 50.0
	var target_body_shape := CircleShape2D.new()
	target_body_shape.radius = 1.0
	_expect(
		service.register_enemy(
			attacker,
			1,
			RELATIONS.PLAYER_ALLIED,
			PROXY.create(attacker_touch_shape),
			PROXY.create(attacker_body_shape)
		)
		and service.register_enemy(
			target,
			2,
			RELATIONS.HOSTILE_WAVE,
			PROXY.create(target_touch_shape),
			PROXY.create(target_body_shape)
		),
		"Directed shell fixtures must register both attack and body proxies."
	)
	service.set_hostile_aabb_query(
		func(
			_world_aabb: Rect2,
			_source_faction_id: int,
			excluded_entity: Node2D,
			result: Array[Node2D]
		) -> void:
			result.clear()
			if attacker != excluded_entity:
				result.append(attacker)
			if target != excluded_entity:
				result.append(target)
	)
	service.request_mode(SERVICE.Mode.HYBRID_ENEMY_CONTACT)
	service.step(1)
	_expect(
		not service.has_directed_contact(attacker, target)
		and service.has_directed_contact(target, attacker),
		"Narrow phase must use source touch shell against target body, not touch against touch."
	)
	_expect(
		StringName(service.get_metrics()["authoritative_scope"])
		== &"ENEMY_TO_ENEMY_ONLY",
		"Hybrid mode must explicitly report its enemy-only authority boundary."
	)
	target.position = Vector2(4.0, 0.0)
	service.step(2)
	_expect(
		service.has_directed_contact(attacker, target),
		"The directed shell must close exactly at attack radius plus target body radius."
	)
	service.free()


func _test_planned_sweep_is_separate_from_current_contact() -> void:
	var service := SERVICE.new()
	service.automatic_physics_step = false
	var attacker := FixtureEnemy.new()
	var target := FixtureEnemy.new()
	attacker.position = Vector2(-20.0, 0.0)
	target.position = Vector2(20.0, 0.0)
	fixtures.append(attacker)
	fixtures.append(target)
	var planned_attacker_position := Vector2(20.0, 0.0)
	var planned_target_position := Vector2(-20.0, 0.0)
	var circle := CircleShape2D.new()
	circle.radius = 2.0
	var proxy = PROXY.create(circle)
	_expect(
		service.register_enemy(
			attacker,
			101,
			RELATIONS.PLAYER_ALLIED,
			proxy,
			proxy,
			Callable(),
			Callable(),
			func(_delta: float) -> Vector2: return planned_attacker_position,
			func(_delta: float) -> Vector2: return planned_attacker_position,
			func(_delta: float, _counterpart: Node2D) -> bool: return true,
			func() -> Node2D: return target
		)
		and service.register_enemy(
			target,
			102,
			RELATIONS.HOSTILE_WAVE,
			proxy,
			proxy,
			Callable(),
			Callable(),
			func(_delta: float) -> Vector2: return planned_target_position,
			func(_delta: float) -> Vector2: return planned_target_position,
			func(_delta: float, _counterpart: Node2D) -> bool: return true,
			func() -> Node2D: return attacker
		),
		"Planned-sweep fixtures must register explicit future position providers."
	)
	service.set_hostile_aabb_query(
		func(
			_world_aabb: Rect2,
			_source_faction_id: int,
			excluded_entity: Node2D,
			result: Array[Node2D]
		) -> void:
			result.clear()
			if attacker != excluded_entity:
				result.append(attacker)
			if target != excluded_entity:
				result.append(target)
	)
	service.request_mode(SERVICE.Mode.HYBRID_ENEMY_CONTACT)
	service.step(1)
	_expect(
		not service.has_directed_contact(attacker, target),
		"A future crossing must not be exposed as current contact."
	)
	service.step_planned(1.0 / 60.0, 1)
	var attacker_fraction := service.get_directed_safe_motion_fraction(
		attacker,
		target
	)
	var target_fraction := service.get_directed_safe_motion_fraction(
		target,
		attacker
	)
	_expect(
		service.has_planned_directed_contact(attacker, target)
		and not service.has_directed_contact(attacker, target),
		"Planned swept contact and current overlap must remain separate snapshots."
	)
	_expect(
		absf(attacker_fraction - 0.45) <= 0.00002
		and absf(target_fraction - 0.45) <= 0.00002,
		"Opposing high-speed plans must expose the analytic directed TOI fraction."
	)
	attacker.position = attacker.position.lerp(
		planned_attacker_position,
		attacker_fraction
	)
	target.position = target.position.lerp(
		planned_target_position,
		target_fraction
	)
	service.step(2)
	_expect(
		service.has_directed_contact(attacker, target)
		and attacker.position.x <= target.position.x,
		"TOI-clipped transforms must finish on the shell without crossing sides."
	)
	var metrics: Dictionary = service.get_metrics()
	_expect(
		int(metrics["planned_steps_total"]) == 1
		and int(metrics["swept_hits_total"]) >= 2
		and int(metrics["toi_solves_total"]) >= 2,
		"Planned sweep metrics must expose continuous narrow-phase and TOI work."
	)
	service.free()


func _test_uncommitted_target_plan_remains_shadow() -> void:
	var service := SERVICE.new()
	service.automatic_physics_step = false
	var attacker := FixtureEnemy.new()
	var target := FixtureEnemy.new()
	attacker.position = Vector2.ZERO
	target.position = Vector2(13.0, 0.0)
	fixtures.append(attacker)
	fixtures.append(target)
	var attacker_plan := Vector2(10.0, 0.0)
	var target_plan := Vector2(5.0, 0.0)
	var third_target := Enemy.new()
	var circle := CircleShape2D.new()
	circle.radius = 2.0
	var proxy = PROXY.create(circle)
	service.register_enemy(
		attacker,
		201,
		RELATIONS.PLAYER_ALLIED,
		proxy,
		proxy,
		Callable(),
		Callable(),
		func(_delta: float) -> Vector2: return attacker_plan,
		func(_delta: float) -> Vector2: return attacker_plan,
		func(_delta: float, _counterpart: Node2D) -> bool: return true,
		func() -> Node2D: return target
	)
	service.register_enemy(
		target,
		202,
		RELATIONS.HOSTILE_WAVE,
		proxy,
		proxy,
		Callable(),
		Callable(),
		func(_delta: float) -> Vector2: return target_plan,
		func(_delta: float) -> Vector2: return target_plan,
		func(_delta: float, _counterpart: Node2D) -> bool: return true,
		func() -> Node2D: return third_target
	)
	service.set_hostile_aabb_query(
		func(
			_world_aabb: Rect2,
			_source_faction_id: int,
			excluded_entity: Node2D,
			result: Array[Node2D]
		) -> void:
			result.clear()
			result.append(target if excluded_entity == attacker else attacker)
	)
	service.request_mode(SERVICE.Mode.HYBRID_ENEMY_CONTACT)
	service.step(1)
	service.step_planned(1.0 / 60.0, 1)
	_expect(
		is_equal_approx(
			service.get_directed_safe_motion_fraction(attacker, target),
			1.0
		)
		and service.has_planned_directed_contact(attacker, target),
		"A target committed to a third enemy must remain shadow-only instead of false-stopping."
	)
	_expect(
		int(service.get_metrics()["uncommitted_pair_shadow_hits_total"]) > 0,
		"Skipped uncommitted pair authority must be visible in service metrics."
	)
	service.free()
	third_target.free()


func _test_offset_body_anchor_is_kept_in_broad_phase() -> void:
	var service := SERVICE.new()
	service.automatic_physics_step = false
	var attacker := FixtureEnemy.new()
	var offset_target := FixtureEnemy.new()
	attacker.position = Vector2.ZERO
	offset_target.position = Vector2(100.0, 0.0)
	fixtures.append(attacker)
	fixtures.append(offset_target)
	var circle := CircleShape2D.new()
	circle.radius = 2.0
	var proxy = PROXY.create(circle)
	service.register_enemy(
		attacker,
		301,
		RELATIONS.PLAYER_ALLIED,
		proxy,
		proxy
	)
	service.register_enemy(
		offset_target,
		302,
		RELATIONS.HOSTILE_WAVE,
		proxy,
		proxy,
		Callable(),
		func() -> Vector2: return Vector2(3.0, 0.0)
	)
	service.set_hostile_aabb_query(
		func(
			world_aabb: Rect2,
			_source_faction_id: int,
			excluded_entity: Node2D,
			result: Array[Node2D]
		) -> void:
			result.clear()
			for candidate in [attacker, offset_target]:
				if (
					candidate != excluded_entity
					and world_aabb.has_point(candidate.global_position)
				):
					result.append(candidate)
	)
	service.request_mode(SERVICE.Mode.HYBRID_ENEMY_CONTACT)
	service.step(1)
	_expect(
		service.has_directed_contact(attacker, offset_target),
		"Broad phase must grow by body center offset from the indexed enemy root anchor."
	)
	service.free()


func _make_fixture(
	fixture_name: StringName,
	fixture_position: Vector2,
	faction_id: int
) -> FixtureEnemy:
	var fixture := FixtureEnemy.new()
	fixture.fixture_name = fixture_name
	fixture.position = fixture_position
	fixtures.append(fixture)
	var circle := CircleShape2D.new()
	circle.radius = 5.0
	proxy_by_instance_id[fixture.get_instance_id()] = PROXY.create(circle)
	faction_by_instance_id[fixture.get_instance_id()] = faction_id
	observed_by_instance_id[fixture.get_instance_id()] = []
	return fixture


func _set_observed_pair(first: Node2D, second: Node2D, active: bool) -> void:
	_set_observed_direction(first, second, active)
	_set_observed_direction(second, first, active)


func _set_observed_direction(source: Node2D, target: Node2D, active: bool) -> void:
	var contacts := observed_by_instance_id[source.get_instance_id()] as Array
	if active and not contacts.has(target):
		contacts.append(target)
	elif not active:
		contacts.erase(target)


func _event_signatures(events: Array[Dictionary]) -> Array[String]:
	var result: Array[String] = []
	for event in events:
		result.append("%d>%d:%s" % [
			int(event["attacker_simulation_id"]),
			int(event["target_simulation_id"]),
			String(event["event_name"]),
		])
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
