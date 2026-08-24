extends Node
class_name TowerDefenseCampaignCoordinator

const MIN_WAVE_SPAWN_INTERVAL_SECONDS := 0.025
const MAX_WAVE_SPAWN_COUNT_PER_TICK := 4
const FORMAL_FOUR_DAY_CAMPAIGN_IDS: Array[StringName] = [
	&"tower_defense_singleplayer",
	&"tower_defense_multiplayer",
]

enum IntermissionContinuation {
	NONE,
	BEGIN_NEXT_FLOW_STEP,
	BEGIN_ROGUE_EXPLORATION,
}

enum IntermissionCountdownKind {
	WAVE_INTERMISSION,
	NEW_DAY_PREPARATION,
}

signal remote_flow_state_applied(
	step_id: StringName,
	state: CombatFlowState.State,
	seconds: int
)
signal result_entered(state: CombatFlowState.State)
signal terminal_wave_fate_interlude_started

@export var terminal_wave_enters_fate_interlude := false
@export var custom_first_wave_announcement_text := ""

var active_campaign: WaveCampaignConfig = null
var singleplayer_campaign: WaveCampaignConfig = null
var multiplayer_campaign: WaveCampaignConfig = null
var flow_graph: FlowGraphConfig = null
var waves: Array[WaveConfig] = []
var bosses: Array[Resource] = []
var day_cycle_config: DayCycleConfig = null
var configuration_errors: PackedStringArray = []

var wave_state: CombatFlowState.State = CombatFlowState.State.PRE_WAVE:
	set(value):
		wave_state = value
		if _plant_placement_coordinator != null:
			_plant_placement_coordinator.set_flow_state(value)
var current_flow_step: FlowStepConfig = null
var next_flow_step_after_rest: FlowStepConfig = null
var intermission_continuation: IntermissionContinuation = (
	IntermissionContinuation.NONE
)
var intermission_countdown_kind: IntermissionCountdownKind = (
	IntermissionCountdownKind.WAVE_INTERMISSION
)
var current_wave_index := 0
var wave_enemy_terminal_ledger := WaveEnemyTerminalLedger.new()
var current_wave_total: int:
	get:
		return wave_enemy_terminal_ledger.get_total()
var current_wave_spawned: int:
	get:
		return wave_enemy_terminal_ledger.get_spawned()
var current_wave_defeated: int:
	get:
		return wave_enemy_terminal_ledger.get_defeated()
var current_wave_escaped: int:
	get:
		return wave_enemy_terminal_ledger.get_escaped()
var current_wave_removed: int:
	get:
		return wave_enemy_terminal_ledger.get_removed()
var current_wave_resolved: int:
	get:
		return wave_enemy_terminal_ledger.get_resolved()
var countdown_seconds := 0

# Replicated wave progress has no independent revision and arrives on both the
# reliable flow channel and the ordered progress channel. Keep its wave epoch
# separate from current_flow_step so a late packet from the previous wave
# cannot overwrite a newer flow state.
var _last_remote_wave_progress_number := 0

var progression_started_msec := 0
var first_defense_tower_seconds := -1.0
var water_chain_online_seconds := -1.0
var daily_xirang_rewards: Dictionary[int, int] = {}
var progression_day_records: Array[Dictionary] = []

var _runtime_port: TowerDefenseCampaignRuntimePort
var _enemy_coordinator: TowerDefenseEnemyCoordinator
var _presentation_coordinator: TowerDefensePresentationCoordinator
var _boss_coordinator: TowerDefenseBossCoordinator
var _player_roster_coordinator: TowerDefensePlayerRosterCoordinator
var _prewarmer_coordinator: TowerDefensePrewarmerCoordinator
var _fate_flow_coordinator: TowerDefenseFateFlowCoordinator
var _rogue_exploration_coordinator: TowerDefenseRogueExplorationCoordinator
var _multiplayer_adapter: TowerDefenseMultiplayerModeAdapter
var _plant_placement_coordinator: TowerDefensePlantPlacementCoordinator
var _home_defense_coordinator: TowerDefenseHomeDefenseCoordinator
var _state_timer: Timer
var _enemy_spawn_timer: Timer
var _progression_config: TowerDefenseProgressionConfig
var _run_state: RunStateStore
var _production_coordinator: ProductionCoordinator
var _luoxi_special_game_coordinator: LuoxiSpecialGameCoordinator
var _luoxi_merchant: TowerDefenseLuoxiMerchant
var _day_phase_announcements_enabled := true
var _custom_first_wave_announcement_shown := false
var _intermission_rogue_day_number := 0
var _intermission_completion_started := false
var _intermission_zero_flow_state_published := false


func configure(
	runtime_mode: int,
	definition: GameModeDefinition,
	singleplayer_campaign: WaveCampaignConfig,
	multiplayer_campaign: WaveCampaignConfig,
	configured_day_cycle: DayCycleConfig
) -> bool:
	clear()
	day_cycle_config = configured_day_cycle
	var resolved_singleplayer := singleplayer_campaign
	var resolved_multiplayer := multiplayer_campaign
	if (
		definition != null
		and resolved_singleplayer == null
		and not definition.singleplayer_campaign_path.is_empty()
	):
		resolved_singleplayer = load(
			definition.singleplayer_campaign_path
		) as WaveCampaignConfig
	if (
		definition != null
		and resolved_multiplayer == null
		and not definition.multiplayer_campaign_path.is_empty()
	):
		resolved_multiplayer = load(
			definition.multiplayer_campaign_path
		) as WaveCampaignConfig
	self.singleplayer_campaign = resolved_singleplayer
	self.multiplayer_campaign = resolved_multiplayer
	active_campaign = (
		resolved_singleplayer
		if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else resolved_multiplayer
	)
	if active_campaign == null:
		configuration_errors.append(
			"TowerDefense Campaign 缺少当前运行模式的 WaveCampaignConfig。"
		)
		return false
	configuration_errors.append_array(active_campaign.validate_campaign())
	if not configuration_errors.is_empty():
		return false
	flow_graph = active_campaign.flow_graph
	waves.assign(active_campaign.get_waves())
	for boss_config in active_campaign.get_bosses():
		bosses.append(boss_config)
	return true


func setup_runtime(
	runtime_port: TowerDefenseCampaignRuntimePort,
	enemy_coordinator: TowerDefenseEnemyCoordinator,
	presentation_coordinator: TowerDefensePresentationCoordinator,
	boss_coordinator: TowerDefenseBossCoordinator,
	player_roster_coordinator: TowerDefensePlayerRosterCoordinator,
	prewarmer_coordinator: TowerDefensePrewarmerCoordinator,
	fate_flow_coordinator: TowerDefenseFateFlowCoordinator,
	rogue_exploration_coordinator: TowerDefenseRogueExplorationCoordinator,
	multiplayer_adapter: TowerDefenseMultiplayerModeAdapter,
	plant_placement_coordinator: TowerDefensePlantPlacementCoordinator,
	home_defense_coordinator: TowerDefenseHomeDefenseCoordinator,
	state_timer: Timer,
	enemy_spawn_timer: Timer,
	progression_config: TowerDefenseProgressionConfig,
	run_state: RunStateStore,
	production_coordinator: ProductionCoordinator,
	luoxi_special_game_coordinator: LuoxiSpecialGameCoordinator,
	luoxi_merchant: TowerDefenseLuoxiMerchant,
	day_phase_announcements_enabled: bool
) -> bool:
	_runtime_port = runtime_port
	_enemy_coordinator = enemy_coordinator
	_presentation_coordinator = presentation_coordinator
	_boss_coordinator = boss_coordinator
	_player_roster_coordinator = player_roster_coordinator
	_prewarmer_coordinator = prewarmer_coordinator
	_fate_flow_coordinator = fate_flow_coordinator
	_rogue_exploration_coordinator = rogue_exploration_coordinator
	_multiplayer_adapter = multiplayer_adapter
	_plant_placement_coordinator = plant_placement_coordinator
	_home_defense_coordinator = home_defense_coordinator
	_state_timer = state_timer
	_enemy_spawn_timer = enemy_spawn_timer
	_progression_config = progression_config
	_run_state = run_state
	_production_coordinator = production_coordinator
	_luoxi_special_game_coordinator = luoxi_special_game_coordinator
	_luoxi_merchant = luoxi_merchant
	_day_phase_announcements_enabled = day_phase_announcements_enabled
	wave_state = wave_state
	return is_runtime_bound()


func is_runtime_bound() -> bool:
	return (
		_runtime_port != null
		and _runtime_port.is_bound()
		and _enemy_coordinator != null
		and _presentation_coordinator != null
		and _boss_coordinator != null
		and _player_roster_coordinator != null
		and _prewarmer_coordinator != null
		and _fate_flow_coordinator != null
		and _rogue_exploration_coordinator != null
		and _multiplayer_adapter != null
		and _plant_placement_coordinator != null
		and _home_defense_coordinator != null
		and _state_timer != null
		and _enemy_spawn_timer != null
		and _progression_config != null
		and _run_state != null
		and _production_coordinator != null
		and _luoxi_special_game_coordinator != null
		and _luoxi_merchant != null
	)


func stop_state_timer() -> void:
	if _state_timer != null:
		_state_timer.stop()


func stop_enemy_spawn_timer() -> void:
	if _enemy_spawn_timer != null:
		_enemy_spawn_timer.stop()


## 以下转场命令是非倒计时流程写入 Campaign 状态的唯一公共入口。
## 调用方负责各自的表现与业务启动；Campaign 原子维护 step/state/countdown
## 并停止两个只属于塔防流程的 timer，避免流程节点只改一半状态。
func transition_to_fate_interlude(next_step: FlowStepConfig) -> void:
	next_flow_step_after_rest = next_step
	_commit_non_countdown_flow_state(CombatFlowState.State.FATE_INTERLUDE)


## 远端 Fate 的 step_id 表示 Host 当前流程节点，后继节点由 Fate 快照持有；
## 因此这里只提交表现对应的 state/timer，不伪造 next_flow_step_after_rest。
func synchronize_remote_fate_interlude_state() -> void:
	next_flow_step_after_rest = null
	_commit_non_countdown_flow_state(CombatFlowState.State.FATE_INTERLUDE)


func transition_to_rogue_exploration(next_step: FlowStepConfig) -> bool:
	if next_step == null:
		push_error("TowerDefenseCampaignCoordinator: Rogue 转场缺少后继流程节点。")
		return false
	next_flow_step_after_rest = next_step
	_commit_non_countdown_flow_state(CombatFlowState.State.ROGUE_EXPLORATION)
	return true


func transition_to_boss_intro(boss_step: BossConfig) -> bool:
	if boss_step == null:
		push_error("TowerDefenseCampaignCoordinator: Boss intro 缺少 BossConfig。")
		return false
	var entering_boss_flow := wave_state not in [
		CombatFlowState.State.BOSS_INTRO,
		CombatFlowState.State.BOSS_ACTIVE,
	]
	current_flow_step = boss_step
	next_flow_step_after_rest = null
	if entering_boss_flow:
		reset_wave_progress(1, 1)
	_commit_non_countdown_flow_state(CombatFlowState.State.BOSS_INTRO)
	return true


func transition_to_boss_active(boss_step: BossConfig) -> bool:
	if boss_step == null:
		push_error("TowerDefenseCampaignCoordinator: Boss active 缺少 BossConfig。")
		return false
	var entering_boss_flow := wave_state not in [
		CombatFlowState.State.BOSS_INTRO,
		CombatFlowState.State.BOSS_ACTIVE,
	]
	current_flow_step = boss_step
	next_flow_step_after_rest = null
	if entering_boss_flow:
		reset_wave_progress(1, 1)
	_commit_non_countdown_flow_state(CombatFlowState.State.BOSS_ACTIVE)
	return true


## 仅供无完整 runtime 的边界测试设置竞态前置状态；生产流程不得调用。
func replace_flow_state_for_fixture(
	state: CombatFlowState.State,
	flow_step: FlowStepConfig = null,
	next_step: FlowStepConfig = null,
	seconds: int = 0
) -> void:
	wave_state = state
	current_flow_step = flow_step
	next_flow_step_after_rest = next_step
	countdown_seconds = maxi(seconds, 0)
	_clear_intermission_context()
	if state == CombatFlowState.State.INTERMISSION and next_step != null:
		intermission_continuation = (
			IntermissionContinuation.BEGIN_NEXT_FLOW_STEP
		)


func _commit_non_countdown_flow_state(state: CombatFlowState.State) -> void:
	wave_state = state
	countdown_seconds = 0
	_clear_intermission_context()
	stop_state_timer()
	stop_enemy_spawn_timer()


func _clear_intermission_context() -> void:
	intermission_continuation = IntermissionContinuation.NONE
	intermission_countdown_kind = (
		IntermissionCountdownKind.WAVE_INTERMISSION
	)
	_intermission_rogue_day_number = 0
	_intermission_completion_started = false
	_intermission_zero_flow_state_published = false


func clear() -> void:
	active_campaign = null
	singleplayer_campaign = null
	multiplayer_campaign = null
	flow_graph = null
	waves.clear()
	bosses.clear()
	configuration_errors.clear()
	_clear_intermission_context()
	_last_remote_wave_progress_number = 0
	reset_wave_progress(0)


## Campaign 持有波次账本；Enemy/Home/Boss 只提交带实体身份的终结事务。
func reset_wave_progress(total: int, spawned: int = 0) -> void:
	if not wave_enemy_terminal_ledger.reset(total, spawned):
		push_error("TowerDefenseCampaignCoordinator: 非法波次进度重置被拒绝。")


func register_wave_enemy(
	enemy_id: int,
	role: WaveEnemyTerminalLedger.EnemyRole
) -> bool:
	return wave_enemy_terminal_ledger.register_enemy(enemy_id, role)


func try_resolve_wave_enemy(
	enemy_id: int,
	reason: CombatTypes.EnemyTerminalReason
) -> bool:
	return wave_enemy_terminal_ledger.resolve_enemy(enemy_id, reason)


func detach_wave_enemy(enemy_id: int) -> WaveEnemyTerminalLedger.DetachResult:
	return wave_enemy_terminal_ledger.detach_enemy(enemy_id)


func is_wave_enemy_active(enemy_id: int) -> bool:
	return wave_enemy_terminal_ledger.is_enemy_active(enemy_id)


func has_wave_enemy_record(enemy_id: int) -> bool:
	return wave_enemy_terminal_ledger.has_enemy(enemy_id)


func is_wave_enemy_defeat_committed(enemy_id: int) -> bool:
	return (
		wave_enemy_terminal_ledger.get_terminal_reason(enemy_id)
		== CombatTypes.EnemyTerminalReason.DEFEATED
	)


func get_attached_wave_enemy_ids(role_filter: int = -1) -> Dictionary:
	return wave_enemy_terminal_ledger.get_attached_enemy_ids(role_filter)


func get_attached_wave_enemy_count(role_filter: int = -1) -> int:
	return wave_enemy_terminal_ledger.get_attached_enemy_count(role_filter)


func clear_wave_enemy_entities() -> void:
	wave_enemy_terminal_ledger.clear_entities()


func apply_remote_wave_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> bool:
	# Boss 与最后一波可能共享 wave_number，但 Boss 有独立的权威生命与
	# 生命周期复制。进入 Boss step 后必须彻底隔离通用 wave_progress 流，
	# 否则跨 RPC channel 迟到的末波包无法仅凭数值与 Boss 包区分。
	if current_flow_step is BossConfig:
		return false
	if (
		wave_number <= 0
		or defeated < 0
		or escaped < 0
		or resolved < 0
		or total < 0
		or defeated + escaped > resolved
		or resolved > total
	):
		return false
	var current_flow_wave_number := current_wave_index + 1
	if (
		wave_number < current_flow_wave_number
		or wave_number < _last_remote_wave_progress_number
	):
		return false
	var starts_new_remote_wave := (
		wave_number > _last_remote_wave_progress_number
	)
	var removed := resolved - defeated - escaped
	if (
		not starts_new_remote_wave
		and (
			total != current_wave_total
			or defeated < current_wave_defeated
			or escaped < current_wave_escaped
			or removed < current_wave_removed
			or resolved < current_wave_resolved
		)
	):
		return false
	var previous_spawned := 0 if starts_new_remote_wave else current_wave_spawned
	var snapshot_spawned := clampi(
		maxi(previous_spawned, resolved),
		0,
		total
	)
	if not wave_enemy_terminal_ledger.apply_snapshot(
		total,
		snapshot_spawned,
		defeated,
		escaped,
		removed
	):
		return false
	current_wave_index = wave_number - 1
	_last_remote_wave_progress_number = wave_number
	return true


func is_wave_progress_complete() -> bool:
	return wave_enemy_terminal_ledger.is_complete()


func get_wave_progress_snapshot() -> Dictionary:
	return {
		"wave_number": current_wave_index + 1,
		"defeated": current_wave_defeated,
		"escaped": current_wave_escaped,
		"resolved": current_wave_resolved,
		"total": current_wave_total,
	}


## 只供无真实实体的边界测试构造完整账本状态。
func replace_wave_terminal_state_for_fixture(
	total: int,
	spawned: int,
	defeated: int,
	escaped: int = 0,
	removed: int = 0
) -> bool:
	return wave_enemy_terminal_ledger.reset(
		total, spawned, defeated, escaped, removed
	)


func get_replicated_wave_progress_snapshot() -> Dictionary:
	if not current_flow_step is WaveConfig:
		return {}
	return get_wave_progress_snapshot()


func replace_runtime_state_for_fixture(
	fixture_flow_graph: FlowGraphConfig,
	fixture_waves: Array[WaveConfig],
	fixture_bosses: Array[Resource]
) -> void:
	flow_graph = fixture_flow_graph
	waves.assign(fixture_waves)
	bosses.assign(fixture_bosses)


func validate_flow_graph() -> PackedStringArray:
	if flow_graph == null:
		return PackedStringArray([
			"TowerDefense Campaign 没有配置 FlowGraphConfig。",
		])
	return flow_graph.validate_graph()


func get_start_flow_step() -> FlowStepConfig:
	return flow_graph.start_step if flow_graph != null else null


func get_flow_step_by_id(step_id: StringName) -> FlowStepConfig:
	if step_id == &"" or flow_graph == null:
		return null
	return flow_graph.get_step_by_id(step_id)


func get_flow_step_id(flow_step: FlowStepConfig) -> StringName:
	return flow_step.step_id if flow_step != null else &""


func get_default_next_flow_step(flow_step: FlowStepConfig) -> FlowStepConfig:
	if (
		flow_step == null
		or flow_graph == null
		or flow_graph.get_step_index(flow_step) < 0
	):
		return null
	return flow_graph.get_default_next_step(flow_step)


func get_wave_number_for_step(
	wave_config: WaveConfig,
	fallback_wave_index: int
) -> int:
	if wave_config == null:
		return fallback_wave_index + 1
	var wave_index := waves.find(wave_config)
	if wave_index >= 0:
		return wave_index + 1
	if flow_graph != null:
		var wave_number := 0
		for step in flow_graph.steps:
			if step is WaveConfig:
				wave_number += 1
			if step == wave_config:
				return maxi(wave_number, 1)
	return fallback_wave_index + 1


func get_configured_bosses() -> Array[BossConfig]:
	var result: Array[BossConfig] = []
	if flow_graph != null:
		for step in flow_graph.steps:
			var boss_step := step as BossConfig
			if boss_step != null:
				result.append(boss_step)
	if result.is_empty():
		for boss_resource in bosses:
			var boss_config := boss_resource as BossConfig
			if boss_config != null:
				result.append(boss_config)
	return result


func is_night_wave(wave_number: int) -> bool:
	return day_cycle_config != null and day_cycle_config.is_night_wave(wave_number)


func is_night_intermission_after_wave(completed_wave_number: int) -> bool:
	return (
		day_cycle_config != null
		and day_cycle_config.is_night_intermission_after_wave(completed_wave_number)
	)


func get_day_number_for_wave(wave_number: int) -> int:
	return day_cycle_config.get_day_number(wave_number) if day_cycle_config != null else 1


func get_wave_in_day(wave_number: int) -> int:
	return day_cycle_config.get_wave_in_day(wave_number) if day_cycle_config != null else 1


func is_day_end_wave(wave_number: int) -> bool:
	return day_cycle_config != null and day_cycle_config.is_day_end_wave(wave_number)


func should_record_day(
	runtime_mode: int,
	day_number: int,
	existing_records: Array[Dictionary]
) -> bool:
	if runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW or day_number <= 0:
		return false
	for record in existing_records:
		if int(record.get("day", 0)) == day_number:
			return false
	return true


func request_wave_start(requester_peer_id: int = 0) -> bool:
	if _runtime_port.get_runtime_mode() == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	if (
		_runtime_port.get_runtime_mode()
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and (
			requester_peer_id != _runtime_port.get_local_peer_id()
			or not _runtime_port.has_peer_player(requester_peer_id)
		)
	):
		return false
	if wave_state not in [
		CombatFlowState.State.PRE_WAVE,
		CombatFlowState.State.INTERMISSION,
	]:
		return false
	var flow_step := (
		current_flow_step
		if wave_state == CombatFlowState.State.PRE_WAVE
		else next_flow_step_after_rest
	)
	if flow_step == null or countdown_seconds <= TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS:
		return false
	countdown_seconds = TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS
	_show_current_countdown(false)
	_presentation_coordinator.play_countdown_tick()
	_state_timer.start(1.0)
	publish_flow_state(wave_state)
	return true


func enter_pre_flow_step(flow_step: FlowStepConfig) -> void:
	if flow_step == null:
		enter_victory()
		return
	wave_state = CombatFlowState.State.PRE_WAVE
	_clear_intermission_context()
	_presentation_coordinator.transition_world_to_day()
	current_flow_step = flow_step
	next_flow_step_after_rest = flow_step
	if flow_step is WaveConfig:
		current_wave_index = get_wave_number_for_step(
			flow_step as WaveConfig,
			current_wave_index
		) - 1
	_enemy_spawn_timer.stop()
	_multiplayer_adapter.set_merchant_active(true)
	countdown_seconds = get_initial_preparation_seconds()
	_presentation_coordinator.update_post_wave_music(flow_step)
	_presentation_coordinator.show_countdown(
		countdown_seconds,
		can_local_player_start_wave_early()
	)
	_prewarmer_coordinator.schedule_enemy_navigation_prewarm(
		_runtime_port.get_runtime_preparation_generation()
	)
	publish_flow_state(CombatFlowState.State.PRE_WAVE)

	if countdown_seconds <= 0:
		begin_flow_step(current_flow_step)
		return
	if countdown_seconds <= TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS:
		_presentation_coordinator.play_countdown_tick()
	_state_timer.start(1.0)


func enter_intermission(next_step: FlowStepConfig = null) -> void:
	_presentation_coordinator.apply_intermission_lighting(
		maxi(current_wave_index + 1, 1)
	)
	_start_intermission_countdown(
		next_step,
		IntermissionContinuation.BEGIN_NEXT_FLOW_STEP,
		IntermissionCountdownKind.WAVE_INTERMISSION,
		0
	)


func enter_day_end_rogue_intermission(
	completed_day_number: int,
	next_step: FlowStepConfig
) -> bool:
	var completed_wave := current_flow_step as WaveConfig
	var completed_wave_number := get_wave_number_for_step(
		completed_wave,
		current_wave_index
	)
	if (
		completed_wave == null
		or next_step == null
		or completed_day_number < 1
		or completed_day_number
		> TowerDefenseProgressionConfig.ROGUE_EXPLORATION_DAY_COUNT
		or get_day_number_for_wave(completed_wave_number) != completed_day_number
		or not should_enter_daily_rogue_exploration(completed_wave_number)
	):
		push_error(
			"TowerDefenseCampaignCoordinator: 日终 Rogue 休整上下文无效。"
		)
		return false
	_presentation_coordinator.apply_intermission_lighting(completed_wave_number)
	_start_intermission_countdown(
		next_step,
		IntermissionContinuation.BEGIN_ROGUE_EXPLORATION,
		IntermissionCountdownKind.WAVE_INTERMISSION,
		completed_day_number
	)
	return true


func enter_new_day_preparation(next_step: FlowStepConfig) -> void:
	if next_step == null:
		enter_victory()
		return
	current_flow_step = next_step
	if next_step is WaveConfig:
		current_wave_index = get_wave_number_for_step(
			next_step as WaveConfig,
			current_wave_index
		) - 1
	_presentation_coordinator.transition_world_to_day()
	_start_intermission_countdown(
		next_step,
		IntermissionContinuation.BEGIN_NEXT_FLOW_STEP,
		IntermissionCountdownKind.NEW_DAY_PREPARATION,
		0
	)


func _start_intermission_countdown(
	next_step: FlowStepConfig,
	continuation: IntermissionContinuation,
	countdown_kind: IntermissionCountdownKind,
	rogue_day_number: int
) -> void:
	wave_state = CombatFlowState.State.INTERMISSION
	_enemy_spawn_timer.stop()
	_multiplayer_adapter.set_merchant_active(true)
	next_flow_step_after_rest = next_step
	intermission_continuation = continuation
	intermission_countdown_kind = countdown_kind
	_intermission_rogue_day_number = rogue_day_number
	_intermission_completion_started = false
	_intermission_zero_flow_state_published = false
	countdown_seconds = get_current_intermission_seconds()
	_presentation_coordinator.update_post_wave_music(current_flow_step)
	_show_current_countdown(can_local_player_start_wave_early())
	publish_flow_state(CombatFlowState.State.INTERMISSION)
	_intermission_zero_flow_state_published = countdown_seconds <= 0
	_player_roster_coordinator.force_revive_dead_players(true)

	if countdown_seconds <= 0:
		complete_intermission()
		return
	if countdown_seconds <= TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS:
		_presentation_coordinator.play_countdown_tick()
	_state_timer.start(1.0)


func complete_intermission() -> void:
	if (
		wave_state != CombatFlowState.State.INTERMISSION
		or _intermission_completion_started
	):
		return
	if countdown_seconds > 0:
		return
	_intermission_completion_started = true
	match intermission_continuation:
		IntermissionContinuation.BEGIN_NEXT_FLOW_STEP:
			var next_step := next_flow_step_after_rest
			begin_flow_step(next_step)
		IntermissionContinuation.BEGIN_ROGUE_EXPLORATION:
			_publish_day_end_intermission_zero_if_needed()
			if not _rogue_exploration_coordinator.begin_exploration_transfer(
				_intermission_rogue_day_number,
				next_flow_step_after_rest
			):
				enter_defeat()
		_:
			push_error(
				"TowerDefenseCampaignCoordinator: 休整结束时缺少显式后继类型。"
			)
			enter_defeat()


func _publish_day_end_intermission_zero_if_needed() -> void:
	if _intermission_zero_flow_state_published:
		return
	countdown_seconds = 0
	publish_flow_state(CombatFlowState.State.INTERMISSION)
	_intermission_zero_flow_state_published = true


func begin_flow_step(flow_step: FlowStepConfig) -> void:
	if flow_step == null:
		enter_victory()
		return
	current_flow_step = flow_step
	next_flow_step_after_rest = null
	_clear_intermission_context()
	if flow_step is WaveConfig:
		begin_wave_config(flow_step as WaveConfig)
	elif flow_step is BossConfig:
		_boss_coordinator.begin_intro(flow_step as BossConfig)
	else:
		push_error("流程节点 %s 类型不支持。" % flow_step.get_flow_display_name())
		enter_defeat()


func begin_wave_config(wave_config: WaveConfig) -> void:
	if wave_config == null:
		push_error("流程节点缺少 WaveConfig。")
		enter_defeat()
		return
	if not _enemy_coordinator.resolve_spawn_points(wave_config):
		enter_defeat()
		return
	_prewarmer_coordinator.ensure_navigation_prewarmed_sync()

	wave_state = CombatFlowState.State.WAVE_ACTIVE
	_player_roster_coordinator.reset_wave_death_counts()
	current_wave_index = get_wave_number_for_step(
		wave_config,
		current_wave_index
	) - 1
	_presentation_coordinator.apply_wave_start_lighting(current_wave_index + 1)
	var phase_announcement_started := _announce_wave_phase_start(
		current_wave_index + 1
	)
	_state_timer.stop()
	_multiplayer_adapter.set_merchant_active(false)
	_home_defense_coordinator.clear_resolved_enemy_ids()
	_enemy_coordinator.clear_active_enemies()
	_enemy_coordinator.clear_hud_alive_enemies()
	var wave_total := _enemy_coordinator.begin_wave(
		wave_config,
		_progression_config,
		_runtime_port.get_progression_player_count()
	)
	reset_wave_progress(wave_total)
	_presentation_coordinator.update_wave_music(wave_config)
	_enemy_coordinator.show_wave_progress()
	if not phase_announcement_started:
		_presentation_coordinator.play_wave_start_audio()
	publish_flow_state(CombatFlowState.State.WAVE_ACTIVE)

	if current_wave_total <= 0:
		_enemy_coordinator.check_wave_completion()
		return
	_enemy_coordinator.spawn_wave_batch(MAX_WAVE_SPAWN_COUNT_PER_TICK)
	if _enemy_coordinator.has_pending_queue():
		_enemy_spawn_timer.start(
			maxf(wave_config.spawn_interval, MIN_WAVE_SPAWN_INTERVAL_SECONDS)
		)


func on_state_timer_timeout() -> void:
	if _runtime_port.get_runtime_mode() == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		update_client_flow_countdown()
		return
	if wave_state not in [
		CombatFlowState.State.PRE_WAVE,
		CombatFlowState.State.INTERMISSION,
	]:
		_state_timer.stop()
		return

	countdown_seconds = maxi(countdown_seconds - 1, 0)
	if countdown_seconds > 0:
		_show_current_countdown(can_local_player_start_wave_early())
		if countdown_seconds <= TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS:
			_presentation_coordinator.play_countdown_tick()
		return

	_state_timer.stop()
	if wave_state == CombatFlowState.State.PRE_WAVE:
		begin_flow_step(current_flow_step)
		return
	complete_intermission()


func start_client_flow_countdown(
	state: CombatFlowState.State,
	step_id: StringName,
	seconds: int
) -> void:
	wave_state = state
	var flow_step := get_flow_step_by_id(step_id)
	_clear_intermission_context()
	if flow_step != null:
		current_flow_step = flow_step
		if state == CombatFlowState.State.INTERMISSION:
			_configure_remote_intermission_context(flow_step)
		if flow_step is WaveConfig:
			current_wave_index = get_wave_number_for_step(
				flow_step as WaveConfig,
				current_wave_index
			) - 1
	if state in [
		CombatFlowState.State.PRE_WAVE,
		CombatFlowState.State.INTERMISSION,
	]:
		_multiplayer_adapter.set_local_merchants_active(true)
		_presentation_coordinator.update_post_wave_music(flow_step)
	countdown_seconds = maxi(seconds, 0)
	_show_current_countdown(can_local_player_start_wave_early())
	_presentation_coordinator.play_client_countdown_tick_if_new(
		state,
		step_id,
		countdown_seconds
	)
	if countdown_seconds <= 0:
		_state_timer.stop()
		return
	_state_timer.start(1.0)


func update_client_flow_countdown() -> void:
	if wave_state not in [
		CombatFlowState.State.PRE_WAVE,
		CombatFlowState.State.INTERMISSION,
	]:
		_state_timer.stop()
		return
	countdown_seconds = maxi(countdown_seconds - 1, 0)
	_show_current_countdown(can_local_player_start_wave_early())
	if countdown_seconds <= 0:
		_state_timer.stop()
		return
	_presentation_coordinator.play_client_countdown_tick_if_new(
		wave_state,
		get_flow_step_id(current_flow_step),
		countdown_seconds
	)


func apply_remote_flow_state(
	step_id: StringName,
	state: int,
	seconds: int
) -> void:
	if _runtime_port.get_runtime_mode() != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var typed_state := state as CombatFlowState.State
	var flow_step := get_flow_step_by_id(step_id)
	if (
		flow_step == null
		and typed_state not in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	):
		push_error(
			"TowerDefenseCampaignCoordinator: 收到当前 Campaign 不存在的流程 step_id：%s"
			% String(step_id)
		)
		return
	if _fate_flow_coordinator.should_defer_remote_flow_state(step_id, state, seconds):
		return
	var remote_rogue_day_number := (
		_get_rogue_intermission_day_number(flow_step)
		if typed_state == CombatFlowState.State.INTERMISSION
		else 0
	)
	var should_begin_remote_rogue_transfer := (
		remote_rogue_day_number > 0
		and seconds <= 0
		and _progression_config.get_daily_rogue_action_points(
			remote_rogue_day_number
		) > 0
	)
	if (
		typed_state != CombatFlowState.State.ROGUE_EXPLORATION
		and not should_begin_remote_rogue_transfer
	):
		_rogue_exploration_coordinator.cancel_pending_exploration_transfer()
	var leaving_fate_interlude := (
		_fate_flow_coordinator.is_leaving_remote_interlude(typed_state)
	)
	if flow_step != null:
		current_flow_step = flow_step
		if flow_step is WaveConfig:
			current_wave_index = get_wave_number_for_step(
				flow_step as WaveConfig,
				current_wave_index
			) - 1
	if (
		_rogue_exploration_coordinator.has_pending_presentation_exit()
		and typed_state not in [
			CombatFlowState.State.ROGUE_EXPLORATION,
			CombatFlowState.State.FATE_INTERLUDE,
		]
	):
		_rogue_exploration_coordinator.complete_pending_presentation_exit()
	var entering_fate_from_pending_rogue := (
		typed_state == CombatFlowState.State.FATE_INTERLUDE
		and _rogue_exploration_coordinator.has_pending_presentation_exit()
	)
	if not entering_fate_from_pending_rogue:
		_fate_flow_coordinator.set_interlude_systems_frozen(
			typed_state == CombatFlowState.State.FATE_INTERLUDE
		)
	match typed_state:
		CombatFlowState.State.PRE_WAVE:
			_presentation_coordinator.transition_world_to_day()
			start_client_flow_countdown(typed_state, step_id, seconds)
		CombatFlowState.State.INTERMISSION:
			if _is_new_day_preparation_step(flow_step):
				_presentation_coordinator.transition_world_to_day()
			else:
				_presentation_coordinator.apply_intermission_lighting(
					maxi(current_wave_index + 1, 1)
				)
			start_client_flow_countdown(typed_state, step_id, seconds)
		CombatFlowState.State.WAVE_ACTIVE:
			next_flow_step_after_rest = null
			_commit_non_countdown_flow_state(
				CombatFlowState.State.WAVE_ACTIVE
			)
			var wave_number := maxi(current_wave_index + 1, 1)
			_presentation_coordinator.apply_wave_start_lighting(wave_number)
			var phase_started := _announce_wave_phase_start(wave_number)
			_multiplayer_adapter.set_local_merchants_active(false)
			var wave_config := flow_step as WaveConfig
			if wave_config != null:
				_presentation_coordinator.update_wave_music(wave_config)
			_enemy_coordinator.show_wave_progress()
			if not phase_started:
				_presentation_coordinator.play_wave_start_audio()
		CombatFlowState.State.BOSS_INTRO:
			if flow_step is BossConfig and is_formal_four_day_campaign():
				_presentation_coordinator.transition_world_to_day()
			_boss_coordinator.apply_remote_flow_state(
				CombatFlowState.State.BOSS_INTRO,
				flow_step as BossConfig
			)
		CombatFlowState.State.BOSS_ACTIVE:
			if flow_step is BossConfig and is_formal_four_day_campaign():
				_presentation_coordinator.transition_world_to_day()
			_boss_coordinator.apply_remote_flow_state(
				CombatFlowState.State.BOSS_ACTIVE,
				flow_step as BossConfig
			)
		CombatFlowState.State.FATE_INTERLUDE:
			_fate_flow_coordinator.apply_remote_interlude_flow(
				get_day_number_for_wave(maxi(current_wave_index + 1, 1))
			)
		CombatFlowState.State.ROGUE_EXPLORATION:
			next_flow_step_after_rest = null
			_commit_non_countdown_flow_state(
				CombatFlowState.State.ROGUE_EXPLORATION
			)
			_multiplayer_adapter.set_local_merchants_active(false)
		CombatFlowState.State.VICTORY:
			enter_victory(false)
		CombatFlowState.State.DEFEAT:
			enter_defeat(false)
	if should_begin_remote_rogue_transfer:
		_rogue_exploration_coordinator.begin_remote_exploration_transfer()
	if leaving_fate_interlude:
		_fate_flow_coordinator.complete_remote_flow_transition()
	remote_flow_state_applied.emit(step_id, typed_state, seconds)


func get_flow_state_snapshot() -> Dictionary:
	return {
		"step_id": get_flow_step_id(current_flow_step),
		"state": int(wave_state),
		"countdown_seconds": countdown_seconds,
	}


func complete_current_step() -> void:
	var next_step := get_default_next_flow_step(current_flow_step)
	var completed_wave := current_flow_step as WaveConfig
	var completed_wave_number := (
		get_wave_number_for_step(completed_wave, current_wave_index)
		if completed_wave != null
		else 0
	)
	var completed_day := completed_wave != null and is_day_end_wave(completed_wave_number)
	if completed_day:
		record_progression_day(get_day_number_for_wave(completed_wave_number))
	if (
		terminal_wave_enters_fate_interlude
		and completed_wave != null
		and active_campaign != null
		and active_campaign.get_waves().size() == 1
		and next_step == null
	):
		terminal_wave_fate_interlude_started.emit()
		_fate_flow_coordinator.enter_interlude(null)
		return
	if next_step == null:
		enter_victory()
		return
	if completed_day:
		var completed_day_number := get_day_number_for_wave(
			completed_wave_number
		)
		if should_enter_daily_rogue_exploration(completed_wave_number):
			if not enter_day_end_rogue_intermission(
				completed_day_number,
				next_step
			):
				enter_defeat()
			return
		_fate_flow_coordinator.enter_interlude(next_step)
		return
	enter_intermission(next_step)


func resume_flow_after_fate_interlude(next_step_id: StringName) -> void:
	var next_step := get_flow_step_by_id(next_step_id)
	enter_new_day_preparation(next_step)


func should_enter_daily_rogue_exploration(completed_wave_number: int) -> bool:
	return (
		_rogue_exploration_coordinator != null
		and is_formal_four_day_campaign()
		and completed_wave_number in [4, 8, 12]
	)


func is_formal_four_day_campaign() -> bool:
	return (
		active_campaign != null
		and active_campaign.campaign_id in FORMAL_FOUR_DAY_CAMPAIGN_IDS
		and waves.size() == 12
		and _progression_config != null
		and _progression_config.daily_rogue_action_points.size()
		== TowerDefenseProgressionConfig.ROGUE_EXPLORATION_DAY_COUNT
	)


func _is_day_four_boss_preparation() -> bool:
	return (
		wave_state == CombatFlowState.State.INTERMISSION
		and intermission_continuation
		== IntermissionContinuation.BEGIN_NEXT_FLOW_STEP
		and intermission_countdown_kind
		== IntermissionCountdownKind.NEW_DAY_PREPARATION
		and next_flow_step_after_rest is BossConfig
		and is_formal_four_day_campaign()
	)


func resume_flow_after_rogue_exploration(next_step_id: StringName) -> void:
	var next_step := get_flow_step_by_id(next_step_id)
	_fate_flow_coordinator.enter_interlude(next_step)


func enter_day_four_boss_preparation(boss_step: BossConfig) -> void:
	enter_new_day_preparation(boss_step)


func enter_victory(emit_multiplayer: bool = true) -> void:
	if wave_state == CombatFlowState.State.VICTORY:
		return
	wave_enemy_terminal_ledger.resolve_all_active_as_removed()
	_luoxi_special_game_coordinator.cancel_all()
	_luoxi_merchant.abort_special_game()
	_plant_placement_coordinator.cancel_placement()
	_presentation_coordinator.cancel_defeat_camera()
	_presentation_coordinator.restore_camera_after_boss_intro(
		_runtime_port.get_local_player()
	)
	_clear_intermission_context()
	wave_state = CombatFlowState.State.VICTORY
	_presentation_coordinator.transition_world_to_day()
	_player_roster_coordinator.force_revive_dead_players(emit_multiplayer)
	_player_roster_coordinator.clear_result_respawn_state()
	_presentation_coordinator.clear_result_status()
	_presentation_coordinator.stop_gate_damage_warning()
	_enemy_spawn_timer.stop()
	_state_timer.stop()
	_multiplayer_adapter.set_merchant_active(false)
	_boss_coordinator.stop_presentation()
	_presentation_coordinator.show_victory()
	result_entered.emit(CombatFlowState.State.VICTORY)
	if (
		emit_multiplayer
		and _runtime_port.get_runtime_mode()
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		_multiplayer_adapter.victory_started.emit()
		publish_flow_state(CombatFlowState.State.VICTORY)


func enter_defeat(emit_multiplayer: bool = true) -> void:
	if wave_state == CombatFlowState.State.DEFEAT:
		return
	wave_enemy_terminal_ledger.resolve_all_active_as_removed()
	_luoxi_special_game_coordinator.cancel_all()
	_luoxi_merchant.abort_special_game()
	_plant_placement_coordinator.cancel_placement()
	_clear_intermission_context()
	wave_state = CombatFlowState.State.DEFEAT
	_presentation_coordinator.transition_world_to_day()
	_presentation_coordinator.reset_defeat_presentation()
	_player_roster_coordinator.clear_result_respawn_state()
	_presentation_coordinator.clear_result_status()
	_enemy_spawn_timer.stop()
	_state_timer.stop()
	_multiplayer_adapter.set_merchant_active(false)
	_presentation_coordinator.stop_background_music_for_defeat()
	_boss_coordinator.stop_presentation()
	_presentation_coordinator.hide_wave_hud()
	result_entered.emit(CombatFlowState.State.DEFEAT)
	if (
		emit_multiplayer
		and _runtime_port.get_runtime_mode()
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		_multiplayer_adapter.defeat_started.emit()
	_presentation_coordinator.begin_defeat_camera_sequence(
		_home_defense_coordinator.get_home_targets()
	)


func complete_defeat_presentation() -> void:
	_presentation_coordinator.replace_defeat_camera_tween(null)
	if wave_state == CombatFlowState.State.DEFEAT:
		_presentation_coordinator.complete_defeat_presentation()


func publish_flow_state(state: CombatFlowState.State) -> void:
	_multiplayer_adapter.publish_flow_state(state)


func get_initial_preparation_seconds() -> int:
	return maxi(ceili(_progression_config.initial_preparation_seconds), 0)


func get_wave_intermission_seconds() -> int:
	return maxi(ceili(_progression_config.wave_intermission_seconds), 0)


func get_new_day_preparation_seconds() -> int:
	return maxi(ceili(_progression_config.new_day_preparation_seconds), 0)


func get_current_intermission_seconds() -> int:
	return (
		get_new_day_preparation_seconds()
		if intermission_countdown_kind
		== IntermissionCountdownKind.NEW_DAY_PREPARATION
		else get_wave_intermission_seconds()
	)


func is_day_end_rogue_intermission() -> bool:
	return (
		wave_state == CombatFlowState.State.INTERMISSION
		and intermission_continuation
		== IntermissionContinuation.BEGIN_ROGUE_EXPLORATION
	)


func _configure_remote_intermission_context(flow_step: FlowStepConfig) -> void:
	var rogue_day_number := _get_rogue_intermission_day_number(flow_step)
	if rogue_day_number > 0:
		intermission_continuation = (
			IntermissionContinuation.BEGIN_ROGUE_EXPLORATION
		)
		intermission_countdown_kind = (
			IntermissionCountdownKind.WAVE_INTERMISSION
		)
		_intermission_rogue_day_number = rogue_day_number
		next_flow_step_after_rest = get_default_next_flow_step(flow_step)
		return
	intermission_continuation = (
		IntermissionContinuation.BEGIN_NEXT_FLOW_STEP
	)
	intermission_countdown_kind = (
		IntermissionCountdownKind.NEW_DAY_PREPARATION
		if _is_new_day_preparation_step(flow_step)
		else IntermissionCountdownKind.WAVE_INTERMISSION
	)
	next_flow_step_after_rest = (
		flow_step
		if intermission_countdown_kind
		== IntermissionCountdownKind.NEW_DAY_PREPARATION
		else get_default_next_flow_step(flow_step)
	)


func _get_rogue_intermission_day_number(flow_step: FlowStepConfig) -> int:
	var wave_config := flow_step as WaveConfig
	if wave_config == null:
		return 0
	var wave_number := get_wave_number_for_step(
		wave_config,
		current_wave_index
	)
	if not should_enter_daily_rogue_exploration(wave_number):
		return 0
	return get_day_number_for_wave(wave_number)


func _is_new_day_preparation_step(flow_step: FlowStepConfig) -> bool:
	if not is_formal_four_day_campaign():
		return false
	if flow_step is BossConfig:
		return true
	var wave_config := flow_step as WaveConfig
	if wave_config == null:
		return false
	var wave_number := get_wave_number_for_step(
		wave_config,
		current_wave_index
	)
	return wave_number > 1 and get_wave_in_day(wave_number) == 1


func _show_current_countdown(can_start_early: bool) -> void:
	if _is_day_four_boss_preparation():
		_presentation_coordinator.show_day_four_boss_preparation(
			countdown_seconds,
			can_start_early
		)
		return
	_presentation_coordinator.show_countdown(
		countdown_seconds,
		can_start_early,
		(
			TowerDefenseWaveHUD.CountdownTarget.ROGUE_EXPLORATION
			if is_day_end_rogue_intermission()
			else TowerDefenseWaveHUD.CountdownTarget.NEXT_WAVE
		)
	)


func can_local_player_start_wave_early() -> bool:
	return (
		_runtime_port.get_runtime_mode() != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		and countdown_seconds > TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS
	)


func _announce_wave_phase_start(wave_number: int) -> bool:
	if (
		wave_number == 1
		and not custom_first_wave_announcement_text.strip_edges().is_empty()
	):
		if not _custom_first_wave_announcement_shown:
			_custom_first_wave_announcement_shown = true
			_presentation_coordinator.show_custom_phase_announcement(
				custom_first_wave_announcement_text
			)
		return true
	return _presentation_coordinator.announce_wave_phase_start(
		wave_number,
		_day_phase_announcements_enabled
	)


func start_progression_metrics() -> void:
	if progression_started_msec <= 0:
		progression_started_msec = int(
			GameplayPauseController.get_global_gameplay_time_seconds() * 1000.0
		)


func get_progression_elapsed_seconds() -> float:
	if progression_started_msec <= 0:
		return 0.0
	return maxf(
		float(
			int(
				GameplayPauseController.get_global_gameplay_time_seconds() * 1000.0
			)
			- progression_started_msec
		) / 1000.0,
		0.0
	)


func track_progression_plant_placement(plant: PlantDefense) -> void:
	if (
		_runtime_port.get_runtime_mode() == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or plant == null
		or plant.config == null
	):
		return
	var elapsed_seconds := get_progression_elapsed_seconds()
	if (
		first_defense_tower_seconds < 0.0
		and plant.config.building_category
		== PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER
	):
		first_defense_tower_seconds = elapsed_seconds
	if (
		water_chain_online_seconds < 0.0
		and plant.config.plant_id == PlantDefenseRegistry.WATER_COLLECTOR_ID
	):
		water_chain_online_seconds = elapsed_seconds


func record_xirang_reward(amount: int) -> void:
	if amount <= 0:
		return
	var day_number := get_day_number_for_wave(current_wave_index + 1)
	daily_xirang_rewards[day_number] = (
		int(daily_xirang_rewards.get(day_number, 0)) + amount
	)


func record_progression_day(day_number: int) -> void:
	if not should_record_day(
		_runtime_port.get_runtime_mode(),
		day_number,
		progression_day_records
	):
		return
	var inventory_materials := _get_tracked_inventory_material_totals()
	var shared_materials := _get_tracked_shared_material_totals()
	var combined_materials := inventory_materials.duplicate()
	for config_path_variant in shared_materials:
		var config_path := String(config_path_variant)
		combined_materials[config_path] = (
			int(combined_materials.get(config_path, 0))
			+ int(shared_materials[config_path_variant])
		)
	progression_day_records.append({
		"day": day_number,
		"elapsed_seconds": get_progression_elapsed_seconds(),
		"building_count": _get_active_progression_building_count(),
		"daily_xirang": int(daily_xirang_rewards.get(day_number, 0)),
		"inventory_materials": inventory_materials,
		"shared_storage_materials": shared_materials,
		"combined_materials": combined_materials,
	})


func _get_active_progression_building_count() -> int:
	var building_count := 0
	for plant_variant in get_tree().get_nodes_in_group(&"plant_defense"):
		var plant := plant_variant as PlantDefense
		if (
			plant != null
			and is_instance_valid(plant)
			and not plant.is_dead
			and not plant.is_removing
		):
			building_count += 1
	return building_count


func _get_tracked_inventory_material_totals() -> Dictionary:
	var totals := {}
	for item in _progression_config.tracked_materials:
		var total := 0
		if _runtime_port.get_runtime_mode() == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
			total = _run_state.get_inventory_item_total(item)
		else:
			for peer_id in _runtime_port.get_peer_ids():
				total += _run_state.get_inventory_item_total_for_peer(peer_id, item)
		totals[item.resource_path] = total
	return totals


func _get_tracked_shared_material_totals() -> Dictionary:
	var totals := {}
	for item in _progression_config.tracked_materials:
		totals[item.resource_path] = _production_coordinator.get_total_item_count(item)
	return totals


func get_progression_metrics_snapshot() -> Dictionary:
	var first_day_building_count := -1
	for record in progression_day_records:
		if int(record.get("day", 0)) == 1:
			first_day_building_count = int(record.get("building_count", -1))
			break
	return {
		"first_defense_tower_seconds": first_defense_tower_seconds,
		"water_chain_online_seconds": water_chain_online_seconds,
		"first_day_building_count": first_day_building_count,
		"daily_xirang_rewards": daily_xirang_rewards.duplicate(true),
		"day_records": progression_day_records.duplicate(true),
	}
