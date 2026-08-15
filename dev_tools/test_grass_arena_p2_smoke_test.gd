extends SceneTree

const ARENA_SCENE := preload("res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p2.tscn")
const TEST_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/p2/singleplayer/campaign.tres"
)
const MULTIPLAYER_TEST_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/p2/multiplayer/campaign.tres"
)
const SLIME_CONFIG := preload("res://resources/config/enemies/slime.tres")

var failures: Array[String] = []
var arena: TestGrassArenaP2


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(PlayerCharacterRegistry.WEISHIDAIER_ID)
	arena = ARENA_SCENE.instantiate() as TestGrassArenaP2
	_expect(arena != null, "P2 必须实例化为 TestGrassArenaP2。")
	if arena == null:
		_finish()
		return
	arena.auto_start_waves = false
	root.add_child(arena)
	current_scene = arena
	await _wait_frames(3)

	_test_campaign_contract()
	_test_inherited_arena_and_interlude()
	_test_entry_announcement_disabled()
	await _test_one_kill_completes_day()

	current_scene = null
	arena.queue_free()
	await _wait_frames(3)
	_finish()


func _test_entry_announcement_disabled() -> void:
	_expect(
		arena.test_entry_announcement_text.is_empty()
		and not arena.day_phase_announcements_enabled
		and arena.day_phase_announcement.presentation_count == 0,
		"P2继承P1时不得误播“测试场景 P1”报幕。"
	)


func _test_campaign_contract() -> void:
	_expect(
		arena.singleplayer_campaign == TEST_CAMPAIGN,
		"P2 必须绑定独立的单史莱姆 Campaign。"
	)
	_expect(
		arena.multiplayer_campaign == MULTIPLAYER_TEST_CAMPAIGN,
		"P2 必须绑定独立的多人单史莱姆 Campaign。"
	)
	_expect(
		TEST_CAMPAIGN.validate_campaign().is_empty(),
		"P2 Campaign 必须通过流程校验。"
	)
	var waves := TEST_CAMPAIGN.get_waves()
	_expect(waves.size() == 1, "P2 必须只有一个波次。")
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(wave.enemy_entries.size() == 1, "P2 唯一波次必须只有一个敌人条目。")
	_expect(wave.get_total_enemy_count() == 1, "P2 唯一波次必须总共只生成一只敌人。")
	if wave.enemy_entries.size() == 1:
		var entry := wave.enemy_entries[0]
		_expect(
			entry.enemy_config == SLIME_CONFIG and entry.count == 1,
			"P2 敌人必须精确为一只普通史莱姆。"
		)
	_expect(wave.max_alive_enemies == 1, "P2 场上敌人上限必须为一只。")
	var multiplayer_waves := MULTIPLAYER_TEST_CAMPAIGN.get_waves()
	_expect(
		MULTIPLAYER_TEST_CAMPAIGN.validate_campaign().is_empty()
		and multiplayer_waves.size() == 1
		and multiplayer_waves[0].get_total_enemy_count() == 1,
		"P2 多人 Campaign 必须通过校验并精确保留一只普通史莱姆。"
	)
	_expect(
		is_zero_approx(
			arena.progression_config.enemy_count_per_extra_player_ratio
		)
		and arena.progression_config.get_scaled_enemy_count(1, 8) == 1,
		"P2 测试敌人数不得随多人房间人数缩放。"
	)
	arena.enemy_coordinator.begin_wave(
		wave,
		arena.progression_config,
		arena.campaign_runtime_port.get_progression_player_count()
	)
	_expect(
		arena.enemy_coordinator.pending_enemy_configs == [SLIME_CONFIG],
		"P2 运行时生成队列必须精确包含一只普通史莱姆。"
	)
	arena.enemy_coordinator.clear_queue()


func _test_inherited_arena_and_interlude() -> void:
	_expect(
		arena.dual_grid_terrain.world_map_layer.get_used_rect()
		== TestGrassArena.GRASS_RECT,
		"P2 必须完整继承 P1 的 16×16 草地。"
	)
	var interlude_count := 0
	for candidate in arena.find_children("*", "", true, false):
		if candidate is XiaocongFateInterlude:
			interlude_count += 1
	_expect(
		interlude_count == 1
		and arena.xiaocong_fate_interlude == arena.get_node("XiaocongFateInterlude"),
		"P2 必须复用继承链中的唯一小葱暗室。"
	)


func _test_one_kill_completes_day() -> void:
	var wave := TEST_CAMPAIGN.get_waves()[0]
	arena.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.WAVE_ACTIVE,
		wave
	)
	arena.campaign_coordinator.current_wave_index = 0
	arena.campaign_coordinator.replace_wave_terminal_state_for_fixture(1, 1, 1)
	arena.enemy_coordinator.clear_active_enemies()
	arena.enemy_coordinator.clear_queue()
	arena.enemy_coordinator.check_wave_completion()
	var fate_interlude_ready := await _wait_for_fate_interlude(5.0)

	var hint_layer := arena.get_node("TestControlsHint") as CanvasLayer
	_expect(
		arena.campaign_coordinator.wave_state
		== CombatFlowState.State.FATE_INTERLUDE,
		"唯一史莱姆被击败后必须直接进入一整天结束的小葱流程。"
	)
	_expect(
		arena.campaign_coordinator.progression_day_records.size() == 1
		and int(arena.campaign_coordinator.progression_day_records[0].get(
			"day", 0
		)) == 1,
		"P2 完成唯一敌人后必须记录第 1 天完整进度。"
	)
	_expect(
		fate_interlude_ready
		and arena.fate_manager.active
		and arena.fate_manager.completed_day == 1
		and arena.xiaocong_fate_interlude.is_active,
		"P2 必须启动正式的小葱命运管理与暗室交互。"
	)
	_expect(
		not hint_layer.visible
		and arena.player.global_position.x > 8000.0
		and arena.player.global_position.y > 8000.0,
		"进入暗室后必须隐藏测试提示，并把玩家传送至隔离的小葱区域。"
	)

	# 通过 FateManager 的公开测试入口发出完成信号，让 FateFlow 负责遮罩、
	# 房间退场、玩家回传与 Campaign 恢复，禁止再调用已抽取的 Game 私有方法。
	arena.fate_manager.force_finish()
	var entered_victory := await _wait_for_wave_state(
		CombatFlowState.State.VICTORY,
		5.0
	)
	_expect(
		entered_victory,
		"P2 小葱日结完成且无后续波次时必须进入胜利。"
	)


func _wait_for_fate_interlude(timeout_seconds: float) -> bool:
	var deadline_msec := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if arena.fate_manager.active and arena.xiaocong_fate_interlude.is_active:
			return true
		await process_frame
		await physics_frame
	return false


func _wait_for_wave_state(target_state: int, timeout_seconds: float) -> bool:
	var deadline_msec := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		if arena.campaign_coordinator.wave_state == target_state:
			return true
		await process_frame
		await physics_frame
	return false


func _wait_frames(frame_count: int) -> void:
	for _frame in frame_count:
		await process_frame
		await physics_frame


func _finish() -> void:
	if failures.is_empty():
		print("TEST_GRASS_ARENA_P2_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
