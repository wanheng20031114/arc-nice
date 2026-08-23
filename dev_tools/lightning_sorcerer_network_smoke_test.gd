extends SceneTree

const MP_GAME_PATH := "res://scene/multiplayer/mp_game.gd"
const MP_GAME_SCRIPT := preload(MP_GAME_PATH)
const LIGHTNING_SORCERER_PATH := "res://scene/enemy/sorcerer/lightning_sorcerer.gd"
const LIGHTNING_SORCERER_SCENE := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer.tscn"
)
const LIGHTNING_SORCERER_CONFIG := preload(
	"res://resources/config/enemies/lightning_sorcerer.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)


class RecordingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var sent_methods: Array[StringName] = []
	var sent_arguments: Array[Array] = []

	func _rpc_to_connected_clients(
		method_name: StringName,
		args: Array = []
	) -> void:
		sent_methods.append(method_name)
		sent_arguments.append(args.duplicate(true))


class TestNetManager:
	extends NetManagerStore

	var host_mode := false

	func is_host() -> bool:
		return host_mode

	func is_client() -> bool:
		return not host_mode


class LightningVfxRuntime:
	extends CombatRuntimeBase

	var played_chains: Array[PackedVector2Array] = []
	var players_by_peer_id: Dictionary = {}

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return players_by_peer_id.get(peer_id) as Player

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

	func apply_remote_flow_state(
		_step_id: StringName,
		_state: int,
		_seconds: int
	) -> void:
		pass

	func get_flow_state_snapshot() -> Dictionary:
		return {}

	func apply_remote_boss_started(
		_net_id: int,
		_boss_config: BossConfig,
		_spawn_position: Vector2
	) -> void:
		pass

	func apply_remote_defeat() -> void:
		pass

	func apply_remote_victory() -> void:
		pass

	func apply_remote_enemy_count(_alive_count: int) -> void:
		pass

	func apply_remote_merchant_active(_active: bool) -> void:
		pass

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass

	func try_purchase_skill1_for_peer(_peer_id: int) -> int:
		return 0

	func apply_skill1_purchase_state(
		_peer_id: int,
		_current_xirang: int,
		_skill1_unlocked: bool,
		_skill1_upgrade_level: int = -1,
		_skill1_charge_duration: float = -1.0
	) -> void:
		pass

	func show_local_skill1_purchase_result(_result_code: int) -> void:
		pass

	func try_refresh_luoxi_collectibles_for_peer(_peer_id: int) -> int:
		return 0

	func get_luoxi_collectible_refresh_count(_peer_id: int) -> int:
		return 0

	func try_claim_luoxi_collectible_for_peer(
		_peer_id: int,
		_config_path_or_choice: Variant
	) -> int:
		return 0

	func has_luoxi_collectible_claimed(_peer_id: int) -> bool:
		return false

	func record_luoxi_collectible_claim(_peer_id: int) -> void:
		pass

	func mark_luoxi_collectible_claimed(_peer_id: int) -> void:
		pass

	func show_local_luoxi_collectible_result(_result_code: int) -> void:
		pass

	func show_local_luoxi_refresh_result(
		_result_code: int,
		_refresh_count: int,
		_current_xirang: int
	) -> void:
		pass

	func show_debug_collectible_grant_result(
		_config_path: String,
		_success: bool
	) -> void:
		pass

	func play_lightning_sorcerer_chain_vfx(points: PackedVector2Array) -> bool:
		played_chains.append(points.duplicate())
		return true


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_host_broadcast_contract()
	await _test_target_warning_proxy_contract()
	_test_pre_spawn_action_buffer_and_snapshot_decoupling()
	_test_client_validation_and_visual_only_contract()

	if failures.is_empty():
		print("LIGHTNING_SORCERER_NETWORK_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_host_broadcast_contract() -> void:
	var mp_game := RecordingMpGame.new()
	var net_manager := TestNetManager.new()
	var runtime := LightningVfxRuntime.new()
	net_manager.host_mode = true
	mp_game.set("net_manager", net_manager)
	mp_game.set("game", runtime)
	_attach_enemy_coordinator(mp_game, runtime, net_manager)
	var enemy_position := Vector2(12.0, 18.0)
	var plant_offset := Vector2(44.0, -8.0)
	mp_game.broadcast_enemy_target_action(
		73,
		&"lightning_windup",
		7,
		enemy_position,
		10
	)
	mp_game.broadcast_enemy_target_action(
		73,
		&"lightning_windup_retry",
		7,
		enemy_position,
		10
	)
	mp_game.broadcast_enemy_action(
		73,
		&"lightning_plant_windup",
		plant_offset,
		enemy_position,
		11
	)
	mp_game.broadcast_enemy_action(
		73,
		&"lightning_plant_windup_retry",
		plant_offset,
		enemy_position,
		11
	)
	mp_game.broadcast_enemy_action(
		73,
		&"fire",
		Vector2.RIGHT,
		enemy_position,
		12
	)
	mp_game.broadcast_enemy_action(
		73,
		&"cancel",
		Vector2.RIGHT,
		enemy_position,
		13
	)
	_expect(
		mp_game.sent_methods == [
			&"net_enemy_target_action",
			&"net_enemy_target_action",
			&"net_enemy_action",
			&"net_enemy_action",
			&"net_enemy_action",
			&"net_enemy_action",
		]
		and mp_game.sent_arguments[0].slice(0, 5) == [
			73,
			"lightning_windup",
			7,
			enemy_position,
			10,
		]
		and mp_game.sent_arguments[1].slice(0, 5) == [
			73,
			"lightning_windup_retry",
			7,
			enemy_position,
			10,
		]
		and mp_game.sent_arguments[2].slice(0, 5) == [
			73,
			"lightning_plant_windup",
			plant_offset,
			enemy_position,
			11,
		]
		and mp_game.sent_arguments[3].slice(0, 5) == [
			73,
			"lightning_plant_windup_retry",
			plant_offset,
			enemy_position,
			11,
		]
		and mp_game.sent_arguments[4][1] == "fire"
		and mp_game.sent_arguments[4][4] == 12
		and mp_game.sent_arguments[5][1] == "cancel"
		and mp_game.sent_arguments[5][4] == 13,
		"Lightning warning must reuse target-action for players and offset action for stationary plants, including one same-id retry."
	)
	var valid_points := PackedVector2Array([
		Vector2(10.0, 20.0),
		Vector2(30.0, 40.0),
	])
	mp_game.broadcast_enemy_lightning_chain(valid_points)
	_expect(
		mp_game.sent_methods.size() == 7
		and mp_game.sent_methods[-1] == &"net_enemy_lightning_chain"
		and mp_game.sent_arguments.size() == 7
		and mp_game.sent_arguments[-1].size() == 1
		and mp_game.sent_arguments[-1][0] == valid_points,
		"Host must send one PackedVector2Array and no gameplay payload alongside it."
	)

	mp_game.broadcast_enemy_lightning_chain(PackedVector2Array())
	mp_game.broadcast_enemy_lightning_chain(_make_points(1))
	mp_game.broadcast_enemy_lightning_chain(_make_points(7))
	mp_game.broadcast_enemy_lightning_chain(PackedVector2Array([Vector2(INF, 0.0)]))
	_expect(
		mp_game.sent_methods.size() == 7,
		"Host must drop incomplete, oversized, and non-finite lightning visual payloads."
	)
	mp_game.free()
	runtime.free()
	net_manager.free()


func _test_target_warning_proxy_contract() -> void:
	var fixture_root := Node2D.new()
	fixture_root.name = "LightningWarningNetworkFixture"
	root.add_child(fixture_root)
	current_scene = fixture_root

	var runtime := LightningVfxRuntime.new()
	var net_manager := TestNetManager.new()
	var mp_game := MP_GAME_SCRIPT.new()
	mp_game.set("net_manager", net_manager)
	mp_game.set("game", runtime)
	var enemy_coordinator := _attach_enemy_coordinator(
		mp_game,
		runtime,
		net_manager
	)

	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "Player warning fixture must instantiate a typed player.")
	if player == null:
		mp_game.free()
		runtime.free()
		net_manager.free()
		current_scene = null
		fixture_root.free()
		return
	fixture_root.add_child(player)
	player.peer_id = 7
	player.global_position = Vector2(96.0, 64.0)
	runtime.players_by_peer_id[player.peer_id] = player

	var lightning := LIGHTNING_SORCERER_SCENE.instantiate() as LightningSorcerer
	_expect(lightning != null, "Lightning warning fixture must instantiate the real enemy scene.")
	if lightning == null:
		mp_game.free()
		runtime.free()
		net_manager.free()
		current_scene = null
		fixture_root.free()
		return
	fixture_root.add_child(lightning)
	lightning.global_position = Vector2(16.0, 24.0)
	lightning.setup(LIGHTNING_SORCERER_CONFIG, player)
	lightning.configure_multiplayer_proxy()
	lightning.set_meta("net_id", 73)
	enemy_coordinator.register_client_enemy(
		73,
		lightning,
		float(mp_game.call("_get_net_time"))
	)

	var target_warning := lightning.get_node_or_null("TargetWarning") as Node2D
	_expect(
		target_warning != null
		and target_warning.top_level
		and not target_warning.visible,
		"Lightning proxy must own one hidden, top-level, scene-authored target warning."
	)
	if target_warning == null:
		mp_game.free()
		runtime.free()
		net_manager.free()
		current_scene = null
		fixture_root.free()
		return
	var warning_instance_id := target_warning.get_instance_id()
	var authored_child_count := lightning.get_child_count()

	mp_game.net_enemy_target_action(
		73,
		"lightning_windup",
		player.peer_id,
		lightning.global_position,
		10
	)
	_expect(
		target_warning.visible
		and bool(target_warning.call("is_warning_active"))
		and target_warning.global_position.is_equal_approx(
			player.get_multiplayer_visual_global_position().round()
		)
		and lightning.latest_proxy_action_id == 10,
		"Player target-action must show the prebuilt warning on the resolved player."
	)
	await process_frame
	await process_frame
	var progressed_before_retry := float(
		target_warning.call("get_warning_progress")
	)
	_expect(
		lightning.is_processing() and progressed_before_retry > 0.0,
		"Active proxy warnings must keep their owner processing across real render frames."
	)
	player.global_position = Vector2(132.0, 91.0)
	await process_frame
	_expect(
		target_warning.global_position.is_equal_approx(
			player.get_multiplayer_visual_global_position().round()
		),
		"Player warning must follow the player's multiplayer visual position."
	)
	mp_game.net_enemy_target_action(
		73,
		"lightning_windup_retry",
		player.peer_id,
		lightning.global_position,
		10
	)
	_expect(
		lightning.latest_proxy_action_id == 10
		and float(target_warning.call("get_warning_progress"))
			>= progressed_before_retry,
		"Same-id warning retry must be ignored after the start arrived and must not reset progress."
	)
	lightning.play_multiplayer_enemy_action(
		&"lightning_plant_windup",
		Vector2(300.0, 0.0),
		9
	)
	_expect(
		lightning.latest_proxy_action_id == 10
		and target_warning.visible
		and lightning.get_child_count() == authored_child_count
		and target_warning.get_instance_id() == warning_instance_id,
		"A stale cross-channel start must not replace the active warning or allocate another marker."
	)

	mp_game.net_enemy_action(
		73,
		"fire",
		Vector2.RIGHT,
		lightning.global_position,
		11
	)
	_expect(
		lightning.latest_proxy_action_id == 11
		and not target_warning.visible
		and not bool(target_warning.call("is_warning_active")),
		"Generic fire must clear the player target warning."
	)
	mp_game.net_enemy_target_action(
		73,
		"lightning_windup",
		player.peer_id,
		lightning.global_position,
		10
	)
	_expect(
		not target_warning.visible and lightning.latest_proxy_action_id == 11,
		"A start arriving after newer fire must not resurrect the warning."
	)

	lightning.play_multiplayer_enemy_target_action_with_context(
		&"lightning_windup_retry",
		player,
		lightning.global_position,
		12,
		0.12
	)
	var expected_retry_progress := clampf(
		(LightningSorcerer.TARGET_WARNING_RETRY_DELAY + 0.12)
			/ LIGHTNING_SORCERER_CONFIG.windup_duration,
		0.0,
		1.0
	)
	_expect(
		target_warning.visible
		and is_equal_approx(
			float(target_warning.call("get_warning_progress")),
			expected_retry_progress
		),
		"Retry must recover a dropped player start including measured network age."
	)
	mp_game.net_enemy_action(
		73,
		"cancel",
		Vector2.LEFT,
		lightning.global_position,
		13
	)
	_expect(
		not target_warning.visible and lightning.latest_proxy_action_id == 13,
		"Generic cancel must clear a retry-recovered player warning."
	)

	var plant_offset := Vector2(38.0, -14.0)
	var authoritative_plant_caster_position := (
		lightning.global_position + Vector2(23.0, -9.0)
	)
	var expected_plant_position := (
		authoritative_plant_caster_position + plant_offset
	).round()
	mp_game.net_enemy_action(
		73,
		"lightning_plant_windup",
		plant_offset,
		authoritative_plant_caster_position,
		14
	)
	_expect(
		target_warning.visible
		and target_warning.global_position.is_equal_approx(
			expected_plant_position
		)
		and lightning.latest_proxy_action_id == 14,
		"Plant warning must decode the generic action direction as a world-space offset."
	)
	lightning.call("_process", 0.18)
	var plant_progress_before_retry := float(
		target_warning.call("get_warning_progress")
	)
	mp_game.net_enemy_action(
		73,
		"lightning_plant_windup_retry",
		plant_offset,
		authoritative_plant_caster_position,
		14
	)
	_expect(
		float(target_warning.call("get_warning_progress"))
			>= plant_progress_before_retry
		and lightning.latest_proxy_action_id == 14,
		"Same-id plant retry must share ordering with player and generic actions without resetting progress."
	)
	mp_game.net_enemy_action(
		73,
		"cancel",
		Vector2.RIGHT,
		lightning.global_position,
		15
	)
	_expect(not target_warning.visible, "Generic cancel must clear a plant warning.")

	mp_game.net_enemy_target_action(
		73,
		"lightning_windup",
		player.peer_id,
		lightning.global_position,
		16
	)
	lightning.call("_expire_proxy_windup", 16)
	_expect(
		not target_warning.visible
		and not lightning.is_processing()
		and lightning.latest_proxy_action_id == 16,
		"Proxy timeout must clear the warning and return the dormant marker path without rewinding ordering."
	)
	lightning.play_multiplayer_enemy_target_action(
		&"lightning_windup_retry",
		player,
		16
	)
	_expect(
		not target_warning.visible,
		"A same-id retry arriving after timeout must not revive an expired warning."
	)

	lightning.play_multiplayer_enemy_action(
		&"lightning_plant_windup",
		plant_offset,
		17
	)
	_expect(target_warning.visible, "Death cleanup fixture must start a warning first.")
	lightning.play_multiplayer_death_sequence()
	var ordering_after_death := lightning.latest_proxy_action_id
	lightning.play_multiplayer_enemy_target_action(
		&"lightning_windup",
		player,
		ordering_after_death + 1
	)
	_expect(
		lightning.is_dead
		and not target_warning.visible
		and lightning.latest_proxy_action_id == ordering_after_death,
		"Proxy death must clear the marker and reject even newer late starts."
	)

	mp_game.free()
	runtime.free()
	net_manager.free()
	current_scene = null
	fixture_root.free()


func _attach_enemy_coordinator(
	mp_game: Node,
	runtime: CombatRuntimeBase,
	net_manager: NetManagerStore
) -> MpEnemyCoordinator:
	var session_coordinator := MpSessionCoordinator.new()
	session_coordinator.name = "SessionCoordinator"
	mp_game.add_child(session_coordinator)
	mp_game.set("session_coordinator", session_coordinator)
	session_coordinator.bind_transport_dependencies(net_manager)
	session_coordinator.bind_runtime(runtime)

	var gameplay_gateway := MultiplayerGameplayGateway.new()
	gameplay_gateway.name = "MultiplayerGameplayGateway"
	runtime.add_child(gameplay_gateway)
	gameplay_gateway.bind_runtime(runtime)

	var coordinator := MpEnemyCoordinator.new()
	coordinator.name = "EnemyCoordinator"
	mp_game.add_child(coordinator)
	mp_game.set("enemy_coordinator", coordinator)
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	coordinator.bind_runtime(runtime)
	coordinator.bind_lifecycle_dependencies(
		net_manager,
		gameplay_gateway,
		Callable(mp_game, "_get_net_time")
	)
	coordinator.lifecycle_rpc_broadcast_requested.connect(
		Callable(mp_game, "_on_enemy_lifecycle_rpc_broadcast_requested")
	)
	return coordinator


func _test_pre_spawn_action_buffer_and_snapshot_decoupling() -> void:
	var fixture_root := Node2D.new()
	fixture_root.name = "LightningPendingActionFixture"
	root.add_child(fixture_root)
	current_scene = fixture_root

	var runtime := LightningVfxRuntime.new()
	var net_manager := TestNetManager.new()
	var mp_game := MP_GAME_SCRIPT.new()
	mp_game.set("net_manager", net_manager)
	mp_game.set("game", runtime)
	var enemy_coordinator := _attach_enemy_coordinator(
		mp_game,
		runtime,
		net_manager
	)
	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "Pending-action fixture must instantiate a player.")
	if player == null:
		mp_game.free()
		runtime.free()
		net_manager.free()
		current_scene = null
		fixture_root.free()
		return
	fixture_root.add_child(player)
	player.peer_id = 17
	player.global_position = Vector2(120.0, 80.0)
	runtime.players_by_peer_id[player.peer_id] = player

	var synchronized_host_time := float(mp_game.call("_get_net_time"))
	mp_game.call(
		"_map_host_timestamp_to_client_time",
		synchronized_host_time,
		true
	)
	var retry_net_id := 401
	mp_game.net_enemy_target_action(
		retry_net_id,
		"lightning_windup",
		player.peer_id,
		Vector2(20.0, 30.0),
		20,
		synchronized_host_time - 0.08
	)
	mp_game.net_enemy_target_action(
		retry_net_id,
		"lightning_windup_retry",
		player.peer_id,
		Vector2(24.0, 34.0),
		20,
		synchronized_host_time - 0.02
	)
	var pending_actions := enemy_coordinator.pending_enemy_actions
	var retry_record := pending_actions.get(retry_net_id, {}) as Dictionary
	_expect(
		pending_actions.size() == 1
		and StringName(retry_record.get("action_name", &""))
			== &"lightning_windup_retry"
		and int(retry_record.get("action_id", 0)) == 20,
		"A same-id pre-spawn retry with the later Host timestamp must replace the start in O(1) storage."
	)
	var retry_lightning := _register_lightning_proxy(
		fixture_root,
		mp_game,
		player,
		retry_net_id
	)
	_expect(retry_lightning != null, "Retry fixture must register a lightning proxy.")
	if retry_lightning != null:
		var retry_warning := retry_lightning.get_node("TargetWarning") as Node2D
		_expect(
			pending_actions.is_empty()
			and retry_lightning.latest_proxy_action_id == 20
			and retry_warning.visible
			and float(retry_warning.call("get_warning_progress"))
				>= LightningSorcerer.TARGET_WARNING_RETRY_DELAY
					/ LIGHTNING_SORCERER_CONFIG.windup_duration,
			"Proxy registration must consume the newest retry and preserve its elapsed warning progress."
		)

	var cancel_net_id := 402
	mp_game.net_enemy_target_action(
		cancel_net_id,
		"lightning_windup",
		player.peer_id,
		Vector2.ZERO,
		30,
		synchronized_host_time
	)
	mp_game.net_enemy_action(
		cancel_net_id,
		"cancel",
		Vector2.RIGHT,
		Vector2.ZERO,
		31,
		synchronized_host_time + 0.01
	)
	var cancel_record := pending_actions.get(cancel_net_id, {}) as Dictionary
	_expect(
		pending_actions.size() == 1
		and int(cancel_record.get("kind", -1))
			== MpEnemyCoordinator.CLIENT_ENEMY_ACTION_KIND_GENERIC
		and StringName(cancel_record.get("action_name", &"")) == &"cancel",
		"Target starts and generic terminal/cancel actions must share one sequence buffer; the newer cancel wins."
	)
	var cancel_lightning := _register_lightning_proxy(
		fixture_root,
		mp_game,
		player,
		cancel_net_id
	)
	if cancel_lightning != null:
		var cancel_warning := cancel_lightning.get_node("TargetWarning") as Node2D
		_expect(
			cancel_lightning.latest_proxy_action_id == 31
			and not cancel_warning.visible,
			"A buffered generic cancel must not replay the older target warning after spawn."
		)

	if retry_lightning != null:
		mp_game.net_enemy_action(
			retry_net_id,
			"cancel",
			Vector2.RIGHT,
			retry_lightning.global_position,
			21,
			synchronized_host_time
		)
		var interp := enemy_coordinator.call("_create_interpolator") as NetInterpolator
		var mapped_action_time := float(mp_game.call(
			"_map_host_timestamp_to_client_time",
			synchronized_host_time,
			false
		))
		interp.push_snapshot(
			mapped_action_time + 0.1,
			Vector2(900.0, 700.0),
			Vector2.ZERO
		)
		var interpolators := enemy_coordinator.enemy_interpolators
		interpolators[retry_net_id] = interp
		var proxy_position_before_action := retry_lightning.global_position
		mp_game.net_enemy_target_action(
			retry_net_id,
			"lightning_windup",
			player.peer_id,
			Vector2(600.0, 500.0),
			22,
			synchronized_host_time
		)
		var reordered_warning := retry_lightning.get_node("TargetWarning") as Node2D
		_expect(
			retry_lightning.latest_proxy_action_id == 22
			and reordered_warning.visible
			and retry_lightning.global_position.is_equal_approx(
				proxy_position_before_action
			)
			and is_equal_approx(
				interp.get_latest_timestamp(),
				mapped_action_time + 0.1
			),
			"A snapshot 100 ms ahead may reject the old position sample, but must still deliver the legal action."
		)

	var expired_net_id := 403
	mp_game.net_enemy_target_action(
		expired_net_id,
		"lightning_windup",
		player.peer_id,
		Vector2.ZERO,
		40,
		-1.0
	)
	var expired_record := pending_actions.get(expired_net_id, {}) as Dictionary
	expired_record["received_at"] = (
		float(mp_game.call("_get_net_time"))
		- MpEnemyCoordinator.CLIENT_PENDING_ENEMY_ACTION_MAX_AGE_SECONDS
		- 0.1
	)
	pending_actions[expired_net_id] = expired_record
	var expired_lightning := _register_lightning_proxy(
		fixture_root,
		mp_game,
		player,
		expired_net_id
	)
	if expired_lightning != null:
		var expired_warning := expired_lightning.get_node("TargetWarning") as Node2D
		_expect(
			not pending_actions.has(expired_net_id)
			and expired_lightning.latest_proxy_action_id == 0
			and not expired_warning.visible,
			"Expired pre-spawn actions must be consumed as cleanup only and never resurrect a warning."
		)

	var terminal_net_id := 404
	mp_game.net_enemy_target_action(
		terminal_net_id,
		"lightning_windup",
		player.peer_id,
		Vector2.ZERO,
		50,
		synchronized_host_time
	)
	mp_game.net_enemy_terminal(
		terminal_net_id,
		2,
		Vector2.ZERO
	)
	mp_game.net_enemy_target_action(
		terminal_net_id,
		"lightning_windup_retry",
		player.peer_id,
		Vector2.ZERO,
		50,
		synchronized_host_time + 0.1
	)
	var terminal_ids := enemy_coordinator.client_terminal_enemy_ids
	_expect(
		not pending_actions.has(terminal_net_id)
		and terminal_ids.has(terminal_net_id),
		"Reliable terminal cleanup must reject a delayed CH7 retry instead of rebuilding pending state."
	)

	enemy_coordinator.clear_pending_enemy_actions()
	enemy_coordinator.clear_client_terminal_markers()
	var pressure_start_usec := Time.get_ticks_usec()
	var pressure_count := 10000
	var pressure_base_id := 100000
	for index in range(pressure_count):
		mp_game.net_enemy_action(
			pressure_base_id + index,
			"cancel",
			Vector2.RIGHT,
			Vector2.ZERO,
			1,
			-1.0
		)
	var pressure_elapsed_ms := (
		float(Time.get_ticks_usec() - pressure_start_usec) / 1000.0
	)
	var action_capacity := int(
		MpEnemyCoordinator.CLIENT_PENDING_ENEMY_ACTION_MAX_ENTRIES
	)
	_expect(
		pending_actions.size() == action_capacity
		and (enemy_coordinator.get("_pending_enemy_action_previous_ids") as Dictionary).size()
			== action_capacity
		and (enemy_coordinator.get("_pending_enemy_action_next_ids") as Dictionary).size()
			== action_capacity
		and int(enemy_coordinator.get("_pending_enemy_action_oldest_id"))
			== pressure_base_id + pressure_count - action_capacity
		and int(enemy_coordinator.get("_pending_enemy_action_newest_id"))
			== pressure_base_id + pressure_count - 1,
		"10k unknown ids must retain exactly the bounded newest FIFO window with coherent O(1) links."
	)
	_expect(
		pressure_elapsed_ms < 2000.0,
		"10k unknown-id buffering exceeded a generous 2 s smoke-test budget."
	)
	print("LIGHTNING_PENDING_ACTION_10K_MS=%.3f" % pressure_elapsed_ms)
	enemy_coordinator.clear_pending_enemy_actions()
	_expect(
		pending_actions.is_empty()
		and (enemy_coordinator.get("_pending_enemy_action_previous_ids") as Dictionary).is_empty()
		and (enemy_coordinator.get("_pending_enemy_action_next_ids") as Dictionary).is_empty()
		and int(enemy_coordinator.get("_pending_enemy_action_oldest_id")) == 0
		and int(enemy_coordinator.get("_pending_enemy_action_newest_id")) == 0,
		"Pending-action cleanup must reset records, links and endpoints together."
	)

	for index in range(10000):
		enemy_coordinator.mark_client_terminal(pressure_base_id + index)
	var terminal_capacity := int(
		MpEnemyCoordinator.CLIENT_TERMINAL_ENEMY_TOMBSTONE_MAX_ENTRIES
	)
	_expect(
		terminal_ids.size() == terminal_capacity
		and int(enemy_coordinator.get("_client_terminal_enemy_oldest_id"))
			== pressure_base_id + 10000 - terminal_capacity
		and int(enemy_coordinator.get("_client_terminal_enemy_newest_id"))
			== pressure_base_id + 9999,
		"Terminal tombstones must also remain bounded under a 10k lifecycle burst."
	)
	enemy_coordinator.clear_client_terminal_markers()

	mp_game.net_enemy_action(0, "cancel", Vector2.RIGHT, Vector2.ZERO, 1, -1.0)
	mp_game.net_enemy_action(1, "cancel", Vector2(INF, 0.0), Vector2.ZERO, 1, -1.0)
	mp_game.net_enemy_action(2, "cancel", Vector2.RIGHT, Vector2(NAN, 0.0), 1, -1.0)
	mp_game.net_enemy_target_action(3, "lightning_windup", 0, Vector2.ZERO, 1, -1.0)
	mp_game.net_enemy_target_action(4, "lightning_windup", 17, Vector2.ZERO, 1, NAN)
	_expect(
		pending_actions.is_empty(),
		"Malformed and non-finite fault-injection payloads must not enter the bounded buffer."
	)

	var source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/enemy/mp_enemy_coordinator.gd"
	)
	var spawn_body := _extract_function_body(source, "func receive_enemy_spawn(")
	var publish_body := _extract_function_body(
		source,
		"func _publish_prepared_client_spawns("
	)
	var boss_body := _extract_function_body(source, "func register_client_enemy(")
	_expect(
		spawn_body.contains("_commit_prepared_client_spawns([prepared])")
		and publish_body.contains("_take_live_pending_enemy_action(")
		and publish_body.contains("_deliver_action_record(")
		and boss_body.contains("consume_pending_enemy_action(net_id, current_time)"),
		"Normal enemies and bosses must both consume pending actions immediately after proxy registration."
	)

	mp_game.free()
	runtime.free()
	net_manager.free()
	current_scene = null
	fixture_root.free()


func _register_lightning_proxy(
	fixture_root: Node2D,
	mp_game: Node,
	player: Player,
	net_id: int
) -> LightningSorcerer:
	var lightning := LIGHTNING_SORCERER_SCENE.instantiate() as LightningSorcerer
	if lightning == null:
		return null
	fixture_root.add_child(lightning)
	lightning.global_position = Vector2(16.0, 24.0)
	lightning.setup(LIGHTNING_SORCERER_CONFIG, player)
	lightning.configure_multiplayer_proxy()
	lightning.set_meta("net_id", net_id)
	var enemy_coordinator := mp_game.get("enemy_coordinator") as MpEnemyCoordinator
	enemy_coordinator.register_client_enemy(
		net_id,
		lightning,
		float(mp_game.call("_get_net_time"))
	)
	return lightning


func _test_client_validation_and_visual_only_contract() -> void:
	var mp_game := MP_GAME_SCRIPT.new()
	var net_manager := TestNetManager.new()
	var runtime := LightningVfxRuntime.new()
	mp_game.set("net_manager", net_manager)
	mp_game.set("game", runtime)
	_attach_enemy_coordinator(mp_game, runtime, net_manager)
	var synchronized_host_time := float(mp_game.call("_get_net_time"))
	mp_game.call(
		"_map_host_timestamp_to_client_time",
		synchronized_host_time,
		true
	)
	var mapped_action_time := float(mp_game.call(
		"_map_host_timestamp_to_client_time",
		synchronized_host_time - 0.12,
		false
	))
	var measured_action_age := maxf(
		float(mp_game.call("_get_net_time")) - mapped_action_time,
		0.0
	)
	_expect(
		measured_action_age >= 0.1 and measured_action_age <= 0.25,
		"Enemy action context must convert the synchronized host timestamp into client-side elapsed time."
	)

	var two_points := _make_points(2)
	var six_points := _make_points(6)
	mp_game.net_enemy_lightning_chain(two_points)
	mp_game.net_enemy_lightning_chain(six_points)
	_expect(
		runtime.played_chains.size() == 2
		and runtime.played_chains[0] == two_points
		and runtime.played_chains[1] == six_points,
		"Client must accept only the inclusive 2..6-point visual payload range."
	)

	mp_game.net_enemy_lightning_chain(PackedVector2Array())
	mp_game.net_enemy_lightning_chain(_make_points(1))
	mp_game.net_enemy_lightning_chain(_make_points(7))
	mp_game.net_enemy_lightning_chain(PackedVector2Array([Vector2(NAN, 0.0)]))
	mp_game.net_enemy_lightning_chain(PackedVector2Array([Vector2(0.0, -INF)]))
	_expect(
		runtime.played_chains.size() == 2,
		"Client must drop out-of-range arrays plus NaN and infinite coordinates."
	)

	var source := FileAccess.get_file_as_string(MP_GAME_PATH)
	var rpc_body := _extract_function_body(
		source,
		"func net_enemy_lightning_chain("
	)
	var enemy_coordinator_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/enemy/mp_enemy_coordinator.gd"
	)
	var lightning_receiver_body := _extract_function_body(
		enemy_coordinator_source,
		"func receive_enemy_lightning_chain("
	)
	var lightning_receive_path := rpc_body + lightning_receiver_body
	_expect(
		not rpc_body.is_empty()
		and rpc_body.contains("enemy_coordinator.receive_enemy_lightning_chain(points)")
		and lightning_receiver_body.contains("play_lightning_sorcerer_chain_vfx")
		and not lightning_receive_path.contains("find_nearest")
		and not lightning_receive_path.contains("take_damage")
		and not lightning_receive_path.contains("request_multiplayer")
		and not lightning_receive_path.contains("apply_authoritative"),
		"Client RPC must replay pure VFX without target selection or damage execution."
	)

	var target_action_body := _extract_function_body(
		source,
		"func net_enemy_target_action("
	)
	var generic_action_body := _extract_function_body(
		source,
		"func net_enemy_action("
	)
	var lightning_source := FileAccess.get_file_as_string(
		LIGHTNING_SORCERER_PATH
	)
	var proxy_target_body := _extract_function_body(
		lightning_source,
		"func play_multiplayer_enemy_target_action("
	)
	var proxy_generic_body := _extract_function_body(
		lightning_source,
		"func play_multiplayer_enemy_action("
	)
	var proxy_target_context_body := _extract_function_body(
		lightning_source,
		"func play_multiplayer_enemy_target_action_with_context("
	)
	var proxy_generic_context_body := _extract_function_body(
		lightning_source,
		"func play_multiplayer_enemy_action_with_context("
	)
	var client_visual_bodies := (
		target_action_body
		+ generic_action_body
		+ proxy_target_body
		+ proxy_generic_body
		+ proxy_target_context_body
		+ proxy_generic_context_body
	)
	_expect(
		not target_action_body.is_empty()
		and not generic_action_body.is_empty()
		and not proxy_target_body.is_empty()
		and not proxy_generic_body.is_empty()
		and not proxy_target_context_body.is_empty()
		and not proxy_generic_context_body.is_empty()
		and not client_visual_bodies.contains("find_nearest")
		and not client_visual_bodies.contains("_query_runtime_attack_target")
		and not client_visual_bodies.contains("_resolve_chain_hits")
		and not client_visual_bodies.contains("_apply_chain_damage")
		and not client_visual_bodies.contains("take_damage")
		and not client_visual_bodies.contains("receive_damage")
		and not client_visual_bodies.contains("request_multiplayer_player_damage"),
		"Target-warning receive paths must remain visual-only and never reacquire targets or apply damage on clients."
	)
	_expect(
		not source.contains("net_enemy_lightning_target_warning")
		and lightning_source.contains("_broadcast_enemy_target_action(")
		and lightning_source.contains("PLANT_WINDUP_ACTION")
		and lightning_source.contains("_broadcast_enemy_action("),
		"Lightning target warnings must reuse the existing target/generic action protocol instead of adding an RPC surface."
	)
	mp_game.free()
	runtime.free()
	net_manager.free()


func _make_points(count: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for point_index in range(count):
		points.append(Vector2(point_index * 8.0, point_index * -4.0))
	return points


func _extract_function_body(source: String, signature: String) -> String:
	var function_start := source.find(signature)
	if function_start < 0:
		return ""
	var function_end := source.find("\n\nfunc ", function_start)
	if function_end < 0:
		function_end = source.length()
	return source.substr(function_start, function_end - function_start)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
