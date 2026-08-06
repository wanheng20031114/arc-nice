extends SceneTree

## Focused regression for cross-channel life-state ordering. Player snapshots
## share the reliable health revision without consuming it on receipt, while
## enemy snapshots and damage feedback share the entity health revision.

const SnapshotManagerScript := preload(
	"res://scene/multiplayer/snapshot_manager.gd"
)
const MpGameScript := preload("res://scene/multiplayer/mp_game.gd")
const PlayerScene := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const EnemyConfigResource := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "DamageSnapshotOrderingSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_player_health_revision_codec()
	_test_enemy_health_revision_codec()
	await _test_player_snapshot_revision_fence()
	await _test_enemy_health_revision_fence()

	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("DAMAGE_SNAPSHOT_ORDERING_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_player_health_revision_codec() -> void:
	var sender := SnapshotManagerScript.new()
	var receiver := SnapshotManagerScript.new()
	var state := SnapshotManagerScript.PlayerState.new()
	state.peer_id = 17
	state.sequence = 1
	state.current_health = 70
	state.max_health = 100
	state.health_revision = 9
	state.skill1_charge_duration = 1.0

	var states: Array[SnapshotManager.PlayerState] = [state]
	var full_data := sender.encode_player_snapshots_for_peer(17, states, true)
	var decoded := receiver.decode_player_snapshots_with_baseline(full_data)
	_expect(decoded.size() == 1, "Player health-revision keyframe must decode.")
	if decoded.size() == 1:
		_expect(
			decoded[0].health_revision == 9,
			"Player keyframe must preserve health_revision."
		)

	# A correction may advance the revision while health stays unchanged. The
	# delta codec must still carry that ordering fence.
	state.sequence = 2
	state.health_revision = 10
	var delta_data := sender.encode_player_snapshots_for_peer(17, states, false)
	var decoded_delta := receiver.decode_player_snapshots_with_baseline(delta_data)
	_expect(decoded_delta.size() == 1, "Player health-revision delta must decode.")
	if decoded_delta.size() == 1:
		_expect(
			decoded_delta[0].health_revision == 10,
			"Revision-only player delta must update health_revision."
		)


func _test_player_snapshot_revision_fence() -> void:
	var player := PlayerScene.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	player.set_process(false)
	player.set_physics_process(false)
	var test_max_health := player.max_health
	var initial_health := maxi(test_max_health - 10, 1)
	var confirmed_health := maxi(test_max_health - 20, 1)
	player.current_health = initial_health
	player.is_dead = false
	player.invincibility_time_left = 0.8

	var mp_game := MpGameScript.new()
	var player_coordinator := MpPlayerCoordinator.new()
	player_coordinator.name = "PlayerCoordinator"
	mp_game.add_child(player_coordinator)
	mp_game.player_coordinator = player_coordinator
	var health_revisions := mp_game.get("_player_health_revisions") as Dictionary
	health_revisions[17] = 5
	player_coordinator.set_applied_health_revision(17, 5)
	var stale_state := _make_player_state(
		17,
		4,
		test_max_health,
		test_max_health,
		false,
		0.0
	)
	player_coordinator.call("_apply_realtime_snapshot", player, stale_state)
	_expect(
		player.current_health == initial_health,
		"A stale player snapshot must not restore health after a reliable result."
	)
	_expect(
		is_equal_approx(player.invincibility_time_left, 0.8),
		"A stale player snapshot must not clear confirmed hit invincibility."
	)

	var current_state := _make_player_state(
		17,
		5,
		confirmed_health,
		test_max_health,
		false,
		0.25
	)
	player_coordinator.call("_apply_realtime_snapshot", player, current_state)
	_expect(
		player.current_health == confirmed_health,
		"A player snapshot at the accepted revision must still apply health."
	)
	_expect(
		is_equal_approx(player.invincibility_time_left, 0.25),
		"A current player snapshot must apply Host invincibility time."
	)
	# Snapshot receipt deliberately does not consume the reliable event revision;
	# otherwise an earlier-arriving snapshot would suppress damage feedback.
	_expect(
		int(health_revisions.get(17, 0)) == 5,
		"Snapshot application must not advance the reliable event revision."
	)
	_expect(
		player_coordinator.get_applied_health_revision(17) == 5,
		"Current player snapshot must retain the applied health revision."
	)

	# A newer snapshot may arrive before reliable feedback. It owns health state,
	# but must not consume the reliable event revision or suppress presentation.
	var ahead_state := _make_player_state(
		17,
		7,
		maxi(confirmed_health - 5, 1),
		test_max_health,
		false,
		0.1
	)
	player_coordinator.call("_apply_realtime_snapshot", player, ahead_state)
	var ahead_health := player.current_health
	_expect(
		player_coordinator.get_applied_health_revision(17) == 7,
		"Newer snapshot must advance only the applied health fence."
	)
	_expect(
		int(health_revisions.get(17, 0)) == 5,
		"Newer snapshot must leave reliable presentation dedup untouched."
	)
	var stale_event_applied := bool(mp_game.call(
		"_try_apply_player_health_event",
		player,
		17,
		test_max_health,
		false,
		6
	))
	_expect(
		not stale_event_applied and player.current_health == ahead_health,
		"An older reliable event may present feedback but must not regress health."
	)

	mp_game.free()
	player.queue_free()
	await process_frame


func _test_enemy_health_revision_codec() -> void:
	var sender := SnapshotManagerScript.new()
	var receiver := SnapshotManagerScript.new()
	var state := SnapshotManagerScript.EnemyState.new()
	state.net_id = 31
	state.position = Vector2(12.0, 18.0)
	state.health = 60
	state.health_revision = 4

	var states: Array[SnapshotManager.EnemyState] = [state]
	var full_data := sender.encode_enemy_snapshots_for_peer(31, states, true)
	var decoded := receiver.decode_enemy_snapshots_with_baseline(full_data)
	_expect(decoded.size() == 1, "Enemy health-revision keyframe must decode.")
	if decoded.size() == 1:
		_expect(
			decoded[0].health == 60 and decoded[0].health_revision == 4,
			"Enemy keyframe must preserve health and health_revision."
		)

	state.health = 75
	state.health_revision = 5
	var heal_delta := sender.encode_enemy_snapshots_for_peer(31, states, false)
	var decoded_heal := receiver.decode_enemy_snapshots_with_baseline(heal_delta)
	_expect(decoded_heal.size() == 1, "Enemy healing delta must decode.")
	if decoded_heal.size() == 1:
		_expect(
			decoded_heal[0].health == 75
			and decoded_heal[0].health_revision == 5,
			"Enemy healing delta must preserve its revision."
		)

	state.health_revision = 6
	var revision_delta := sender.encode_enemy_snapshots_for_peer(31, states, false)
	var decoded_revision := receiver.decode_enemy_snapshots_with_baseline(
		revision_delta
	)
	_expect(decoded_revision.size() == 1, "Enemy revision-only delta must decode.")
	if decoded_revision.size() == 1:
		_expect(
			decoded_revision[0].health == 75
			and decoded_revision[0].health_revision == 6,
			"Enemy revision-only delta must retain health and advance revision."
		)


func _test_enemy_health_revision_fence() -> void:
	var config := EnemyConfigResource.duplicate(true) as EnemyConfig
	var enemy := config.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.setup(config, null)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	enemy.current_health = 60
	enemy.health_revision = 2

	var mp_game := MpGameScript.new()
	var damage_applied := bool(mp_game.call(
		"_apply_enemy_network_health",
		enemy,
		40,
		3
	))
	_expect(
		damage_applied
		and enemy.current_health == 40
		and enemy.health_revision == 3,
		"Newer enemy damage health must apply."
	)
	var stale_heal_applied := bool(mp_game.call(
		"_apply_enemy_network_health",
		enemy,
		55,
		2
	))
	_expect(
		not stale_heal_applied and enemy.current_health == 40,
		"An older enemy heal must not overwrite newer damage."
	)
	var heal_applied := bool(mp_game.call(
		"_apply_enemy_network_health",
		enemy,
		55,
		4
	))
	_expect(
		heal_applied
		and enemy.current_health == 55
		and enemy.health_revision == 4,
		"Newer enemy healing must apply to the proxy."
	)
	var stale_damage_applied := bool(mp_game.call(
		"_apply_enemy_network_health",
		enemy,
		35,
		3
	))
	_expect(
		not stale_damage_applied and enemy.current_health == 55,
		"Older enemy damage must not overwrite newer healing."
	)

	mp_game.free()
	enemy.queue_free()
	await process_frame


func _make_player_state(
	peer_id: int,
	health_revision: int,
	health: int,
	maximum_health: int,
	is_dead: bool,
	invincibility_time_left: float
) -> SnapshotManager.PlayerState:
	var state := SnapshotManagerScript.PlayerState.new()
	state.peer_id = peer_id
	state.health_revision = health_revision
	state.current_health = health
	state.max_health = maximum_health
	state.is_dead = is_dead
	state.invincibility_time_left = invincibility_time_left
	state.skill1_charge_duration = 1.0
	return state


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
