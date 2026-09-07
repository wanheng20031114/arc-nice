extends Node

var result: Dictionary = {}
var failures: Array[String] = []
var signal_count := 0
var observed_revision := -1
var last_payload: Dictionary = {}

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var state := RunStateStore.new()
	state.ensure_run_started()
	state.shared_warehouse_snapshot_changed.connect(_on_delta)
	var config := load("res://resources/config/plant_defense/oak_warehouse.tres") as PlantDefenseConfig
	var warehouse := config.plant_scene.instantiate() as OakWarehouse
	add_child(warehouse)
	warehouse.setup(config, null, [Vector2i.ZERO])
	var water := load("res://resources/config/materials/material_water_bottle.tres") as PickupConfig
	_check(SharedWarehouseLedgerBridge.bind_identity(warehouse, 42), "Bind stable identity")
	warehouse.storage_items[0] = water
	warehouse.storage_stack_counts[0] = 7
	warehouse.storage_revision = 3
	var expected := warehouse.export_storage_snapshot()
	var before := state.get_shared_warehouse_ledger_revision()
	_check(SharedWarehouseLedgerBridge.persist_to_ledger(state, warehouse, 42), "Live typed commit succeeds")
	_check(state.get_shared_warehouse_snapshot(42) == expected, "Typed path preserves exact wire/ledger payload")
	_check(observed_revision == before + 1 and signal_count == 1, "Commit emits one immediate delta with advanced revision")
	warehouse.storage_stack_counts[0] = 8
	_check(int(state.get_shared_warehouse_snapshot(42)["slots"][0]["stack_count"]) == 7, "Committed payload owns its data independently of live arrays")
	last_payload["slots"][0]["stack_count"] = 500
	_check(int(state.get_shared_warehouse_snapshot(42)["slots"][0]["stack_count"]) == 7, "Signal consumer cannot mutate the ledger")
	var valid_items: Array[PickupConfig] = warehouse.storage_items.duplicate()
	var valid_counts: Array[int] = warehouse.storage_stack_counts.duplicate()
	var rejected_revision := state.get_shared_warehouse_ledger_revision()
	_check(not state.upsert_shared_warehouse_items(42, 4, valid_items, valid_counts, rejected_revision - 1), "Stale CAS rejects atomically")
	_check(not state.upsert_shared_warehouse_items(0, 4, valid_items, valid_counts), "Invalid ID rejects")
	_check(not state.upsert_shared_warehouse_items(42, -1, valid_items, valid_counts), "Negative storage revision rejects")
	_check(not state.upsert_shared_warehouse_items(42, 4, [], valid_counts), "Malformed shape rejects")
	valid_counts[0] = 1000
	_check(not state.upsert_shared_warehouse_items(42, 4, valid_items, valid_counts), "Over-limit stack rejects")
	valid_counts[0] = 0
	_check(not state.upsert_shared_warehouse_items(42, 4, valid_items, valid_counts), "Non-empty zero count rejects")
	valid_counts[0] = 1
	valid_items[0] = PickupConfig.new()
	_check(not state.upsert_shared_warehouse_items(42, 4, valid_items, valid_counts), "Unregistered resource rejects")
	valid_items[0] = null
	_check(not state.upsert_shared_warehouse_items(42, 4, valid_items, valid_counts), "Empty slot with positive count rejects")
	_check(state.get_shared_warehouse_ledger_revision() == rejected_revision and signal_count == 1, "Rejected commits leave ledger/revision/signals unchanged")
	# External dictionaries continue to pass through the existing catalog decoder.
	var malformed := expected.duplicate(true)
	malformed["slots"][0]["config_path"] = "res://project.godot"
	_check(not state.upsert_shared_warehouse_snapshot(malformed), "Network dictionary retains resource allowlist validation")
	var timings: Array[Dictionary] = []
	for occupied in [1, 20]:
		for slot in 20:
			warehouse.storage_items[slot] = water if slot < occupied else null
			warehouse.storage_stack_counts[slot] = 1 if slot < occupied else 0
		var start := Time.get_ticks_usec()
		for transaction in 500:
			warehouse.storage_revision += 1
			warehouse.storage_stack_counts[0] = transaction + 1
			SharedWarehouseLedgerBridge.bind_identity(warehouse, 42)
			_check(state.upsert_shared_warehouse_snapshot(warehouse.export_storage_snapshot(), state.get_shared_warehouse_ledger_revision()), "Legacy dictionary commit succeeds")
		var legacy_usec := Time.get_ticks_usec() - start
		start = Time.get_ticks_usec()
		for transaction in 500:
			warehouse.storage_revision += 1
			warehouse.storage_stack_counts[0] = transaction + 1
			_check(SharedWarehouseLedgerBridge.persist_to_ledger(state, warehouse, 42), "Typed bridge commit succeeds")
		var typed_usec := Time.get_ticks_usec() - start
		_check(state.get_shared_warehouse_snapshot(42) == warehouse.export_storage_snapshot(), "Final runtime state remains exactly persisted")
		timings.append({"occupied_slots": occupied, "transactions": 500, "legacy_usec": legacy_usec, "typed_usec": typed_usec})
	_check(signal_count == 2001, "Every successful transaction still publishes an immediate ledger event")
	var saved := state.export_shared_warehouse_ledger()
	var restored := RunStateStore.new()
	restored.ensure_run_started()
	_check(restored.apply_shared_warehouse_ledger_snapshot(saved, true), "Cross-scene full ledger accepts typed-produced snapshots")
	warehouse.storage_items.fill(null)
	warehouse.storage_stack_counts.fill(0)
	_check(SharedWarehouseLedgerBridge.restore_from_ledger(restored, warehouse, 42), "Fresh scene restores storage through the existing strict snapshot path")
	_check(warehouse.storage_stack_counts[0] == 500, "Restoration retains final production output")
	_check(SharedWarehouseLedgerBridge.remove_from_ledger(restored, 42), "Warehouse removal still removes persistent state")
	_check(restored.get_shared_warehouse_snapshot(42).is_empty(), "Removed store cannot return on scene re-entry")
	state.free()
	restored.free()
	print("WAREHOUSE_LEDGER_SCALING_REGRESSION ", JSON.stringify({"failures": failures, "timings": timings, "immediate_events": signal_count}))
	result["exit_code"] = 0 if failures.is_empty() else 1
	queue_free()

func _on_delta(_id: int, snapshot: Dictionary, _removed: bool, revision: int) -> void:
	signal_count += 1
	observed_revision = revision
	last_payload = snapshot

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
