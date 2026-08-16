extends SceneTree

const GAME_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const CULTIVATION_CENTER_SCENE := preload(
	"res://scene/plant_defense/plant_cultivation_center.tscn"
)
const PRODUCTION_COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const PROGRESSION: TowerDefenseProgressionConfig = preload(
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)
const FORMAL_CAMPAIGN: WaveCampaignConfig = preload(
	"res://resources/config/campaigns/tower_defense/singleplayer/campaign.tres"
)
const WOOD_TO_PLANK: ProductionRecipe = preload(
	"res://resources/config/production/wood_to_plank.tres"
)
const WATER_COLLECTOR_ASSEMBLY: ProductionRecipe = preload(
	"res://resources/config/production/water_collector_assembly.tres"
)
const WOOD: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)
const SAPLING: PickupConfig = preload(
	"res://resources/config/materials/material_sapling.tres"
)
const SIMPLE_BAMBOO: ProductionRecipe = preload(
	"res://resources/config/production/simple_bamboo_mortar.tres"
)
const SIMPLE_HYDRANGEA: ProductionRecipe = preload(
	"res://resources/config/production/simple_hydrangea_rain_tower.tres"
)
const CULTIVATION_BAMBOO: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_bamboo_mortar.tres"
)
const CULTIVATION_HYDRANGEA: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_hydrangea_rain_tower.tres"
)
const CULTIVATION_ORANGE: ProductionRecipe = preload(
	"res://resources/config/production/wooden_core_to_orange_charging_tower.tres"
)
const FORMAL_SCALED_TOTALS := {
	1: [3000, 3850, 3470, 2080, 2100, 2240, 2150, 2240, 3120, 3780, 3000, 4900],
	2: [3750, 4813, 4338, 2602, 2628, 2805, 2692, 2806, 3901, 4725, 3750, 6125],
	4: [5250, 6738, 6073, 3642, 3678, 3924, 3767, 3926, 5461, 6615, 5250, 8575],
	8: [8250, 10588, 9543, 5722, 5778, 6164, 5917, 6166, 8581, 10395, 8250, 13475],
}
const EXPECTED_DAILY_XIRANG: Array[int] = [16730, 39220, 177700]

var failures: Array[String] = []


class ResearchUnlockProbe:
	extends RefCounted

	var completed_ids: Dictionary[StringName, bool] = {}

	func is_completed(research_id: StringName) -> bool:
		return completed_ids.has(research_id)

	func complete(research_id: StringName) -> void:
		completed_ids[research_id] = true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_campaign_coordinator_contract()
	_test_progression_resource()
	_test_player_count_scaling()
	_test_formal_economy()
	await _test_research_gates()
	await _test_singleplayer_starting_package()
	for player_count in [2, 4, 8]:
		await _test_multiplayer_starting_package(player_count)
	await _cleanup_runtime()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_PROGRESSION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_campaign_coordinator_contract() -> void:
	var empty_definition := GameModeDefinition.new()
	var isolated_coordinator := TowerDefenseCampaignCoordinator.new()
	_expect(
		not isolated_coordinator.configure(
			int(CombatRuntimeBase.RuntimeMode.SINGLEPLAYER),
			empty_definition,
			null,
			null,
			null
		)
		and isolated_coordinator.configuration_errors.size() == 1,
		"Empty mode paths must fail as campaign configuration, without calling load on an empty path."
	)
	isolated_coordinator.free()
	var game := GAME_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	root.add_child(game)
	await process_frame
	var coordinator := game.get_node_or_null(
		"CampaignCoordinator"
	) as TowerDefenseCampaignCoordinator
	_expect(
		coordinator != null
		and game.campaign_coordinator == coordinator
		and coordinator.active_campaign != null
		and coordinator.flow_graph != null
		and not coordinator.waves.is_empty()
		and not coordinator.bosses.is_empty(),
		"Tower campaign rules must be authored and owned by one static coordinator."
	)
	var wave_trace: Array[String] = []
	if coordinator != null:
		for wave_index in range(coordinator.waves.size()):
			var wave := coordinator.waves[wave_index]
			wave_trace.append("%s:%d:%d:%d:%d" % [
				String(wave.step_id),
				coordinator.get_wave_number_for_step(wave, -1),
				coordinator.get_day_number_for_wave(wave_index + 1),
				int(coordinator.is_night_wave(wave_index + 1)),
				int(coordinator.is_day_end_wave(wave_index + 1)),
			])
	_expect(
		wave_trace == [
			"wave_01:1:1:0:0", "wave_02:2:1:0:0",
			"wave_03:3:1:1:0", "wave_04:4:1:1:1",
			"wave_05:5:2:0:0", "wave_06:6:2:0:0",
			"wave_07:7:2:1:0", "wave_08:8:2:1:1",
			"wave_09:9:3:0:0", "wave_10:10:3:0:0",
			"wave_11:11:3:1:0", "wave_12:12:3:1:1",
		],
		"Fixed tower campaign trace must preserve wave order, day mapping, night phases and day endings."
	)
	game.queue_free()
	await _wait_for_freed(game)


func _test_progression_resource() -> void:
	_expect(PROGRESSION != null and PROGRESSION.is_valid(), "Progression config must validate.")
	_expect(
		PROGRESSION.daily_rogue_action_points == [5, 5, 5],
		"Formal day-one through day-three Rogue action points must default to 5/5/5."
	)
	var baseline_contract_hash := PROGRESSION.compute_runtime_contract_hash()
	var changed_action_points := PROGRESSION.duplicate(true) as TowerDefenseProgressionConfig
	changed_action_points.daily_rogue_action_points = [4, 5, 6]
	_expect(
		not baseline_contract_hash.is_empty()
		and changed_action_points.compute_runtime_contract_hash()
		!= baseline_contract_hash,
		"Changing ordered daily Rogue action points must change the runtime contract hash."
	)
	changed_action_points.daily_rogue_action_points = [6, 5, 4]
	var reordered_contract_hash := changed_action_points.compute_runtime_contract_hash()
	changed_action_points.daily_rogue_action_points = [4, 5, 6]
	_expect(
		reordered_contract_hash
		!= changed_action_points.compute_runtime_contract_hash(),
		"Daily Rogue action-point order must be contract-significant."
	)
	var invalid_length := PROGRESSION.duplicate(true) as TowerDefenseProgressionConfig
	invalid_length.daily_rogue_action_points = [5, 5]
	invalid_length.per_player_amounts = []
	_expect(
		not invalid_length.is_valid()
		and invalid_length.validate_config().size() >= 2,
		"Invalid Rogue day count and package length must return validation errors without OOB."
	)
	_expect(
		PROGRESSION.per_player_items == [SAPLING]
		and PROGRESSION.per_player_amounts == [3]
		and PROGRESSION.team_items.is_empty()
		and PROGRESSION.team_amounts.is_empty(),
		"Formal tower defense must add only three saplings per player and no team package."
	)
	_expect(
		PROGRESSION.initial_preparation_seconds == 300.0
		and PROGRESSION.wave_intermission_seconds == 300.0
		and PROGRESSION.new_day_preparation_seconds == 300.0,
		"Every formal preparation and intermission must last five minutes."
	)
	var changed_timer := PROGRESSION.duplicate(true) as TowerDefenseProgressionConfig
	changed_timer.wave_intermission_seconds = 299.0
	_expect(
		changed_timer.compute_runtime_contract_hash() != baseline_contract_hash,
		"Each preparation timer must remain independently contract-significant."
	)
	var minimum_water_chain_seconds := (
		ceili(
			float(WATER_COLLECTOR_ASSEMBLY.input_amounts[0])
			/ float(WOOD_TO_PLANK.output_amounts[0])
		) * WOOD_TO_PLANK.duration_seconds
		+ WATER_COLLECTOR_ASSEMBLY.duration_seconds
	)
	_expect(
		RunStateStore.STARTING_WOOD_COUNT
		>= WATER_COLLECTOR_ASSEMBLY.input_amounts[0]
		/ WOOD_TO_PLANK.output_amounts[0]
		and minimum_water_chain_seconds
		<= PROGRESSION.initial_preparation_seconds,
		"The deterministic starter route must bring a water collector online before wave 1."
	)


func _test_player_count_scaling() -> void:
	var waves := FORMAL_CAMPAIGN.get_waves()
	_expect(waves.size() == 12, "Formal campaign must expose 12 waves for scaling checks.")
	for player_count_variant in FORMAL_SCALED_TOTALS:
		var player_count := int(player_count_variant)
		var expected_totals := FORMAL_SCALED_TOTALS[player_count_variant] as Array
		var actual_totals: Array[int] = []
		for wave in waves:
			var total := 0
			for entry in wave.enemy_entries:
				total += PROGRESSION.get_scaled_enemy_count(entry.count, player_count)
			actual_totals.append(total)
		_expect(
			actual_totals == expected_totals,
			"Formal %d-player wave totals changed: %s" % [player_count, actual_totals]
		)
func _test_formal_economy() -> void:
	var daily_rewards: Array[int] = [0, 0, 0]
	var waves := FORMAL_CAMPAIGN.get_waves()
	for wave_index in waves.size():
		for entry in waves[wave_index].enemy_entries:
			daily_rewards[floori(float(wave_index) / 4.0)] += (
				entry.count * entry.enemy_config.xirang_kill_reward
			)
	_expect(
		daily_rewards == EXPECTED_DAILY_XIRANG,
		"Formal daily Xirang baseline changed: %s" % [str(daily_rewards)]
	)
func _test_research_gates() -> void:
	var bamboo_research := GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID
	var hydrangea_research := GlobalResearchRegistry.HYDRANGEA_RAIN_TOWER_CRAFTING_ID
	var orange_research := GlobalResearchRegistry.ORANGE_CHARGING_TOWER_CRAFTING_ID
	_expect(
		SIMPLE_BAMBOO.required_global_research_id == bamboo_research
		and CULTIVATION_BAMBOO.required_global_research_id == bamboo_research,
		"Bamboo simple-crafting and cultivation must share one research gate."
	)
	_expect(
		SIMPLE_HYDRANGEA.required_global_research_id == hydrangea_research
		and CULTIVATION_HYDRANGEA.required_global_research_id == hydrangea_research,
		"Hydrangea simple-crafting and cultivation must share one research gate."
	)
	_expect(
		CULTIVATION_ORANGE.required_global_research_id == orange_research
		and GlobalResearchRegistry.get_unlock_research_id_for_production_recipe(
			CULTIVATION_ORANGE.recipe_id
		) == orange_research,
		"Orange cultivation must use its dedicated production-recipe research gate."
	)
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.get_simple_crafting_result(SIMPLE_BAMBOO)
		== RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED
		and run_state.get_simple_crafting_result(SIMPLE_HYDRANGEA)
		== RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED,
		"Simple crafting must reject both gated towers before research."
	)
	_expect(
		run_state.get_simple_crafting_result(SIMPLE_BAMBOO, [bamboo_research])
		!= RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED
		and run_state.get_simple_crafting_result(
			SIMPLE_HYDRANGEA,
			[hydrangea_research]
		) != RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED,
		"Completed research must remove the simple-crafting lock."
	)
	run_state.free()

	var coordinator := PRODUCTION_COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	root.add_child(coordinator)
	coordinator.configure_multiplayer_output_peers([1])
	var cultivation := CULTIVATION_CENTER_SCENE.instantiate() as ProductionBuilding
	cultivation.set_production_coordinator(coordinator)
	var unlock_probe := ResearchUnlockProbe.new()
	cultivation.set_recipe_unlock_checker(Callable(unlock_probe, "is_completed"))
	_expect(
		not cultivation.select_recipe(CULTIVATION_BAMBOO.recipe_id, 1)
		and not cultivation.select_recipe(CULTIVATION_HYDRANGEA.recipe_id, 1)
		and not cultivation.select_recipe(CULTIVATION_ORANGE.recipe_id, 1),
		"Cultivation center must reject gated tower selection before research."
	)
	unlock_probe.complete(bamboo_research)
	_expect(
		cultivation.select_recipe(CULTIVATION_BAMBOO.recipe_id, 1),
		"Cultivation center must accept bamboo after its research completes."
	)
	unlock_probe.complete(hydrangea_research)
	_expect(
		cultivation.select_recipe(CULTIVATION_HYDRANGEA.recipe_id, 1)
		and not cultivation.select_recipe(CULTIVATION_ORANGE.recipe_id, 1),
		"Hydrangea research must unlock hydrangea without unlocking orange cultivation."
	)
	unlock_probe.complete(orange_research)
	_expect(
		cultivation.select_recipe(CULTIVATION_ORANGE.recipe_id, 1),
		"Cultivation center must accept orange after its dedicated research completes."
	)
	cultivation.free()
	coordinator.queue_free()
	await process_frame


func _test_singleplayer_starting_package() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	var game := GAME_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	root.add_child(game)
	await process_frame
	_expect(
		game.player_roster_coordinator.starting_package_granted,
		"Singleplayer starter package must be granted."
	)
	_expect_exact_starting_inventory(run_state, 0, "Singleplayer")
	_expect(
		bool(game.call("_grant_tower_defense_starting_package")),
		"Repeated starter-package requests must report the existing completed grant."
	)
	_expect_exact_starting_inventory(run_state, 0, "Repeated singleplayer grant")
	_expect(
		game.campaign_coordinator.get_initial_preparation_seconds() == 300
		and game.campaign_coordinator.get_wave_intermission_seconds() == 300
		and game.campaign_coordinator.get_new_day_preparation_seconds() == 300,
		"Runtime must source all three countdowns from progression config."
	)
	var metrics := game.get_progression_metrics_snapshot()
	_expect(
		metrics.has("first_defense_tower_seconds")
		and metrics.has("water_chain_online_seconds")
		and metrics.has("first_day_building_count")
		and metrics.has("daily_xirang_rewards")
		and metrics.has("day_records"),
		"Runtime must expose the complete progression telemetry contract."
	)
	game.queue_free()
	await _wait_for_freed(game)


func _test_multiplayer_starting_package(player_count: int) -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	var names := {}
	var characters := {}
	for peer_id in range(1, player_count + 1):
		names[peer_id] = "Player %d" % peer_id
		characters[peer_id] = &"weishidaier"
	var game := GAME_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		names,
		characters
	)
	root.add_child(game)
	await process_frame
	_expect(
		game.player_roster_coordinator.starting_package_granted,
		"%d-player starter package must be granted." % player_count
	)
	for peer_id in range(1, player_count + 1):
		_expect_exact_starting_inventory(
			run_state,
			peer_id,
			"%d-player peer %d" % [player_count, peer_id]
		)
	if player_count == 2:
		game.campaign_coordinator.enter_pre_flow_step(
			game.campaign_coordinator.get_start_flow_step()
		)
		_expect(
			not game.campaign_coordinator.request_wave_start(2),
			"A non-host player must not end multiplayer preparation."
		)
		_expect(
			game.campaign_coordinator.request_wave_start(1),
			"The host must be able to confirm the final wave countdown."
		)
		_expect(
			game.campaign_coordinator.wave_state == CombatFlowState.State.PRE_WAVE
			and game.campaign_coordinator.countdown_seconds == 3,
			"Host confirmation must preserve a complete 3-second countdown."
		)
		for _countdown_step in range(3):
			game.countdown_audio.stop()
			game.campaign_coordinator.on_state_timer_timeout()
		_expect(
			game.campaign_coordinator.current_wave_total
			== int((FORMAL_SCALED_TOTALS[2] as Array)[0]),
			"Host runtime must apply the two-player wave scaling contract."
		)
	game.queue_free()
	await _wait_for_freed(game)


func _expect_exact_starting_inventory(
	run_state: RunStateStore,
	peer_id: int,
	context: String
) -> void:
	var occupied_slot_count := 0
	var has_unexpected_item := false
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		var item := (
			run_state.get_item_for_peer(peer_id, slot_index)
			if peer_id > 0
			else run_state.get_item(slot_index)
		)
		if item == null:
			continue
		occupied_slot_count += 1
		has_unexpected_item = has_unexpected_item or (
			not PickupConfig.inventory_identity_matches(item, WOOD)
			and not PickupConfig.inventory_identity_matches(item, SAPLING)
		)
	var wood_total := (
		run_state.get_inventory_item_total_for_peer(peer_id, WOOD)
		if peer_id > 0
		else run_state.get_inventory_item_total(WOOD)
	)
	var sapling_total := (
		run_state.get_inventory_item_total_for_peer(peer_id, SAPLING)
		if peer_id > 0
		else run_state.get_inventory_item_total(SAPLING)
	)
	_expect(
		wood_total == RunStateStore.STARTING_WOOD_COUNT
		and sapling_total == 3
		and occupied_slot_count == 2
		and not has_unexpected_item,
		"%s must start with only 20 wood and three saplings." % context
	)


func _wait_for_freed(node: Node) -> void:
	for _frame in range(8):
		if not is_instance_valid(node):
			return
		await process_frame
		await physics_frame


func _cleanup_runtime() -> void:
	var current := current_scene
	current_scene = null
	if current != null and is_instance_valid(current):
		current.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _disable_tower_fixture_background_loads(game: TowerDefenseGame) -> void:
	var coordinator := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if coordinator != null:
		coordinator.elite_enemy_config_loads_requested = true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
