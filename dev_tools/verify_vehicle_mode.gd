extends Node

## Headless integration check for the authored vehicle scene. It follows the
## loader's deferred preparation/activation path, real spawn batches and lethal
## damage/terminal bookkeeping. Only timer waiting and combat aiming are skipped.
## RunState is changed in memory; this script never saves settings or progress.
## Run the authored verify_vehicle_mode.tscn so production autoloads are available.

const ENTRY_PATH := "res://scene/vehicle_mode/vehicle_game.tscn"
const CAMPAIGN_PATH := "res://resources/config/campaigns/vehicle/singleplayer/campaign.tres"
const PREPARATION_TIMEOUT_MS := 90000
const EXPECTED_WAVES := 12

var failures := 0
var assertions := 0
var killed_enemies := 0
var claimed_rewards := 0
var current_case := "catalog"
var run_state: RunStateStore
var runtime: VehicleGame
var expected_lethal_enemies := 0
var completed_twelve_waves := false
var completed_defeat_case := false
var completed_teardown_case := false


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	run_state = get_tree().root.get_node("RunState") as RunStateStore
	_check_catalog_and_campaign()
	if await _create_runtime():
		_check_authored_ui()
		await _check_twelve_waves()
	await _dispose_runtime()
	if failures == 0 and await _create_runtime():
		_check_defeat_during_reward()
	await _dispose_runtime()
	if failures == 0 and await _create_runtime():
		_check_teardown_during_reward()
	await _dispose_runtime()
	get_tree().paused = false
	await get_tree().process_frame
	await get_tree().process_frame
	current_case = "completion audit"
	_expect(completed_twelve_waves, "Twelve-wave verification reached its final assertions")
	_expect(completed_defeat_case, "Defeat verification reached its final assertions")
	_expect(completed_teardown_case, "Teardown verification reached its final assertions")
	_expect(expected_lethal_enemies > 0 and killed_enemies == expected_lethal_enemies,
		"All expected real enemies were killed: %d / %d" % [killed_enemies, expected_lethal_enemies])
	_expect(claimed_rewards == EXPECTED_WAVES, "The complete verification emitted twelve reward grants")
	print("VEHICLE_MODE: %d lethal enemies, %d wave rewards, %d assertions, %d failures" % [
		killed_enemies, claimed_rewards, assertions, failures,
	])
	get_tree().quit(0 if failures == 0 else 1)


func _check_catalog_and_campaign() -> void:
	var catalog := GameModeCatalog.get_shared()
	_expect(catalog != null, "Mode catalog loads")
	if catalog == null:
		return
	var catalog_errors := catalog.validate_definitions()
	_expect(catalog_errors.is_empty(), "Catalog validates: %s" % str(catalog_errors))
	_expect(catalog.definitions.size() == 9, "Nine frozen multiplayer definitions remain")
	var release_ids: Array[int] = []
	for definition in GameModeCatalog.get_release_lobby_definitions():
		release_ids.append(definition.mode_id)
	release_ids.sort()
	_expect(release_ids == [0, 1, 4], "Release lobby remains Standard/Tower/Rogue")
	_expect(
		GameModeCatalog.get_definition_by_wire_key("standard")
		== GameModeCatalog.get_definition(GameModeCatalog.MODE_STANDARD),
		"Vehicle variant cannot replace the Standard wire definition"
	)
	var vehicle_definition := GameModeCatalog.get_definition_by_singleplayer_entry(ENTRY_PATH)
	_expect(vehicle_definition != null, "Vehicle entry resolves independently")
	if vehicle_definition == null:
		return
	_expect(vehicle_definition.mode_id == 0, "Vehicle retains Standard audience policy")
	_expect(not vehicle_definition.include_starting_inventory, "Vehicle starts with an empty bag")
	_expect(vehicle_definition.singleplayer_campaign_path == CAMPAIGN_PATH, "Entry uses vehicle campaign")
	var campaign := load(CAMPAIGN_PATH) as WaveCampaignConfig
	_expect(campaign != null, "Vehicle campaign loads")
	if campaign == null:
		return
	var campaign_errors := campaign.validate_campaign()
	_expect(campaign_errors.is_empty(), "Campaign validates: %s" % str(campaign_errors))
	var waves := campaign.get_waves()
	_expect(waves.size() == EXPECTED_WAVES, "Exactly twelve authored waves")
	if waves.size() != EXPECTED_WAVES:
		return
	_expect(campaign.flow_graph.start_step == waves[0], "Flow begins with wave one")
	var enemy_paths := {}
	var previous_total := 0
	expected_lethal_enemies = waves[0].get_total_enemy_count() * 2
	for index in range(waves.size()):
		var wave := waves[index]
		var total := wave.get_total_enemy_count()
		expected_lethal_enemies += total
		_expect(total >= 12 and total >= previous_total, "Wave %d has increasing nontrivial strength" % (index + 1))
		_expect(wave.enemy_entries.size() >= 2, "Wave %d mixes enemy roles" % (index + 1))
		_expect(wave.max_alive_enemies >= wave.spawn_count_per_tick and wave.max_alive_enemies < total,
			"Wave %d enforces a concurrent enemy cap" % (index + 1))
		_expect(wave.spawn_interval >= 0.1 and wave.post_clear_rest_duration > 0.0,
			"Wave %d authors spawn pacing and rest" % (index + 1))
		if index < EXPECTED_WAVES - 1:
			_expect(wave.exits.size() == 1 and wave.exits[0].target_step_id == waves[index + 1].step_id,
				"Wave %d connects to the next wave" % (index + 1))
		else:
			_expect(wave.exits.is_empty(), "Wave twelve ends the campaign")
		for entry in wave.enemy_entries:
			enemy_paths[entry.enemy_config.resource_path] = true
		previous_total = total
	_expect(enemy_paths.size() >= 12, "Campaign uses varied enemy families")


func _create_runtime() -> bool:
	current_case = "deferred activation"
	run_state.begin_new_run(PlayerCharacterRegistry.VEHICLE_ID, false)
	var packed := load(ENTRY_PATH) as PackedScene
	_expect(packed != null, "Authored vehicle scene loads")
	if packed == null:
		return false
	runtime = packed.instantiate() as VehicleGame
	_expect(runtime != null, "Authored root uses VehicleGame")
	if runtime == null:
		return false
	runtime.defer_runtime_activation()
	get_tree().root.add_child(runtime)
	get_tree().current_scene = runtime
	var deadline := Time.get_ticks_msec() + PREPARATION_TIMEOUT_MS
	while not runtime.is_runtime_preparation_complete() and not runtime.is_runtime_preparation_failed():
		if Time.get_ticks_msec() >= deadline:
			break
		await get_tree().process_frame
	_expect(runtime.is_runtime_preparation_complete(), "Preparation completes: %s" % str(runtime.get_runtime_preparation_progress()))
	if not runtime.is_runtime_preparation_complete():
		return false
	_expect(runtime.runtime_activation_deferred and not runtime.runtime_activated,
		"Runtime stays deferred during loading")
	_expect(runtime.current_flow_step == null and runtime.enemy_container.get_child_count() == 0,
		"Deferred preparation does not start combat")
	runtime.activate_runtime()
	_expect(runtime.runtime_activated, "Loader activation is recorded")
	_expect(runtime.current_flow_step == runtime.waves[0], "Activation begins the first authored step")
	_expect(runtime.wave_state == CombatFlowState.State.PRE_WAVE and not runtime.state_timer.is_stopped(),
		"Activation starts the countdown instead of leaving the game idle")
	_expect(_inventory_count() == 0, "No starter items consume wave reward slots")
	runtime.wave_reward.reward_claimed.connect(_on_reward_claimed)
	return runtime.current_flow_step != null


func _check_authored_ui() -> void:
	current_case = "authored HUD"
	_expect(runtime.player is PlayerVehicle, "Runtime creates the actual vehicle character")
	_expect(runtime.vehicle_hud is VehicleCombatHUD and runtime.vehicle_hud.hud_root.visible,
		"Vehicle HUD is bound and visible after activation")
	_expect(not runtime.currency_hud.visible and not runtime.wave_hud.visible, "Old HUDs remain hidden")
	_expect(not runtime.standard_merchants_enabled, "NPC services are disabled")
	for node_name in ["LuoxiMerchant", "ZhuangfangyiMerchant"]:
		var merchant := runtime.get_node(node_name) as CanvasItem
		_expect(not merchant.visible and merchant.process_mode == Node.PROCESS_MODE_DISABLED,
			"%s stays hidden and inactive" % node_name)
	_expect(runtime.wave_reward.choice_overlay is LuoxiCollectibleChoiceOverlay, "Rewards reuse Luoxi cards")
	_expect(runtime.wave_reward.process_mode == Node.PROCESS_MODE_ALWAYS, "Cards process while the world is paused")
	_expect(runtime.wave_reward.choice_overlay.refresh_button.disabled, "NPC shop refresh is disabled")
	_expect(not runtime.wave_reward.choice_overlay.get_node("Root/Center/Content/RefreshPanel").visible,
		"NPC shop refresh panel is hidden")
	_expect(runtime.player_profile_panel.process_mode == Node.PROCESS_MODE_ALWAYS,
		"Inventory remains usable during reward pause")
	_expect(runtime.player_profile_panel.layer > runtime.wave_reward.choice_overlay.layer,
		"Inventory can appear above the cards")


func _check_twelve_waves() -> void:
	_advance_countdown()
	for wave_number in range(1, EXPECTED_WAVES + 1):
		current_case = "wave %d" % wave_number
		_expect(runtime.current_wave_index + 1 == wave_number, "Flow reaches the expected wave")
		_expect(runtime.wave_state == CombatFlowState.State.WAVE_ACTIVE, "Wave enters active combat")
		if not _clear_current_wave():
			return
		_check_pending_reward(wave_number)
		if not runtime.wave_reward.is_open():
			return
		var reward := runtime.wave_reward
		var offers := reward.choice_overlay.choices.duplicate()
		var inventory_before := _inventory_count()
		if wave_number == 1:
			_check_mandatory_reward_input()
			_check_full_inventory(offers)
			run_state.inventory_changed.connect(_attempt_reentrant_claim, CONNECT_ONE_SHOT)
		var chosen_item := offers[0] as PickupConfig
		var item_copies_before := run_state.get_inventory_item_total(chosen_item)
		var event := _action(&"select_option_1")
		reward.choice_overlay.confirmation_lock_time_left = 0.0
		_expect(reward.choice_overlay.handle_input(event), "Native card input accepts a selection")
		_expect(not reward.is_open() and not get_tree().paused, "Successful grant closes cards and unpauses the world")
		_expect(_inventory_count() == inventory_before + 1, "Exactly one inventory item is granted")
		_expect(run_state.get_inventory_item_total(chosen_item) == item_copies_before + 1,
			"The selected card is the granted collectible")
		_expect(not runtime.player.has_control_lock(VehicleGame.REWARD_CONTROL_LOCK), "Reward releases its driving lock")
		reward.choice_overlay.choice_selected.emit(1)
		_expect(_inventory_count() == inventory_before + 1, "Stale repeated card selection cannot grant twice")
		_expect(not reward.open_for_wave(wave_number), "A claimed wave cannot reopen its reward")
		if wave_number < EXPECTED_WAVES:
			_expect(runtime.wave_state == CombatFlowState.State.INTERMISSION, "Selection enters the rest countdown")
			_expect(not runtime.state_timer.is_stopped() and runtime.countdown_seconds > 0,
				"Next wave waits for its authored rest countdown")
			_advance_countdown()
		else:
			_expect(runtime.wave_state == CombatFlowState.State.VICTORY, "Twelfth reward finishes with victory")
			_expect(runtime.vehicle_hud.result_overlay.visible, "Victory appears in the new HUD")
			_expect(runtime.state_timer.is_stopped() and runtime.enemy_spawn_timer.is_stopped(),
				"Victory stops both gameplay timers")
		await get_tree().process_frame
	_expect(_inventory_count() == EXPECTED_WAVES, "Completed run keeps all twelve chosen rewards")
	_expect(claimed_rewards == EXPECTED_WAVES, "Exactly twelve success events are emitted")
	completed_twelve_waves = true


func _advance_countdown() -> void:
	var initial_state := runtime.wave_state
	var remaining_ticks := runtime.countdown_seconds
	for _tick in range(remaining_ticks):
		runtime.state_timer.stop()
		runtime._on_state_timer_timeout()
	_expect(runtime.wave_state == CombatFlowState.State.WAVE_ACTIVE,
		"State %d countdown naturally starts the next wave" % initial_state)
	runtime.enemy_spawn_timer.stop()


func _clear_current_wave() -> bool:
	var wave := runtime.waves[runtime.current_wave_index]
	var total := wave.get_total_enemy_count()
	var cycles := 0
	while runtime.wave_state == CombatFlowState.State.WAVE_ACTIVE and cycles <= total + 1:
		cycles += 1
		# Fill the real queue up to the real concurrent limit, then prove another
		# tick cannot exceed it. No snapshot replaces the wave's live ledger.
		for _batch in range(wave.max_alive_enemies + 1):
			runtime._spawn_wave_batch()
		var attached := runtime.wave_enemy_terminal_ledger.get_attached_enemy_count()
		_expect(attached <= wave.max_alive_enemies, "Spawner obeys the live enemy cap")
		if attached == 0:
			_expect(false, "Active nonempty wave must spawn an enemy")
			return false
		var enemies := runtime.enemy_container.get_children()
		for node in enemies:
			var enemy := node as Enemy
			if enemy == null:
				continue
			var enemy_id := enemy.get_instance_id()
			var isolated_config := enemy.config.duplicate() as EnemyConfig
			isolated_config.drop_table = null
			enemy.config = isolated_config
			enemy.set_xirang_kill_reward_override(0)
			enemy.hit_audio.stream = null
			enemy.death_audio.stream = null
			_expect(enemy.try_apply_multiplayer_health_snapshot(1, enemy.health_revision + 1),
				"Real enemy accepts the one-HP terminal fixture")
			var request := DamageRequest.new(1)
			request.with_flag(CombatTypes.DamageFlag.BYPASS_MITIGATION)
			request.with_flag(CombatTypes.DamageFlag.BYPASS_INVULNERABILITY)
			request.with_flag(CombatTypes.DamageFlag.BYPASS_FACTION_FILTER)
			request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
			request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
			var result := enemy.apply_combat_damage(request)
			_expect(result.accepted and result.lethal and enemy.is_dead, "Real lethal damage settles enemy death")
			if not enemy.is_dead:
				return false
			_expect(runtime.wave_enemy_terminal_ledger.get_terminal_reason(enemy_id)
				== CombatTypes.EnemyTerminalReason.DEFEATED, "Death signal commits the canonical terminal ledger")
			var defeated_before_duplicate := runtime.current_wave_defeated
			runtime._on_wave_enemy_defeated(enemy)
			_expect(runtime.current_wave_defeated == defeated_before_duplicate, "Repeated terminal notification is idempotent")
			killed_enemies += 1
			enemy.free()
		_expect(runtime.wave_enemy_terminal_ledger.get_attached_enemy_count() == 0,
			"Real tree exit detaches all killed objectives")
	_expect(runtime.current_wave_defeated == total and runtime.current_wave_removed == 0,
		"Every authored objective is defeated without removal shortcuts")
	return runtime.wave_state == CombatFlowState.State.INTERMISSION


func _check_pending_reward(wave_number: int) -> void:
	var reward := runtime.wave_reward
	_expect(reward.is_open() and get_tree().paused, "Wave clear automatically opens and pauses for reward")
	_expect(runtime._pending_reward_wave == wave_number, "Reward owns this wave until a successful grant")
	_expect(runtime.state_timer.is_stopped() and runtime.enemy_spawn_timer.is_stopped(),
		"No next-wave timer runs while choosing")
	_expect(runtime.player.has_control_lock(VehicleGame.REWARD_CONTROL_LOCK), "Driving is locked while choosing")
	_expect(reward.choice_overlay.choices.size() == 3, "Exactly three Luoxi cards are offered")
	_expect(not reward.choice_overlay.cards[3].visible, "Fourth card remains hidden")
	var unique_paths := {}
	for item: PickupConfig in reward.choice_overlay.choices:
		_expect(runtime.player.is_collectible_compatible(item) and VehicleWaveReward.is_useful_for_vehicle(item),
			"Every offer can improve the vehicle")
		_expect(CollectibleRegistry.is_standard_random_collectible(item), "Event-only rewards are excluded")
		unique_paths[item.resource_path] = true
	_expect(unique_paths.size() == 3, "Three candidates are distinct")
	if wave_number == EXPECTED_WAVES:
		_expect(runtime.wave_state != CombatFlowState.State.VICTORY, "Final wave also grants a choice before victory")


func _check_mandatory_reward_input() -> void:
	var reward := runtime.wave_reward
	var before := _inventory_count()
	reward._input(_action(&"quit"))
	reward._input(_action(&"pause"))
	_expect(reward.is_open() and get_tree().paused, "Escape and pause cannot abandon a mandatory reward")
	reward.choice_overlay.choice_selected.emit(-1)
	reward.choice_overlay.choice_selected.emit(3)
	_expect(_inventory_count() == before and reward.is_open(), "Invalid card indices do not mutate inventory")
	reward.choice_overlay.confirmation_lock_time_left = 1.0
	reward.choice_overlay.handle_input(_action(&"select_option_1"))
	_expect(_inventory_count() == before and reward.is_open(), "Luoxi confirmation lock prevents accidental selection")


func _check_full_inventory(original_offers: Array) -> void:
	var reward := runtime.wave_reward
	var before := _inventory_count()
	var filler := CollectibleRegistry.get_for_path("res://resources/config/collectibles/collectible_admin_doll.tres")
	var filler_slots: Array[int] = []
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if run_state.get_item(slot_index) == null:
			filler_slots.append(slot_index)
			_expect(run_state.try_add_item(filler), "Fill an inventory slot for the capacity boundary")
	_expect(_inventory_count() == RunStateStore.INVENTORY_CAPACITY, "Capacity fixture fills the actual bag")
	reward.choice_overlay.choice_selected.emit(0)
	_expect(reward.is_open() and get_tree().paused and reward.inventory_button.visible, "Full bag keeps reward pending and exposes organize")
	_expect(reward.choice_overlay.choices == original_offers, "Full bag preserves the same three candidates")
	_expect(reward.hint_label.text.contains("背包空间不足"), "Full bag explains why the grant is pending")
	reward.inventory_button.pressed.emit()
	_expect(runtime.player_profile_panel.overlay.visible and not reward.choice_overlay.visible,
		"Organize opens the actual inventory over the reward")
	reward.choice_overlay.choice_selected.emit(1)
	_expect(_inventory_count() == RunStateStore.INVENTORY_CAPACITY, "Cards cannot grant while inventory owns input")
	for slot_index in filler_slots:
		runtime.player_profile_panel._on_inventory_item_discard_requested(slot_index)
	_expect(_inventory_count() == before, "Inventory UI can discard filler items while paused")
	reward._input(_action(&"quit"))
	_expect(not runtime.player_profile_panel.overlay.visible and reward.choice_overlay.visible,
		"Escape returns from inventory to the pending cards")
	_expect(reward.is_open() and get_tree().paused and reward.choice_overlay.choices == original_offers,
		"Organizing preserves the mandatory reward and pause")


func _check_defeat_during_reward() -> void:
	current_case = "defeat while choosing"
	_advance_countdown()
	if not _clear_current_wave():
		return
	_expect(runtime.wave_reward.is_open() and get_tree().paused, "Defeat fixture starts with a pending reward")
	var before := _inventory_count()
	runtime.player.apply_direct_health_loss(runtime.player.current_health)
	_expect(runtime.wave_state == CombatFlowState.State.DEFEAT, "Real player death enters defeat")
	_expect(not runtime.wave_reward.is_open() and not get_tree().paused, "Defeat closes reward and releases its pause")
	_expect(runtime.vehicle_hud.result_overlay.visible, "Defeat uses the new HUD result")
	runtime.wave_reward.choice_overlay.choice_selected.emit(0)
	_expect(_inventory_count() == before, "Defeat rejects a stale reward selection")
	completed_defeat_case = true


func _check_teardown_during_reward() -> void:
	current_case = "teardown while choosing"
	_advance_countdown()
	if not _clear_current_wave():
		return
	_expect(runtime.wave_reward.is_open() and get_tree().paused, "Teardown fixture starts with a pending reward")
	runtime.wave_reward.cancel()
	_expect(not get_tree().paused, "Cancelling a reward releases its own pause")
	get_tree().paused = true
	_expect(runtime.wave_reward.open_for_wave(1), "Reward can reopen an unclaimed wave")
	runtime.wave_reward.cancel()
	_expect(get_tree().paused, "Cancelling preserves a pause that existed before the reward")
	get_tree().paused = false
	_expect(runtime.wave_reward.open_for_wave(1), "Unclaimed reward opens before scene teardown")
	runtime.prepare_for_scene_teardown()
	_expect(runtime.is_scene_teardown_prepared(), "Runtime records its teardown boundary")
	_expect(not runtime.wave_reward.is_open() and not get_tree().paused, "Scene teardown closes cards and restores the tree")
	_expect(not runtime.player.has_control_lock(VehicleGame.REWARD_CONTROL_LOCK), "Scene teardown releases the reward driving lock")
	completed_teardown_case = true


func _dispose_runtime() -> void:
	if runtime != null and is_instance_valid(runtime):
		runtime.prepare_for_scene_teardown()
		runtime.free()
		runtime = null
	await get_tree().process_frame
	await get_tree().process_frame


func _inventory_count() -> int:
	var total := 0
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		total += run_state.get_item_count(slot_index)
	return total


func _action(action: StringName) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	return event


func _attempt_reentrant_claim() -> void:
	runtime.wave_reward.choice_overlay.choice_selected.emit(1)


func _on_reward_claimed(_wave_number: int, _item: PickupConfig) -> void:
	claimed_rewards += 1


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if condition:
		return
	failures += 1
	push_error("VEHICLE_MODE [%s]: %s" % [current_case, description])
