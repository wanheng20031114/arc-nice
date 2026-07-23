extends SceneTree

# Dense, same-cohort A/B for the production guardian-aura hot path. Both modes
# run against the same live nodes in interleaved order, and every measurement is
# rejected unless each enemy has the exact same sorted source-id/bonus signature.
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const GUARDIAN_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_guardian.tres"
)
const GUARDIAN_SYSTEM_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/guardian_aura_system.tscn"
)

const ENEMY_COUNT := 300
const GUARDIAN_COUNT := 36
const SAMPLE_PAIRS := 10
const COHORT_COLUMNS := 50
const COHORT_SPACING := Vector2(16.0, 24.0)
const ARCHITECTURE_COLUMNS := 25
# Keep adjacent bodies inside the authored aura's exact overlap boundary while
# removing the artificial 40 px horde packing. The fixture still owns 135 real
# source links, but now measures spatial pruning across a map-sized footprint.
const ARCHITECTURE_SPACING := Vector2(50.0, 50.0)

var failures: Array[String] = []
var catch_up_unrestricted_targets := 0
var catch_up_limited_targets := 0
var two_tick_debt_repayment_targets := 0
var catch_up_unrestricted_ms := 0.0
var catch_up_limited_ms := 0.0
var source_catch_up_refreshes := 0
var source_convergence_refreshes := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Node2D.new()
	fixture.name = "GuardianAuraDensePerformanceAB"
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	fixture.add_child(enemy_container)
	var boss_container := Node2D.new()
	boss_container.name = "BossContainer"
	fixture.add_child(boss_container)
	root.add_child(fixture)

	var guardian_system := GUARDIAN_SYSTEM_SCENE.instantiate() as GuardianAuraSystem
	fixture.add_child(guardian_system)
	guardian_system.set_physics_process(false)
	var combat_target_index := CombatTargetIndex.new()

	var enemies: Array[Enemy] = []
	var guardians: Array[Enemy] = []
	var spawned_guardians := 0
	for enemy_index in range(ENEMY_COUNT):
		var use_guardian := enemy_index % 8 == 0 and spawned_guardians < GUARDIAN_COUNT
		var enemy_config: EnemyConfig = GUARDIAN_CONFIG if use_guardian else BASIC_CONFIG
		var enemy := enemy_config.enemy_scene.instantiate() as Enemy
		enemy_container.add_child(enemy)
		enemy.setup(enemy_config, null, null)
		enemy.configure_multiplayer_proxy()
		enemy.global_position = Vector2(
			float(enemy_index % COHORT_COLUMNS) * COHORT_SPACING.x,
			float(enemy_index / COHORT_COLUMNS) * COHORT_SPACING.y
		)
		combat_target_index.register_enemy(enemy_index + 1, enemy)
		enemies.append(enemy)
		if use_guardian:
			spawned_guardians += 1
			guardians.append(enemy)

	_expect(
		spawned_guardians == GUARDIAN_COUNT,
		"Dense A/B fixture did not create the authored guardian count."
	)
	await process_frame
	await physics_frame
	guardian_system.set_physics_process(false)

	# Warm both code paths and establish the reference source signature before
	# timing. Timed samples therefore measure steady membership maintenance, not
	# one mode receiving all modifier mutations first.
	GuardianAuraSystem.source_driven_refresh_enabled = false
	guardian_system.use_snapshot_coverage_grid = false
	guardian_system.force_refresh_all()
	var reference_signature := _get_source_signature(guardian_system, enemies)
	var reference_source_links := _get_source_link_count(guardian_system)
	_expect(
		guardian_system.get_guardian_count() == GUARDIAN_COUNT,
		"Dense A/B system did not classify every guardian source."
	)
	_expect(
		reference_source_links > GUARDIAN_COUNT,
		"Dense A/B fixture produced no meaningful overlapping source cohort."
	)
	guardian_system.use_snapshot_coverage_grid = true
	guardian_system.use_extent_overlap_certificates = false
	guardian_system.force_refresh_all()
	_expect(
		_get_source_signature(guardian_system, enemies) == reference_signature,
		"Snapshot coverage grid changed the dense cohort source signature."
	)
	_expect(
		guardian_system.active_guardian_source_ids.size() == GUARDIAN_COUNT,
		"Snapshot grid did not materialize one compact slot per guardian."
	)
	guardian_system.use_extent_overlap_certificates = true
	guardian_system.force_refresh_all()
	_expect(
		_get_source_signature(guardian_system, enemies) == reference_signature,
		"Extent overlap certificates changed the dense cohort source signature."
	)
	GuardianAuraSystem.source_driven_refresh_enabled = true
	guardian_system.reset_runtime_performance_metrics()
	guardian_system.force_refresh_all()
	_expect(
		_get_source_signature(guardian_system, enemies) == reference_signature,
		"Indexed source-driven refresh changed the dense cohort source signature."
	)
	_expect(
		guardian_system.source_index_query_count == GUARDIAN_COUNT
		and guardian_system.source_fallback_scan_count == 0,
		"Production source-driven refresh did not issue exactly one local index query per guardian."
	)
	GuardianAuraSystem.source_driven_refresh_enabled = false

	var legacy_samples: Array[float] = []
	var snapshot_samples: Array[float] = []
	for pair_index in range(SAMPLE_PAIRS):
		if pair_index % 2 == 0:
			_run_measured_mode(
				guardian_system,
				enemies,
				false,
				reference_signature,
				legacy_samples
			)
			_run_measured_mode(
				guardian_system,
				enemies,
				true,
				reference_signature,
				snapshot_samples
			)
		else:
			_run_measured_mode(
				guardian_system,
				enemies,
				true,
				reference_signature,
				snapshot_samples
			)
			_run_measured_mode(
				guardian_system,
				enemies,
				false,
				reference_signature,
				legacy_samples
			)

	var legacy_median_ms := _median(legacy_samples)
	var snapshot_median_ms := _median(snapshot_samples)
	var speedup := legacy_median_ms / maxf(snapshot_median_ms, 0.000001)
	_expect(
		snapshot_median_ms < legacy_median_ms,
		"Snapshot coverage grid did not beat the legacy dense-cohort median."
	)

	var exact_samples: Array[float] = []
	var certified_samples: Array[float] = []
	for pair_index in range(SAMPLE_PAIRS):
		if pair_index % 2 == 0:
			_run_measured_certificate_mode(
				guardian_system,
				enemies,
				false,
				reference_signature,
				exact_samples
			)
			_run_measured_certificate_mode(
				guardian_system,
				enemies,
				true,
				reference_signature,
				certified_samples
			)
		else:
			_run_measured_certificate_mode(
				guardian_system,
				enemies,
				true,
				reference_signature,
				certified_samples
			)
			_run_measured_certificate_mode(
				guardian_system,
				enemies,
				false,
				reference_signature,
				exact_samples
			)
	var exact_median_ms := _median(exact_samples)
	var certified_median_ms := _median(certified_samples)
	var certificate_speedup := exact_median_ms / maxf(certified_median_ms, 0.000001)
	_expect(
		certified_median_ms < exact_median_ms,
		"Extent certificates did not beat the exact-only snapshot median."
	)

	var dense_target_driven_samples: Array[float] = []
	var dense_source_driven_samples: Array[float] = []
	for pair_index in range(SAMPLE_PAIRS):
		if pair_index % 2 == 0:
			_run_measured_architecture_mode(
				guardian_system,
				enemies,
				false,
				reference_signature,
				dense_target_driven_samples
			)
			_run_measured_architecture_mode(
				guardian_system,
				enemies,
				true,
				reference_signature,
				dense_source_driven_samples
			)
		else:
			_run_measured_architecture_mode(
				guardian_system,
				enemies,
				true,
				reference_signature,
				dense_source_driven_samples
			)
			_run_measured_architecture_mode(
				guardian_system,
				enemies,
				false,
				reference_signature,
				dense_target_driven_samples
			)
	var dense_target_driven_median_ms := _median(dense_target_driven_samples)
	var dense_source_driven_median_ms := _median(dense_source_driven_samples)
	var dense_source_cost_ratio := (
		dense_source_driven_median_ms
		/ maxf(dense_target_driven_median_ms, 0.000001)
	)
	var dense_paired_cost_ratio := _median_paired_cost_ratio(
		dense_source_driven_samples,
		dense_target_driven_samples
	)
	# Each array slot comes from one adjacent, order-interleaved A/B pair. Its
	# ratio cancels transient host load much more reliably than dividing two
	# independently selected medians. The fully connected strip is the deliberate
	# worst case for source queries, so production only needs a bounded margin.
	_expect(
		dense_paired_cost_ratio <= 1.25,
		"Source-driven refresh regressed the maximally dense cohort by more than 25%%."
	)

	# The certificate/grid test above intentionally packs all 300 enemies into a
	# narrow worst-case strip. Architecture timings use the same nodes and index
	# after spreading them across a map-sized cohort: the source-driven design is
	# specifically intended to prune empty world space, not claim that 36 local
	# bucket queries beat one target grid in a maximally overlapping blob.
	for enemy_index in range(enemies.size()):
		enemies[enemy_index].global_position = Vector2(
			float(enemy_index % ARCHITECTURE_COLUMNS) * ARCHITECTURE_SPACING.x,
			float(enemy_index / ARCHITECTURE_COLUMNS) * ARCHITECTURE_SPACING.y
		)
	GuardianAuraSystem.source_driven_refresh_enabled = false
	guardian_system.use_snapshot_coverage_grid = true
	guardian_system.use_extent_overlap_certificates = true
	guardian_system.force_refresh_all()
	var architecture_reference_signature := _get_source_signature(
		guardian_system,
		enemies
	)
	var architecture_source_links := _get_source_link_count(guardian_system)
	guardian_system.reset_runtime_performance_metrics()
	GuardianAuraSystem.source_driven_refresh_enabled = true
	guardian_system.force_refresh_all()
	_expect(
		_get_source_signature(guardian_system, enemies)
			== architecture_reference_signature
		and guardian_system.source_index_query_count == GUARDIAN_COUNT
		and guardian_system.source_fallback_scan_count == 0,
		"Map-sized source warm-up must preserve membership through local index queries."
	)
	GuardianAuraSystem.source_driven_refresh_enabled = false
	_expect(
		architecture_source_links > GUARDIAN_COUNT,
		"Map-sized architecture fixture produced no meaningful aura overlap."
	)

	var target_driven_samples: Array[float] = []
	var source_driven_samples: Array[float] = []
	for pair_index in range(SAMPLE_PAIRS):
		if pair_index % 2 == 0:
			_run_measured_architecture_mode(
				guardian_system,
				enemies,
				false,
				architecture_reference_signature,
				target_driven_samples
			)
			_run_measured_architecture_mode(
				guardian_system,
				enemies,
				true,
				architecture_reference_signature,
				source_driven_samples
			)
		else:
			_run_measured_architecture_mode(
				guardian_system,
				enemies,
				true,
				architecture_reference_signature,
				source_driven_samples
			)
			_run_measured_architecture_mode(
				guardian_system,
				enemies,
				false,
				architecture_reference_signature,
				target_driven_samples
			)
	var target_driven_median_ms := _median(target_driven_samples)
	var source_driven_median_ms := _median(source_driven_samples)
	var source_driven_speedup := (
		target_driven_median_ms / maxf(source_driven_median_ms, 0.000001)
	)
	var architecture_paired_cost_ratio := _median_paired_cost_ratio(
		source_driven_samples,
		target_driven_samples
	)
	_expect(
		architecture_paired_cost_ratio < 0.9,
		"Indexed source-driven refresh did not beat target-driven refresh."
	)

	GuardianAuraSystem.source_driven_refresh_enabled = false
	guardian_system.use_snapshot_coverage_grid = true
	guardian_system.use_extent_overlap_certificates = false
	guardian_system.collect_overlap_query_metrics = true
	guardian_system.reset_overlap_query_metrics()
	guardian_system.force_refresh_all()
	guardian_system.collect_overlap_query_metrics = false
	var exact_candidate_count := guardian_system.overlap_candidate_count
	_expect(
		guardian_system.overlap_exact_fallback_count == exact_candidate_count,
		"Exact-only mode must route every candidate through collision-shape fallback."
	)

	guardian_system.use_extent_overlap_certificates = true
	guardian_system.collect_overlap_query_metrics = true
	guardian_system.reset_overlap_query_metrics()
	guardian_system.force_refresh_all()
	guardian_system.collect_overlap_query_metrics = false
	var certified_candidate_count := guardian_system.overlap_candidate_count
	var exact_fallback_count := guardian_system.overlap_exact_fallback_count
	_expect(
		certified_candidate_count == exact_candidate_count
		and certified_candidate_count > 0
		and exact_fallback_count < certified_candidate_count,
		"Extent certificates did not remove any exact collision-shape queries."
	)
	_expect(
		guardian_system.overlap_fast_accept_count
		+ guardian_system.overlap_fast_reject_count
		+ exact_fallback_count
		== certified_candidate_count,
		"Certificate counters must partition every guardian-target candidate exactly once."
	)
	_test_render_frame_catch_up_limit(
		guardian_system,
		enemies,
		guardians,
		architecture_reference_signature
	)
	_test_source_driven_render_frame_catch_up_limit(
		guardian_system,
		enemies,
		guardians
	)
	print(
		(
			"GUARDIAN_AURA_DENSE_AB enemies=%d guardians=%d samples=%d "
			+ "source_links=%d legacy_median_ms=%.3f snapshot_median_ms=%.3f speedup=%.3fx "
			+ "exact_median_ms=%.3f certified_median_ms=%.3f certificate_speedup=%.3fx "
			+ "target_driven_median_ms=%.3f source_driven_median_ms=%.3f "
			+ "source_driven_speedup=%.3fx "
			+ "dense_target_driven_median_ms=%.3f dense_source_driven_median_ms=%.3f "
			+ "dense_source_cost_ratio=%.3fx "
			+ "dense_paired_cost_ratio=%.3fx architecture_paired_cost_ratio=%.3fx "
			+ "architecture_source_links=%d "
			+ "candidates=%d fast_accept=%d fast_reject=%d exact_fallback=%d "
			+ "catchup_unrestricted_targets=%d catchup_limited_targets=%d "
			+ "two_tick_debt_repayment_targets=%d "
			+ "catchup_unrestricted_ms=%.3f catchup_limited_ms=%.3f "
			+ "source_catchup_refreshes=%d source_convergence_refreshes=%d "
			+ "source_signature=%s"
		)
		% [
			ENEMY_COUNT,
			GUARDIAN_COUNT,
			SAMPLE_PAIRS,
			reference_source_links,
			legacy_median_ms,
			snapshot_median_ms,
			speedup,
			exact_median_ms,
			certified_median_ms,
			certificate_speedup,
			target_driven_median_ms,
			source_driven_median_ms,
			source_driven_speedup,
			dense_target_driven_median_ms,
			dense_source_driven_median_ms,
			dense_source_cost_ratio,
			dense_paired_cost_ratio,
			architecture_paired_cost_ratio,
			architecture_source_links,
			certified_candidate_count,
			guardian_system.overlap_fast_accept_count,
			guardian_system.overlap_fast_reject_count,
			exact_fallback_count,
			catch_up_unrestricted_targets,
			catch_up_limited_targets,
			two_tick_debt_repayment_targets,
			catch_up_unrestricted_ms,
			catch_up_limited_ms,
			source_catch_up_refreshes,
			source_convergence_refreshes,
			architecture_reference_signature.sha256_text(),
		]
	)

	combat_target_index.clear()
	GuardianAuraSystem.source_driven_refresh_enabled = true
	fixture.queue_free()
	await process_frame
	await physics_frame
	if failures.is_empty():
		print("GUARDIAN_AURA_DENSE_PERFORMANCE_AB_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_measured_mode(
	system: GuardianAuraSystem,
	enemies: Array[Enemy],
	use_snapshot: bool,
	reference_signature: String,
	samples: Array[float]
) -> void:
	GuardianAuraSystem.source_driven_refresh_enabled = false
	system.use_snapshot_coverage_grid = use_snapshot
	system.use_extent_overlap_certificates = true
	var started_usec := Time.get_ticks_usec()
	system.force_refresh_all()
	samples.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)
	_expect(
		_get_source_signature(system, enemies) == reference_signature,
		"%s mode changed the dense cohort source signature."
		% ("snapshot" if use_snapshot else "legacy")
	)


func _run_measured_certificate_mode(
	system: GuardianAuraSystem,
	enemies: Array[Enemy],
	use_certificates: bool,
	reference_signature: String,
	samples: Array[float]
) -> void:
	GuardianAuraSystem.source_driven_refresh_enabled = false
	system.use_snapshot_coverage_grid = true
	system.use_extent_overlap_certificates = use_certificates
	var started_usec := Time.get_ticks_usec()
	system.force_refresh_all()
	samples.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)
	_expect(
		_get_source_signature(system, enemies) == reference_signature,
		"%s certificate mode changed the dense cohort source signature."
		% ("enabled" if use_certificates else "exact-only")
	)


func _run_measured_architecture_mode(
	system: GuardianAuraSystem,
	enemies: Array[Enemy],
	use_source_driven: bool,
	reference_signature: String,
	samples: Array[float]
) -> void:
	GuardianAuraSystem.source_driven_refresh_enabled = use_source_driven
	system.use_snapshot_coverage_grid = true
	system.use_extent_overlap_certificates = true
	var started_usec := Time.get_ticks_usec()
	system.force_refresh_all()
	samples.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)
	_expect(
		_get_source_signature(system, enemies) == reference_signature,
		"%s architecture changed the dense cohort source signature."
		% ("source-driven" if use_source_driven else "target-driven")
	)


func _test_render_frame_catch_up_limit(
	system: GuardianAuraSystem,
	enemies: Array[Enemy],
	guardians: Array[Enemy],
	original_signature: String
) -> void:
	GuardianAuraSystem.source_driven_refresh_enabled = false
	var original_positions := PackedVector2Array()
	for guardian in guardians:
		original_positions.append(guardian.global_position)
		guardian.global_position += Vector2(64.0, 12.0)
	system.force_refresh_all()
	var shifted_signature := _get_source_signature(system, enemies)
	_expect(
		shifted_signature != original_signature,
		"Catch-up fixture movement must change the guardian source signature."
	)

	for guardian_index in range(guardians.size()):
		guardians[guardian_index].global_position = original_positions[guardian_index]
	system.force_refresh_all()
	_expect(
		_get_source_signature(system, enemies) == original_signature,
		"Catch-up fixture failed to restore its original source signature."
	)
	for guardian in guardians:
		guardian.global_position += Vector2(64.0, 12.0)

	var steps_per_refresh := maxi(
		floori(system.refresh_interval_seconds * 60.0 + 0.0001),
		1
	)
	var expected_batch_size := ceili(
		float(enemies.size()) / float(steps_per_refresh)
	)
	var original_service_budget: int = system.max_refresh_service_usec
	system.max_refresh_service_usec = 1000000
	system.limit_refresh_to_once_per_render_frame = false
	var unrestricted_visit_start := system.refresh_target_visit_count
	var unrestricted_started_usec := Time.get_ticks_usec()
	for _catch_up_tick in range(8):
		system.call("_physics_process", 1.0 / 60.0)
	catch_up_unrestricted_ms = (
		float(Time.get_ticks_usec() - unrestricted_started_usec) / 1000.0
	)
	catch_up_unrestricted_targets = (
		system.refresh_target_visit_count - unrestricted_visit_start
	)
	_expect(
		catch_up_unrestricted_targets == expected_batch_size * 8,
		"Unrestricted catch-up A/B must execute all eight accrued target batches."
	)
	# At the production 5 Hz cadence, eight 60 Hz ticks intentionally represent
	# only two thirds of a complete pass. Finish the remaining cadence steps
	# outside the measured window before checking exact convergence.
	for _remaining_tick in range(maxi(steps_per_refresh - 8, 0)):
		system.call("_physics_process", 1.0 / 60.0)
	_expect(
		_get_source_signature(system, enemies) == shifted_signature,
		"Unrestricted target batches did not converge after one refresh interval."
	)

	for guardian_index in range(guardians.size()):
		guardians[guardian_index].global_position = original_positions[guardian_index]
	system.force_refresh_all()
	for guardian in guardians:
		guardian.global_position += Vector2(64.0, 12.0)

	system.limit_refresh_to_once_per_render_frame = true
	system.last_refresh_render_frame = -1
	var service_step_start := system.refresh_service_step_count
	var limited_visit_start := system.refresh_target_visit_count
	var limited_started_usec := Time.get_ticks_usec()
	for _catch_up_tick in range(8):
		system.call("_physics_process", 1.0 / 60.0)
	catch_up_limited_ms = float(Time.get_ticks_usec() - limited_started_usec) / 1000.0
	catch_up_limited_targets = system.refresh_target_visit_count - limited_visit_start
	var admitted_steps := system.refresh_service_step_count - service_step_start
	_expect(
		admitted_steps == 1
		and catch_up_limited_targets == expected_batch_size
		and system.refresh_cursor == expected_batch_size,
		(
			"Eight same-render physics ticks must admit one %d-target batch "
			+ "(steps=%d visits=%d cursor=%d)."
		)
		% [
			expected_batch_size,
			admitted_steps,
			catch_up_limited_targets,
			system.refresh_cursor,
		]
	)

	# Simulate the remaining distinct visible frames by invalidating the synthetic
	# epoch between calls. One complete authored refresh interval must still
	# converge to the same source state as force_refresh_all().
	for _visible_frame in range(steps_per_refresh - 1):
		system.last_refresh_render_frame = -1
		system.call("_physics_process", 1.0 / 60.0)
	_expect(
		_get_source_signature(system, enemies) == shifted_signature,
		"Render-frame-limited batches did not converge to the exact shifted source signature."
	)

	# At stable 30 FPS, two physics ticks share one rendered frame. The skipped
	# tick contributes debt, and the following visible frame repays both 50-target
	# quanta as one bounded 100-target batch instead of silently halving cadence.
	system.force_refresh_all()
	system.last_refresh_render_frame = -1
	system.call("_physics_process", 1.0 / 60.0)
	system.call("_physics_process", 1.0 / 60.0)
	system.last_refresh_render_frame = -1
	system.call("_physics_process", 1.0 / 60.0)
	two_tick_debt_repayment_targets = system.last_refresh_target_count
	_expect(
		two_tick_debt_repayment_targets == expected_batch_size * 2
		and is_zero_approx(system.refresh_target_debt),
		"Two-tick render debt must be repaid by one bounded double batch."
	)
	system.max_refresh_service_usec = original_service_budget


func _test_source_driven_render_frame_catch_up_limit(
	system: GuardianAuraSystem,
	enemies: Array[Enemy],
	guardians: Array[Enemy]
) -> void:
	GuardianAuraSystem.source_driven_refresh_enabled = true
	system.force_refresh_all()
	var starting_signature := _get_source_signature(system, enemies)
	var original_positions := PackedVector2Array()
	for guardian in guardians:
		original_positions.append(guardian.global_position)
		guardian.global_position += Vector2(-48.0, 40.0)
	system.force_refresh_all()
	var shifted_signature := _get_source_signature(system, enemies)
	_expect(
		shifted_signature != starting_signature,
		"Source scheduler fixture movement must change source membership."
	)
	for guardian_index in range(guardians.size()):
		guardians[guardian_index].global_position = original_positions[guardian_index]
	system.force_refresh_all()
	for guardian in guardians:
		guardian.global_position += Vector2(-48.0, 40.0)

	var expected_first_batch := ceili(
		float(guardians.size())
		* (1.0 / 60.0)
		/ system.refresh_interval_seconds
	)
	var original_service_budget: int = system.max_refresh_service_usec
	system.max_refresh_service_usec = 1000000
	system.limit_refresh_to_once_per_render_frame = true
	system.last_refresh_render_frame = -1
	var refresh_start := system.source_refresh_count
	var index_query_start := system.source_index_query_count
	for _catch_up_tick in range(8):
		system.call("_physics_process", 1.0 / 60.0)
	source_catch_up_refreshes = system.source_refresh_count - refresh_start
	_expect(
		source_catch_up_refreshes == expected_first_batch
		and system.source_index_query_count - index_query_start
			== expected_first_batch,
		(
			"Eight same-render source ticks must issue only the first %d "
			+ "local guardian queries (refreshes=%d queries=%d)."
		)
		% [
			expected_first_batch,
			source_catch_up_refreshes,
			system.source_index_query_count - index_query_start,
		]
	)

	# The coalesced debt may be repaid in one bounded batch, but the deadline and
	# guardian-count cap remain authoritative. Continue visible frames until each
	# source has been refreshed at least once and verify exact convergence.
	var convergence_start := system.source_refresh_count
	for _visible_frame in range(guardians.size()):
		if _get_source_signature(system, enemies) == shifted_signature:
			break
		system.last_refresh_render_frame = -1
		system.call("_physics_process", 1.0 / 60.0)
	source_convergence_refreshes = system.source_refresh_count - convergence_start
	_expect(
		_get_source_signature(system, enemies) == shifted_signature
		and source_convergence_refreshes <= guardians.size()
			+ system.max_refresh_guardians_per_render_frame,
		"Bounded source debt repayment did not converge to exact membership."
	)

	for guardian_index in range(guardians.size()):
		guardians[guardian_index].global_position = original_positions[guardian_index]
	system.force_refresh_all()
	system.max_refresh_service_usec = original_service_budget


func _get_source_signature(
	system: GuardianAuraSystem,
	enemies: Array[Enemy]
) -> String:
	var signature_parts := PackedStringArray()
	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		var enemy_id := enemy.get_instance_id()
		var sources: Dictionary = system.aura_sources_by_enemy.get(enemy_id, {})
		var source_ids: Array = sources.keys()
		source_ids.sort()
		signature_parts.append("%d:" % enemy_index)
		for source_id_variant in source_ids:
			var source_id := int(source_id_variant)
			signature_parts.append("%d=%d," % [source_id, int(sources[source_id])])
		signature_parts.append(
			"|defense=%d;" % enemy.get_effective_physical_defense()
		)
	return "".join(signature_parts)


func _get_source_link_count(system: GuardianAuraSystem) -> int:
	var source_link_count := 0
	for sources_variant in system.aura_sources_by_enemy.values():
		var sources := sources_variant as Dictionary
		source_link_count += sources.size()
	return source_link_count


func _median(values: Array[float]) -> float:
	var sorted_values := values.duplicate()
	sorted_values.sort()
	if sorted_values.is_empty():
		return 0.0
	var middle := sorted_values.size() / 2
	if sorted_values.size() % 2 == 0:
		return (sorted_values[middle - 1] + sorted_values[middle]) * 0.5
	return sorted_values[middle]


func _median_paired_cost_ratio(
	numerator_samples: Array[float],
	denominator_samples: Array[float]
) -> float:
	var paired_count := mini(
		numerator_samples.size(),
		denominator_samples.size()
	)
	var ratios: Array[float] = []
	ratios.resize(paired_count)
	for sample_index in range(paired_count):
		ratios[sample_index] = (
			numerator_samples[sample_index]
			/ maxf(denominator_samples[sample_index], 0.000001)
		)
	return _median(ratios)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
