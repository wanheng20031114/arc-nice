extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const SPEED_TOWER_SCENE := preload(
	"res://scene/plant_defense/speed_tower.tscn"
)
const SPEED_TOWER_CONFIG := preload(
	"res://resources/config/plant_defense/speed_tower.tres"
)
const COORDINATOR_SCRIPT := preload(
	"res://scene/game_modes/tower_defense/plant/support/speed_tower_move_speed_coordinator.gd"
)

var failures: Array[String] = []


class RosterProbe:
	extends TowerDefensePlayerRosterCoordinator

	var players: Array[Player] = []

	func get_all_players() -> Array[Player]:
		return players


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "Speed Tower smoke test requires RunState.")
	if run_state == null:
		_finish(null)
		return
	run_state.begin_new_run(&"weishidaier", false)

	var fixture := Node2D.new()
	fixture.name = "SpeedTowerMoveSpeedBonusSmokeTest"
	root.add_child(fixture)
	current_scene = fixture

	var plant_system := PlantSystem.new()
	var roster := RosterProbe.new()
	fixture.add_child(plant_system)
	fixture.add_child(roster)

	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	await process_frame
	player.set("_base_move_speed", 120.0)
	player.refresh_collectible_stats()
	roster.local_player = player
	roster.players.append(player)

	var client_player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(client_player)
	await process_frame
	client_player.set("_base_move_speed", 120.0)
	client_player.refresh_collectible_stats()
	var snapshot_sender := SnapshotManager.new()
	var snapshot_receiver := SnapshotManager.new()

	var coordinator := COORDINATOR_SCRIPT.new() as SpeedTowerMoveSpeedCoordinator
	coordinator.plant_system = plant_system
	coordinator.player_roster_coordinator = roster
	fixture.add_child(coordinator)
	await process_frame
	_expect(coordinator.get_active_source_count() == 0, "No source must mean no bonus.")
	_expect(is_equal_approx(player.move_speed, 120.0), "No source must preserve base speed.")
	var baseline_snapshot := _round_trip_authoritative_speed_snapshot(
		player,
		snapshot_sender,
		snapshot_receiver,
		true
	)
	var baseline_state := baseline_snapshot.get("state") as SnapshotManager.PlayerState
	_expect(
		baseline_state != null
		and is_equal_approx(baseline_state.effective_move_speed_multiplier, 1.0),
		"The no-tower keyframe must publish final speed relative to stable base speed."
	)
	if baseline_state != null:
		client_player.apply_multiplayer_effective_move_speed_multiplier(
			baseline_state.effective_move_speed_multiplier
		)

	var first := _make_tower(fixture, Vector2i.ZERO, false)
	plant_system.plant_placed.emit(first)
	_expect(coordinator.get_active_source_count() == 1, "First completed tower must register.")
	_expect(
		is_equal_approx(coordinator.get_total_move_speed_bonus(), 10.0),
		"One tower must publish an absolute +10 bonus."
	)
	_expect(is_equal_approx(player.move_speed, 130.0), "One tower must raise speed 120 to 130.")
	var first_tower_snapshot := _round_trip_authoritative_speed_snapshot(
		player,
		snapshot_sender,
		snapshot_receiver
	)
	var first_tower_state := (
		first_tower_snapshot.get("state") as SnapshotManager.PlayerState
	)
	_expect(
		first_tower_state != null
		and absf(
			first_tower_state.effective_move_speed_multiplier
			- 130.0 / 120.0
		) <= 0.001
		and int(first_tower_snapshot.get("size", 0))
		== int(baseline_snapshot.get("size", -1)),
		"A tower bonus change must trigger a full player meta snapshot with final speed."
	)
	if first_tower_state != null:
		client_player.apply_multiplayer_effective_move_speed_multiplier(
			first_tower_state.effective_move_speed_multiplier
		)
	_expect(
		is_zero_approx(client_player.get_tower_defense_speed_tower_bonus())
		and _is_close(float(client_player.call("_get_effective_move_speed")), 130.0),
		"A Host 130 snapshot must converge a client with local tower bonus 0 to 130."
	)
	client_player.set_tower_defense_speed_tower_bonus(10.0)
	_expect(
		is_equal_approx(client_player.move_speed, 130.0)
		and _is_close(float(client_player.call("_get_effective_move_speed")), 130.0),
		"A delayed local tower-spawn event must not double-apply the snapshot bonus."
	)

	plant_system.plant_placed.emit(first)
	_expect(
		coordinator.get_active_source_count() == 1
		and is_equal_approx(player.move_speed, 130.0),
		"Duplicate placement events must be idempotent."
	)

	var second := _make_tower(fixture, Vector2i(2, 0), true)
	plant_system.plant_placed.emit(second)
	_expect(
		coordinator.get_active_source_count() == 1
		and is_equal_approx(player.move_speed, 130.0),
		"A tower under construction must not grant its bonus."
	)
	# A late join currently receives roster entries independently of Host
	# construction timing. Even if its local event path temporarily counts both
	# towers, the authoritative snapshot must keep effective movement at +10.
	client_player.set_tower_defense_speed_tower_bonus(20.0)
	var construction_snapshot := _round_trip_authoritative_speed_snapshot(
		player,
		snapshot_sender,
		snapshot_receiver
	)
	var construction_state := (
		construction_snapshot.get("state") as SnapshotManager.PlayerState
	)
	_expect(
		construction_state != null
		and absf(
			construction_state.effective_move_speed_multiplier
			- 130.0 / 120.0
		) <= 0.001
		and int(construction_snapshot.get("size", 0))
		< int(baseline_snapshot.get("size", 0)),
		"An unchanged Host bonus must retain its value through the compact delta baseline."
	)
	if construction_state != null:
		client_player.apply_multiplayer_effective_move_speed_multiplier(
			construction_state.effective_move_speed_multiplier
		)
	_expect(
		is_equal_approx(client_player.get_tower_defense_speed_tower_bonus(), 20.0)
		and _is_close(float(client_player.call("_get_effective_move_speed")), 130.0),
		"The same Host 130 snapshot must converge a client with local tower bonus 20 to 130."
	)
	second.call("_finish_construction", true)
	_expect(coordinator.get_active_source_count() == 2, "Construction completion must register.")
	_expect(
		is_equal_approx(coordinator.get_total_move_speed_bonus(), 20.0),
		"Two towers must publish an absolute +20 bonus."
	)
	_expect(is_equal_approx(player.move_speed, 140.0), "Two towers must raise speed 120 to 140.")
	var completed_snapshot := _round_trip_authoritative_speed_snapshot(
		player,
		snapshot_sender,
		snapshot_receiver
	)
	var completed_state := completed_snapshot.get("state") as SnapshotManager.PlayerState
	if completed_state != null:
		client_player.apply_multiplayer_effective_move_speed_multiplier(
			completed_state.effective_move_speed_multiplier
		)
	_expect(
		completed_state != null
		and _is_close(float(client_player.call("_get_effective_move_speed")), 140.0),
		"The construction-complete snapshot must converge the client to +20."
	)
	player.configure_run_stat_bonuses({"move_speed": 15.0})
	_expect(
		is_equal_approx(player.move_speed, 155.0),
		"Tower and run move-speed bonuses must add linearly."
	)
	player.configure_run_stat_bonuses({})
	_expect(is_equal_approx(player.move_speed, 140.0), "Clearing run bonus must restore 140.")

	plant_system.plant_removed.emit(first)
	_expect(
		coordinator.get_active_source_count() == 1
		and is_equal_approx(coordinator.get_total_move_speed_bonus(), 10.0)
		and is_equal_approx(player.move_speed, 130.0),
		"Removal must immediately subtract exactly one tower."
	)
	var first_removal_snapshot := _round_trip_authoritative_speed_snapshot(
		player,
		snapshot_sender,
		snapshot_receiver
	)
	var first_removal_state := (
		first_removal_snapshot.get("state") as SnapshotManager.PlayerState
	)
	if first_removal_state != null:
		client_player.apply_multiplayer_effective_move_speed_multiplier(
			first_removal_state.effective_move_speed_multiplier
		)
	_expect(
		_is_close(float(client_player.call("_get_effective_move_speed")), 130.0),
		"A Host removal snapshot must subtract the tower before its reliable remove event arrives."
	)
	client_player.set_tower_defense_speed_tower_bonus(10.0)
	_expect(
		_is_close(float(client_player.call("_get_effective_move_speed")), 130.0),
		"The delayed local remove event must not subtract the Host bonus twice."
	)

	var late_player := PLAYER_SCENE.instantiate() as Player
	roster.player_runtime_binding_requested.emit(late_player)
	_expect(
		is_equal_approx(
			late_player.get_tower_defense_speed_tower_bonus(),
			10.0
		),
		"A late player must receive the current absolute bonus before entering the tree."
	)
	fixture.add_child(late_player)
	await process_frame
	var late_base := float(late_player.get("_base_move_speed"))
	_expect(
		is_equal_approx(late_player.move_speed, late_base + 10.0),
		"A late player must initialize with the active tower bonus."
	)
	roster.players.append(late_player)

	plant_system.plant_removed.emit(second)
	var final_removal_snapshot := _round_trip_authoritative_speed_snapshot(
		player,
		snapshot_sender,
		snapshot_receiver
	)
	var final_removal_state := (
		final_removal_snapshot.get("state") as SnapshotManager.PlayerState
	)
	if final_removal_state != null:
		client_player.apply_multiplayer_effective_move_speed_multiplier(
			final_removal_state.effective_move_speed_multiplier
		)
	_expect(
		final_removal_state != null
		and absf(final_removal_state.effective_move_speed_multiplier - 1.0) <= 0.001
		and coordinator.get_active_source_count() == 0
		and is_zero_approx(coordinator.get_total_move_speed_bonus())
		and is_equal_approx(player.move_speed, 120.0)
		and is_equal_approx(late_player.move_speed, late_base)
		and _is_close(float(client_player.call("_get_effective_move_speed")), 120.0),
		"Removing the final tower must clear every player's bonus immediately."
	)
	client_player.set_tower_defense_speed_tower_bonus(0.0)
	_expect(
		_is_close(float(client_player.call("_get_effective_move_speed")), 120.0),
		"A final delayed removal event must preserve the zero-bonus snapshot result."
	)
	# The existing u16 / 1000 field can represent 65.535. Do not impose the old
	# transient-multiplier ceiling on large additive tower stacks.
	client_player.apply_multiplayer_effective_move_speed_multiplier(9.25)
	_expect(
		_is_close(float(client_player.call("_get_effective_move_speed")), 1110.0),
		"A representable 99-tower ratio must not be truncated by the client setter."
	)

	_finish(fixture)


func _make_tower(
	parent: Node,
	top_left: Vector2i,
	play_construction: bool
) -> SpeedTower:
	var tower := SPEED_TOWER_SCENE.instantiate() as SpeedTower
	parent.add_child(tower)
	tower.setup(
		SPEED_TOWER_CONFIG,
		null,
		[
			top_left,
			top_left + Vector2i.RIGHT,
			top_left + Vector2i.DOWN,
			top_left + Vector2i.ONE,
		],
		false,
		-1,
		0,
		-1,
		play_construction
	)
	return tower


func _round_trip_authoritative_speed_snapshot(
	host_player: Player,
	sender: SnapshotManager,
	receiver: SnapshotManager,
	force_keyframe: bool = false
) -> Dictionary:
	var states := TowerDefensePlayerRosterCoordinator.collect_snapshot_states_from(
		{77: host_player}
	)
	var data := sender.encode_player_snapshots_for_peer(
		9001,
		states,
		force_keyframe
	)
	var decoded := receiver.decode_player_snapshots_with_baseline(data)
	_expect(decoded.size() == 1, "The authoritative speed snapshot must decode one player.")
	return {
		"size": data.size(),
		"state": decoded[0] if decoded.size() == 1 else null,
	}


func _finish(fixture: Node) -> void:
	if fixture != null:
		fixture.queue_free()
	current_scene = null
	if failures.is_empty():
		print("SPEED_TOWER_MOVE_SPEED_BONUS_SMOKE_TEST_OK")
		print("event_driven=true")
		print("persistent_scan=false")
		print("two_tower_bonus=20")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _is_close(value: float, expected: float, epsilon: float = 0.1) -> bool:
	return absf(value - expected) <= epsilon
