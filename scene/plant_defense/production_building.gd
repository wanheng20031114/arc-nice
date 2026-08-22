extends PlantDefense
class_name ProductionBuilding

signal production_state_changed(replicate: bool)
signal production_command_requested(command: Dictionary)
signal production_snapshot_requested(building_net_id: int)
signal multiplayer_production_result(success: bool, reason: StringName)
signal production_duration_multiplier_changed(
	previous_multiplier: float,
	current_multiplier: float
)

const RUNTIME_STATE_SCHEMA := 5
const INTERACTION_GROUP := PlantDefense.BUILDING_INTERACTION_GROUP
const INTERACTION_SELECTION_REFRESH_SECONDS := 0.08
const VISUAL_PROJECTION_WINDOW_SECONDS := 1.0
const MULTIPLAYER_PRODUCTION_REQUEST_TIMEOUT_SECONDS := 4.0
const MAX_BUFFERED_OUTPUT_PATH_LENGTH := 512
const MIN_PRODUCTION_DURATION_MULTIPLIER := 0.05

enum PanelTheme {
	DEFAULT,
	PLANT,
}

@export_group("生产配置")
@export var recipes: Array[ProductionRecipe] = []
@export var auto_select_first_recipe := false
@export var production_panel_background_override: Texture2D = null
@export var production_panel_theme: PanelTheme = PanelTheme.DEFAULT

@onready var interaction_area: Area2D = $InteractionArea
@onready var interaction_prompt: Control = $InteractionPrompt
@onready var prompt_keycap: Control = $InteractionPrompt/PromptMargin/PromptRow/Keycap
@onready var health_bar: PlantHealthBar = $HealthBar
@onready var multiplayer_production_request_timer: Timer = $MultiplayerProductionRequestTimer
@onready var production_output_bubble: ProductionOutputBubble = $ProductionOutputBubble

var production_coordinator: ProductionCoordinator = null
var production_panel: ProductionBuildingPanel = null
var recipe_unlock_checker := Callable()
var nearby_player: Player = null
var is_interaction_target := false
var production_enabled := true
var production_loop_enabled := false
var output_detail_visible := false
var active_recipe_id: StringName = &""
var progress_elapsed_seconds := 0.0
var completion_wait_reason: StringName = &""
var buffered_output_item: PickupConfig = null
var buffered_output_count := 0
var personal_output_peer_id := 0
var production_revision := 0
var building_net_id := 0
var multiplayer_production_peer_id := 0
var multiplayer_production_enabled := false
var multiplayer_production_snapshot_ready := true
var multiplayer_production_request_pending := false
var multiplayer_production_pending_request_id := 0
var next_multiplayer_production_request_id := 1
var production_duration_multiplier_modifiers: Dictionary[int, float] = {}
var cached_production_duration_multiplier := 1.0
var interaction_selection_refresh_left := 0.0
var prompt_rest_position := Vector2.ZERO
var prompt_tween: Tween = null
var _visual_progress_elapsed_at_sync := 0.0
var _visual_progress_sync_msec: int = 0
var _visual_projection_duration_seconds := VISUAL_PROJECTION_WINDOW_SECONDS
var _has_multiplayer_runtime_sample := false
var _last_multiplayer_runtime_host_sample_time := 0.0


func _ready() -> void:
	super._ready()
	add_to_group(INTERACTION_GROUP)
	prompt_rest_position = interaction_prompt.position
	_hide_interaction_prompt()
	set_process(false)
	set_process_unhandled_input(false)
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	multiplayer_production_request_timer.timeout.connect(
		_on_multiplayer_production_request_timeout
	)
	production_state_changed.connect(_refresh_production_output_bubble)
	_refresh_production_output_bubble()


func _process(delta: float) -> void:
	if nearby_player == null or not is_instance_valid(nearby_player):
		nearby_player = null
		_set_interaction_target(false)
		set_process(false)
		return
	interaction_selection_refresh_left -= delta
	if interaction_selection_refresh_left > 0.0:
		return
	interaction_selection_refresh_left = INTERACTION_SELECTION_REFRESH_SECONDS
	_refresh_interaction_selection(nearby_player)


func _unhandled_input(event: InputEvent) -> void:
	if (
		not is_interaction_target
		or nearby_player == null
		or production_panel == null
		or production_panel.is_open()
		or not event.is_action_pressed(&"interact")
		or nearby_player.controls_locked
		or nearby_player.is_dead
	):
		return
	get_viewport().set_input_as_handled()
	production_panel.open_for(self, nearby_player)


func _on_setup_completed() -> void:
	production_duration_multiplier_modifiers.clear()
	cached_production_duration_multiplier = 1.0
	progress_elapsed_seconds = 0.0
	completion_wait_reason = &""
	buffered_output_item = null
	buffered_output_count = 0
	production_enabled = true
	production_loop_enabled = uses_fixed_continuous_production()
	active_recipe_id = &""
	personal_output_peer_id = 0
	if auto_select_first_recipe:
		for recipe in recipes:
			if (
				recipe != null
				and recipe.is_valid()
				and is_recipe_unlocked(recipe)
				and not recipe.outputs_to_player_inventory()
			):
				active_recipe_id = recipe.recipe_id
				break
	production_revision = 0
	_has_multiplayer_runtime_sample = false
	_last_multiplayer_runtime_host_sample_time = 0.0
	_sync_visual_progress_clock()
	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)
	_refresh_production_output_bubble()


func _on_operational_started() -> void:
	_sync_visual_progress_clock()
	interaction_area.set_deferred("monitoring", true)
	_refresh_production_output_bubble()


func _on_removal_started(_mode: RemovalMode) -> void:
	_clear_ready_production_wait_registration()
	var interaction_player := nearby_player
	nearby_player = null
	health_bar.hide()
	set_process(false)
	interaction_area.set_deferred("monitoring", false)
	_set_interaction_target(false)
	close_production_panel()
	_refresh_production_output_bubble()
	_refresh_interaction_selection(interaction_player)


func set_production_coordinator(coordinator: ProductionCoordinator) -> void:
	if production_coordinator == coordinator:
		return
	_clear_ready_production_wait_registration()
	production_coordinator = coordinator
	if production_coordinator != null and completion_wait_reason != &"":
		production_coordinator.update_ready_production_wait(
			self,
			completion_wait_reason
		)


func set_shared_production_panel(shared_panel: ProductionBuildingPanel) -> void:
	if production_panel == shared_panel:
		return
	close_production_panel()
	production_panel = shared_panel


func set_recipe_unlock_checker(checker: Callable) -> void:
	recipe_unlock_checker = checker
	notify_recipe_unlocks_changed()


func notify_recipe_unlocks_changed() -> void:
	production_state_changed.emit(false)


func is_recipe_unlocked(recipe: ProductionRecipe) -> bool:
	if recipe == null or not recipe.is_valid():
		return false
	if not recipe.requires_global_research():
		return true
	return (
		recipe_unlock_checker.is_valid()
		and bool(recipe_unlock_checker.call(recipe.required_global_research_id))
	)


func close_production_panel() -> void:
	if _has_bound_production_panel():
		production_panel.close()


func is_modal_ui_open() -> bool:
	return _has_bound_production_panel() and production_panel.is_open()


func get_interaction_player() -> Player:
	return nearby_player


func set_interaction_target_selected(selected: bool) -> void:
	_set_interaction_target(selected)


func get_recipe(recipe_id: StringName) -> ProductionRecipe:
	for recipe in recipes:
		if recipe != null and recipe.recipe_id == recipe_id:
			return recipe
	return null


func get_active_recipe() -> ProductionRecipe:
	return get_recipe(active_recipe_id)


func set_output_detail_visible(visible: bool) -> void:
	if output_detail_visible == visible:
		return
	output_detail_visible = visible
	_refresh_production_output_bubble()


func is_production_actively_advancing() -> bool:
	var recipe := get_active_recipe()
	return (
		is_operational
		and not is_dead
		and not is_removing
		and production_enabled
		and recipe != null
		and recipe.is_valid()
		and is_recipe_unlocked(recipe)
		and completion_wait_reason == &""
		and progress_elapsed_seconds < recipe.duration_seconds
		and (not is_multiplayer_proxy or _has_multiplayer_runtime_sample)
	)


func get_display_recipe() -> ProductionRecipe:
	var active_recipe := get_active_recipe()
	if active_recipe != null:
		return active_recipe
	for recipe in recipes:
		if recipe != null and recipe.is_valid():
			return recipe
	return null


func uses_environment_source() -> bool:
	var recipe := get_display_recipe()
	return recipe != null and recipe.uses_environment_source()


## Subclasses with an intrinsic continuous cycle can hide and lock the shared
## single/loop mode selector while retaining the normal pause/resume control.
func uses_fixed_continuous_production() -> bool:
	return false


func is_player_within_multiplayer_interaction_distance(
	player: Player,
	maximum_distance: float
) -> bool:
	return (
		player != null
		and is_instance_valid(player)
		and maximum_distance >= 0.0
		and player.global_position.distance_squared_to(global_position)
		<= maximum_distance * maximum_distance
	)


func configure_multiplayer_production(
	new_building_net_id: int,
	peer_id: int,
	snapshot_ready: bool = false
) -> void:
	var normalized_building_net_id := maxi(new_building_net_id, 0)
	var normalized_peer_id := maxi(peer_id, 0)
	var will_be_enabled := normalized_building_net_id > 0 and normalized_peer_id > 0
	var identity_changed := (
		building_net_id != normalized_building_net_id
		or multiplayer_production_peer_id != normalized_peer_id
	)
	if not identity_changed and multiplayer_production_enabled == will_be_enabled:
		if snapshot_ready and not multiplayer_production_snapshot_ready:
			set_multiplayer_production_snapshot_ready(true)
		return
	if identity_changed:
		_has_multiplayer_runtime_sample = false
		_last_multiplayer_runtime_host_sample_time = 0.0
	building_net_id = normalized_building_net_id
	multiplayer_production_peer_id = normalized_peer_id
	multiplayer_production_enabled = will_be_enabled
	multiplayer_production_snapshot_ready = snapshot_ready or not will_be_enabled
	multiplayer_production_request_pending = false
	multiplayer_production_pending_request_id = 0
	multiplayer_production_request_timer.stop()
	production_state_changed.emit(false)


func set_multiplayer_production_snapshot_ready(is_ready: bool) -> void:
	multiplayer_production_snapshot_ready = is_ready or not multiplayer_production_enabled
	if multiplayer_production_snapshot_ready and not multiplayer_production_request_pending:
		multiplayer_production_request_timer.stop()
	production_state_changed.emit(false)


func is_multiplayer_production_ready() -> bool:
	return (
		is_operational
		and not is_dead
		and not is_removing
		and multiplayer_production_enabled
		and multiplayer_production_snapshot_ready
		and not multiplayer_production_request_pending
	)


func request_multiplayer_recipe_selection(recipe_id: StringName) -> bool:
	var recipe := get_recipe(recipe_id)
	if not is_multiplayer_production_ready() or not is_recipe_unlocked(recipe):
		return false
	var command := ProductionBuildingProtocol.make_select_recipe_command(
		next_multiplayer_production_request_id,
		building_net_id,
		multiplayer_production_peer_id,
		production_revision,
		recipe_id
	)
	return _submit_multiplayer_production_command(command)


func request_multiplayer_enabled_change(enabled: bool) -> bool:
	if not is_multiplayer_production_ready():
		return false
	var command := ProductionBuildingProtocol.make_set_enabled_command(
		next_multiplayer_production_request_id,
		building_net_id,
		multiplayer_production_peer_id,
		production_revision,
		enabled
	)
	return _submit_multiplayer_production_command(command)


func request_multiplayer_loop_change(enabled: bool) -> bool:
	if uses_fixed_continuous_production() or not is_multiplayer_production_ready():
		return false
	var command := ProductionBuildingProtocol.make_set_loop_enabled_command(
		next_multiplayer_production_request_id,
		building_net_id,
		multiplayer_production_peer_id,
		production_revision,
		enabled
	)
	return _submit_multiplayer_production_command(command)


func request_multiplayer_output_collection() -> bool:
	if not is_multiplayer_production_ready() or not has_buffered_output():
		return false
	var command := ProductionBuildingProtocol.make_collect_output_command(
		next_multiplayer_production_request_id,
		building_net_id,
		multiplayer_production_peer_id,
		production_revision
	)
	return _submit_multiplayer_production_command(command)


func request_multiplayer_production_snapshot() -> bool:
	if not multiplayer_production_enabled or building_net_id <= 0:
		return false
	set_multiplayer_production_snapshot_ready(false)
	multiplayer_production_request_timer.start(
		MULTIPLAYER_PRODUCTION_REQUEST_TIMEOUT_SECONDS
	)
	production_snapshot_requested.emit(building_net_id)
	return true


func complete_multiplayer_production_request(result: Dictionary) -> bool:
	if not is_current_multiplayer_production_result(result):
		return false
	multiplayer_production_request_pending = false
	multiplayer_production_pending_request_id = 0
	multiplayer_production_snapshot_ready = true
	multiplayer_production_request_timer.stop()
	multiplayer_production_result.emit(
		bool(result.get("success", false)),
		StringName(result.get(
			"reason",
			ProductionBuildingProtocol.RESULT_INVALID_COMMAND
		))
	)
	production_state_changed.emit(false)
	return true


func is_current_multiplayer_production_result(result: Dictionary) -> bool:
	return (
		multiplayer_production_enabled
		and multiplayer_production_request_pending
		and ProductionBuildingProtocol.get_int_field(result, "request_id", 0)
		== multiplayer_production_pending_request_id
		and ProductionBuildingProtocol.get_int_field(result, "building_net_id", 0)
		== building_net_id
		and ProductionBuildingProtocol.get_int_field(result, "peer_id", 0)
		== multiplayer_production_peer_id
	)


func select_recipe(
	recipe_id: StringName,
	output_peer_id: int = 0
) -> bool:
	if is_multiplayer_proxy:
		return false
	var recipe := get_recipe(recipe_id)
	if not is_recipe_unlocked(recipe):
		return false
	if has_buffered_output() and active_recipe_id != recipe_id:
		return false
	var next_output_peer_id := 0
	if recipe.outputs_to_player_inventory():
		if (
			production_coordinator == null
			or not production_coordinator.is_personal_output_peer_available(output_peer_id)
		):
			return false
		next_output_peer_id = output_peer_id
	if (
		active_recipe_id == recipe_id
		and personal_output_peer_id == next_output_peer_id
	):
		return true
	active_recipe_id = recipe_id
	personal_output_peer_id = next_output_peer_id
	progress_elapsed_seconds = 0.0
	completion_wait_reason = &""
	_clear_ready_production_wait_registration()
	_bump_production_state()
	return true


func release_personal_output_peer(peer_id: int) -> bool:
	if peer_id <= 0 or personal_output_peer_id != peer_id:
		return false
	active_recipe_id = &""
	personal_output_peer_id = 0
	progress_elapsed_seconds = 0.0
	completion_wait_reason = ProductionCoordinator.RESULT_OUTPUT_PEER_UNAVAILABLE
	_clear_ready_production_wait_registration()
	# player_left is already delivered to every endpoint. Suppressing replication
	# here keeps the disconnect repair packet-neutral while preserving revisions.
	_bump_production_state(false)
	return true


func set_production_enabled(enabled: bool) -> bool:
	if is_multiplayer_proxy:
		return false
	if production_enabled == enabled:
		return true
	production_enabled = enabled
	# Pausing always discards the partial cycle, including a ready-but-blocked
	# cycle at zero remaining time.
	progress_elapsed_seconds = 0.0
	completion_wait_reason = (
		ProductionCoordinator.RESULT_OUTPUT_SLOT_OCCUPIED
		if is_local_output_slot_full()
		else &""
	)
	_clear_ready_production_wait_registration()
	_bump_production_state()
	return true


func set_production_loop_enabled(loop_enabled: bool) -> bool:
	if is_multiplayer_proxy:
		return false
	if uses_fixed_continuous_production() and not loop_enabled:
		return false
	if production_loop_enabled == loop_enabled:
		return true
	production_loop_enabled = loop_enabled
	_bump_production_state()
	return true


func apply_authoritative_multiplayer_production_command(
	command: Dictionary
) -> StringName:
	if not ProductionBuildingProtocol.is_valid_command(command):
		return ProductionBuildingProtocol.RESULT_INVALID_COMMAND
	if is_multiplayer_proxy or is_dead or is_removing or not is_operational:
		return ProductionBuildingProtocol.RESULT_UNAVAILABLE
	if int(command["expected_production_revision"]) != production_revision:
		return ProductionBuildingProtocol.RESULT_STALE_STATE
	match ProductionBuildingProtocol.get_operation(command):
		ProductionBuildingProtocol.OPERATION_SELECT_RECIPE:
			var recipe_id := StringName(command["recipe_id"])
			var recipe := get_recipe(recipe_id)
			if recipe == null or not recipe.is_valid():
				return ProductionBuildingProtocol.RESULT_INVALID_RECIPE
			if not is_recipe_unlocked(recipe):
				return ProductionBuildingProtocol.RESULT_RESEARCH_LOCKED
			return (
				ProductionBuildingProtocol.RESULT_SUCCESS
				if select_recipe(
					recipe_id,
					ProductionBuildingProtocol.get_int_field(
						command,
						"peer_id",
						0
					)
				)
				else ProductionBuildingProtocol.RESULT_UNAVAILABLE
			)
		ProductionBuildingProtocol.OPERATION_SET_ENABLED:
			return (
				ProductionBuildingProtocol.RESULT_SUCCESS
				if set_production_enabled(bool(command["enabled"]))
				else ProductionBuildingProtocol.RESULT_UNAVAILABLE
			)
		ProductionBuildingProtocol.OPERATION_SET_LOOP_ENABLED:
			return (
				ProductionBuildingProtocol.RESULT_SUCCESS
				if set_production_loop_enabled(bool(command["loop_enabled"]))
				else ProductionBuildingProtocol.RESULT_UNAVAILABLE
			)
		ProductionBuildingProtocol.OPERATION_COLLECT_OUTPUT:
			return try_collect_buffered_output(
				ProductionBuildingProtocol.get_int_field(command, "peer_id", 0)
			)
		_:
			return ProductionBuildingProtocol.RESULT_INVALID_COMMAND


func advance_shared_production_tick(delta_seconds: float) -> void:
	if (
		is_multiplayer_proxy
		or not is_operational
		or is_dead
		or is_removing
		or not production_enabled
		or delta_seconds <= 0.0
	):
		return
	if (
		completion_wait_reason == ProductionCoordinator.RESULT_MISSING_INPUT
		or completion_wait_reason == ProductionCoordinator.RESULT_STORAGE_FULL
		or completion_wait_reason
			== ProductionCoordinator.RESULT_OUTPUT_SLOT_OCCUPIED
	):
		# These waits are event-driven by storage/inventory changes or an explicit
		# local-output collection. Keep the one-second simulation tick O(1).
		return
	var recipe := get_active_recipe()
	if not is_recipe_unlocked(recipe):
		return
	if recipe.outputs_to_local_slot() and is_local_output_slot_full():
		completion_wait_reason = ProductionCoordinator.RESULT_OUTPUT_SLOT_OCCUPIED
		return
	var previous_elapsed := progress_elapsed_seconds
	progress_elapsed_seconds = minf(
		progress_elapsed_seconds
		+ delta_seconds / get_production_duration_multiplier(),
		recipe.duration_seconds
	)
	if progress_elapsed_seconds + 0.0001 >= recipe.duration_seconds:
		if try_complete_ready_production():
			return
	if not is_equal_approx(previous_elapsed, progress_elapsed_seconds):
		_bump_production_state()


func try_complete_ready_production() -> bool:
	if (
		is_multiplayer_proxy
		or not is_operational
		or is_dead
		or is_removing
		or not production_enabled
		or production_coordinator == null
	):
		return false
	var recipe := get_active_recipe()
	if (
		not is_recipe_unlocked(recipe)
		or progress_elapsed_seconds + 0.0001 < recipe.duration_seconds
	):
		return false
	if recipe.outputs_to_local_slot():
		return _complete_local_output_cycle(recipe)
	# Remove this attempt from the parked cohort before the coordinator publishes
	# transaction signals. A successful output may synchronously wake other
	# buildings without recursively committing this still-ready cycle twice.
	_clear_ready_production_wait_registration()
	var result := production_coordinator.try_commit_recipe(
		recipe,
		personal_output_peer_id
	)
	if result == ProductionCoordinator.RESULT_SUCCESS:
		progress_elapsed_seconds = 0.0
		completion_wait_reason = &""
		if not production_loop_enabled:
			production_enabled = false
		_clear_ready_production_wait_registration()
		_bump_production_state()
		return true
	production_coordinator.update_ready_production_wait(self, result)
	if completion_wait_reason != result:
		completion_wait_reason = result
		_bump_production_state()
	return false


func has_buffered_output() -> bool:
	return buffered_output_item != null and buffered_output_count > 0


func get_buffered_output_item() -> PickupConfig:
	return buffered_output_item if has_buffered_output() else null


func get_buffered_output_count() -> int:
	return buffered_output_count if has_buffered_output() else 0


func get_local_output_capacity() -> int:
	var recipe := get_active_recipe()
	return recipe.get_local_output_capacity() if recipe != null else 0


func is_local_output_slot_full() -> bool:
	if not has_buffered_output():
		return false
	var capacity := get_local_output_capacity()
	return capacity <= 0 or buffered_output_count >= capacity


func try_collect_buffered_output(output_peer_id: int) -> StringName:
	if (
		is_multiplayer_proxy
		or not is_operational
		or is_dead
		or is_removing
		or production_coordinator == null
	):
		return ProductionBuildingProtocol.RESULT_UNAVAILABLE
	if not has_buffered_output():
		return ProductionBuildingProtocol.RESULT_OUTPUT_EMPTY
	var recipe := get_active_recipe()
	if recipe == null or not recipe.outputs_to_local_slot():
		return ProductionBuildingProtocol.RESULT_UNAVAILABLE
	var commit_result := (
		production_coordinator.try_commit_personal_output_without_notification(
			buffered_output_item,
			buffered_output_count,
			output_peer_id
		)
	)
	match commit_result:
		ProductionCoordinator.RESULT_SUCCESS:
			buffered_output_item = null
			buffered_output_count = 0
			completion_wait_reason = &""
			_bump_production_state()
			production_coordinator.publish_personal_output_commit(output_peer_id)
			return ProductionBuildingProtocol.RESULT_SUCCESS
		ProductionCoordinator.RESULT_STORAGE_FULL:
			return ProductionBuildingProtocol.RESULT_INVENTORY_FULL
		ProductionCoordinator.RESULT_OUTPUT_PEER_UNAVAILABLE:
			return ProductionBuildingProtocol.RESULT_INVALID_PLAYER
		_:
			return ProductionBuildingProtocol.RESULT_UNAVAILABLE


func _complete_local_output_cycle(recipe: ProductionRecipe) -> bool:
	var output := _select_local_output(recipe)
	var item := output.get("item") as PickupConfig
	var count := int(output.get("count", 0))
	var capacity := recipe.get_local_output_capacity()
	if (
		item == null
		or not item.can_store_in_inventory
		or count <= 0
		or capacity <= 0
		or count > capacity
	):
		return false
	if has_buffered_output():
		if (
			not PickupConfig.inventory_items_can_stack(buffered_output_item, item)
			or buffered_output_count + count > capacity
		):
			if completion_wait_reason != ProductionCoordinator.RESULT_OUTPUT_SLOT_OCCUPIED:
				completion_wait_reason = ProductionCoordinator.RESULT_OUTPUT_SLOT_OCCUPIED
				_bump_production_state()
			return false
		buffered_output_count += count
	else:
		buffered_output_item = item
		buffered_output_count = count
	progress_elapsed_seconds = 0.0
	if not production_loop_enabled:
		production_enabled = false
	completion_wait_reason = (
		ProductionCoordinator.RESULT_OUTPUT_SLOT_OCCUPIED
		if buffered_output_count >= capacity
		else &""
	)
	_clear_ready_production_wait_registration()
	_bump_production_state()
	return true


func _select_local_output(recipe: ProductionRecipe) -> Dictionary:
	if (
		recipe == null
		or recipe.output_items.is_empty()
		or recipe.output_amounts.is_empty()
	):
		return {}
	return {
		"item": recipe.output_items[0],
		"count": recipe.output_amounts[0],
	}


## Registers one production-duration source. Concurrent sources use only the
## shortest duration multiplier, so overlapping support fields never compound.
func add_production_duration_multiplier_modifier(
	source_id: int,
	multiplier: float
) -> bool:
	if source_id == 0 or not is_finite(multiplier) or multiplier <= 0.0:
		return false
	var safe_multiplier := clampf(
		multiplier,
		MIN_PRODUCTION_DURATION_MULTIPLIER,
		1.0
	)
	if is_equal_approx(safe_multiplier, 1.0):
		return remove_production_duration_multiplier_modifier(source_id)
	if (
		production_duration_multiplier_modifiers.has(source_id)
		and is_equal_approx(
			float(production_duration_multiplier_modifiers[source_id]),
			safe_multiplier
		)
	):
		return false
	production_duration_multiplier_modifiers[source_id] = safe_multiplier
	_refresh_production_duration_multiplier_cache()
	return true


func remove_production_duration_multiplier_modifier(source_id: int) -> bool:
	if not production_duration_multiplier_modifiers.has(source_id):
		return false
	production_duration_multiplier_modifiers.erase(source_id)
	_refresh_production_duration_multiplier_cache()
	return true


func get_production_duration_multiplier() -> float:
	return cached_production_duration_multiplier


func get_effective_production_duration_seconds(recipe: ProductionRecipe) -> float:
	if recipe == null or not is_finite(recipe.duration_seconds):
		return 0.0
	return maxf(
		recipe.duration_seconds * cached_production_duration_multiplier,
		0.0
	)


func _refresh_production_duration_multiplier_cache() -> void:
	var previous_multiplier := cached_production_duration_multiplier
	var strongest_multiplier := 1.0
	for source_id in production_duration_multiplier_modifiers:
		strongest_multiplier = minf(
			strongest_multiplier,
			clampf(
				float(production_duration_multiplier_modifiers[source_id]),
				MIN_PRODUCTION_DURATION_MULTIPLIER,
				1.0
			)
		)
	cached_production_duration_multiplier = strongest_multiplier
	if is_equal_approx(previous_multiplier, cached_production_duration_multiplier):
		return
	# Shared production advances in one-second authoritative quanta. Restart the
	# display-only projection from authoritative work so the rest of this quantum
	# previews exactly the multiplier that the next shared tick will consume.
	_sync_visual_progress_clock()
	production_duration_multiplier_changed.emit(
		previous_multiplier,
		cached_production_duration_multiplier
	)
	# Aura membership is derived runtime state. Refresh local UI without changing
	# production_revision or producing a multiplayer state packet.
	production_state_changed.emit(false)


func get_progress_ratio() -> float:
	var recipe := get_active_recipe()
	if recipe == null or recipe.duration_seconds <= 0.0:
		return 0.0
	return clampf(progress_elapsed_seconds / recipe.duration_seconds, 0.0, 1.0)


## Smooth display state projected only until the next shared one-second logic
## tick. It cannot advance authoritative production, consume items or emit
## network state, so a stalled tick never grants progress.
func get_visual_progress_elapsed_seconds() -> float:
	var recipe := get_active_recipe()
	if recipe == null or not recipe.is_valid():
		return 0.0
	var visual_elapsed := clampf(
		_visual_progress_elapsed_at_sync,
		0.0,
		recipe.duration_seconds
	)
	if _should_project_visual_progress(recipe):
		var elapsed_since_sync := maxf(
			float(Time.get_ticks_msec() - _visual_progress_sync_msec) / 1000.0,
			0.0
		)
		var projection_fraction := clampf(
			elapsed_since_sync / maxf(_visual_projection_duration_seconds, 0.001),
			0.0,
			1.0
		)
		visual_elapsed += minf(
			VISUAL_PROJECTION_WINDOW_SECONDS
			/ get_production_duration_multiplier(),
			maxf(
				recipe.duration_seconds - visual_elapsed,
				0.0
			)
		) * projection_fraction
	return clampf(visual_elapsed, 0.0, recipe.duration_seconds)


func get_visual_progress_ratio() -> float:
	var recipe := get_active_recipe()
	if recipe == null or not recipe.is_valid():
		return 0.0
	return clampf(
		get_visual_progress_elapsed_seconds() / recipe.duration_seconds,
		0.0,
		1.0
	)


func get_visual_remaining_seconds() -> float:
	var recipe := get_active_recipe()
	if recipe == null:
		return 0.0
	return maxf(
		recipe.duration_seconds - get_visual_progress_elapsed_seconds(),
		0.0
	) * get_production_duration_multiplier()


func get_visual_projection_duration_seconds() -> float:
	return _visual_projection_duration_seconds


func get_remaining_seconds() -> float:
	var recipe := get_active_recipe()
	if recipe == null:
		return 0.0
	return maxf(
		recipe.duration_seconds - progress_elapsed_seconds,
		0.0
	) * get_production_duration_multiplier()


func export_multiplayer_runtime_state() -> Dictionary:
	return {
		"schema": RUNTIME_STATE_SCHEMA,
		"enabled": production_enabled,
		"loop_enabled": production_loop_enabled,
		"active_recipe_id": String(active_recipe_id),
		"progress_elapsed_seconds": progress_elapsed_seconds,
		"wait_reason": String(completion_wait_reason),
		"buffered_output_config_path": (
			buffered_output_item.resource_path if has_buffered_output() else ""
		),
		"buffered_output_count": get_buffered_output_count(),
		"personal_output_peer_id": personal_output_peer_id,
		"revision": production_revision,
		"projection_duration_seconds": get_visual_projection_duration_seconds(),
	}


func apply_multiplayer_runtime_state(state: Dictionary, mapped_sample_time: float) -> void:
	_apply_multiplayer_runtime_state_sample(
		state,
		mapped_sample_time,
		mapped_sample_time
	)


func apply_multiplayer_runtime_state_with_host_sample(
	state: Dictionary,
	mapped_sample_time: float,
	host_sample_time: float
) -> void:
	_apply_multiplayer_runtime_state_sample(
		state,
		mapped_sample_time,
		host_sample_time
	)


func _apply_multiplayer_runtime_state_sample(
	state: Dictionary,
	mapped_sample_time: float,
	received_host_sample_time: float
) -> void:
	if not is_multiplayer_proxy:
		return
	if (
		typeof(state.get("schema")) != TYPE_INT
		or int(state["schema"]) != RUNTIME_STATE_SCHEMA
		or typeof(state.get("revision")) != TYPE_INT
		or typeof(state.get("enabled")) != TYPE_BOOL
		or typeof(state.get("loop_enabled")) != TYPE_BOOL
		or typeof(state.get("active_recipe_id")) not in [TYPE_STRING, TYPE_STRING_NAME]
		or typeof(state.get("progress_elapsed_seconds")) not in [TYPE_INT, TYPE_FLOAT]
		or typeof(state.get("wait_reason")) not in [TYPE_STRING, TYPE_STRING_NAME]
		or typeof(state.get("buffered_output_config_path"))
			not in [TYPE_STRING, TYPE_STRING_NAME]
		or typeof(state.get("buffered_output_count")) != TYPE_INT
		or typeof(state.get("personal_output_peer_id")) != TYPE_INT
		or typeof(state.get("projection_duration_seconds")) not in [TYPE_INT, TYPE_FLOAT]
	):
		return
	var received_progress := float(state["progress_elapsed_seconds"])
	var received_projection := float(state["projection_duration_seconds"])
	if (
		not is_finite(received_progress)
		or not is_finite(received_projection)
		or not is_finite(received_host_sample_time)
	):
		return
	var received_revision := int(state["revision"])
	var received_output_peer_id := int(state["personal_output_peer_id"])
	var received_buffered_output_count := int(state["buffered_output_count"])
	var received_buffered_output_path := String(
		state["buffered_output_config_path"]
	)
	if (
		received_revision < 0
		or received_output_peer_id < 0
		or received_buffered_output_count < 0
		or received_buffered_output_path.length()
			> MAX_BUFFERED_OUTPUT_PATH_LENGTH
	):
		return
	if (
		received_revision < production_revision
		or (
			received_revision == production_revision
			and _has_multiplayer_runtime_sample
			and received_host_sample_time
			<= _last_multiplayer_runtime_host_sample_time
		)
	):
		return
	var received_recipe_id := StringName(state["active_recipe_id"])
	var received_recipe := get_recipe(received_recipe_id)
	if received_recipe_id != &"" and received_recipe == null:
		return
	var received_loop_enabled := bool(state["loop_enabled"])
	if uses_fixed_continuous_production() and not received_loop_enabled:
		return
	var received_buffered_output_item: PickupConfig = null
	if received_buffered_output_path.is_empty():
		if received_buffered_output_count != 0:
			return
	else:
		if (
			received_buffered_output_count <= 0
			or not received_buffered_output_path.begins_with(
				"res://resources/config/"
			)
			or received_buffered_output_path.get_extension() != "tres"
			or not ResourceLoader.exists(received_buffered_output_path)
		):
			return
		received_buffered_output_item = load(
			received_buffered_output_path
		) as PickupConfig
		if (
			received_recipe == null
			or not received_recipe.outputs_to_local_slot()
			or received_buffered_output_item == null
			or not received_buffered_output_item.can_store_in_inventory
			or not PickupConfig.inventory_identity_matches(
				received_recipe.output_items[0],
				received_buffered_output_item
			)
			or received_buffered_output_count
				> received_recipe.get_local_output_capacity()
		):
			return
	var received_wait_reason := StringName(state["wait_reason"])
	if received_recipe != null and received_recipe.outputs_to_player_inventory():
		if production_coordinator == null:
			return
		if not production_coordinator.is_personal_output_peer_available(
			received_output_peer_id
		):
			# A reliable production snapshot can cross the transport-level player_left
			# notification. Keep the disconnect tombstone authoritative locally so an
			# older in-flight state cannot resurrect an unavailable output binding.
			received_recipe_id = &""
			received_output_peer_id = 0
			received_progress = 0.0
			received_wait_reason = ProductionCoordinator.RESULT_OUTPUT_PEER_UNAVAILABLE
	_has_multiplayer_runtime_sample = true
	_last_multiplayer_runtime_host_sample_time = received_host_sample_time
	production_revision = received_revision
	production_enabled = bool(state["enabled"])
	production_loop_enabled = received_loop_enabled
	active_recipe_id = received_recipe_id
	personal_output_peer_id = received_output_peer_id
	buffered_output_item = received_buffered_output_item
	buffered_output_count = received_buffered_output_count
	var recipe := get_active_recipe()
	progress_elapsed_seconds = clampf(
		received_progress,
		0.0,
		recipe.duration_seconds if recipe != null else 0.0
	)
	completion_wait_reason = received_wait_reason
	_sync_visual_progress_clock()
	_visual_projection_duration_seconds = clampf(
		received_projection,
		0.001,
		VISUAL_PROJECTION_WINDOW_SECONDS
	)
	var sample_age_seconds := maxf(
		float(Time.get_ticks_msec()) / 1000.0 - mapped_sample_time,
		0.0
	)
	_visual_progress_sync_msec -= int(
		minf(sample_age_seconds, _visual_projection_duration_seconds) * 1000.0
	)
	if multiplayer_production_enabled:
		multiplayer_production_snapshot_ready = true
		if not multiplayer_production_request_pending:
			multiplayer_production_request_timer.stop()
	production_state_changed.emit(false)


func on_shared_production_panel_opened(panel: ProductionBuildingPanel) -> void:
	if panel != production_panel or not _has_bound_production_panel():
		return
	_set_interaction_target(false)
	_refresh_interaction_selection(nearby_player)
	modal_ui_visibility_changed.emit(true)


func on_shared_production_panel_closed(panel: ProductionBuildingPanel) -> void:
	if panel != production_panel:
		return
	if nearby_player != null:
		_refresh_interaction_selection(nearby_player)
	else:
		_set_interaction_target(false)
	modal_ui_visibility_changed.emit(false)


func _has_bound_production_panel() -> bool:
	return (
		production_panel != null
		and is_instance_valid(production_panel)
		and production_panel.is_bound_to_building(self)
	)


func _bump_production_state(replicate: bool = true) -> void:
	production_revision += 1
	_sync_visual_progress_clock()
	production_state_changed.emit(replicate)


func _refresh_production_output_bubble(_replicate: bool = false) -> void:
	production_output_bubble.refresh(
		get_active_recipe(),
		output_detail_visible and not is_dead and not is_removing,
		is_production_actively_advancing()
	)


func _clear_ready_production_wait_registration() -> void:
	if production_coordinator != null:
		production_coordinator.clear_ready_production_wait(self)


func _submit_multiplayer_production_command(command: Dictionary) -> bool:
	if not ProductionBuildingProtocol.is_valid_command(command):
		return false
	var request_id := ProductionBuildingProtocol.get_int_field(
		command,
		"request_id",
		0
	)
	multiplayer_production_request_pending = true
	multiplayer_production_pending_request_id = request_id
	next_multiplayer_production_request_id = maxi(
		next_multiplayer_production_request_id,
		request_id + 1
	)
	multiplayer_production_request_timer.start(
		MULTIPLAYER_PRODUCTION_REQUEST_TIMEOUT_SECONDS
	)
	production_state_changed.emit(false)
	production_command_requested.emit(command)
	return true


func _on_multiplayer_production_request_timeout() -> void:
	if not multiplayer_production_enabled:
		return
	if (
		not multiplayer_production_request_pending
		and multiplayer_production_snapshot_ready
	):
		return
	multiplayer_production_request_pending = false
	multiplayer_production_pending_request_id = 0
	multiplayer_production_snapshot_ready = false
	production_state_changed.emit(false)
	multiplayer_production_request_timer.start(
		MULTIPLAYER_PRODUCTION_REQUEST_TIMEOUT_SECONDS
	)
	production_snapshot_requested.emit(building_net_id)


func _sync_visual_progress_clock() -> void:
	var recipe := get_active_recipe()
	var maximum_elapsed := recipe.duration_seconds if recipe != null else 0.0
	_visual_progress_elapsed_at_sync = clampf(
		progress_elapsed_seconds,
		0.0,
		maximum_elapsed
	)
	_visual_progress_sync_msec = Time.get_ticks_msec()
	_visual_projection_duration_seconds = (
		production_coordinator.get_seconds_until_next_tick()
		if production_coordinator != null
		else VISUAL_PROJECTION_WINDOW_SECONDS
	)


func _should_project_visual_progress(recipe: ProductionRecipe) -> bool:
	return (
		recipe != null
		and is_operational
		and not is_dead
		and not is_removing
		and production_enabled
		and completion_wait_reason == &""
		and _visual_progress_elapsed_at_sync + 0.0001 < recipe.duration_seconds
	)


func _on_interaction_area_body_entered(body: Node2D) -> void:
	var player := body as Player
	if player == null or not player.uses_local_input or player.is_dead:
		return
	nearby_player = player
	interaction_selection_refresh_left = 0.0
	set_process(true)
	_refresh_interaction_selection(player)


func _on_interaction_area_body_exited(body: Node2D) -> void:
	if body != nearby_player:
		return
	var exiting_player := nearby_player
	nearby_player = null
	set_process(false)
	_set_interaction_target(false)
	close_production_panel()
	_refresh_interaction_selection(exiting_player)


func _refresh_interaction_selection(player: Player) -> void:
	if player == null or not is_instance_valid(player) or get_tree() == null:
		return
	var nearby_buildings: Array[PlantDefense] = []
	var nearest_building: PlantDefense = null
	var nearest_distance_squared := INF
	var building_panel_is_open := false
	for node in get_tree().get_nodes_in_group(INTERACTION_GROUP):
		var building := node as PlantDefense
		if (
			building == null
			or not is_instance_valid(building)
			or building.is_queued_for_deletion()
			or building.get_interaction_player() != player
		):
			continue
		nearby_buildings.append(building)
		if building.is_modal_ui_open():
			building_panel_is_open = true
		if building.is_dead or building.is_removing or building.is_modal_ui_open():
			continue
		var distance_squared := player.global_position.distance_squared_to(
			building.global_position
		)
		if PlantDefense.is_interaction_candidate_preferred(
			building,
			distance_squared,
			nearest_building,
			nearest_distance_squared
		):
			nearest_building = building
			nearest_distance_squared = distance_squared
	var can_select := (
		not building_panel_is_open
		and not player.is_dead
		and not player.controls_locked
	)
	for building in nearby_buildings:
		building.set_interaction_target_selected(
			can_select and building == nearest_building
		)


func _set_interaction_target(should_be_target: bool) -> void:
	if is_interaction_target == should_be_target:
		set_process_unhandled_input(should_be_target)
		if not should_be_target and interaction_prompt.visible:
			_hide_interaction_prompt()
		return
	is_interaction_target = should_be_target
	set_process_unhandled_input(should_be_target)
	if should_be_target:
		_show_interaction_prompt()
	else:
		_hide_interaction_prompt()


func _show_interaction_prompt() -> void:
	_stop_prompt_tween()
	interaction_prompt.position = prompt_rest_position + Vector2(0, 1)
	interaction_prompt.modulate = Color(1, 1, 1, 0)
	prompt_keycap.modulate = Color(1, 1, 0.72, 1)
	interaction_prompt.show()
	prompt_tween = create_tween().set_parallel(true)
	prompt_tween.tween_property(interaction_prompt, "modulate:a", 1.0, 0.08)
	prompt_tween.tween_method(_set_prompt_reveal_offset, 1.0, 0.0, 0.08)
	prompt_tween.tween_property(prompt_keycap, "modulate", Color.WHITE, 0.14)


func _hide_interaction_prompt() -> void:
	_stop_prompt_tween()
	interaction_prompt.hide()
	interaction_prompt.position = prompt_rest_position
	interaction_prompt.modulate = Color.WHITE
	prompt_keycap.modulate = Color.WHITE


func _stop_prompt_tween() -> void:
	if prompt_tween != null and prompt_tween.is_valid():
		prompt_tween.kill()
	prompt_tween = null


func _set_prompt_reveal_offset(offset: float) -> void:
	interaction_prompt.position = prompt_rest_position + Vector2(0, roundf(offset))


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)
