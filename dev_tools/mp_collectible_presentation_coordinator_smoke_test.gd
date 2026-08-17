extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/collectible_presentation/mp_collectible_presentation_coordinator.tscn"
)
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"


class TestRuntime:
	extends CombatRuntimeBase

	var test_player: Player = null

	func _ready() -> void:
		pass

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return test_player if test_player != null and test_player.peer_id == peer_id else null

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class TestNetManager:
	extends NetManagerStore

	var host_mode := true

	func is_host() -> bool:
		return host_mode

	func is_client() -> bool:
		return not host_mode


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var world_parent := Node2D.new()
	world_parent.name = "CollectiblePresentationSmokeWorld"
	root.add_child(world_parent)
	var coordinator := (
		COORDINATOR_SCENE.instantiate()
		as MpCollectiblePresentationCoordinator
	)
	_expect(coordinator != null, "CollectiblePresentationCoordinator scene must instantiate.")
	if coordinator == null:
		world_parent.queue_free()
		_finish()
		return
	world_parent.add_child(coordinator)
	_test_static_boundary(coordinator)
	await _test_runtime_paths(coordinator, world_parent)
	world_parent.queue_free()
	await process_frame
	_finish()


func _test_static_boundary(
	coordinator: MpCollectiblePresentationCoordinator
) -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(
		mp_game != null
		and mp_game.get_node_or_null("CollectiblePresentationCoordinator")
		is MpCollectiblePresentationCoordinator,
		"MpGame must statically contain CollectiblePresentationCoordinator."
	)
	if mp_game != null:
		mp_game.free()
	var source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	var rpc_pattern := RegEx.new()
	rpc_pattern.compile("(?m)^@rpc\\(")
	_expect(
		rpc_pattern.search_all(source).size() == 144,
		"Collectible presentation extraction must preserve all 144 protocol-v82 MpGame RPC facades."
	)
	_expect(
		source.contains(
			"@rpc(\"authority\", \"call_remote\", \"unreliable\", 7)\n"
			+ "func net_collectible_visual_effect("
		)
		and source.contains(
			"@rpc(\"authority\", \"call_remote\", \"unreliable\", 7)\n"
			+ "func net_collectible_follow_visual_effect("
		),
		"Collectible visual RPC metadata and order must remain unchanged."
	)
	_expect(
		source.contains("effect_event_id: int = 0\n) -> void:")
		and source.contains("collectible_presentation_coordinator.receive_visual_effect")
		and source.contains("collectible_presentation_coordinator.receive_follow_visual_effect"),
		"Collectible RPC facades must retain defaults and delegate to the coordinator."
	)
	_expect(
		not source.contains("func _spawn_collectible_visual_effect")
		and not source.contains("func _spawn_collectible_follow_visual_effect")
		and not source.contains("_processed_collectible_effect_event_ids"),
		"MpGame must not retain extracted collectible presentation state."
	)
	var coordinator_source := coordinator.get_script().source_code as String
	_expect(
		not coordinator_source.contains("current_scene")
		and not coordinator_source.contains("has_method")
		and not coordinator_source.contains(".call("),
		"Collectible presentation must use typed runtime dependencies."
	)


func _test_runtime_paths(
	coordinator: MpCollectiblePresentationCoordinator,
	world_parent: Node2D
) -> void:
	var runtime := TestRuntime.new()
	var player := Player.new()
	player.peer_id = 2
	runtime.test_player = player
	runtime.peer_players[2] = player
	runtime.add_child(player)
	var net_manager := TestNetManager.new()
	coordinator.bind_runtime(runtime, world_parent, net_manager, 0.0)

	var broadcasts: Array[Dictionary] = []
	coordinator.rpc_broadcast_requested.connect(
		func(method_name: StringName, args: Array) -> void:
			broadcasts.append({"method": method_name, "args": args})
	)
	coordinator.broadcast_visual_effect(
		&"area",
		Vector2(10.0, 20.0),
		72.0,
		Color.CYAN,
		1.2
	)
	coordinator.broadcast_follow_visual_effect(&"moon_shield", 2, 64.0, 8.0)
	_expect(broadcasts.size() == 2, "Host must emit both collectible presentation RPCs.")
	if broadcasts.size() == 2:
		_expect(
			int((broadcasts[0].get("args", []) as Array)[5]) == 1
			and int((broadcasts[1].get("args", []) as Array)[4]) == 2,
			"World and follow effects must share the original monotonic event IDs."
		)
	net_manager.host_mode = false
	coordinator.broadcast_visual_effect(&"area", Vector2.ZERO, 1.0, Color.WHITE, 1.0)
	_expect(broadcasts.size() == 2, "Clients must not originate collectible visuals.")

	coordinator.receive_visual_effect(
		"lightning", Vector2(30.0, 40.0), 16.0, Color.WHITE, 9.0, 101
	)
	coordinator.receive_visual_effect(
		"area", Vector2.ZERO, 80.0, Color.RED, 9.0, 101
	)
	coordinator.receive_visual_effect(
		"area", Vector2(50.0, 60.0), 80.0, Color.RED, 9.0, 102
	)
	coordinator.receive_visual_effect(
		"frost_area", Vector2(70.0, 80.0), 96.0, Color.WHITE, 9.0, 103
	)
	var lightning := _first_child_of_type(world_parent, &"CollectibleLightningEffect")
	var area := _first_child_of_type(world_parent, &"CollectibleAreaEffect")
	var frost := _first_child_of_type(world_parent, &"CollectibleFrostAreaEffect")
	_expect(
		lightning is CollectibleLightningEffect
		and lightning.get_parent() == world_parent
		and (lightning as CollectibleLightningEffect).top_level
		and (lightning as CollectibleLightningEffect).global_position
		== Vector2(30.0, 40.0),
		"Lightning must retain its MpGame parent, top-level mode, and world position."
	)
	_expect(
		area is CollectibleAreaEffect
		and area.get_parent() == world_parent
		and is_equal_approx((area as CollectibleAreaEffect).effect_radius, 80.0)
		and (area as CollectibleAreaEffect).effect_color == Color.RED,
		"Area visuals must retain parent and setup arguments."
	)
	_expect(
		frost is CollectibleFrostAreaEffect
		and frost.get_parent() == world_parent
		and is_equal_approx((frost as CollectibleFrostAreaEffect).effect_radius, 96.0),
		"Frost visuals must retain parent and setup arguments."
	)
	_expect(
		_count_children_of_type(world_parent, &"CollectibleAreaEffect") == 1,
		"Duplicate event IDs must not spawn a second world visual."
	)

	coordinator.receive_follow_visual_effect("moon_shield", 2, 70.0, 8.0, 104)
	var moon_shield := _first_child_of_type(player, &"CollectibleMoonShieldVisual")
	_expect(
		moon_shield is CollectibleMoonShieldVisual
		and moon_shield.get_parent() == player
		and (moon_shield as CollectibleMoonShieldVisual).position == Vector2.ZERO
		and is_equal_approx(
			(moon_shield as CollectibleMoonShieldVisual).shield_radius,
			70.0
		),
		"Moon shield must remain a zero-offset child of the owning Player."
	)
	coordinator.clear_peer(2)
	_expect(
		moon_shield != null and moon_shield.is_queued_for_deletion(),
		"Peer cleanup must retire its follow visuals."
	)

	coordinator.prune_recent_effect_events(INF)
	coordinator.receive_visual_effect(
		"area", Vector2.ZERO, 40.0, Color.BLUE, 9.0, 102
	)
	_expect(
		_count_children_of_type(world_parent, &"CollectibleAreaEffect") == 2,
		"Expired dedup entries must be accepted after cache pruning."
	)
	coordinator.reset_session_state()
	net_manager.host_mode = true
	coordinator.broadcast_visual_effect(&"area", Vector2.ZERO, 1.0, Color.WHITE, 1.0)
	_expect(
		broadcasts.size() == 3
		and int((broadcasts[2].get("args", []) as Array)[5]) == 1,
		"Session reset must restart collectible presentation event IDs."
	)
	coordinator.unbind_runtime(runtime)
	runtime.free()
	net_manager.free()


func _first_child_of_type(parent: Node, type_name: StringName) -> Node:
	for child in parent.get_children():
		if _is_expected_visual_type(child, type_name):
			return child
	return null


func _count_children_of_type(parent: Node, type_name: StringName) -> int:
	var count := 0
	for child in parent.get_children():
		if _is_expected_visual_type(child, type_name):
			count += 1
	return count


func _is_expected_visual_type(node: Node, type_name: StringName) -> bool:
	match type_name:
		&"CollectibleLightningEffect":
			return node is CollectibleLightningEffect
		&"CollectibleAreaEffect":
			return node is CollectibleAreaEffect
		&"CollectibleFrostAreaEffect":
			return node is CollectibleFrostAreaEffect
		&"CollectibleMoonShieldVisual":
			return node is CollectibleMoonShieldVisual
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("MP_COLLECTIBLE_PRESENTATION_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
