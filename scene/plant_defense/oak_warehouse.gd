extends PlantDefense
class_name OakWarehouse

signal storage_changed

const STORAGE_CAPACITY := RunStateStore.INVENTORY_CAPACITY
const INTERACTION_GROUP := &"oak_warehouse_interaction"
const INTERACTION_SELECTION_REFRESH_SECONDS := 0.08

@onready var interaction_area: Area2D = $InteractionArea
@onready var interaction_prompt: Control = $InteractionPrompt
@onready var prompt_keycap: Control = $InteractionPrompt/PromptMargin/PromptRow/Keycap
@onready var idle_animation_player: AnimationPlayer = $IdleAnimationPlayer
@onready var storage_panel: OakWarehousePanel = $OakWarehousePanel
@onready var health_bar: Control = $HealthBar

var storage_items: Array[PickupConfig] = []
var storage_stack_counts: Array[int] = []
var nearby_player: Player = null
var is_interaction_target := false
var interaction_selection_refresh_left := 0.0
var prompt_rest_position := Vector2.ZERO
var prompt_tween: Tween = null


func _ready() -> void:
	super._ready()
	add_to_group(INTERACTION_GROUP)
	storage_items.resize(STORAGE_CAPACITY)
	storage_stack_counts.resize(STORAGE_CAPACITY)
	storage_stack_counts.fill(0)
	prompt_rest_position = interaction_prompt.position
	_hide_interaction_prompt()
	if idle_animation_player.has_animation(&"idle"):
		var phase := fmod(float(get_instance_id()) * 0.37, 4.0)
		idle_animation_player.play(&"idle")
		idle_animation_player.seek(phase, true)
	set_process(false)
	set_process_unhandled_input(false)
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	storage_panel.opened.connect(_on_storage_panel_opened)
	storage_panel.closed.connect(_on_storage_panel_closed)


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


func _on_setup_completed() -> void:
	super._on_setup_completed()
	health_bar.call("setup", max_health, current_health)
	health_changed.connect(_on_health_changed)
	storage_panel.bind_warehouse(self, owner_player)
	if owner_player != null and not owner_player.died.is_connected(_on_owner_player_died):
		owner_player.died.connect(_on_owner_player_died)


func _unhandled_input(event: InputEvent) -> void:
	if not is_interaction_target or nearby_player == null or storage_panel.is_open():
		return
	if not event.is_action_pressed(&"interact"):
		return
	if nearby_player.controls_locked or nearby_player.is_dead:
		return

	get_viewport().set_input_as_handled()
	storage_panel.bind_warehouse(self, nearby_player)
	storage_panel.open()


func is_modal_ui_open() -> bool:
	return storage_panel != null and storage_panel.is_open()


func get_storage_item(slot_index: int) -> PickupConfig:
	if slot_index < 0 or slot_index >= STORAGE_CAPACITY:
		return null
	return storage_items[slot_index]


func get_storage_item_count(slot_index: int) -> int:
	if slot_index < 0 or slot_index >= STORAGE_CAPACITY:
		return 0
	if storage_items[slot_index] == null:
		return 0
	return maxi(storage_stack_counts[slot_index], 1)


func can_add_storage_item_count(item: PickupConfig, count: int) -> bool:
	if item == null or not item.can_store_in_inventory or count <= 0:
		return false
	return _get_available_storage_capacity(item) >= count


func try_add_storage_item_count(item: PickupConfig, count: int) -> bool:
	if not can_add_storage_item_count(item, count):
		return false

	var remaining := count
	var stack_limit := _get_stack_limit(item)
	if item.stackable:
		for slot_index in range(STORAGE_CAPACITY):
			if not _items_share_stack(storage_items[slot_index], item):
				continue
			var room := maxi(stack_limit - storage_stack_counts[slot_index], 0)
			var added := mini(room, remaining)
			storage_stack_counts[slot_index] += added
			remaining -= added
			if remaining <= 0:
				storage_changed.emit()
				return true

	for slot_index in range(STORAGE_CAPACITY):
		if storage_items[slot_index] != null:
			continue
		var added := mini(stack_limit, remaining)
		storage_items[slot_index] = item
		storage_stack_counts[slot_index] = added
		remaining -= added
		if remaining <= 0:
			storage_changed.emit()
			return true
	return false


func discard_storage_item(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= STORAGE_CAPACITY:
		return false
	if storage_items[slot_index] == null:
		return false
	storage_items[slot_index] = null
	storage_stack_counts[slot_index] = 0
	storage_changed.emit()
	return true


func transfer_player_stack_to_storage(slot_index: int, run_state: RunStateStore) -> bool:
	if run_state == null:
		return false
	var item := run_state.get_item(slot_index)
	var count := run_state.get_item_count(slot_index)
	if not can_add_storage_item_count(item, count):
		return false
	if not run_state.discard_item(slot_index):
		return false
	return try_add_storage_item_count(item, count)


func transfer_storage_stack_to_player(slot_index: int, run_state: RunStateStore) -> bool:
	if run_state == null:
		return false
	var item := get_storage_item(slot_index)
	var count := get_storage_item_count(slot_index)
	if item == null or count <= 0:
		return false
	if not run_state.try_add_item_count(item, count):
		return false
	return discard_storage_item(slot_index)


func _get_available_storage_capacity(item: PickupConfig) -> int:
	var stack_limit := _get_stack_limit(item)
	var capacity := 0
	for slot_index in range(STORAGE_CAPACITY):
		var stored_item := storage_items[slot_index]
		if stored_item == null:
			capacity += stack_limit
		elif item.stackable and _items_share_stack(stored_item, item):
			capacity += maxi(stack_limit - storage_stack_counts[slot_index], 0)
	return capacity


func _items_share_stack(existing_item: PickupConfig, incoming_item: PickupConfig) -> bool:
	if existing_item == null or incoming_item == null or not incoming_item.stackable:
		return false
	if existing_item == incoming_item:
		return true
	return (
		not existing_item.resource_path.is_empty()
		and existing_item.resource_path == incoming_item.resource_path
	)


func _get_stack_limit(item: PickupConfig) -> int:
	if item == null or not item.stackable:
		return 1
	return clampi(item.inventory_stack_limit, 1, 999)


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
	storage_panel.close()
	_refresh_interaction_selection(exiting_player)


func _on_storage_panel_opened() -> void:
	_set_interaction_target(false)
	_refresh_interaction_selection(nearby_player)
	modal_ui_visibility_changed.emit(true)


func _on_storage_panel_closed() -> void:
	if nearby_player != null:
		_refresh_interaction_selection(nearby_player)
	else:
		_set_interaction_target(false)
	modal_ui_visibility_changed.emit(false)


func _refresh_interaction_selection(player: Player) -> void:
	if player == null or not is_instance_valid(player) or get_tree() == null:
		return
	var nearby_warehouses: Array[OakWarehouse] = []
	var nearest_warehouse: OakWarehouse = null
	var nearest_distance_squared := INF
	var warehouse_panel_is_open := false
	for node in get_tree().get_nodes_in_group(INTERACTION_GROUP):
		var warehouse := node as OakWarehouse
		if (
			warehouse == null
			or not is_instance_valid(warehouse)
			or warehouse.is_queued_for_deletion()
		):
			continue
		if (
			warehouse.storage_panel.is_open()
			and warehouse.storage_panel.tracked_player == player
		):
			warehouse_panel_is_open = true
		if warehouse.nearby_player != player:
			continue
		nearby_warehouses.append(warehouse)
		if warehouse.is_dead or warehouse.storage_panel.is_open():
			continue
		var distance_squared := player.global_position.distance_squared_to(
			warehouse.global_position
		)
		var wins_distance_tie := false
		if is_equal_approx(distance_squared, nearest_distance_squared):
			wins_distance_tie = (
				nearest_warehouse == null
				or warehouse.global_position.y < nearest_warehouse.global_position.y
				or (
					is_equal_approx(
						warehouse.global_position.y,
						nearest_warehouse.global_position.y
					)
					and (
						warehouse.global_position.x < nearest_warehouse.global_position.x
						or (
							is_equal_approx(
								warehouse.global_position.x,
								nearest_warehouse.global_position.x
							)
							and (
								warehouse.get_instance_id()
								< nearest_warehouse.get_instance_id()
							)
						)
					)
				)
			)
		if distance_squared < nearest_distance_squared or wins_distance_tie:
			nearest_warehouse = warehouse
			nearest_distance_squared = distance_squared

	var can_select := (
		not warehouse_panel_is_open
		and not player.is_dead
		and not player.controls_locked
	)
	for warehouse in nearby_warehouses:
		warehouse._set_interaction_target(
			can_select and warehouse == nearest_warehouse
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
	health_bar.call("set_health", new_health, new_max_health)


func _on_owner_player_died() -> void:
	_set_interaction_target(false)
	storage_panel.close()
	_refresh_interaction_selection(nearby_player)


func _on_death_started() -> void:
	var interaction_player := nearby_player
	nearby_player = null
	set_process(false)
	interaction_area.set_deferred("monitoring", false)
	_set_interaction_target(false)
	storage_panel.close()
	_refresh_interaction_selection(interaction_player)
	super._on_death_started()
