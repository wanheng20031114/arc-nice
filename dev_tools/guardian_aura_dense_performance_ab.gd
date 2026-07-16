extends SceneTree

# Dense, same-cohort A/B for the production guardian-aura hot path. Both modes
# run against the same live nodes in interleaved order, and every measurement is
# rejected unless each enemy has the exact same sorted source-id/bonus signature.
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const GUARDIAN_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_guardian.tres"
)
const GUARDIAN_SYSTEM_SCENE := preload(
	"res://scene/enemy/guardian_aura_system.tscn"
)

const ENEMY_COUNT := 300
const GUARDIAN_COUNT := 36
const SAMPLE_PAIRS := 10
const COHORT_COLUMNS := 50
const COHORT_SPACING := Vector2(16.0, 24.0)

var failures: Array[String] = []


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

	var enemies: Array[Enemy] = []
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
		enemies.append(enemy)
		if use_guardian:
			spawned_guardians += 1

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
	guardian_system.force_refresh_all()
	_expect(
		_get_source_signature(guardian_system, enemies) == reference_signature,
		"Snapshot coverage grid changed the dense cohort source signature."
	)
	_expect(
		guardian_system.active_guardian_source_ids.size() == GUARDIAN_COUNT,
		"Snapshot grid did not materialize one compact slot per guardian."
	)

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
	print(
		(
			"GUARDIAN_AURA_DENSE_AB enemies=%d guardians=%d samples=%d "
			+ "source_links=%d legacy_median_ms=%.3f snapshot_median_ms=%.3f speedup=%.3fx "
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
			reference_signature.sha256_text(),
		]
	)

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
	system.use_snapshot_coverage_grid = use_snapshot
	var started_usec := Time.get_ticks_usec()
	system.force_refresh_all()
	samples.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)
	_expect(
		_get_source_signature(system, enemies) == reference_signature,
		"%s mode changed the dense cohort source signature."
		% ("snapshot" if use_snapshot else "legacy")
	)


func _get_source_signature(
	system: GuardianAuraSystem,
	enemies: Array[Enemy]
) -> String:
	var signature := ""
	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		var enemy_id := enemy.get_instance_id()
		var sources: Dictionary = system.aura_sources_by_enemy.get(enemy_id, {})
		var source_ids: Array = sources.keys()
		source_ids.sort()
		signature += "%d:" % enemy_index
		for source_id_variant in source_ids:
			var source_id := int(source_id_variant)
			signature += "%d=%d," % [source_id, int(sources[source_id])]
		signature += "|defense=%d;" % enemy.get_effective_physical_defense()
	return signature


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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
