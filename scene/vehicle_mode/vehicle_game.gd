extends StandardGame
class_name VehicleGame

const REWARD_CONTROL_LOCK := &"vehicle_wave_reward"
const RESULT_CONTROL_LOCK := &"vehicle_result"
const BRIEFING_CONTROL_LOCK := &"vehicle_briefing"
const ENTRY_PATH := "res://scene/vehicle_mode/vehicle_game.tscn"

@export var save_run_records := true

@onready var vehicle_hud: VehicleCombatHUD = $VehicleCombatHUD
@onready var wave_reward: VehicleWaveReward = $VehicleWaveReward

var _pending_reward_wave := 0
var run_progress := VehicleRunProgress.new()
var _briefing_shown := false
var _briefing_open := false
var _transition_requested := false
var _last_health := 0
var _service_wave := 0


func _ready() -> void:
	super._ready()
	if not runtime_activation_deferred and not is_runtime_preparation_failed():
		activate_runtime()


func _on_runtime_activated() -> void:
	super._on_runtime_activated()
	_show_start_briefing()


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if wave_state == CombatFlowState.State.WAVE_ACTIVE:
		run_progress.advance_time(delta)


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
	player_profile_panel.portrait.material = vehicle_hud.vehicle_portrait.material
	vehicle_hud.return_to_menu_requested.connect(_return_to_menu)
	vehicle_hud.start_requested.connect(_start_from_briefing)
	vehicle_hud.retry_requested.connect(_restart_run)
	vehicle_hud.inventory_requested.connect(_open_inventory)
	wave_reward.setup(player, run_state)
	wave_reward.reward_claimed.connect(_on_wave_reward_claimed)
	wave_reward.inventory_requested.connect(_open_inventory)
	wave_reward.inventory_close_requested.connect(player_profile_panel.close)
	player_profile_panel.opened.connect(wave_reward.set_inventory_open.bind(true))
	player_profile_panel.closed.connect(wave_reward.set_inventory_open.bind(false))
	player_profile_panel.opened.connect(_on_inventory_opened)
	player_profile_panel.closed.connect(_on_inventory_closed)
	_last_health = player.current_health
	player.health_changed.connect(_on_vehicle_health_changed)
	vehicle_hud.set_run_status(run_progress)
	if save_run_records:
		var record_error := run_progress.load_records()
		if record_error not in [OK, ERR_FILE_NOT_FOUND]:
			push_warning("Vehicle records could not be loaded: %s" % error_string(record_error))
	runtime_preparation_completed.connect(vehicle_hud.set_launch_ready.bind(true))


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
	run_progress.begin_wave()
	_update_wave_music(wave_config)
	wave_start_audio.play()
	vehicle_hud.set_wave(
		current_wave_index + 1, waves.size(), wave_config.wave_name, current_wave_total
	)
	_present_wave_progress(current_wave_resolved, current_wave_total)
	vehicle_hud.set_run_status(run_progress)


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
	run_progress.complete_wave(current_wave_index + 1)
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
		if _service_vehicle(wave_number):
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
	run_progress.finish(victory)
	if save_run_records:
		var save_error := run_progress.save_records()
		if save_error != OK:
			push_warning("Vehicle records could not be saved: %s" % error_string(save_error))
	vehicle_hud.set_result_stats(run_progress.get_result_text())
	if victory:
		vehicle_hud.show_victory()
	else:
		vehicle_hud.show_defeat()


func _hide_mode_wave_presentation() -> void:
	wave_hud.hide_all()
	vehicle_hud.hide_all()


func _open_inventory() -> void:
	if _briefing_open or wave_state in [CombatFlowState.State.VICTORY, CombatFlowState.State.DEFEAT]:
		return
	player_profile_panel.open()
	player_profile_panel.tab_bar.current_tab = 0


func _return_to_menu() -> void:
	if _transition_requested:
		return
	_transition_requested = true
	wave_reward.cancel()
	player_profile_panel.close()
	_on_pause_return_to_main_menu()


func _restart_run() -> void:
	if _transition_requested or wave_state not in [CombatFlowState.State.VICTORY, CombatFlowState.State.DEFEAT]:
		return
	_transition_requested = true
	prepare_for_scene_teardown()
	GameplayPauseController.get_autoload_instance().unregister_context(self)
	run_state.begin_new_run(PlayerCharacterRegistry.VEHICLE_ID, false)
	get_node("/root/GameLoadCoordinator").begin_singleplayer(ENTRY_PATH)


func _show_start_briefing() -> void:
	if _briefing_shown:
		return
	_briefing_shown = true
	_briefing_open = true
	state_timer.stop()
	player.set_control_lock(BRIEFING_CONTROL_LOCK, true)
	player_profile_panel.set_process_unhandled_input(false)
	vehicle_hud.show_briefing(run_progress.best_score, is_runtime_preparation_complete())


func _start_from_briefing() -> void:
	if not _briefing_open or not is_runtime_preparation_complete():
		return
	_briefing_open = false
	player.set_control_lock(BRIEFING_CONTROL_LOCK, false)
	player_profile_panel.set_process_unhandled_input(true)
	_enter_pre_flow_step(_get_start_flow_step())


func _service_vehicle(wave_number: int) -> bool:
	if wave_number != _service_wave + 1:
		return false
	# Commit each service once into the canonical run ledger. Add to its existing
	# totals so independent rewards can contribute to these same stats safely.
	var status := run_state.export_party_status_ledger()
	var bonuses := run_state.get_player_stat_bonuses(0)
	bonuses["attack_damage"] += VehicleRunProgress.ATTACK_PER_SERVICE
	bonuses["max_health"] += VehicleRunProgress.HEALTH_PER_SERVICE
	status["player_stat_bonuses"]["0"] = bonuses
	status["revision"] = run_state.party_status_ledger_revision + 1
	if not run_state.apply_party_status_ledger(status):
		push_error("VehicleGame: 波间维修成长账本提交失败。")
		_enter_defeat()
		return false
	_service_wave = wave_number
	player.heal(ceili(player.max_health * VehicleRunProgress.REPAIR_HEALTH_RATIO))
	(player as PlayerVehicle).service_ammunition()
	vehicle_hud.set_service_status(wave_number, player.attack_damage)
	return true


func _on_wave_enemy_defeated(enemy: Enemy) -> void:
	var defeated_before := current_wave_defeated
	super._on_wave_enemy_defeated(enemy)
	if current_wave_defeated > defeated_before:
		run_progress.record_kill()


func _on_vehicle_health_changed(current: int, _maximum: int) -> void:
	if wave_state == CombatFlowState.State.WAVE_ACTIVE:
		run_progress.record_health_loss(_last_health - current)
	_last_health = current


func _on_inventory_opened() -> void:
	GameplayPauseController.get_autoload_instance().acquire_local_modal_pause(player_profile_panel)


func _on_inventory_closed() -> void:
	GameplayPauseController.get_autoload_instance().release_local_modal_pause(player_profile_panel)


func _on_scene_teardown_prepared() -> void:
	wave_reward.cancel()
	player_profile_panel.close()
	_pending_reward_wave = 0
	if player != null:
		player.set_control_lock(REWARD_CONTROL_LOCK, false)
		player.set_control_lock(RESULT_CONTROL_LOCK, false)
		player.set_control_lock(BRIEFING_CONTROL_LOCK, false)
	super._on_scene_teardown_prepared()
