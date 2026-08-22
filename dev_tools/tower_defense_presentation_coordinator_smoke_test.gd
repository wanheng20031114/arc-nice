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
	"res://scene/game_modes/tower_defense/ui/day_phase_announcement.tscn"
)
const STATUS_HUD_SCENE := preload(
	"res://scene/game_modes/tower_defense/ui/tower_defense_status_hud.tscn"
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

	func transition_world_to_day(_duration_seconds: float = -1.0) -> void:
		day_requests += 1

	func transition_world_to_night(_duration_seconds: float = -1.0) -> void:
		night_requests += 1


class PresentationCampaignProbe:
	extends TowerDefenseCampaignCoordinator

	var defeat_completions := 0
	var presentation: TowerDefensePresentationCoordinator = null

	func complete_defeat_presentation() -> void:
		defeat_completions += 1
		presentation.complete_defeat_presentation()


class PresentationPlantPlacementProbe:
	extends TowerDefensePlantPlacementCoordinator

	var exclusive_modal_open := false

	func has_exclusive_modal_open() -> bool:
		return exclusive_modal_open


class OutputDetailBuildingProbe:
	extends ProductionBuilding

	var visibility_requests: Array[bool] = []

	func set_output_detail_visible(visible: bool) -> void:
		output_detail_visible = visible
		visibility_requests.append(visible)


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
	var campaign := fixture["campaign"] as PresentationCampaignProbe
	var wave_hud := fixture["wave_hud"] as TowerDefenseWaveHUD
	var announcement := fixture["announcement"] as DayPhaseAnnouncement
	var music_player := fixture["music_player"] as AudioStreamPlayer
	var plant_system := fixture["plant_system"] as PlantSystem
	var plant_placement := (
		fixture["plant_placement"] as PresentationPlantPlacementProbe
	)
	var existing_building := (
		fixture["existing_building"] as OutputDetailBuildingProbe
	)

	_expect(coordinator.is_bound(), "PresentationCoordinator 必须完成强类型依赖绑定。")
	_test_output_detail_visibility(
		coordinator,
		plant_system,
		plant_placement,
		existing_building
	)
	_test_lighting_and_announcement(coordinator, runtime, announcement)
	_test_hud_and_request_bridge(coordinator, wave_hud)
	_test_countdown_deduplication(coordinator)
	_test_music(coordinator, music_player)
	_test_defeat_idempotency(coordinator, campaign)
	_test_plant_system_rebinding(fixture)

	plant_system.plant_footprints.clear()
	existing_building.free()
	for owned_node in fixture["owned_nodes"] as Array[Node]:
		owned_node.queue_free()
	runtime.free()
	campaign.free()
	await process_frame
	_finish()


func _create_fixture() -> Dictionary:
	var runtime := PresentationRuntimeProbe.new()
	var campaign := PresentationCampaignProbe.new()
	campaign.day_cycle_config = DAY_CYCLE
	var coordinator := PRESENTATION_SCENE.instantiate() as TowerDefensePresentationCoordinator
	var wave_hud := WAVE_HUD_SCENE.instantiate() as TowerDefenseWaveHUD
	var announcement := DAY_ANNOUNCEMENT_SCENE.instantiate() as DayPhaseAnnouncement
	var status_hud := STATUS_HUD_SCENE.instantiate() as TowerDefenseStatusHUD
	var plant_placement := PresentationPlantPlacementProbe.new()
	var plant_system := PlantSystem.new()
	var existing_building := OutputDetailBuildingProbe.new()
	plant_system.plant_footprints[existing_building] = []
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
		plant_placement,
		plant_system,
		coordinator,
	]:
		root.add_child(node)
	await process_frame
	coordinator.setup(
		runtime,
		campaign,
		plant_placement,
		plant_system,
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
	campaign.presentation = coordinator
	return {
		"runtime": runtime,
		"campaign": campaign,
		"coordinator": coordinator,
		"wave_hud": wave_hud,
		"announcement": announcement,
		"music_player": music_player,
		"plant_system": plant_system,
		"plant_placement": plant_placement,
		"existing_building": existing_building,
		"map_camera": map_camera,
		"countdown_audio": countdown_audio,
		"wave_start_audio": wave_start_audio,
		"defeat_audio": defeat_audio,
		"status_hud": status_hud,
		"owned_nodes": [
			wave_hud,
			announcement,
			status_hud,
			map_camera,
			music_player,
			countdown_audio,
			wave_start_audio,
			defeat_audio,
			plant_placement,
			plant_system,
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
	var tower_scene_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
	)
	for expected_connection in [
		'[connection signal="profile_requested" from="CurrencyHUD" to="PresentationCoordinator" method="open_player_profile"]',
		'[connection signal="settings_requested" from="CurrencyHUD" to="PresentationCoordinator" method="open_settings"]',
		'[connection signal="return_to_lobby_requested" from="WaveHUD" to="PresentationCoordinator" method="_on_wave_hud_return_to_lobby_requested"]',
		'[connection signal="start_wave_requested" from="WaveHUD" to="PresentationCoordinator" method="_on_wave_hud_start_wave_requested"]',
	]:
		_expect(
			tower_scene_source.contains(expected_connection),
			"塔防模式 UI 请求必须在生产场景中静态连接到 PresentationCoordinator。"
		)
	var root_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.gd"
	)
	_expect(
		not root_source.contains("func _configure_minimap")
		and not root_source.contains("func _toggle_full_screen")
		and not root_source.contains("settings_requested.connect")
		and root_source.contains(
			"presentation_coordinator.handle_unhandled_input(event)"
		),
		"塔防根脚本只应委托模式 UI 输入，不能重新持有表现实现或动态信号连接。"
	)
	var presentation_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/presentation/tower_defense_presentation_coordinator.gd"
	)
	_expect(
		presentation_source.contains('event.is_action_pressed(&"show_detail")')
		and presentation_source.contains("and not event.is_echo()")
		and presentation_source.contains(
			"not _plant_placement_coordinator.has_exclusive_modal_open()"
		)
		and presentation_source.contains(
			"get_viewport().set_input_as_handled()"
		)
		and not presentation_source.contains("rpc("),
		"产物详情开关必须拒绝按键连发、服从独占模态门禁、消费输入，且不得进入 RPC 边界。"
	)


func _test_output_detail_visibility(
	coordinator: TowerDefensePresentationCoordinator,
	plant_system: PlantSystem,
	plant_placement: PresentationPlantPlacementProbe,
	existing_building: OutputDetailBuildingProbe
) -> void:
	_expect(
		not bool(coordinator.get("_output_detail_visible"))
		and existing_building.visibility_requests == [false],
		"每局产物详情必须默认关闭，并立即应用到已放置的生产建筑。"
	)
	var toggle_event := InputEventAction.new()
	toggle_event.action = &"show_detail"
	toggle_event.pressed = true
	coordinator.handle_unhandled_input(toggle_event)
	_expect(
		bool(coordinator.get("_output_detail_visible"))
		and existing_building.visibility_requests == [false, true],
		"show_detail 必须切换本地状态并更新现有生产建筑。"
	)
	var echo_event := InputEventKey.new()
	echo_event.physical_keycode = KEY_C
	echo_event.pressed = true
	echo_event.echo = true
	coordinator.handle_unhandled_input(echo_event)
	_expect(
		bool(coordinator.get("_output_detail_visible"))
		and existing_building.visibility_requests == [false, true],
		"show_detail 的键盘回响事件不得重复切换或刷新生产详情。"
	)
	plant_placement.exclusive_modal_open = true
	coordinator.handle_unhandled_input(toggle_event)
	_expect(
		bool(coordinator.get("_output_detail_visible"))
		and existing_building.visibility_requests == [false, true],
		"独占模态界面打开时不得切换或刷新产物详情。"
	)
	plant_placement.exclusive_modal_open = false
	coordinator.handle_unhandled_input(toggle_event)
	var hidden_new_building := OutputDetailBuildingProbe.new()
	plant_system.plant_placed.emit(hidden_new_building)
	_expect(
		not bool(coordinator.get("_output_detail_visible"))
		and hidden_new_building.visibility_requests == [false],
		"关闭状态下新放置的生产建筑必须立即继承隐藏状态。"
	)
	hidden_new_building.free()
	coordinator.handle_unhandled_input(toggle_event)
	var visible_new_building := OutputDetailBuildingProbe.new()
	plant_system.plant_placed.emit(visible_new_building)
	_expect(
		bool(coordinator.get("_output_detail_visible"))
		and visible_new_building.visibility_requests == [true],
		"开启状态下新放置的生产建筑必须立即继承显示状态。"
	)
	visible_new_building.free()


func _test_plant_system_rebinding(fixture: Dictionary) -> void:
	var coordinator := fixture["coordinator"] as TowerDefensePresentationCoordinator
	var old_plant_system := fixture["plant_system"] as PlantSystem
	var callback := Callable(coordinator, "_on_plant_placed")
	_setup_fixture_coordinator(fixture, old_plant_system)
	_expect(
		old_plant_system.plant_placed.is_connected(callback)
		and bool(coordinator.get("_output_detail_visible")),
		"重复 setup 必须保持单一 plant_placed 连接和本局本地开关状态。"
	)
	var same_system_probe := OutputDetailBuildingProbe.new()
	old_plant_system.plant_placed.emit(same_system_probe)
	_expect(
		same_system_probe.visibility_requests == [true],
		"重复绑定同一 PlantSystem 后 plant_placed 回调不得重复触发。"
	)
	same_system_probe.free()

	var replacement_plant_system := PlantSystem.new()
	var replacement_existing_probe := OutputDetailBuildingProbe.new()
	replacement_plant_system.plant_footprints[replacement_existing_probe] = []
	root.add_child(replacement_plant_system)
	(fixture["owned_nodes"] as Array[Node]).append(replacement_plant_system)
	_setup_fixture_coordinator(fixture, replacement_plant_system)
	_expect(
		not old_plant_system.plant_placed.is_connected(callback)
		and replacement_plant_system.plant_placed.is_connected(callback)
		and replacement_existing_probe.visibility_requests == [true],
		"更换 PlantSystem 时必须断开旧信号、连接新信号，并应用当前本地显示状态。"
	)
	var stale_probe := OutputDetailBuildingProbe.new()
	old_plant_system.plant_placed.emit(stale_probe)
	var active_probe := OutputDetailBuildingProbe.new()
	replacement_plant_system.plant_placed.emit(active_probe)
	_expect(
		stale_probe.visibility_requests.is_empty()
		and active_probe.visibility_requests == [true],
		"更换 PlantSystem 后只有当前系统的新建筑能够继承本地显示状态。"
	)
	stale_probe.free()
	active_probe.free()
	replacement_plant_system.plant_footprints.clear()
	replacement_existing_probe.free()


func _setup_fixture_coordinator(
	fixture: Dictionary,
	plant_system: PlantSystem
) -> void:
	var coordinator := fixture["coordinator"] as TowerDefensePresentationCoordinator
	coordinator.setup(
		fixture["runtime"] as PresentationRuntimeProbe,
		fixture["campaign"] as PresentationCampaignProbe,
		fixture["plant_placement"] as PresentationPlantPlacementProbe,
		plant_system,
		DAY_CYCLE,
		fixture["map_camera"] as Camera2D,
		fixture["music_player"] as AudioStreamPlayer,
		fixture["countdown_audio"] as AudioStreamPlayer,
		fixture["wave_start_audio"] as AudioStreamPlayer,
		fixture["defeat_audio"] as AudioStreamPlayer,
		fixture["wave_hud"] as TowerDefenseWaveHUD,
		fixture["announcement"] as DayPhaseAnnouncement,
		fixture["status_hud"] as TowerDefenseStatusHUD
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
	campaign: PresentationCampaignProbe
) -> void:
	coordinator.reset_defeat_presentation()
	coordinator.begin_defeat_camera_sequence([])
	coordinator.complete_defeat_presentation()
	_expect(
		campaign.defeat_completions == 1
		and coordinator.defeat_presentation_completed,
		"无可用基地镜头目标时必须经 CampaignCoordinator 强类型边界立即且幂等完成失败表现。"
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
