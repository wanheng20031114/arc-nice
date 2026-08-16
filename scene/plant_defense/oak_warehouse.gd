extends PlantDefense
class_name OakWarehouse

const RuntimeContentCatalogScript := preload(
	"res://resources/config/runtime_content_catalog.gd"
)

signal storage_changed
signal storage_command_requested(command: Dictionary)
signal storage_snapshot_requested(warehouse_net_id: int)

const STORAGE_CAPACITY := RunStateStore.INVENTORY_CAPACITY
const INTERACTION_GROUP := PlantDefense.BUILDING_INTERACTION_GROUP
const INTERACTION_SELECTION_REFRESH_SECONDS := 0.08
const MULTIPLAYER_STORAGE_REQUEST_TIMEOUT_SECONDS := 4.0

@onready var interaction_area: Area2D = $InteractionArea
@onready var interaction_prompt: Control = $InteractionPrompt
@onready var prompt_keycap: Control = $InteractionPrompt/PromptMargin/PromptRow/Keycap
@onready var idle_animation_player: AnimationPlayer = $IdleAnimationPlayer
@onready var health_bar: Control = $HealthBar
@onready var multiplayer_storage_request_timer: Timer = $MultiplayerStorageRequestTimer

var storage_items: Array[PickupConfig] = []
var storage_stack_counts: Array[int] = []
var storage_revision: int = 0
var warehouse_net_id: int = 0
var multiplayer_storage_peer_id: int = 0
var multiplayer_storage_enabled := false
var multiplayer_storage_snapshot_ready := true
var multiplayer_storage_request_pending := false
var multiplayer_storage_pending_request_id: int = 0
var next_multiplayer_storage_request_id: int = 1
var storage_panel: OakWarehousePanel = null
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
	multiplayer_storage_request_timer.timeout.connect(
		_on_multiplayer_storage_request_timeout
	)


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


func _on_operational_started() -> void:
	interaction_area.set_deferred("monitoring", true)


func set_shared_storage_panel(shared_panel: OakWarehousePanel) -> void:
	if storage_panel == shared_panel:
		return
	close_storage_panel()
	storage_panel = shared_panel


func close_storage_panel() -> void:
	if _has_bound_storage_panel():
		storage_panel.close()


func _unhandled_input(event: InputEvent) -> void:
	if (
		not is_interaction_target
		or nearby_player == null
		or storage_panel == null
		or storage_panel.is_open()
	):
		return
	if not event.is_action_pressed(&"interact"):
		return
	if nearby_player.controls_locked or nearby_player.is_dead:
		return

	get_viewport().set_input_as_handled()
	storage_panel.open_for(self, nearby_player)


func is_modal_ui_open() -> bool:
	return _has_bound_storage_panel() and storage_panel.is_open()


func get_interaction_player() -> Player:
	return nearby_player


func set_interaction_target_selected(selected: bool) -> void:
	_set_interaction_target(selected)


func _has_bound_storage_panel() -> bool:
	return (
		storage_panel != null
		and is_instance_valid(storage_panel)
		and storage_panel.is_bound_to_warehouse(self)
	)


func _sync_bound_storage_panel_state() -> void:
	if not _has_bound_storage_panel():
		return
	storage_panel.set_multiplayer_storage_state(
		multiplayer_storage_enabled,
		multiplayer_storage_snapshot_ready,
		multiplayer_storage_request_pending
	)


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


func get_storage_revision() -> int:
	return storage_revision


func get_storage_item_total(item: PickupConfig) -> int:
	if item == null:
		return 0
	var total := 0
	for slot_index in STORAGE_CAPACITY:
		if PickupConfig.inventory_identity_matches(storage_items[slot_index], item):
			total += get_storage_item_count(slot_index)
	return total


func export_production_storage_snapshot() -> Dictionary:
	return {
		"warehouse": self,
		"revision": storage_revision,
		"items": storage_items.duplicate(),
		"counts": storage_stack_counts.duplicate(),
		"changed": false,
	}


func apply_production_storage_snapshot(
	items: Array,
	counts: Array,
	expected_revision: int,
	emit_change_signal: bool = true
) -> bool:
	if (
		is_multiplayer_proxy
		or is_dead
		or is_removing
		or not is_operational
		or expected_revision != storage_revision
		or items.size() != STORAGE_CAPACITY
		or counts.size() != STORAGE_CAPACITY
	):
		return false
	for slot_index in STORAGE_CAPACITY:
		var item := items[slot_index] as PickupConfig
		var count := int(counts[slot_index])
		if item == null:
			if count != 0:
				return false
			continue
		if (
			not item.can_store_in_inventory
			or count <= 0
			or count > PickupConfig.get_inventory_stack_limit(item)
		):
			return false
	storage_items.assign(items)
	storage_stack_counts.assign(counts)
	storage_revision += 1
	if emit_change_signal:
		storage_changed.emit()
	return true


## Validates one sparse production transaction without copying the other slots.
## The coordinator performs this pass for every touched warehouse before the
## first write, so a malformed or stale journal cannot expose a partial commit.
func validate_production_storage_slot_changes(
	slot_indices: PackedInt32Array,
	items: Array[PickupConfig],
	counts: PackedInt32Array,
	expected_revision: int
) -> bool:
	return (
		not is_multiplayer_proxy
		and not is_dead
		and not is_removing
		and is_operational
		and expected_revision == storage_revision
		and _is_production_storage_slot_payload_valid(
			slot_indices,
			items,
			counts
		)
	)


## Applies a journal that has already participated in the coordinator's
## all-warehouse preflight. No signal is published until every store (and any
## personal inventory output) has committed successfully.
func apply_production_storage_slot_changes(
	slot_indices: PackedInt32Array,
	items: Array[PickupConfig],
	counts: PackedInt32Array,
	expected_revision: int,
	emit_change_signal: bool = true
) -> bool:
	if not validate_production_storage_slot_changes(
		slot_indices,
		items,
		counts,
		expected_revision
	):
		return false
	_write_production_storage_slots(slot_indices, items, counts)
	storage_revision = expected_revision + 1
	if emit_change_signal:
		storage_changed.emit()
	return true


## Restores an unpublished sparse commit if a later store or inventory write
## unexpectedly rejects the same-frame transaction. Rewinding a revision is
## safe here because production signals are deliberately deferred until commit.
func rollback_production_storage_slot_changes(
	slot_indices: PackedInt32Array,
	items: Array[PickupConfig],
	counts: PackedInt32Array,
	applied_revision: int,
	restored_revision: int
) -> bool:
	if (
		storage_revision != applied_revision
		or applied_revision != restored_revision + 1
		or not _is_production_storage_slot_payload_valid(
			slot_indices,
			items,
			counts
		)
	):
		return false
	_write_production_storage_slots(slot_indices, items, counts)
	storage_revision = restored_revision
	return true


func notify_production_storage_changed() -> void:
	storage_changed.emit()


## 为单人和权威联机仓库绑定跨场景稳定标识，但不改变当前网络模式。
## 网络配置仍由 configure_multiplayer_storage() 独立负责。
func configure_persistent_storage_identity(new_warehouse_net_id: int) -> bool:
	if new_warehouse_net_id <= 0:
		return false
	if multiplayer_storage_enabled and warehouse_net_id != new_warehouse_net_id:
		return false
	warehouse_net_id = new_warehouse_net_id
	set_meta(&"net_id", new_warehouse_net_id)
	return true


func configure_multiplayer_storage(
	new_warehouse_net_id: int,
	peer_id: int,
	snapshot_ready: bool = false
) -> void:
	var normalized_warehouse_net_id := maxi(new_warehouse_net_id, 0)
	var normalized_peer_id := maxi(peer_id, 0)
	var storage_will_be_enabled := (
		normalized_warehouse_net_id > 0 and normalized_peer_id > 0
	)
	var identity_changed := (
		warehouse_net_id != normalized_warehouse_net_id
		or multiplayer_storage_peer_id != normalized_peer_id
	)
	var enabled_mode_changed := multiplayer_storage_enabled != storage_will_be_enabled
	if not identity_changed and not enabled_mode_changed:
		_sync_bound_storage_panel_state()
		return
	warehouse_net_id = normalized_warehouse_net_id
	multiplayer_storage_peer_id = normalized_peer_id
	multiplayer_storage_enabled = storage_will_be_enabled
	multiplayer_storage_snapshot_ready = snapshot_ready or not multiplayer_storage_enabled
	multiplayer_storage_request_pending = false
	multiplayer_storage_pending_request_id = 0
	multiplayer_storage_request_timer.stop()
	if _has_bound_storage_panel():
		storage_panel.clear_multiplayer_slot_drop_pending()
	_sync_bound_storage_panel_state()


func set_multiplayer_storage_snapshot_ready(is_ready: bool) -> void:
	multiplayer_storage_snapshot_ready = is_ready or not multiplayer_storage_enabled
	if multiplayer_storage_snapshot_ready and not multiplayer_storage_request_pending:
		multiplayer_storage_request_timer.stop()
	_sync_bound_storage_panel_state()


func is_multiplayer_storage_ready() -> bool:
	return (
		is_inside_tree()
		and is_operational
		and not is_removing
		and multiplayer_storage_enabled
		and multiplayer_storage_snapshot_ready
		and not multiplayer_storage_request_pending
	)


func request_multiplayer_storage_snapshot() -> bool:
	if (
		not is_inside_tree()
		or not is_operational
		or is_dead
		or is_removing
		or not multiplayer_storage_enabled
		or warehouse_net_id <= 0
	):
		return false
	set_multiplayer_storage_snapshot_ready(false)
	multiplayer_storage_request_timer.start(MULTIPLAYER_STORAGE_REQUEST_TIMEOUT_SECONDS)
	storage_snapshot_requested.emit(warehouse_net_id)
	return true


func request_multiplayer_stack_transfer(
	direction: int,
	slot_index: int,
	transfer_count: int = -1
) -> bool:
	if (
		not is_multiplayer_storage_ready()
		or direction < OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE
		or direction > OakWarehouseProtocol.TransferDirection.STORAGE_TO_PLAYER
		or slot_index < 0
		or slot_index >= STORAGE_CAPACITY
	):
		return false
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state == null:
		return false
	var source_count := (
		get_storage_item_count(slot_index)
		if direction == OakWarehouseProtocol.TransferDirection.STORAGE_TO_PLAYER
		else run_state.get_item_count_for_peer(multiplayer_storage_peer_id, slot_index)
	)
	var requested_count := source_count if transfer_count < 0 else transfer_count
	if requested_count <= 0 or requested_count > source_count:
		return false
	var request_id := next_multiplayer_storage_request_id
	next_multiplayer_storage_request_id += 1
	var command := OakWarehouseProtocol.make_transfer_command(
		request_id,
		warehouse_net_id,
		multiplayer_storage_peer_id,
		direction,
		slot_index,
		requested_count,
		run_state.get_inventory_revision_for_peer(multiplayer_storage_peer_id),
		storage_revision
	)
	multiplayer_storage_request_pending = true
	multiplayer_storage_pending_request_id = request_id
	multiplayer_storage_request_timer.start(MULTIPLAYER_STORAGE_REQUEST_TIMEOUT_SECONDS)
	_sync_bound_storage_panel_state()
	storage_command_requested.emit(command)
	return true


func request_multiplayer_slot_move(
	source_container: int,
	source_slot_index: int,
	target_container: int,
	target_slot_index: int,
	expected_inventory_revision: int,
	expected_storage_revision: int
) -> bool:
	if not is_multiplayer_storage_ready():
		return false
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state == null:
		return false
	var request_id := next_multiplayer_storage_request_id
	var command := OakWarehouseProtocol.make_slot_move_command(
		request_id,
		warehouse_net_id,
		multiplayer_storage_peer_id,
		source_container,
		source_slot_index,
		target_container,
		target_slot_index,
		expected_inventory_revision,
		expected_storage_revision
	)
	if not OakWarehouseProtocol.is_valid_slot_move_command(command):
		return false
	next_multiplayer_storage_request_id += 1
	multiplayer_storage_request_pending = true
	multiplayer_storage_pending_request_id = request_id
	multiplayer_storage_request_timer.start(MULTIPLAYER_STORAGE_REQUEST_TIMEOUT_SECONDS)
	_sync_bound_storage_panel_state()
	storage_command_requested.emit(command)
	return true


func complete_multiplayer_storage_request(result: Dictionary) -> bool:
	if not is_current_multiplayer_storage_result(result):
		return false
	multiplayer_storage_request_pending = false
	multiplayer_storage_pending_request_id = 0
	multiplayer_storage_request_timer.stop()
	_sync_bound_storage_panel_state()
	if _has_bound_storage_panel():
		storage_panel.show_multiplayer_command_result(
			bool(result.get("success", false)),
			StringName(result.get("reason", OakWarehouseProtocol.RESULT_INVALID_COMMAND))
		)
	return true


func is_current_multiplayer_storage_result(result: Dictionary) -> bool:
	return (
		multiplayer_storage_enabled
		and multiplayer_storage_request_pending
		and OakWarehouseProtocol.get_int_field(result, "request_id", 0)
		== multiplayer_storage_pending_request_id
		and OakWarehouseProtocol.get_int_field(result, "warehouse_net_id", 0)
		== warehouse_net_id
		and OakWarehouseProtocol.get_int_field(result, "peer_id", 0)
		== multiplayer_storage_peer_id
	)


func _on_multiplayer_storage_request_timeout() -> void:
	if not multiplayer_storage_enabled:
		return
	if (
		not multiplayer_storage_request_pending
		and multiplayer_storage_snapshot_ready
	):
		return
	if multiplayer_storage_request_pending:
		multiplayer_storage_request_pending = false
		multiplayer_storage_pending_request_id = 0
		if _has_bound_storage_panel():
			storage_panel.clear_multiplayer_slot_drop_pending()
	multiplayer_storage_snapshot_ready = false
	_sync_bound_storage_panel_state()
	multiplayer_storage_request_timer.start(MULTIPLAYER_STORAGE_REQUEST_TIMEOUT_SECONDS)
	storage_snapshot_requested.emit(warehouse_net_id)


func can_add_storage_item_count(item: PickupConfig, count: int) -> bool:
	if item == null or not item.can_store_in_inventory or count <= 0:
		return false
	return _get_available_storage_capacity(item) >= count


func try_add_storage_item_count(
	item: PickupConfig,
	count: int,
	expected_revision: int = -1
) -> bool:
	if expected_revision >= 0 and expected_revision != storage_revision:
		return false
	if not can_add_storage_item_count(item, count):
		return false
	_add_storage_item_count_unchecked(item, count)
	_bump_storage_revision()
	return true


func discard_storage_item(slot_index: int, expected_revision: int = -1) -> bool:
	if expected_revision >= 0 and expected_revision != storage_revision:
		return false
	if slot_index < 0 or slot_index >= STORAGE_CAPACITY:
		return false
	if storage_items[slot_index] == null:
		return false
	storage_items[slot_index] = null
	storage_stack_counts[slot_index] = 0
	_bump_storage_revision()
	return true


func transfer_player_stack_to_storage(slot_index: int, run_state: RunStateStore) -> bool:
	if run_state == null:
		return false
	return transfer_player_item_count_to_storage(
		slot_index,
		run_state.get_item_count(slot_index),
		run_state
	)


func transfer_player_item_count_to_storage(
	slot_index: int,
	transfer_count: int,
	run_state: RunStateStore
) -> bool:
	if run_state == null or run_state.get_active_multiplayer_peer_id() > 0:
		return false
	var item := run_state.get_item(slot_index)
	var source_count := run_state.get_item_count(slot_index)
	if transfer_count <= 0 or transfer_count > source_count:
		return false
	if not can_add_storage_item_count(item, transfer_count):
		return false
	var inventory_revision := run_state.get_inventory_revision()
	var expected_storage_revision := storage_revision
	var taken_stack := run_state.take_item_count_at_slot_if_revision(
		slot_index,
		transfer_count,
		inventory_revision,
		false
	)
	if not bool(taken_stack.get("success", false)):
		return false
	_add_storage_item_count_unchecked(item, transfer_count)
	storage_revision = expected_storage_revision + 1
	storage_changed.emit()
	run_state.notify_inventory_transaction_completed()
	return true


func transfer_storage_stack_to_player(slot_index: int, run_state: RunStateStore) -> bool:
	if run_state == null:
		return false
	return transfer_storage_item_count_to_player(
		slot_index,
		get_storage_item_count(slot_index),
		run_state
	)


func transfer_storage_item_count_to_player(
	slot_index: int,
	transfer_count: int,
	run_state: RunStateStore
) -> bool:
	if run_state == null or run_state.get_active_multiplayer_peer_id() > 0:
		return false
	var item := get_storage_item(slot_index)
	var source_count := get_storage_item_count(slot_index)
	if (
		item == null
		or transfer_count <= 0
		or transfer_count > source_count
	):
		return false
	var expected_inventory_revision := run_state.get_inventory_revision()
	var item_added := run_state.try_add_item_count_if_revision(
		item,
		transfer_count,
		expected_inventory_revision,
		false
	)
	if not item_added:
		return false
	_take_storage_item_count_unchecked(slot_index, transfer_count)
	storage_revision += 1
	storage_changed.emit()
	run_state.notify_inventory_transaction_completed()
	return true


func can_move_stack_to_slot(
	source_container: int,
	source_slot_index: int,
	target_container: int,
	target_slot_index: int,
	run_state: RunStateStore,
	expected_inventory_revision: int,
	expected_storage_revision: int,
	peer_id: int = 0
) -> bool:
	if (
		run_state == null
		or (peer_id <= 0 and run_state.get_active_multiplayer_peer_id() > 0)
		or source_container < OakWarehouseProtocol.ItemContainer.PLAYER
		or source_container > OakWarehouseProtocol.ItemContainer.STORAGE
		or target_container < OakWarehouseProtocol.ItemContainer.PLAYER
		or target_container > OakWarehouseProtocol.ItemContainer.STORAGE
		or source_slot_index < 0
		or source_slot_index >= STORAGE_CAPACITY
		or target_slot_index < 0
		or target_slot_index >= STORAGE_CAPACITY
		or (source_container == target_container and source_slot_index == target_slot_index)
		or expected_storage_revision != storage_revision
	):
		return false
	var current_inventory_revision := (
		run_state.get_inventory_revision_for_peer(peer_id)
		if peer_id > 0
		else run_state.get_inventory_revision()
	)
	if expected_inventory_revision != current_inventory_revision:
		return false

	var source_item := _get_container_item(
		source_container,
		source_slot_index,
		run_state,
		peer_id
	)
	if source_item == null:
		return false
	var source_count := _get_container_item_count(
		source_container,
		source_slot_index,
		run_state,
		peer_id
	)
	var target_item := _get_container_item(
		target_container,
		target_slot_index,
		run_state,
		peer_id
	)
	var target_count := _get_container_item_count(
		target_container,
		target_slot_index,
		run_state,
		peer_id
	)
	return _can_place_stack_in_slot(
		source_item,
		source_count,
		target_item,
		target_count
	)


func move_stack_to_slot(
	source_container: int,
	source_slot_index: int,
	target_container: int,
	target_slot_index: int,
	run_state: RunStateStore,
	expected_inventory_revision: int,
	expected_storage_revision: int,
	peer_id: int = 0
) -> bool:
	if not can_move_stack_to_slot(
		source_container,
		source_slot_index,
		target_container,
		target_slot_index,
		run_state,
		expected_inventory_revision,
		expected_storage_revision,
		peer_id
	):
		return false

	if source_container == OakWarehouseProtocol.ItemContainer.PLAYER:
		if target_container == OakWarehouseProtocol.ItemContainer.PLAYER:
			if peer_id > 0:
				return run_state.move_item_stack_to_slot_for_peer_if_revision(
					peer_id,
					source_slot_index,
					target_slot_index,
					expected_inventory_revision
				)
			return run_state.move_item_stack_to_slot(
				source_slot_index,
				target_slot_index,
				expected_inventory_revision
			)
		return _move_player_stack_to_storage_slot(
			source_slot_index,
			target_slot_index,
			run_state,
			expected_inventory_revision,
			expected_storage_revision,
			peer_id
		)

	if target_container == OakWarehouseProtocol.ItemContainer.STORAGE:
		_move_storage_stack_between_slots_unchecked(source_slot_index, target_slot_index)
		_bump_storage_revision()
		return true
	return _move_storage_stack_to_player_slot(
		source_slot_index,
		target_slot_index,
		run_state,
		expected_inventory_revision,
		expected_storage_revision,
		peer_id
	)


func apply_transfer_command(command: Dictionary, run_state: RunStateStore) -> Dictionary:
	var peer_id := OakWarehouseProtocol.get_int_field(command, "peer_id", 0)
	var result_reason := OakWarehouseProtocol.RESULT_INVALID_COMMAND
	if (
		run_state == null
		or not OakWarehouseProtocol.is_valid_command(command)
		or (
			OakWarehouseProtocol.get_int_field(command, "warehouse_net_id", 0)
			!= warehouse_net_id
		)
		or not run_state.has_multiplayer_peer_state(peer_id)
	):
		return _make_transfer_result(command, false, result_reason, run_state, peer_id)
	var expected_inventory_revision := int(command["expected_inventory_revision"])
	var expected_storage_revision := int(command["expected_storage_revision"])
	if run_state.get_inventory_revision_for_peer(peer_id) != expected_inventory_revision:
		return _make_transfer_result(
			command,
			false,
			OakWarehouseProtocol.RESULT_STALE_INVENTORY,
			run_state,
			peer_id
		)
	if storage_revision != expected_storage_revision:
		return _make_transfer_result(
			command,
			false,
			OakWarehouseProtocol.RESULT_STALE_STORAGE,
			run_state,
			peer_id
		)
	if StringName(command.get("operation", OakWarehouseProtocol.OPERATION_TRANSFER)) == OakWarehouseProtocol.OPERATION_SLOT_MOVE:
		return _apply_slot_move_command(
			command,
			run_state,
			peer_id,
			expected_inventory_revision,
			expected_storage_revision
		)

	var slot_index := int(command["slot_index"])
	var direction := int(command["direction"])
	var transfer_count := int(command["transfer_count"])
	var item: PickupConfig = null
	var source_count := 0
	if direction == OakWarehouseProtocol.TransferDirection.PLAYER_TO_STORAGE:
		item = run_state.get_item_for_peer(peer_id, slot_index)
		source_count = run_state.get_item_count_for_peer(peer_id, slot_index)
		if item == null or source_count <= 0:
			result_reason = OakWarehouseProtocol.RESULT_SOURCE_EMPTY
		elif transfer_count <= 0 or transfer_count > source_count:
			result_reason = OakWarehouseProtocol.RESULT_INVALID_AMOUNT
		elif not can_add_storage_item_count(item, transfer_count):
			result_reason = OakWarehouseProtocol.RESULT_TARGET_FULL
		else:
			var taken_stack := run_state.take_item_count_at_slot_for_peer_if_revision(
				peer_id,
				slot_index,
				transfer_count,
				expected_inventory_revision,
				false
			)
			if not bool(taken_stack.get("success", false)):
				result_reason = OakWarehouseProtocol.RESULT_STALE_INVENTORY
			else:
				_add_storage_item_count_unchecked(item, transfer_count)
				storage_revision += 1
				run_state.notify_inventory_transaction_completed()
				storage_changed.emit()
				return _make_transfer_result(
					command,
					true,
					OakWarehouseProtocol.RESULT_SUCCESS,
					run_state,
					peer_id
				)
	else:
		item = get_storage_item(slot_index)
		source_count = get_storage_item_count(slot_index)
		if item == null or source_count <= 0:
			result_reason = OakWarehouseProtocol.RESULT_SOURCE_EMPTY
		elif transfer_count <= 0 or transfer_count > source_count:
			result_reason = OakWarehouseProtocol.RESULT_INVALID_AMOUNT
		elif not run_state.can_add_item_count_for_peer(peer_id, item, transfer_count):
			result_reason = OakWarehouseProtocol.RESULT_TARGET_FULL
		elif not run_state.try_add_item_count_for_peer_if_revision(
			peer_id,
			item,
			transfer_count,
			expected_inventory_revision,
			false
		):
			result_reason = OakWarehouseProtocol.RESULT_STALE_INVENTORY
		else:
			_take_storage_item_count_unchecked(slot_index, transfer_count)
			storage_revision += 1
			run_state.notify_inventory_transaction_completed()
			storage_changed.emit()
			return _make_transfer_result(
				command,
				true,
				OakWarehouseProtocol.RESULT_SUCCESS,
				run_state,
				peer_id
			)
	return _make_transfer_result(command, false, result_reason, run_state, peer_id)


func _apply_slot_move_command(
	command: Dictionary,
	run_state: RunStateStore,
	peer_id: int,
	expected_inventory_revision: int,
	expected_storage_revision: int
) -> Dictionary:
	var source_container := int(command["source_container"])
	var source_slot_index := int(command["source_slot_index"])
	var target_container := int(command["target_container"])
	var target_slot_index := int(command["target_slot_index"])
	var source_item := _get_container_item(
		source_container,
		source_slot_index,
		run_state,
		peer_id
	)
	if source_item == null:
		return _make_transfer_result(
			command,
			false,
			OakWarehouseProtocol.RESULT_SOURCE_EMPTY,
			run_state,
			peer_id
		)
	if not can_move_stack_to_slot(
		source_container,
		source_slot_index,
		target_container,
		target_slot_index,
		run_state,
		expected_inventory_revision,
		expected_storage_revision,
		peer_id
	):
		return _make_transfer_result(
			command,
			false,
			OakWarehouseProtocol.RESULT_TARGET_FULL,
			run_state,
			peer_id
		)
	if not move_stack_to_slot(
		source_container,
		source_slot_index,
		target_container,
		target_slot_index,
		run_state,
		expected_inventory_revision,
		expected_storage_revision,
		peer_id
	):
		return _make_transfer_result(
			command,
			false,
			OakWarehouseProtocol.RESULT_INVALID_COMMAND,
			run_state,
			peer_id
		)
	return _make_transfer_result(
		command,
		true,
		OakWarehouseProtocol.RESULT_SUCCESS,
		run_state,
		peer_id
	)


func _get_available_storage_capacity(item: PickupConfig) -> int:
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	var capacity := 0
	for slot_index in range(STORAGE_CAPACITY):
		var stored_item := storage_items[slot_index]
		if stored_item == null:
			capacity += stack_limit
		elif PickupConfig.inventory_items_can_stack(stored_item, item):
			capacity += maxi(stack_limit - storage_stack_counts[slot_index], 0)
	return capacity


func _is_production_storage_slot_payload_valid(
	slot_indices: PackedInt32Array,
	items: Array[PickupConfig],
	counts: PackedInt32Array
) -> bool:
	var change_count := slot_indices.size()
	if (
		change_count <= 0
		or change_count > STORAGE_CAPACITY
		or items.size() != change_count
		or counts.size() != change_count
	):
		return false
	var visited_slot_mask := 0
	for change_index in change_count:
		var slot_index := int(slot_indices[change_index])
		if slot_index < 0 or slot_index >= STORAGE_CAPACITY:
			return false
		var slot_bit := 1 << slot_index
		if (visited_slot_mask & slot_bit) != 0:
			return false
		visited_slot_mask |= slot_bit
		var item := items[change_index]
		var count := int(counts[change_index])
		if item == null:
			if count != 0:
				return false
			continue
		if (
			not item.can_store_in_inventory
			or count <= 0
			or count > PickupConfig.get_inventory_stack_limit(item)
		):
			return false
	return true


func _write_production_storage_slots(
	slot_indices: PackedInt32Array,
	items: Array[PickupConfig],
	counts: PackedInt32Array
) -> void:
	for change_index in slot_indices.size():
		var slot_index := int(slot_indices[change_index])
		storage_items[slot_index] = items[change_index]
		storage_stack_counts[slot_index] = int(counts[change_index])


func _get_container_item(
	container: int,
	slot_index: int,
	run_state: RunStateStore,
	peer_id: int
) -> PickupConfig:
	if container == OakWarehouseProtocol.ItemContainer.STORAGE:
		return get_storage_item(slot_index)
	if container != OakWarehouseProtocol.ItemContainer.PLAYER or run_state == null:
		return null
	if peer_id > 0:
		return run_state.get_item_for_peer(peer_id, slot_index)
	return run_state.get_item(slot_index)


func _get_container_item_count(
	container: int,
	slot_index: int,
	run_state: RunStateStore,
	peer_id: int
) -> int:
	if container == OakWarehouseProtocol.ItemContainer.STORAGE:
		return get_storage_item_count(slot_index)
	if container != OakWarehouseProtocol.ItemContainer.PLAYER or run_state == null:
		return 0
	if peer_id > 0:
		return run_state.get_item_count_for_peer(peer_id, slot_index)
	return run_state.get_item_count(slot_index)


func _can_place_stack_in_slot(
	item: PickupConfig,
	count: int,
	target_item: PickupConfig,
	target_count: int
) -> bool:
	if (
		item == null
		or count <= 0
		or count > PickupConfig.get_inventory_stack_limit(item)
	):
		return false
	if target_item == null:
		return true
	return (
		PickupConfig.inventory_items_can_stack(target_item, item)
		and target_count + count <= PickupConfig.get_inventory_stack_limit(item)
	)


func _move_player_stack_to_storage_slot(
	source_slot_index: int,
	target_slot_index: int,
	run_state: RunStateStore,
	expected_inventory_revision: int,
	expected_storage_revision: int,
	peer_id: int
) -> bool:
	var taken_stack := (
		run_state.take_item_stack_for_peer_if_revision(
			peer_id,
			source_slot_index,
			expected_inventory_revision,
			false
		)
		if peer_id > 0
		else run_state.take_item_stack_if_revision(
			source_slot_index,
			expected_inventory_revision,
			false
		)
	)
	if not bool(taken_stack.get("success", false)):
		return false
	_add_storage_item_count_to_slot_unchecked(
		taken_stack.get("item") as PickupConfig,
		int(taken_stack.get("stack_count", 0)),
		target_slot_index
	)
	storage_revision = expected_storage_revision + 1
	storage_changed.emit()
	run_state.notify_inventory_transaction_completed()
	return true


func _move_storage_stack_to_player_slot(
	source_slot_index: int,
	target_slot_index: int,
	run_state: RunStateStore,
	expected_inventory_revision: int,
	expected_storage_revision: int,
	peer_id: int
) -> bool:
	var item := get_storage_item(source_slot_index)
	var count := get_storage_item_count(source_slot_index)
	var item_added := (
		run_state.try_add_item_count_to_slot_for_peer_if_revision(
			peer_id,
			item,
			count,
			target_slot_index,
			expected_inventory_revision,
			false
		)
		if peer_id > 0
		else run_state.try_add_item_count_to_slot_if_revision(
			item,
			count,
			target_slot_index,
			expected_inventory_revision,
			false
		)
	)
	if not item_added:
		return false
	storage_items[source_slot_index] = null
	storage_stack_counts[source_slot_index] = 0
	storage_revision = expected_storage_revision + 1
	storage_changed.emit()
	run_state.notify_inventory_transaction_completed()
	return true


func _move_storage_stack_between_slots_unchecked(
	source_slot_index: int,
	target_slot_index: int
) -> void:
	var item := storage_items[source_slot_index]
	var count := storage_stack_counts[source_slot_index]
	_add_storage_item_count_to_slot_unchecked(item, count, target_slot_index)
	storage_items[source_slot_index] = null
	storage_stack_counts[source_slot_index] = 0


func export_storage_snapshot() -> Dictionary:
	var slots: Array[Dictionary] = []
	slots.resize(STORAGE_CAPACITY)
	for slot_index in range(STORAGE_CAPACITY):
		var item := storage_items[slot_index]
		slots[slot_index] = {
			"slot_index": slot_index,
			"config_path": item.resource_path if item != null else "",
			"stack_count": get_storage_item_count(slot_index),
		}
	return {
		"warehouse_net_id": warehouse_net_id,
		"revision": storage_revision,
		"slots": slots,
	}


## Applies one authoritative CH6 packet as a single observable transaction.
## Every payload is decoded and revision-checked before the first warehouse is
## written. Signals are published only after all warehouse arrays have changed,
## so listeners can never observe half of a cross-warehouse production commit.
static func apply_storage_snapshot_batch(
	warehouses: Array[OakWarehouse],
	snapshots: Array
) -> bool:
	if warehouses.is_empty() or warehouses.size() != snapshots.size():
		return false
	var prepared_snapshots: Array[Dictionary] = []
	prepared_snapshots.resize(warehouses.size())
	var seen_warehouse_ids: Dictionary = {}
	for index in warehouses.size():
		var warehouse := warehouses[index]
		if warehouse == null or not is_instance_valid(warehouse):
			return false
		var instance_id := warehouse.get_instance_id()
		if seen_warehouse_ids.has(instance_id):
			return false
		seen_warehouse_ids[instance_id] = true
		if typeof(snapshots[index]) != TYPE_DICTIONARY:
			return false
		var prepared := warehouse.prepare_storage_snapshot(
			snapshots[index] as Dictionary
		)
		if prepared.is_empty():
			return false
		prepared_snapshots[index] = prepared
	# Recheck every base revision before committing. There is no await or signal
	# between this pass and the writes below.
	for index in warehouses.size():
		if not warehouses[index]._is_prepared_storage_snapshot_current(
			prepared_snapshots[index]
		):
			return false
	for index in warehouses.size():
		warehouses[index]._commit_prepared_storage_snapshot(
			prepared_snapshots[index]
		)
	for warehouse in warehouses:
		warehouse.notify_storage_snapshot_committed()
	return true


static func is_storage_snapshot_payload_valid(
	snapshot: Dictionary,
	expected_warehouse_net_id: int
) -> bool:
	return not _decode_storage_snapshot_payload(
		snapshot,
		expected_warehouse_net_id
	).is_empty()


func prepare_storage_snapshot(snapshot: Dictionary) -> Dictionary:
	var decoded := _decode_storage_snapshot_payload(snapshot, warehouse_net_id)
	if decoded.is_empty() or int(decoded.get("revision", -1)) < storage_revision:
		return {}
	decoded["expected_current_revision"] = storage_revision
	return decoded


func apply_storage_snapshot(snapshot: Dictionary) -> bool:
	var prepared := prepare_storage_snapshot(snapshot)
	return commit_prepared_storage_snapshot(prepared)


func commit_prepared_storage_snapshot(
	prepared: Dictionary,
	emit_change_signal: bool = true
) -> bool:
	if prepared.is_empty() or not is_prepared_storage_snapshot_current(prepared):
		return false
	commit_prevalidated_storage_snapshot(prepared)
	if emit_change_signal:
		notify_storage_snapshot_committed()
	return true


func is_prepared_storage_snapshot_current(prepared: Dictionary) -> bool:
	return _is_prepared_storage_snapshot_current(prepared)


## 与 RunState 的 prevalidated 提交入口配对；调用方必须先同时复核两侧，
## 再在无 await/无 signal 的提交段写入，确保玩家背包与仓库零/全提交。
func commit_prevalidated_storage_snapshot(prepared: Dictionary) -> void:
	_commit_prepared_storage_snapshot(prepared)


func notify_storage_snapshot_committed() -> void:
	storage_changed.emit()


static func _decode_storage_snapshot_payload(
	snapshot: Dictionary,
	expected_warehouse_net_id: int
) -> Dictionary:
	if expected_warehouse_net_id <= 0:
		return {}
	var snapshot_net_id := int(snapshot.get("warehouse_net_id", -1))
	if snapshot_net_id != expected_warehouse_net_id:
		return {}
	var new_revision := int(snapshot.get("revision", -1))
	if new_revision < 0:
		return {}
	var raw_slots := snapshot.get("slots", []) as Array
	if raw_slots.size() != STORAGE_CAPACITY:
		return {}
	var decoded_items: Array[PickupConfig] = []
	var decoded_counts: Array[int] = []
	decoded_items.resize(STORAGE_CAPACITY)
	decoded_counts.resize(STORAGE_CAPACITY)
	var seen_slots := {}
	for raw_slot_value in raw_slots:
		var raw_slot := raw_slot_value as Dictionary
		var slot_index := int(raw_slot.get("slot_index", -1))
		if (
			slot_index < 0
			or slot_index >= STORAGE_CAPACITY
			or seen_slots.has(slot_index)
		):
			return {}
		seen_slots[slot_index] = true
		var path := str(raw_slot.get("config_path", ""))
		var count := int(raw_slot.get("stack_count", 0))
		if path.is_empty():
			if count != 0:
				return {}
			continue
		var item := (
			RuntimeContentCatalogScript.load_pickup_config_from_path(path)
		)
		if (
			item == null
			or not item.can_store_in_inventory
			or count <= 0
			or count > PickupConfig.get_inventory_stack_limit(item)
		):
			return {}
		decoded_items[slot_index] = item
		decoded_counts[slot_index] = count
	return {
		"warehouse_net_id": snapshot_net_id,
		"revision": new_revision,
		"items": decoded_items,
		"counts": decoded_counts,
	}


func _is_prepared_storage_snapshot_current(prepared: Dictionary) -> bool:
	if not (
		int(prepared.get("warehouse_net_id", -1)) == warehouse_net_id
		and int(prepared.get("expected_current_revision", -1)) == storage_revision
		and int(prepared.get("revision", -1)) >= storage_revision
		and (prepared.get("items", []) as Array).size() == STORAGE_CAPACITY
		and (prepared.get("counts", []) as Array).size() == STORAGE_CAPACITY
	):
		return false
	var prepared_items := prepared.get("items", []) as Array
	var prepared_counts := prepared.get("counts", []) as Array
	for slot_index in STORAGE_CAPACITY:
		var item := prepared_items[slot_index] as PickupConfig
		var count := int(prepared_counts[slot_index])
		if item == null:
			if count != 0:
				return false
			continue
		if (
			not item.can_store_in_inventory
			or count <= 0
			or count > PickupConfig.get_inventory_stack_limit(item)
		):
			return false
	return true


func _commit_prepared_storage_snapshot(prepared: Dictionary) -> void:
	storage_items.assign(prepared.get("items", []) as Array)
	storage_stack_counts.assign(prepared.get("counts", []) as Array)
	storage_revision = int(prepared.get("revision", storage_revision))
	multiplayer_storage_snapshot_ready = true
	if not multiplayer_storage_request_pending:
		multiplayer_storage_request_timer.stop()
	_sync_bound_storage_panel_state()


func _add_storage_item_count_unchecked(item: PickupConfig, count: int) -> void:
	var remaining := count
	var stack_limit := PickupConfig.get_inventory_stack_limit(item)
	if item.stackable:
		for slot_index in range(STORAGE_CAPACITY):
			if not PickupConfig.inventory_items_can_stack(
				storage_items[slot_index],
				item
			):
				continue
			var room := maxi(stack_limit - storage_stack_counts[slot_index], 0)
			var added := mini(room, remaining)
			storage_stack_counts[slot_index] += added
			remaining -= added
			if remaining <= 0:
				return
	for slot_index in range(STORAGE_CAPACITY):
		if storage_items[slot_index] != null:
			continue
		var added := mini(stack_limit, remaining)
		storage_items[slot_index] = item
		storage_stack_counts[slot_index] = added
		remaining -= added
		if remaining <= 0:
			return


func _add_storage_item_count_to_slot_unchecked(
	item: PickupConfig,
	count: int,
	target_slot_index: int
) -> void:
	if storage_items[target_slot_index] == null:
		storage_items[target_slot_index] = item
		storage_stack_counts[target_slot_index] = count
	else:
		storage_stack_counts[target_slot_index] += count


func _take_storage_item_count_unchecked(slot_index: int, count: int) -> void:
	var remaining_count := get_storage_item_count(slot_index) - count
	if remaining_count > 0:
		storage_stack_counts[slot_index] = remaining_count
		return
	storage_items[slot_index] = null
	storage_stack_counts[slot_index] = 0


func _bump_storage_revision() -> void:
	storage_revision += 1
	storage_changed.emit()


func _make_transfer_result(
	command: Dictionary,
	success: bool,
	reason: StringName,
	run_state: RunStateStore,
	peer_id: int
) -> Dictionary:
	var inventory_revision := 0
	if run_state != null and run_state.has_multiplayer_peer_state(peer_id):
		inventory_revision = run_state.get_inventory_revision_for_peer(peer_id)
	var result := OakWarehouseProtocol.make_result(
		command,
		success,
		reason,
		inventory_revision,
		storage_revision
	)
	if run_state != null and run_state.has_multiplayer_peer_state(peer_id):
		result["inventory_snapshot"] = run_state.export_inventory_snapshot_for_peer(peer_id)
	result["storage_snapshot"] = export_storage_snapshot()
	return result


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
	close_storage_panel()
	_refresh_interaction_selection(exiting_player)


func on_shared_storage_panel_opened(panel: OakWarehousePanel) -> void:
	if panel != storage_panel or not _has_bound_storage_panel() or not panel.is_open():
		return
	if multiplayer_storage_enabled:
		request_multiplayer_storage_snapshot()
	_set_interaction_target(false)
	_refresh_interaction_selection(nearby_player)
	modal_ui_visibility_changed.emit(true)


func on_shared_storage_panel_closed(panel: OakWarehousePanel) -> void:
	if panel != storage_panel:
		return
	if nearby_player != null:
		_refresh_interaction_selection(nearby_player)
	else:
		_set_interaction_target(false)
	modal_ui_visibility_changed.emit(false)


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
		):
			continue
		if building.get_interaction_player() != player:
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
	health_bar.call("set_health", new_health, new_max_health)


func _on_removal_started(_mode: RemovalMode) -> void:
	var interaction_player := nearby_player
	nearby_player = null
	health_bar.hide()
	set_process(false)
	interaction_area.set_deferred("monitoring", false)
	_set_interaction_target(false)
	close_storage_panel()
	_refresh_interaction_selection(interaction_player)
