extends SceneTree

const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const WAVE_04 := preload("res://resources/config/waves/wave_04.tres")
const SAMPLE_COUNT := 21
const EVENTS_PER_SAMPLE := 16
const ARM_ARGUMENT_PREFIX := "--arm="


class LegacyStandardMusicLogic:
	extends RefCounted

	var music_player: AudioStreamPlayer = null
	var background_scope: Node = null
	var music_fade_tween: Tween = null

	func bind_dependencies(
		player: AudioStreamPlayer,
		scope: Node
	) -> void:
		music_player = player
		background_scope = scope

	func pause_all_background_music() -> void:
		stop_music_fade_tween()
		pause_background_music_players(background_scope)

	func stop_music_fade_tween() -> void:
		if music_fade_tween == null:
			return
		music_fade_tween.kill()
		music_fade_tween = null

	func configure_music_loop(
		stream: AudioStream,
		loop_offset: float
	) -> void:
		if stream == null:
			return
		if audio_stream_has_property(stream, &"loop"):
			stream.set(&"loop", true)
		if audio_stream_has_property(stream, &"loop_offset"):
			stream.set(&"loop_offset", maxf(loop_offset, 0.0))

	func audio_stream_has_property(
		stream: AudioStream,
		property_name: StringName
	) -> bool:
		for property in stream.get_property_list():
			if property.get("name") == property_name:
				return true
		return false

	func pause_background_music_players(root_node: Node) -> void:
		if root_node == null:
			return
		if is_background_music_player(root_node):
			root_node.set(&"stream_paused", true)
		for child in root_node.get_children():
			pause_background_music_players(child)

	func is_background_music_player(node: Node) -> bool:
		if not (
			node is AudioStreamPlayer
			or node is AudioStreamPlayer2D
			or node is AudioStreamPlayer3D
		):
			return false
		if not bool(node.get(&"playing")):
			return false
		var bus_name := String(node.get(&"bus")).to_lower()
		var node_name := String(node.name).to_lower()
		return (
			bus_name == "music"
			or node_name.contains("music")
			or node_name.contains("bgm")
		)


var failures: Array[String] = []
var game: StandardGame = null
var music_player: AudioStreamPlayer = null
var benchmark_bgm: AudioStreamPlayer = null
var plain_sfx: AudioStreamPlayer = null
var loop_stream: AudioStream = null
var legacy_logic: LegacyStandardMusicLogic = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _setup_fixture()
	if not failures.is_empty():
		await _finish_with_failures()
		return
	var requested_arm := _get_requested_arm()
	var result := (
		_run_isolated_arm(requested_arm)
		if not requested_arm.is_empty()
		else _run_comparison()
	)
	await _cleanup_fixture()
	if not failures.is_empty():
		_finish_with_current_failures()
		return
	if requested_arm.is_empty():
		print(
			"STANDARD_MUSIC_COORDINATOR_AB_PROBE_OK legacy_p50_usec=%d extracted_p50_usec=%d legacy_p95_usec=%d extracted_p95_usec=%d legacy_trajectory_hash=%d extracted_trajectory_hash=%d"
			% [
				int(result["legacy_p50_usec"]),
				int(result["extracted_p50_usec"]),
				int(result["legacy_p95_usec"]),
				int(result["extracted_p95_usec"]),
				int(result["legacy_trajectory_hash"]),
				int(result["extracted_trajectory_hash"]),
			]
		)
	else:
		print(
			"STANDARD_MUSIC_COORDINATOR_AB_ARM_OK arm=%s p50_usec=%d p95_usec=%d trajectory_hash=%d"
			% [
				requested_arm,
				int(result["p50_usec"]),
				int(result["p95_usec"]),
				int(result["trajectory_hash"]),
			]
		)
	quit(0)


func _setup_fixture() -> void:
	game = STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "Standard Music A/B 必须实例化真实 StandardGame。")
	if game == null:
		return
	game.auto_start_waves = false
	music_player = game.get_node("MusicPlayer") as AudioStreamPlayer
	music_player.autoplay = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	_expect(
		game.music_coordinator != null
		and game.music_coordinator.is_bound(),
		"Standard Music A/B 必须使用已绑定的真实根 façade。"
	)

	var sample_stream := _create_long_audio_stream()
	music_player.stream = sample_stream
	music_player.play()
	var nested_scope := Node.new()
	nested_scope.name = "BenchmarkNestedScope"
	game.add_child(nested_scope)
	benchmark_bgm = AudioStreamPlayer.new()
	benchmark_bgm.name = "BenchmarkBGM"
	benchmark_bgm.bus = &"SFX"
	benchmark_bgm.stream = sample_stream
	nested_scope.add_child(benchmark_bgm)
	plain_sfx = AudioStreamPlayer.new()
	plain_sfx.name = "BenchmarkDialogue"
	plain_sfx.bus = &"SFX"
	plain_sfx.stream = sample_stream
	nested_scope.add_child(plain_sfx)
	benchmark_bgm.play()
	plain_sfx.play()
	await process_frame
	await physics_frame

	loop_stream = WAVE_04.music.duplicate() as AudioStream
	_expect(
		loop_stream != null
		and game.call(
			"_audio_stream_has_property",
			loop_stream,
			&"loop"
		)
		and game.call(
			"_audio_stream_has_property",
			loop_stream,
			&"loop_offset"
		),
		"Standard Music A/B loop stream 必须公开 loop/loop_offset。"
	)
	legacy_logic = LegacyStandardMusicLogic.new()
	legacy_logic.bind_dependencies(music_player, game)


func _run_comparison() -> Dictionary:
	var legacy_samples: Array[int] = []
	var extracted_samples: Array[int] = []
	var legacy_trajectory_hash := 0
	var extracted_trajectory_hash := 0
	_warm_up_arm("legacy")
	_warm_up_arm("extracted")
	for sample_index in range(SAMPLE_COUNT):
		if sample_index % 2 == 0:
			legacy_trajectory_hash ^= _measure_legacy(legacy_samples)
			extracted_trajectory_hash ^= _measure_extracted(extracted_samples)
		else:
			extracted_trajectory_hash ^= _measure_extracted(extracted_samples)
			legacy_trajectory_hash ^= _measure_legacy(legacy_samples)
	legacy_samples.sort()
	extracted_samples.sort()
	var p50_index := _get_nearest_rank_index(legacy_samples.size(), 0.50)
	var p95_index := _get_nearest_rank_index(legacy_samples.size(), 0.95)
	_expect(
		legacy_trajectory_hash == extracted_trajectory_hash,
		"提取前后 Standard Music 累计轨迹 hash 必须严格一致：legacy=%d extracted=%d。"
		% [legacy_trajectory_hash, extracted_trajectory_hash]
	)
	return {
		"legacy_p50_usec": legacy_samples[p50_index],
		"extracted_p50_usec": extracted_samples[p50_index],
		"legacy_p95_usec": legacy_samples[p95_index],
		"extracted_p95_usec": extracted_samples[p95_index],
		"legacy_trajectory_hash": legacy_trajectory_hash,
		"extracted_trajectory_hash": extracted_trajectory_hash,
	}


func _run_isolated_arm(arm: String) -> Dictionary:
	if arm != "legacy" and arm != "extracted":
		failures.append("未知 Standard Music A/B arm：%s。" % arm)
		return {}
	var samples: Array[int] = []
	var trajectory_hash := 0
	_warm_up_arm(arm)
	for _sample_index in range(SAMPLE_COUNT):
		if arm == "legacy":
			trajectory_hash ^= _measure_legacy(samples)
		else:
			trajectory_hash ^= _measure_extracted(samples)
	samples.sort()
	return {
		"p50_usec": samples[
			_get_nearest_rank_index(samples.size(), 0.50)
		],
		"p95_usec": samples[
			_get_nearest_rank_index(samples.size(), 0.95)
		],
		"trajectory_hash": trajectory_hash,
	}


func _measure_legacy(samples: Array[int]) -> int:
	var trace_checksum: int = 0
	var started_at := Time.get_ticks_usec()
	for event_index in range(EVENTS_PER_SAMPLE):
		_prepare_event(event_index)
		var requested_offset := float(event_index % 7) - 2.0
		legacy_logic.configure_music_loop(loop_stream, requested_offset)
		var has_loop := int(
			legacy_logic.audio_stream_has_property(loop_stream, &"loop")
		)
		var is_bgm := int(
			legacy_logic.is_background_music_player(benchmark_bgm)
		)
		var is_plain_sfx := int(
			legacy_logic.is_background_music_player(plain_sfx)
		)
		legacy_logic.pause_all_background_music()
		trace_checksum += _trace_event_value(
			event_index,
			has_loop,
			is_bgm,
			is_plain_sfx
		)
	samples.append(Time.get_ticks_usec() - started_at)
	return _finish_measurement_hash(trace_checksum, "旧版")


func _measure_extracted(samples: Array[int]) -> int:
	var trace_checksum: int = 0
	var started_at := Time.get_ticks_usec()
	for event_index in range(EVENTS_PER_SAMPLE):
		_prepare_event(event_index)
		var requested_offset := float(event_index % 7) - 2.0
		game._configure_music_loop(loop_stream, requested_offset)
		var has_loop := int(
			game._audio_stream_has_property(loop_stream, &"loop")
		)
		var is_bgm := int(
			game._is_background_music_player(benchmark_bgm)
		)
		var is_plain_sfx := int(
			game._is_background_music_player(plain_sfx)
		)
		game.pause_all_background_music()
		trace_checksum += _trace_event_value(
			event_index,
			has_loop,
			is_bgm,
			is_plain_sfx
		)
	samples.append(Time.get_ticks_usec() - started_at)
	return _finish_measurement_hash(trace_checksum, "提取后")


func _prepare_event(event_index: int) -> void:
	music_player.stream_paused = false
	benchmark_bgm.stream_paused = false
	plain_sfx.stream_paused = false
	loop_stream.set(&"loop", false)
	loop_stream.set(&"loop_offset", float(event_index % 3))


func _trace_event_value(
	event_index: int,
	has_loop: int,
	is_bgm: int,
	is_plain_sfx: int
) -> int:
	return (event_index + 1) * (
		has_loop * 100000
		+ int(bool(loop_stream.get(&"loop"))) * 10000
		+ roundi(float(loop_stream.get(&"loop_offset")) * 100.0) * 10
		+ int(music_player.stream_paused) * 4
		+ int(benchmark_bgm.stream_paused) * 2
		+ is_bgm
		+ is_plain_sfx * 1000000
	)


func _finish_measurement_hash(trace_checksum: int, arm_label: String) -> int:
	_expect(
		bool(loop_stream.get(&"loop")),
		"%s Standard Music 轨迹必须保持 loop=true。" % arm_label
	)
	_expect(
		music_player.stream_paused
		and benchmark_bgm.stream_paused
		and not plain_sfx.stream_paused,
		"%s Standard Music 轨迹的递归暂停分类发生变化。" % arm_label
	)
	return hash([
		trace_checksum,
		bool(loop_stream.get(&"loop")),
		float(loop_stream.get(&"loop_offset")),
		music_player.stream_paused,
		benchmark_bgm.stream_paused,
		plain_sfx.stream_paused,
	])


func _warm_up_arm(arm: String) -> void:
	var discarded_samples: Array[int] = []
	if arm == "legacy":
		_measure_legacy(discarded_samples)
	else:
		_measure_extracted(discarded_samples)


func _cleanup_fixture() -> void:
	legacy_logic = null
	loop_stream = null
	if game != null:
		_stop_audio_players(game)
		game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	game = null
	music_player = null
	benchmark_bgm = null
	plain_sfx = null


func _finish_with_failures() -> void:
	await _cleanup_fixture()
	_finish_with_current_failures()


func _finish_with_current_failures() -> void:
	for failure in failures:
		push_error(failure)
	quit(1)


func _stop_audio_players(root_node: Node) -> void:
	for child in root_node.get_children():
		if child is AudioStreamPlayer:
			(child as AudioStreamPlayer).stop()
			(child as AudioStreamPlayer).stream = null
		elif child is AudioStreamPlayer2D:
			(child as AudioStreamPlayer2D).stop()
			(child as AudioStreamPlayer2D).stream = null
		elif child is AudioStreamPlayer3D:
			(child as AudioStreamPlayer3D).stop()
			(child as AudioStreamPlayer3D).stream = null
		_stop_audio_players(child)


func _create_long_audio_stream() -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = 8000
	stream.stereo = false
	var sample_data := PackedByteArray()
	sample_data.resize(80000)
	sample_data.fill(128)
	stream.data = sample_data
	return stream


func _get_requested_arm() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(ARM_ARGUMENT_PREFIX):
			return argument.trim_prefix(ARM_ARGUMENT_PREFIX)
	return ""


func _get_nearest_rank_index(
	sample_count: int,
	percentile: float
) -> int:
	return clampi(
		ceili(float(sample_count) * percentile) - 1,
		0,
		sample_count - 1
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
