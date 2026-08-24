extends SceneTree

const POLICY := preload("res://scene/combat/simulation/enemy_simulation_policy.gd")
const EVIDENCE := preload(
	"res://scene/combat/diagnostics/enemy_simulation_evidence_recorder.gd"
)
const SYNTHETIC_PERCENTILE_SAMPLE_COUNT := 100
const TEST_TICK_COUNT := 600

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_mode_contract()
	_test_semantic_signature()
	_test_recorder_percentile_math()
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"evidence_scope": "protocol_and_math_only",
		"measured_runtime": false,
		"performance_gate": false,
		"failures": failures.duplicate(),
	}
	print("ENEMY_SIMULATION_AB_BASELINE_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_SIMULATION_AB_BASELINE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_mode_contract() -> void:
	_expect(
		POLICY.resolve_mode_from_arguments(PackedStringArray())
		== POLICY.Mode.LEGACY,
		"No command-line override must preserve LEGACY mode."
	)
	_expect(
		POLICY.resolve_mode_from_arguments(
			PackedStringArray(["--enemy-simulation-mode=CoMpAt_60"])
		) == POLICY.Mode.COMPAT_60,
		"The A/B command-line mode must be case-insensitive."
	)
	_expect(
		POLICY.resolve_mode_from_arguments(
			PackedStringArray(["--enemy-simulation-mode=unknown"])
		) == POLICY.Mode.LEGACY,
		"Unknown A/B modes must fail closed to LEGACY."
	)


func _test_semantic_signature() -> void:
	var legacy := _build_semantic_evidence(POLICY.Mode.LEGACY)
	var compatibility := _build_semantic_evidence(
		POLICY.Mode.COMPAT_60
	)
	_expect(
		legacy.has_equivalent_semantics(compatibility),
		"Identical authoritative events must have an identical signature across modes."
	)
	compatibility.record_event(&"damage", TEST_TICK_COUNT, 7, PackedInt64Array([1]))
	_expect(
		not legacy.has_equivalent_semantics(compatibility),
		"A missing or additional gameplay event must fail semantic equivalence."
	)


func _build_semantic_evidence(mode: int) -> RefCounted:
	var recorder := EVIDENCE.new()
	recorder.reset(mode, true)
	for tick in range(TEST_TICK_COUNT):
		recorder.record_authoritative_tick(tick)
		if tick % 30 == 0:
			recorder.record_event(
				&"target",
				tick,
				7,
				PackedInt64Array([11, tick / 30])
			)
		if tick % 45 == 0:
			recorder.record_event(
				&"attack",
				tick,
				7,
				PackedInt64Array([3])
			)
	return recorder


func _test_recorder_percentile_math() -> void:
	var recorder := EVIDENCE.new()
	recorder.reset(POLICY.Mode.LEGACY, false)
	for sample_index in range(SYNTHETIC_PERCENTILE_SAMPLE_COUNT):
		recorder.record_frame_time_ms(float(sample_index + 1))
	var frame_summary := recorder.get_summary()["frame_time"] as Dictionary
	_expect(
		int(frame_summary["sample_count"]) == SYNTHETIC_PERCENTILE_SAMPLE_COUNT,
		"Synthetic percentile sample count mismatch."
	)
	_expect(is_equal_approx(float(frame_summary["p50_ms"]), 50.0), "p50 mismatch.")
	_expect(is_equal_approx(float(frame_summary["p95_ms"]), 95.0), "p95 mismatch.")
	_expect(is_equal_approx(float(frame_summary["p99_ms"]), 99.0), "p99 mismatch.")
	_expect(is_equal_approx(float(frame_summary["max_ms"]), 100.0), "max mismatch.")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
