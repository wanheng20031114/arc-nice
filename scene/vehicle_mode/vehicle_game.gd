extends StandardGame
class_name VehicleGame

const REWARD_CONTROL_LOCK := &"vehicle_wave_reward"
const RESULT_CONTROL_LOCK := &"vehicle_result"

@onready var vehicle_hud: VehicleCombatHUD = $VehicleCombatHUD
@onready var wave_reward: VehicleWaveReward = $VehicleWaveReward

var _pending_reward_wave := 0


func _configure_singleplayer_player() -> void:
	# Running this scene directly in the editor also starts with the vehicle.
	if run_state.get_selected_character_id() != PlayerCharacterRegistry.VEHICLE_ID:
		run_state.begin_new_run(PlayerCharacterRegistry.VEHICLE_ID, false)
	super._configure_singleplayer_player()


func _initialize_mode_player_ui() -> void:
	super._initialize_mode_player_ui()
	currency_hud.hide()
	wave_hud.hide()
	vehicle_hud.bind_player(player)
	vehicle_hud.return_to_menu_requested.connect(_return_to_menu)
	vehicle_hud.inventory_requested.connect(_open_inventory)
	wave_reward.setup(player, run_state)
	wave_reward.reward_claimed.connect(_on_wave_reward_claimed)
	wave_reward.inventory_requested.connect(_open_inventory)
	wave_reward.inventory_close_requested.connect(player_profile_panel.close)
	player_profile_panel.opened.connect(wave_reward.set_inventory_open.bind(true))
	player_profile_panel.closed.connect(wave_reward.set_inventory_open.bind(false))


func _prewarm_mode_runtime_data(preparation_generation: int) -> void:
	await super._prewarm_mode_runtime_data(preparation_generation)
	if is_runtime_preparation_generation_preparing(preparation_generation):
		await LuoxiMerchant.prewarm_collectible_cache(self, preparation_generation)


func _set_intermission_services_active(_active: bool) -> void:
	_set_merchant_active(false)


func _present_flow_countdown(state: CombatFlowState.State, seconds: int) -> void:
	var upcoming_wave := next_flow_step_after_rest as WaveConfig
	var wave_number := (
		_get_wave_number_for_step(upcoming_wave)
		if upcoming_wave != null else current_wave_index + 1
	)
	vehicle_hud.set_countdown(
		wave_number, waves.size(), seconds, state == CombatFlowState.State.INTERMISSION
	)


func _present_wave_started(wave_config: WaveConfig, _is_remote: bool) -> void:
	_update_wave_music(wave_config)
	wave_start_audio.play()
	vehicle_hud.set_wave(
		current_wave_index + 1, waves.size(), wave_config.wave_name, current_wave_total
	)
	_present_wave_progress(current_wave_resolved, current_wave_total)


func _present_wave_progress(defeated_count: int, total_count: int) -> void:
	vehicle_hud.set_progress(
		defeated_count, total_count, wave_enemy_terminal_ledger.get_active_enemy_count()
	)


func _spawn_wave_batch() -> void:
	super._spawn_wave_batch()
	if wave_state == CombatFlowState.State.WAVE_ACTIVE:
		_present_wave_progress(current_wave_resolved, current_wave_total)


func _present_intermission_started(cleared_step: FlowStepConfig) -> void:
	_update_post_wave_music(cleared_step)


func _complete_current_step() -> void:
	if _pending_reward_wave > 0 or wave_state != CombatFlowState.State.WAVE_ACTIVE:
		return
	# Final-wave rewards use the same phase: victory is committed after selection.
	enemy_spawn_timer.stop()
	state_timer.stop()
	wave_state = CombatFlowState.State.INTERMISSION
	next_flow_step_after_rest = _get_default_next_flow_step(current_flow_step)
	_pending_reward_wave = current_wave_index + 1
	player_profile_panel.close()
	player.set_control_lock(REWARD_CONTROL_LOCK, true)
	_present_intermission_started(current_flow_step)
	vehicle_hud.show_reward(_pending_reward_wave)
	if not wave_reward.open_for_wave(_pending_reward_wave):
		push_error("VehicleGame: 无法创建本波的三选一收藏品奖励。")
		_enter_defeat()


func _on_wave_reward_claimed(wave_number: int, _item: PickupConfig) -> void:
	if wave_number != _pending_reward_wave or _pending_reward_wave == 0:
		return
	_pending_reward_wave = 0
	player.set_control_lock(REWARD_CONTROL_LOCK, false)
	if player.is_dead:
		_enter_defeat()
	elif next_flow_step_after_rest == null:
		_enter_victory()
	else:
		_enter_intermission(next_flow_step_after_rest)


func _present_terminal_state(victory: bool) -> void:
	_pending_reward_wave = 0
	wave_reward.cancel()
	player_profile_panel.close()
	player_profile_panel.set_process_unhandled_input(false)
	player.set_control_lock(REWARD_CONTROL_LOCK, false)
	player.set_control_lock(RESULT_CONTROL_LOCK, true)
	boss_coordinator.end_encounter()
	boss_coordinator.stop_presentation()
	if victory:
		vehicle_hud.show_victory()
	else:
		vehicle_hud.show_defeat()


func _hide_mode_wave_presentation() -> void:
	wave_hud.hide_all()
	vehicle_hud.hide_all()


func _open_inventory() -> void:
	if wave_state in [CombatFlowState.State.VICTORY, CombatFlowState.State.DEFEAT]:
		return
	player_profile_panel.open()
	player_profile_panel.tab_bar.current_tab = 0


func _return_to_menu() -> void:
	wave_reward.cancel()
	player_profile_panel.close()
	_on_pause_return_to_main_menu()


func _on_scene_teardown_prepared() -> void:
	wave_reward.cancel()
	_pending_reward_wave = 0
	if player != null:
		player.set_control_lock(REWARD_CONTROL_LOCK, false)
		player.set_control_lock(RESULT_CONTROL_LOCK, false)
	super._on_scene_teardown_prepared()
