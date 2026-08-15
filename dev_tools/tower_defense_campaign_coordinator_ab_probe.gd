extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const FIXED_SEEDS: Array[int] = [0x15A71C, 0x2468ACE, 0x5EEDCA]
const EVENTS_PER_ROUND := 192

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var campaign := game.campaign_coordinator
	var combined_hash := 17
	for seed in FIXED_SEEDS:
		combined_hash = _combine_hash(
			combined_hash,
			_run_round(game, campaign, seed)
		)

	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print(
			"TOWER_DEFENSE_CAMPAIGN_COORDINATOR_AB_PROBE_OK rounds=3 trajectory_hash=%d"
			% combined_hash
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_round(
	game: TowerDefenseGame,
	campaign: TowerDefenseCampaignCoordinator,
	seed: int
) -> int:
	var random := RandomNumberGenerator.new()
	random.seed = seed
	var trace_hash := 23
	var steps := campaign.flow_graph.steps
	for event_index in range(EVENTS_PER_ROUND):
		match random.randi_range(0, 4):
			0:
				if campaign.waves.is_empty():
					continue
				var wave := campaign.waves[
					random.randi_range(0, campaign.waves.size() - 1)
				]
				var fallback := random.randi_range(0, 12)
				var expected := _legacy_wave_number(
					campaign.flow_graph,
					campaign.waves,
					wave,
					fallback
				)
				var actual := campaign.get_wave_number_for_step(wave, fallback)
				_expect(expected == actual, "波次序号轨迹在事件 %d 漂移。" % event_index)
				trace_hash = _combine_hash(trace_hash, actual)
			1:
				if steps.is_empty():
					continue
				var step := steps[random.randi_range(0, steps.size() - 1)]
				var step_id := step.step_id if step != null else &""
				var resolved := campaign.get_flow_step_by_id(step_id)
				_expect(resolved == step, "流程 ID 解析在事件 %d 漂移。" % event_index)
				trace_hash = _combine_hash(trace_hash, String(step_id).hash())
			2:
				var day := random.randi_range(-1, 8)
				var records: Array[Dictionary] = []
				if random.randi_range(0, 1) == 1:
					records.append({"day": random.randi_range(1, 8)})
				var expected := _legacy_should_record_day(
					CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
					day,
					records
				)
				var actual := campaign.should_record_day(
					CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
					day,
					records
				)
				_expect(expected == actual, "成长日去重在事件 %d 漂移。" % event_index)
				trace_hash = _combine_hash(trace_hash, 1 if actual else 0)
			3:
				var start_step := campaign.get_start_flow_step()
				var initial_seconds := random.randi_range(4, 30)
				# A/B 基线刻意复现抽取前的逐字段写入；普通测试必须使用
				# replace_flow_state_for_fixture，勿照搬此旧路径。
				campaign.wave_state = CombatFlowState.State.PRE_WAVE
				campaign.current_flow_step = start_step
				campaign.next_flow_step_after_rest = start_step
				campaign.countdown_seconds = initial_seconds
				var accepted := campaign.request_wave_start()
				var expected_seconds := (
					TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS
					if start_step != null
					else initial_seconds
				)
				_expect(
					accepted == (start_step != null)
					and campaign.countdown_seconds == expected_seconds,
					"提前开波倒计时在事件 %d 漂移。" % event_index
				)
				game.state_timer.stop()
				trace_hash = _combine_hash(trace_hash, campaign.countdown_seconds)
			_:
				var initial_seconds := random.randi_range(5, 30)
				# 同上：保留旧写法只为比较计时行为，不是生产状态入口。
				campaign.wave_state = CombatFlowState.State.PRE_WAVE
				campaign.current_flow_step = campaign.get_start_flow_step()
				campaign.countdown_seconds = initial_seconds
				campaign.on_state_timer_timeout()
				_expect(
					campaign.countdown_seconds == initial_seconds - 1,
					"状态计时器在事件 %d 漂移。" % event_index
				)
				game.state_timer.stop()
				trace_hash = _combine_hash(trace_hash, campaign.countdown_seconds)
	return trace_hash


func _legacy_wave_number(
	graph: FlowGraphConfig,
	waves: Array[WaveConfig],
	wave: WaveConfig,
	fallback_index: int
) -> int:
	var direct_index := waves.find(wave)
	if direct_index >= 0:
		return direct_index + 1
	var wave_number := 0
	for step in graph.steps:
		if step is WaveConfig:
			wave_number += 1
		if step == wave:
			return maxi(wave_number, 1)
	return fallback_index + 1


func _legacy_should_record_day(
	runtime_mode: int,
	day_number: int,
	records: Array[Dictionary]
) -> bool:
	if runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW or day_number <= 0:
		return false
	for record in records:
		if int(record.get("day", 0)) == day_number:
			return false
	return true


func _combine_hash(current: int, value: int) -> int:
	return int((current * 65599 + value) & 0x7fffffff)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
