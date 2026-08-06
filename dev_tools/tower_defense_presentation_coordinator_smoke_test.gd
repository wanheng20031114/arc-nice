extends SceneTree

const PRESENTATION_SCENE := preload(
	"res://scene/game_modes/tower_defense/presentation/tower_defense_presentation_coordinator.tscn"
)
const TOWER_GAME_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const WAVE_HUD_SCENE := preload(
	"res://scene/game_modes/tower_defense/ui/tower_defense_wave_hud.tscn"
)
const DAY_ANNOUNCEMENT_SCENE := preload(
	"res://scene/day_phase_announcement.tscn"
)
const STATUS_HUD_SCENE := preload(
	"res://scene/tower_defense_status_hud.tscn"
)
const DAY_CYCLE := preload(
	"res://resources/config/day_cycle/tower_defense_day_cycle.tres"
)
const COUNTDOWN_STREAM := preload(
	"res://resources/audio/ui/countdown_tick.wav"
)
const WAVE_START_STREAM := preload(
	"res://resources/audio/ui/wave_start.wav"
)
const DEFEAT_STREAM := preload("res://resources/audio/cowboy_dead.wav")


class PresentationRuntimeProbe:
	extends TowerDefenseGame

	var day_requests := 0
	var night_requests := 0
	var defeat_completions := 0
	var presentation: TowerDefensePresentationCoordinator = null

	func transition_world_to_day(_duration_seconds: float = -1.0) -> void:
		day_requests += 1

	func transition_world_to_night(_duration_seconds: float = -1.0) -> void:
		night_requests += 1

	func _complete_defeat_presentation() -> void:
		defeat_completions += 1
		presentation.complete_defeat_presentation()


var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_static_scene_contract()
	var fixture := await _create_fixture()
	if fixture.is_empty():
		_finish()
		return
	var coordinator := fixture["coordinator"] as TowerDefensePresentationCoordinator
	var runtime := fixture["runtime"] as PresentationRuntimeProbe
	var wave_hud := fixture["wave_hud"] as TowerDefenseWaveHUD
	var announcement := fixture["announcement"] as DayPhaseAnnouncement
	var music_player := fixture["music_player"] as AudioStreamPlayer

	_expect(coordinator.is_bound(), "PresentationCoordinator 必须完成强类型依赖绑定。")
	_test_lighting_and_announcement(coordinator, runtime, announcement)
	_test_hud_and_request_bridge(coordinator, wave_hud)
	_test_countdown_deduplication(coordinator)
	_test_music(coordinator, music_player)
	_test_defeat_idempotency(coordinator, runtime)

	for owned_node in fixture["owned_nodes"] as Array[Node]:
		owned_node.queue_free()
	runtime.free()
	(fixture["campaign"] as TowerDefenseCampaignCoordinator).free()
	await process_frame
	_finish()


func _create_fixture() -> Dictionary:
	var runtime := PresentationRuntimeProbe.new()
	var campaign := TowerDefenseCampaignCoordinator.new()
	campaign.day_cycle_config = DAY_CYCLE
	var coordinator := PRESENTATION_SCENE.instantiate() as TowerDefensePresentationCoordinator
	var wave_hud := WAVE_HUD_SCENE.instantiate() as TowerDefenseWaveHUD
	var announcement := DAY_ANNOUNCEMENT_SCENE.instantiate() as DayPhaseAnnouncement
	var status_hud := STATUS_HUD_SCENE.instantiate() as TowerDefenseStatusHUD
	var map_camera := Camera2D.new()
	var music_player := AudioStreamPlayer.new()
	music_player.name = "MusicPlayer"
	music_player.bus = &"Music"
	var countdown_audio := AudioStreamPlayer.new()
	countdown_audio.stream = COUNTDOWN_STREAM
	var wave_start_audio := AudioStreamPlayer.new()
	wave_start_audio.stream = WAVE_START_STREAM
	var defeat_audio := AudioStreamPlayer.new()
	defeat_audio.stream = DEFEAT_STREAM
	for node in [
		wave_hud,
		announcement,
		status_hud,
		map_camera,
		music_player,
		countdown_audio,
		wave_start_audio,
		defeat_audio,
		coordinator,
	]:
		root.add_child(node)
	await process_frame
	coordinator.setup(
		runtime,
		campaign,
		DAY_CYCLE,
		map_camera,
		music_player,
		countdown_audio,
		wave_start_audio,
		defeat_audio,
		wave_hud,
		announcement,
		status_hud
	)
	runtime.presentation = coordinator
	return {
		"runtime": runtime,
		"campaign": campaign,
		"coordinator": coordinator,
		"wave_hud": wave_hud,
		"announcement": announcement,
		"music_player": music_player,
		"owned_nodes": [
			wave_hud,
			announcement,
			status_hud,
			map_camera,
			music_player,
			countdown_audio,
			wave_start_audio,
			defeat_audio,
			coordinator,
		] as Array[Node],
	}


func _test_static_scene_contract() -> void:
	var state := TOWER_GAME_SCENE.get_state()
	var presentation_node_count := 0
	for node_index in range(state.get_node_count()):
		if state.get_node_name(node_index) == &"PresentationCoordinator":
			presentation_node_count += 1
	_expect(
		presentation_node_count == 1,
		"塔防生产场景必须且只能静态实例化一个 PresentationCoordinator。"
	)
	_expect(
		TOWER_GAME_SCENE.resource_path.ends_with("tower_defense_game.tscn"),
		"塔防生产场景路径必须保持稳定。"
	)


func _test_lighting_and_announcement(
	coordinator: TowerDefensePresentationCoordinator,
	runtime: PresentationRuntimeProbe,
	announcement: DayPhaseAnnouncement
) -> void:
	coordinator.apply_wave_start_lighting(1)
	coordinator.apply_wave_start_lighting(3)
	coordinator.apply_intermission_lighting(2)
	_expect(
		runtime.day_requests == 2 and runtime.night_requests == 1,
		"昼夜请求必须继续使用 Campaign 规则并经 TowerDefenseGame 虚方法转发。"
	)
	var baseline_count := announcement.presentation_count
	var first := coordinator.announce_wave_phase_start(1, true)
	var duplicate := coordinator.announce_wave_phase_start(1, true)
	var ordinary := coordinator.announce_wave_phase_start(2, true)
	_expect(
		first
		and duplicate
		and not ordinary
		and announcement.presentation_count == baseline_count + 1,
		"昼夜报幕必须保持同一相位去重，且重复首波继续占用开战提示音。"
	)


func _test_hud_and_request_bridge(
	coordinator: TowerDefensePresentationCoordinator,
	wave_hud: TowerDefenseWaveHUD
) -> void:
	var requests: Array[StringName] = []
	coordinator.return_to_lobby_requested.connect(
		func() -> void: requests.append(&"return")
	)
	coordinator.start_wave_requested.connect(
		func() -> void: requests.append(&"start")
	)
	coordinator.configure_status_hud(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	)
	coordinator.configure_wave_hud(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		77,
		100
	)
	coordinator.connect_wave_hud_requests()
	wave_hud.return_to_lobby_requested.emit()
	wave_hud.start_wave_requested.emit()
	coordinator.show_wave_progress(4, 3, 1, 4, 12)
	coordinator.show_enemy_count(8)
	coordinator.show_boss_progress(0, 1)
	_expect(
		requests == [&"return", &"start"],
		"WaveHUD 请求必须按原顺序经 coordinator 信号桥接给 root。"
	)


func _test_countdown_deduplication(
	coordinator: TowerDefensePresentationCoordinator
) -> void:
	coordinator.play_client_countdown_tick_if_new(
		CombatFlowState.State.PRE_WAVE,
		&"wave_01",
		3
	)
	coordinator.play_client_countdown_tick_if_new(
		CombatFlowState.State.PRE_WAVE,
		&"wave_01",
		3
	)
	_expect(
		int(coordinator.get("_client_last_countdown_tick_seconds")) == 3,
		"重复的客户端倒计时秒数不得再次推进去重游标。"
	)
	coordinator.play_client_countdown_tick_if_new(
		CombatFlowState.State.PRE_WAVE,
		&"wave_01",
		2
	)
	_expect(
		int(coordinator.get("_client_last_countdown_tick_seconds")) == 2,
		"倒计时下降时必须按序推进提示音游标。"
	)


func _test_music(
	coordinator: TowerDefensePresentationCoordinator,
	music_player: AudioStreamPlayer
) -> void:
	var stream := AudioStreamGenerator.new()
	coordinator.play_music_stream(stream, -5.0, 0.0, false)
	_expect(
		music_player.stream == stream
		and is_equal_approx(music_player.volume_db, -5.0),
		"音乐流和目标响度必须由 coordinator 原样应用。"
	)
	coordinator.pause_background_music_players(music_player)
	_expect(
		music_player.stream_paused,
		"暂停背景音乐必须继续覆盖 runtime 树中的 Music 播放器。"
	)


func _test_defeat_idempotency(
	coordinator: TowerDefensePresentationCoordinator,
	runtime: PresentationRuntimeProbe
) -> void:
	coordinator.reset_defeat_presentation()
	coordinator.begin_defeat_camera_sequence([])
	coordinator.complete_defeat_presentation()
	_expect(
		runtime.defeat_completions == 1
		and coordinator.defeat_presentation_completed,
		"无可用基地镜头目标时必须立即且幂等完成失败表现。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("TOWER_DEFENSE_PRESENTATION_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
