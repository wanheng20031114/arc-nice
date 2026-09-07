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
	_check_run_scoring()
	if await _create_runtime():
		_check_authored_ui()
		await _check_modal_pause_clock()
		await _check_live_robot_pause()
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
	_expect(catalog.definitions.size() == 10, "Ten frozen multiplayer definitions remain")
	var release_ids: Array[int] = []
	for definition in GameModeCatalog.get_release_lobby_definitions():
		release_ids.append(definition.mode_id)
	release_ids.sort()
	_expect(release_ids == [0, 1, 4, 9], "Release lobby remains Standard/Tower/Rogue/Mirage")
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
	runtime.save_run_records = false
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
	_expect(runtime._briefing_open and runtime.state_timer.is_stopped(), "Briefing holds the first countdown")
	_expect(runtime.player.has_control_lock(VehicleGame.BRIEFING_CONTROL_LOCK), "Briefing holds the driving controls")
	await _capture_ui("briefing")
	runtime.vehicle_hud.start_requested.emit()
	_expect(not runtime._briefing_open, "Start action closes the briefing")
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
		var health_before_service := -1
		if wave_number == 2:
			var car := runtime.player as PlayerVehicle
			car.apply_direct_health_loss(40)
			health_before_service = car.current_health
			car.current_ammo = 3
			car.is_reloading = true
			car.reload_progress = 0.4
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
			_check_service_progression(wave_number)
			if health_before_service >= 0:
				_expect(runtime.player.current_health == mini(runtime.player.max_health,
					health_before_service + ceili(runtime.player.max_health * 0.25)),
					"Service repairs exactly one quarter of the new maximum, capped at full health")
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
	_expect(runtime.run_progress.cleared_waves == 12 and runtime.run_progress.kills == 483,
		"Score follows exactly the canonical twelve-wave enemy ledger")
	_expect(runtime.run_progress.finished and runtime.run_progress.victory, "Victory finalizes scoring")
	_expect(runtime.run_progress.score == 8930, "A fast undamaged complete run earns the authored maximum score")
	_expect(runtime.vehicle_hud.action_button.text == "再来一局", "Victory offers a real retry action")
	await _capture_ui("victory")
	completed_twelve_waves = true


func _check_run_scoring() -> void:
	current_case = "score and records"
	var progress := VehicleRunProgress.new()
	progress.begin_wave()
	progress.record_kill()
	progress.advance_time(90.0)
	progress.advance_time(-10.0)
	progress.record_health_loss(12)
	progress.record_health_loss(-5)
	_expect(progress.complete_wave(1), "The first cleared wave can settle")
	_expect(not progress.complete_wave(1) and not progress.complete_wave(3), "Duplicate and skipped settlements are rejected")
	_expect(progress.score == 110 and progress.combat_seconds == 90.0 and progress.total_health_loss == 12,
		"Slow damaged wave earns only clear and kill points; negative values cannot improve the record")
	_expect(progress.finish(false) and not progress.finish(true), "The result commits once")
	progress.record_kill()
	progress.record_health_loss(10)
	progress.advance_time(10.0)
	_expect(progress.score == 110 and progress.combat_seconds == 90.0 and progress.total_health_loss == 12,
		"Terminal score and time cannot mutate")
	var record_path := "res://dev_tools/output/vehicle_record_fixture.cfg"
	_expect(progress.save_records(record_path) == OK, "Records save using a separate test file")
	var restored := VehicleRunProgress.new()
	_expect(restored.load_records(record_path) == OK and restored.best_score == 110 and restored.best_cleared_waves == 1,
		"Personal records round-trip through native ConfigFile")
	_expect(restored.kills == 0 and restored.cleared_waves == 0 and restored.score == 0,
		"Loading a record never restores prior run power or loot")
	_expect(DirAccess.remove_absolute(ProjectSettings.globalize_path(record_path)) == OK, "Test record is removed")
	_expect(VehicleRunProgress.format_time(125.9) == "02:05", "Combat time formats as minutes and seconds")
	var champion := VehicleRunProgress.new()
	for wave in range(1, 13):
		champion.begin_wave()
		champion.advance_time(50.0)
		_expect(champion.complete_wave(wave), "Record fixture completes wave %d exactly once" % wave)
	_expect(champion.finish(true) and champion.best_victory_seconds == 600.0,
		"Victory records its combat duration")
	_expect(champion.save_records(record_path) == OK, "A victory record can be saved")
	var slower := VehicleRunProgress.new()
	_expect(slower.load_records(record_path) == OK, "A future run loads the existing victory record")
	for wave in range(1, 13):
		slower.begin_wave()
		slower.advance_time(700.0 / 12.0)
		slower.complete_wave(wave)
	slower.finish(true)
	_expect(slower.best_victory_seconds == 600.0 and slower.get_result_text().contains("最快通关 10:00"),
		"A slower future victory preserves and displays the best time")
	_expect(DirAccess.remove_absolute(ProjectSettings.globalize_path(record_path)) == OK, "Victory record test file is removed")
	var vehicle_config := load("res://resources/config/players/player_vehicle.tres") as PlayerCharacterConfig
	var armored_config := load("res://resources/config/enemies/combat_robot_main_battle_elite.tres") as EnemyConfig
	var armor := DamageTargetProfile.new(armored_config.max_health, armored_config.physical_defense, armored_config.magic_defense)
	var old_damage := DamageResolver.resolve(DamageRequest.new(vehicle_config.starting_attack_damage), armor)
	var serviced_attack := vehicle_config.starting_attack_damage + int(champion.get_service_bonuses()["attack_damage"])
	var serviced_damage := DamageResolver.resolve(DamageRequest.new(serviced_attack), armor)
	_expect(old_damage.applied_damage == 1 and serviced_damage.applied_damage == 14,
		"Actual authored vehicle/boss stats and production damage resolver reproduce 1 damage before service, 14 after eleven services")


func _check_modal_pause_clock() -> void:
	current_case = "modal pause and gameplay clock"
	var pause := GameplayPauseController.get_autoload_instance()
	var countdown_left := runtime.state_timer.time_left
	runtime._open_inventory()
	_expect(get_tree().paused and pause.get_local_modal_pause_owner_count() == 1,
		"Opening the actual profile pauses the combat world")
	var frozen_time := pause.get_gameplay_time_seconds()
	await get_tree().create_timer(0.12, true, false, true).timeout
	_expect(absf(pause.get_gameplay_time_seconds() - frozen_time) < 0.015,
		"Inventory time does not consume timed buffs or gameplay effects")
	_expect(is_equal_approx(runtime.state_timer.time_left, countdown_left), "Inventory freezes the next wave countdown")
	pause.apply_network_pause_state(0, 0, false, 0)
	_expect(get_tree().paused, "An inactive network cleanup cannot release a local modal pause")
	pause.request_pause(true)
	runtime.player_profile_panel.close()
	_expect(get_tree().paused and pause.get_local_modal_pause_owner_count() == 0,
		"Closing inventory preserves an independently opened ESC pause")
	runtime._open_inventory()
	pause.request_pause(false)
	_expect(get_tree().paused and pause.get_local_modal_pause_owner_count() == 1,
		"Closing the ESC menu preserves an independently opened inventory")
	runtime.player_profile_panel.close()
	_expect(not get_tree().paused, "Closing the final pause owner resumes the world")
	var native_owner := runtime.currency_hud
	var native_parent := native_owner.get_parent()
	_expect(pause.acquire_local_modal_pause(native_owner), "A native child can own a local pause")
	_expect(pause.acquire_local_modal_pause(native_owner) and pause.get_local_modal_pause_owner_count() == 1,
		"Acquiring the same owner twice is idempotent")
	native_parent.remove_child(native_owner)
	_expect(not get_tree().paused and pause.get_local_modal_pause_owner_count() == 0,
		"A modal owner leaving the scene releases its lease automatically")
	native_parent.add_child(native_owner)
	for button in native_owner.find_children("*", "BaseButton", true, false):
		var click_connections := 0
		for connection in button.pressed.get_connections():
			if (connection["callable"] as Callable).get_object() == get_node("/root/UIAudio"):
				click_connections += 1
		_expect(click_connections == 1, "A native button reentering the scene keeps exactly one click-audio connection")
	var resumed_time := pause.get_gameplay_time_seconds()
	await get_tree().create_timer(0.12, true, false, true).timeout
	_expect(pause.get_gameplay_time_seconds() - resumed_time >= 0.08, "The gameplay clock advances again after all owners release")


func _check_live_robot_pause() -> void:
	current_case = "live enemy and modal pause integration"
	var coordinator := runtime.get_enemy_simulation_coordinator()
	_expect(coordinator.mode == EnemySimulationPolicy.Mode.LAYERED_CONTACT,
		"Vehicle runs the deployed layered contact coordinator")
	# Use an untracked real enemy before wave one so the campaign ledger and
	# twelve-wave score still describe exactly the authored 483 objectives.
	var config := load("res://resources/config/enemies/combat_robot.tres").duplicate() as EnemyConfig
	config.attack_damage = 0
	var robot := config.enemy_scene.instantiate() as CombatRobot
	robot.config = config
	runtime.enemy_container.add_child(robot)
	robot.setup(config, runtime.player, runtime.grid_pathfinder, runtime)
	robot.global_position = runtime.player.global_position + Vector2(140, 0)
	robot.dash_cooldown_left = 5.0
	robot.touch_damage_cooldown_left = 5.0
	for frame in 4:
		await get_tree().physics_frame
	await get_tree().process_frame
	_expect(robot.is_centrally_simulated() and coordinator.gameplay_step_clock.tick > 0,
		"A real Robot enters vehicle event/decision/motion simulation")
	var pause := GameplayPauseController.get_autoload_instance()
	runtime.player_profile_panel.open()
	var frozen_tick := coordinator.gameplay_step_clock.tick
	var frozen_position := robot.global_position
	var frozen_dash := robot.dash_cooldown_left
	var frozen_touch := robot.touch_damage_cooldown_left
	var frozen_score_seconds := runtime.run_progress.combat_seconds
	var first_engine_frame := Engine.get_physics_frames()
	await get_tree().create_timer(0.18, true).timeout
	_expect(Engine.get_physics_frames() > first_engine_frame,
		"Native physics frame identifiers keep advancing during inventory pause")
	_expect(coordinator.gameplay_step_clock.tick == frozen_tick and robot.global_position == frozen_position,
		"Inventory pauses real coordinator steps and enemy motion")
	_expect(robot.dash_cooldown_left == frozen_dash and robot.touch_damage_cooldown_left == frozen_touch,
		"Inventory freezes both lazy Robot cooldown and native touch deadline")
	pause.request_pause(true)
	runtime.player_profile_panel.close()
	await get_tree().create_timer(0.12, true).timeout
	_expect(coordinator.gameplay_step_clock.tick == frozen_tick and robot.dash_cooldown_left == frozen_dash
		and robot.touch_damage_cooldown_left == frozen_touch,
		"Closing inventory cannot advance enemy deadlines under the remaining ESC owner")
	_expect(runtime.run_progress.combat_seconds == frozen_score_seconds,
		"Nested modals cannot add combat score time")
	pause.request_pause(false)
	_expect(robot.dash_cooldown_left == frozen_dash and robot.touch_damage_cooldown_left == frozen_touch,
		"Releasing the final pause owner does not consume paused physics frames")
	for frame in 4:
		await get_tree().physics_frame
	await get_tree().process_frame
	_expect(coordinator.gameplay_step_clock.tick > frozen_tick,
		"Vehicle coordinator resumes on actual gameplay steps")
	_expect(robot.dash_cooldown_left < frozen_dash and robot.touch_damage_cooldown_left < frozen_touch,
		"Both real enemy cooldowns resume after the final pause owner closes")
	_expect(robot.dash_cooldown_left > 4.0 and robot.touch_damage_cooldown_left > 4.0,
		"Short resumed gameplay cannot consume an unrelated five-second cooldown")
	robot.free()
	_expect(runtime.enemy_container.get_child_count() == 0 and runtime.run_progress.kills == 0,
		"Untracked pause probe leaves no enemy or campaign score behind")


func _check_service_progression(wave_number: int) -> void:
	current_case = "wave %d service" % wave_number
	var bonuses := run_state.get_player_stat_bonuses(0)
	var independent_attack := 7 if wave_number > 1 else 0
	var independent_health := 13 if wave_number > 1 else 0
	_expect(int(bonuses["attack_damage"]) == wave_number * 4 + independent_attack
		and int(bonuses["max_health"]) == wave_number * 10 + independent_health,
		"Guaranteed service and independent same-stat rewards coexist in the canonical run ledger")
	var car := runtime.player as PlayerVehicle
	_expect(car.get_multiplayer_current_ammo() == car.get_multiplayer_ammo_capacity() and not car.get_multiplayer_is_reloading(),
		"Service refills the actual magazine and cancels reload")
	var previous_health := car.current_health
	_expect(not runtime._service_vehicle(wave_number) and car.current_health == previous_health,
		"Duplicate service cannot grant a second heal")
	if wave_number == 1:
		var previous_attack := car.attack_damage
		_expect(run_state.try_upgrade(RunStateStore.StatType.ATTACK, car), "Profile firepower upgrade can be purchased")
		_expect(car.attack_damage > previous_attack and run_state.get_player_stat_bonus_value(0, &"attack_damage") == 4,
			"Buying profile upgrades retains wave service instead of overwriting it")
		_expect(not runtime._service_vehicle(3), "An out-of-order service cannot skip a wave")
		var status := run_state.export_party_status_ledger()
		status["player_stat_bonuses"]["0"]["attack_damage"] += 7
		status["player_stat_bonuses"]["0"]["max_health"] += 13
		status["revision"] = run_state.party_status_ledger_revision + 1
		_expect(run_state.apply_party_status_ledger(status), "An independent reward can contribute to the same service stat keys")
	if wave_number == 11:
		_expect(car.attack_damage > 40 and car.max_health >= 210,
			"The final wave has reliable damage above forty-point armor even without lucky loot")


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
	var pause := GameplayPauseController.get_autoload_instance()
	pause._unhandled_input(_action(&"pause"))
	_expect(pause.is_pause_menu_open() and reward.is_open(), "Pause menu can open above a pending reward")
	reward.choice_overlay.choice_selected.emit(0)
	_expect(_inventory_count() == before and reward.is_open(), "Card selection cannot occur beneath the pause menu")
	pause.request_pause(false)
	_expect(get_tree().paused and reward.is_open(), "Returning from pause retains the same mandatory reward")
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
	runtime._open_inventory()
	_expect(GameplayPauseController.get_autoload_instance().get_local_modal_pause_owner_count() == 2,
		"Defeat fixture nests inventory over its reward")
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
	var pause := GameplayPauseController.get_autoload_instance()
	pause.request_pause(true)
	_expect(runtime.wave_reward.open_for_wave(1), "Reward can reopen an unclaimed wave")
	runtime.wave_reward.cancel()
	_expect(get_tree().paused, "Cancelling preserves a pause that existed before the reward")
	pause.request_pause(false)
	_expect(runtime.wave_reward.open_for_wave(1), "Unclaimed reward opens before scene teardown")
	runtime.prepare_for_scene_teardown()
	_expect(runtime.is_scene_teardown_prepared(), "Runtime records its teardown boundary")
	_expect(not runtime.wave_reward.is_open() and not get_tree().paused, "Scene teardown closes cards and restores the tree")
	_expect(not runtime.player.has_control_lock(VehicleGame.REWARD_CONTROL_LOCK), "Scene teardown releases the reward driving lock")
	completed_teardown_case = true


func _dispose_runtime() -> void:
	if runtime != null and is_instance_valid(runtime) and runtime.run_progress.finished and not runtime.run_progress.victory:
		await _capture_ui("defeat")
	if runtime != null and is_instance_valid(runtime):
		runtime.prepare_for_scene_teardown()
		runtime.free()
		runtime = null
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(not get_tree().paused and GameplayPauseController.get_autoload_instance().get_local_modal_pause_owner_count() == 0,
		"Destroying the runtime releases every modal pause owner")


func _capture_ui(label: String) -> void:
	if not OS.get_cmdline_user_args().has("--capture-ui"):
		return
	assert(DisplayServer.get_name() != "headless", "UI capture requires an actual renderer.")
	await get_tree().create_timer(0.6, true, false, true).timeout
	await RenderingServer.frame_post_draw
	var output_dir := "res://dev_tools/output/vehicle_contract_capture"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	_expect(get_viewport().get_texture().get_image().save_png(output_dir.path_join(label + ".png")) == OK,
		"Rendered %s panel is captured" % label)


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
