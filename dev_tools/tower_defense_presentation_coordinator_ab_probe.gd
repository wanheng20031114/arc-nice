extends SceneTree

const SAMPLE_COUNT := 21
const EVENTS_PER_SAMPLE := 16384
const FIXED_SEED := 0x7D31A906


class LegacyCountdownPresentation:
	extends Node

	var countdown_audio: AudioStreamPlayer = null
	var client_countdown_sequence_key: StringName = &""
	var client_last_countdown_tick_seconds := (
		TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS + 1
	)

	func play_countdown_tick() -> void:
		countdown_audio.pitch_scale = 1.0
		countdown_audio.play()

	func play_client_countdown_tick_if_new(
		state: CombatFlowState.State,
		step_id: StringName,
		seconds: int
	) -> void:
		var sequence_key := StringName(
			"%d:%s" % [int(state), String(step_id)]
		)
		if sequence_key != client_countdown_sequence_key:
			client_countdown_sequence_key = sequence_key
			client_last_countdown_tick_seconds = (
				TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS + 1
			)
		if (
			seconds <= 0
			or seconds > TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS
			or seconds >= client_last_countdown_tick_seconds
		):
			return
		client_last_countdown_tick_seconds = seconds
		play_countdown_tick()


var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var legacy_time_samples: Array[int] = []
	var extracted_time_samples: Array[int] = []
	var legacy_memory_samples: Array[int] = []
	var extracted_memory_samples: Array[int] = []
	_warm_up(true)
	_warm_up(false)
	var legacy_hash := 0
	var extracted_hash := 0
	for sample_index in range(SAMPLE_COUNT):
		if sample_index % 2 == 0:
			legacy_hash ^= _measure_legacy(
				legacy_time_samples,
				legacy_memory_samples
			)
			extracted_hash ^= _measure_extracted(
				extracted_time_samples,
				extracted_memory_samples
			)
		else:
			extracted_hash ^= _measure_extracted(
				extracted_time_samples,
				extracted_memory_samples
			)
			legacy_hash ^= _measure_legacy(
				legacy_time_samples,
				legacy_memory_samples
			)
	legacy_time_samples.sort()
	extracted_time_samples.sort()
	legacy_memory_samples.sort()
	extracted_memory_samples.sort()
	var p50_index := _nearest_rank_index(0.50)
	var p95_index := _nearest_rank_index(0.95)
	var legacy_p50 := legacy_time_samples[p50_index]
	var extracted_p50 := extracted_time_samples[p50_index]
	var legacy_p95 := legacy_time_samples[p95_index]
	var extracted_p95 := extracted_time_samples[p95_index]
	var legacy_memory_p50 := legacy_memory_samples[p50_index]
	var extracted_memory_p50 := extracted_memory_samples[p50_index]
	var legacy_memory_p95 := legacy_memory_samples[p95_index]
	var extracted_memory_p95 := extracted_memory_samples[p95_index]
	var p50_limit := legacy_p50 + maxi(ceili(legacy_p50 * 0.05), 200)
	var p95_limit := legacy_p95 + maxi(ceili(legacy_p95 * 0.05), 200)
	var memory_p50_limit := legacy_memory_p50 + maxi(
		ceili(legacy_memory_p50 * 0.05),
		16 * 1024 * 1024
	)
	var memory_p95_limit := legacy_memory_p95 + maxi(
		ceili(legacy_memory_p95 * 0.05),
		16 * 1024 * 1024
	)
	_expect(
		legacy_hash == extracted_hash,
		"Presentation countdown 轨迹必须严格一致：legacy=%d extracted=%d。"
		% [legacy_hash, extracted_hash]
	)
	_expect(
		extracted_p50 <= p50_limit,
		"extracted p50 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_p50, extracted_p50, p50_limit]
	)
	_expect(
		extracted_p95 <= p95_limit,
		"extracted p95 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_p95, extracted_p95, p95_limit]
	)
	_expect(
		extracted_memory_p50 <= memory_p50_limit,
		"extracted memory p50 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_memory_p50, extracted_memory_p50, memory_p50_limit]
	)
	_expect(
		extracted_memory_p95 <= memory_p95_limit,
		"extracted memory p95 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_memory_p95, extracted_memory_p95, memory_p95_limit]
	)
	if failures.is_empty():
		print(
			"TOWER_DEFENSE_PRESENTATION_COORDINATOR_AB_PROBE_OK legacy_p50_usec=%d extracted_p50_usec=%d legacy_p95_usec=%d extracted_p95_usec=%d p50_limit_usec=%d p95_limit_usec=%d legacy_memory_p50_bytes=%d extracted_memory_p50_bytes=%d legacy_memory_p95_bytes=%d extracted_memory_p95_bytes=%d memory_p50_limit_bytes=%d memory_p95_limit_bytes=%d trajectory_hash=%d"
			% [
				legacy_p50,
				extracted_p50,
				legacy_p95,
				extracted_p95,
				p50_limit,
				p95_limit,
				legacy_memory_p50,
				extracted_memory_p50,
				legacy_memory_p95,
				extracted_memory_p95,
				memory_p50_limit,
				memory_p95_limit,
				legacy_hash,
			]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_legacy(
	time_samples: Array[int],
	memory_samples: Array[int]
) -> int:
	var audio := AudioStreamPlayer.new()
	var logic := LegacyCountdownPresentation.new()
	logic.countdown_audio = audio
	logic.add_child(audio)
	root.add_child(logic)
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = FIXED_SEED
	var checksum := 0
	var started_at := Time.get_ticks_usec()
	for event_index in range(EVENTS_PER_SAMPLE):
		var state := (
			CombatFlowState.State.PRE_WAVE
			if random_generator.randi_range(0, 1) == 0
			else CombatFlowState.State.INTERMISSION
		)
		var step_id := StringName(
			"wave_%02d" % random_generator.randi_range(1, 16)
		)
		var seconds := random_generator.randi_range(0, 5)
		logic.play_client_countdown_tick_if_new(state, step_id, seconds)
		checksum = hash([
			checksum,
			event_index,
			logic.client_countdown_sequence_key,
			logic.client_last_countdown_tick_seconds,
		])
	time_samples.append(Time.get_ticks_usec() - started_at)
	memory_samples.append(int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	logic.free()
	return checksum


func _measure_extracted(
	time_samples: Array[int],
	memory_samples: Array[int]
) -> int:
	var audio := AudioStreamPlayer.new()
	var coordinator := TowerDefensePresentationCoordinator.new()
	coordinator.set("_countdown_audio", audio)
	coordinator.add_child(audio)
	root.add_child(coordinator)
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = FIXED_SEED
	var checksum := 0
	var started_at := Time.get_ticks_usec()
	for event_index in range(EVENTS_PER_SAMPLE):
		var state := (
			CombatFlowState.State.PRE_WAVE
			if random_generator.randi_range(0, 1) == 0
			else CombatFlowState.State.INTERMISSION
		)
		var step_id := StringName(
			"wave_%02d" % random_generator.randi_range(1, 16)
		)
		var seconds := random_generator.randi_range(0, 5)
		coordinator.play_client_countdown_tick_if_new(state, step_id, seconds)
		checksum = hash([
			checksum,
			event_index,
			coordinator._client_countdown_sequence_key,
			coordinator._client_last_countdown_tick_seconds,
		])
	time_samples.append(Time.get_ticks_usec() - started_at)
	memory_samples.append(int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	coordinator.free()
	return checksum


func _warm_up(use_legacy: bool) -> void:
	var discarded_times: Array[int] = []
	var discarded_memory: Array[int] = []
	if use_legacy:
		_measure_legacy(discarded_times, discarded_memory)
	else:
		_measure_extracted(discarded_times, discarded_memory)


func _nearest_rank_index(percentile: float) -> int:
	return clampi(ceili(SAMPLE_COUNT * percentile) - 1, 0, SAMPLE_COUNT - 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
