extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	if not value:
		_failures.append(message)
		printerr("FAIL: ", message)


func _run() -> void:
	var runtime := TowerDefenseGame.new()
	var packed := load("res://scene/enemy/enemy.tscn") as PackedScene
	var enemies: Array[Enemy] = []
	for index in 300:
		var enemy := packed.instantiate() as Enemy
		root.add_child(enemy)
		enemy.set_process(false)
		enemy.set_physics_process(false)
		runtime.register_network_enemy(index + 1, enemy)
		enemies.append(enemy)
	_check(runtime.get_network_enemy_count() == 300, "Initial registry count")
	var started := Time.get_ticks_usec()
	for _index in 1000:
		runtime.get_network_enemies().size()
	var old_usec := Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	for _index in 1000:
		runtime.get_network_enemy_count()
	var new_usec := Time.get_ticks_usec() - started
	runtime.register_network_enemy(1, enemies[0])
	_check(runtime.get_network_enemy_count() == 300, "Repeated registration changed count")
	runtime.register_network_enemy(301, enemies[0])
	_check(runtime.get_network_enemy_count() == 300 and not runtime.has_network_enemy(1), "Reidentification duplicated registry entry")
	var replacement := packed.instantiate() as Enemy
	root.add_child(replacement)
	replacement.set_process(false)
	replacement.set_physics_process(false)
	runtime.register_network_enemy(301, replacement)
	enemies[0].free()
	await process_frame
	_check(runtime.get_network_enemy_count() == 300 and runtime.get_network_enemy(301) == replacement, "Old incarnation exit erased replacement")
	root.remove_child(enemies[1])
	await process_frame
	_check(runtime.get_network_enemy_count() == 299 and not runtime.has_network_enemy(2), "Tree removal failed to unregister")
	enemies[1].free()
	enemies[2].free()
	await process_frame
	_check(runtime.get_network_enemy_count() == 298, "Direct free failed to unregister")
	enemies[3].queue_free()
	await process_frame
	_check(runtime.get_network_enemy_count() == 297, "Queued free failed to unregister")
	runtime.unregister_network_enemy(5, replacement)
	_check(runtime.get_network_enemy_count() == 297, "Wrong expected instance removed current entry")
	runtime.unregister_network_enemy(5, enemies[4])
	_check(runtime.get_network_enemy_count() == 296, "Explicit unregister failed")
	root.remove_child(enemies[4])
	root.add_child(enemies[4])
	runtime.register_network_enemy(302, enemies[4])
	await process_frame
	_check(runtime.get_network_enemy_count() == 297, "Reattached node did not re-register")
	root.remove_child(enemies[4])
	root.add_child(enemies[4])
	await process_frame
	_check(runtime.get_network_enemy_count() == 297, "Deferred old exit erased an immediate reattachment")
	runtime.clear_network_enemy_registry()
	_check(runtime.get_network_enemy_count() == 0, "Session clear retained entries")
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.free()
	replacement.free()
	_check(runtime.get_network_enemy_count() == 0, "Late exit after clear polluted registry")
	runtime.free()
	await _check_mode_terminal_callbacks(packed)
	print("NETWORK_ENEMY_REGISTRY ", JSON.stringify({"count": 300, "iterations": 1000, "old_usec": old_usec, "new_usec": new_usec, "failures": _failures}))
	quit(0 if _failures.is_empty() else 1)


func _check_mode_terminal_callbacks(packed: PackedScene) -> void:
	# Invoke the production tower/wave terminal consumers from actual native
	# tree_exited signals. Test both connection orders: the registry must not
	# erase the ID before a mode ledger can publish its terminal/remove event.
	for use_tower in [true, false]:
		var runtime: CombatRuntimeBase = TowerDefenseGame.new() if use_tower else StandardGame.new()
		runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		var gateway := MultiplayerGameplayGateway.new()
		runtime.multiplayer_gateway = gateway
		var coordinator := TowerDefenseEnemyCoordinator.new()
		coordinator._runtime = runtime
		coordinator._multiplayer_gateway = gateway
		var removed: Array[int] = []
		var defeated: Array[int] = []
		gateway.enemy_removed.connect(func(net_id: int) -> void: removed.append(net_id))
		gateway.enemy_defeated.connect(func(net_id: int, _position: Vector2) -> void: defeated.append(net_id))
		var ledger := WaveEnemyTerminalLedger.new()
		ledger.reset(6)
		for index in 6:
			var enemy := packed.instantiate() as Enemy
			root.add_child(enemy)
			enemy.set_process(false)
			enemy.set_physics_process(false)
			var instance_id := enemy.get_instance_id()
			var net_id := index + 1
			ledger.register_enemy(instance_id)
			var terminal: CombatTypes.EnemyTerminalReason = [CombatTypes.EnemyTerminalReason.DEFEATED, CombatTypes.EnemyTerminalReason.REMOVED, CombatTypes.EnemyTerminalReason.ESCAPED][index % 3]
			var callback := _on_mode_enemy_exited.bind(runtime, coordinator, ledger, instance_id, use_tower)
			if index < 3:
				enemy.tree_exited.connect(callback)
			runtime.register_network_enemy(net_id, enemy)
			if index >= 3:
				enemy.tree_exited.connect(callback)
			if terminal == CombatTypes.EnemyTerminalReason.DEFEATED:
				if use_tower:
					coordinator.emit_multiplayer_enemy_defeated(enemy)
				else:
					(runtime as StandardGame)._emit_multiplayer_enemy_defeated(enemy)
			if terminal != CombatTypes.EnemyTerminalReason.REMOVED:
				ledger.resolve_enemy(instance_id, terminal)
			enemy.free()
			_check(runtime.get_network_enemy_count() == 0, "Mode synchronous detach retained registry entry")
			_check(runtime.combat_target_index.enemies_by_net_id.is_empty(), "Mode synchronous detach retained combat index")
		await process_frame
		_check(removed == [1, 2, 4, 5], "Mode removal events were missing/duplicated: " + str(removed))
		_check(defeated == [1, 4], "Mode defeat events were missing/duplicated: " + str(defeated))
		_check(ledger.get_attached_enemy_count() == 0, "Mode ledger retained detached enemies")
		coordinator.free()
		gateway.free()
		runtime.free()


func _on_mode_enemy_exited(
	runtime: CombatRuntimeBase,
	coordinator: TowerDefenseEnemyCoordinator,
	ledger: WaveEnemyTerminalLedger,
	instance_id: int,
	use_tower: bool
) -> void:
	var result := ledger.detach_enemy(instance_id)
	if use_tower:
		coordinator.mark_multiplayer_enemy_detached(instance_id, result)
	else:
		(runtime as StandardGame)._mark_multiplayer_enemy_detached(instance_id, result)
