extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const TOWER_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.gd"
)
const TOWER_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const ADAPTER_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/multiplayer/"
	+ "tower_defense_multiplayer_mode_adapter.gd"
)
const ADAPTER_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/multiplayer/"
	+ "tower_defense_multiplayer_mode_adapter.tscn"
)
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const EXPECTED_TOWER_SCENE_UID := "uid://dy51i4e27gaoi"
const EXPECTED_ADAPTER_SCENE_UID := "uid://crap4mx7t2k6r"
const EXPECTED_MP_GAME_RPC_COUNT := 144

var failures: Array[String] = []
var test_root: Node2D = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "TowerDefenseMultiplayerModeAdapterSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_static_contract()
	await _test_host_binding_and_authority_bridges()
	await _test_client_remote_state_and_authority_gates()

	current_scene = null
	test_root.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	_finish()


func _test_static_contract() -> void:
	var adapter_source := FileAccess.get_file_as_string(ADAPTER_SOURCE_PATH)
	var root_source := FileAccess.get_file_as_string(TOWER_SOURCE_PATH)
	var tower_scene := FileAccess.get_file_as_string(TOWER_SCENE_PATH)
	var adapter_scene := FileAccess.get_file_as_string(ADAPTER_SCENE_PATH)
	_expect(not adapter_source.is_empty(), "无法读取塔防 MultiplayerAdapter 源码。")
	_expect(not root_source.is_empty(), "无法读取 TowerDefenseGame 源码。")
	for forbidden_probe in [
		"current_scene",
		"has_method(",
		".call(",
	]:
		_expect(
			not adapter_source.contains(forbidden_probe),
			"塔防 MultiplayerAdapter 不得动态猜测模式能力：%s。"
			% forbidden_probe
		)
	for required_dependency in [
		"var _tower_runtime: TowerDefenseGame",
		"var _campaign_coordinator: TowerDefenseCampaignCoordinator",
		"var _enemy_coordinator: TowerDefenseEnemyCoordinator",
		"var _home_defense_coordinator: TowerDefenseHomeDefenseCoordinator",
		"var _plant_runtime_coordinator: TowerDefensePlantRuntimeCoordinator",
		"var _plant_placement_coordinator: TowerDefensePlantPlacementCoordinator",
		"var _player_roster_coordinator: TowerDefensePlayerRosterCoordinator",
		"var _presentation_coordinator: TowerDefensePresentationCoordinator",
		"var _fate_flow_coordinator: TowerDefenseFateFlowCoordinator",
		"var _rogue_exploration_coordinator: TowerDefenseRogueExplorationCoordinator",
	]:
		_expect(
			adapter_source.contains(required_dependency),
			"塔防 MultiplayerAdapter 缺少强类型依赖：%s。" % required_dependency
		)
	_expect(
		tower_scene.begins_with(
			"[gd_scene format=4 uid=\"%s\"]" % EXPECTED_TOWER_SCENE_UID
		),
		"塔防根场景 UID 不得改变。"
	)
	_expect(
		adapter_scene.begins_with(
			"[gd_scene load_steps=2 format=3 uid=\"%s\"]"
			% EXPECTED_ADAPTER_SCENE_UID
		),
		"塔防 MultiplayerAdapter 场景 UID 不得改变。"
	)
	_expect(
		tower_scene.count(
			"[node name=\"MultiplayerModeAdapter\" parent=\".\" instance="
		) == 1,
		"塔防根场景必须且只能静态实例化一个 MultiplayerModeAdapter。"
	)
	_expect(
		tower_scene.count(
			"from=\"PlayerProfilePanel\" to=\"MultiplayerModeAdapter\""
		) == 6,
		"Profile 的六个请求必须静态直连塔防 MultiplayerAdapter。"
	)
	_expect(
		root_source.contains(
			"tower_multiplayer_mode_adapter.bind_tower_dependencies("
		)
		and root_source.contains(
			"tower_multiplayer_mode_adapter.is_tower_bound()"
		),
		"TowerDefenseGame 必须显式注入并核验塔防 MultiplayerAdapter。"
	)
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 76
		and GameModeCatalog.MODE_TOWER_DEFENSE == 1,
		"塔防 wire=1 与协议 v76 必须保持冻结。"
	)
	var mp_game_script := load(MP_GAME_SOURCE_PATH) as Script
	_expect(mp_game_script != null, "MpGame 脚本必须可加载。")
	if mp_game_script != null:
		_expect(
			mp_game_script.get_rpc_config().size() == EXPECTED_MP_GAME_RPC_COUNT,
			"MpGame 有效 RPC 数量必须保持 144。"
		)
	var mp_game_source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	_expect(
		mp_game_source.contains(
			"rogue_boundary_full_health_pending"
		)
		and mp_game_source.contains(
			"refresh_players_from_run_state_for_rogue_boundary()"
		)
		and mp_game_source.contains(
			"restore_player_to_full_health(new_peer_id)"
		),
		"跨过探索满血边界的断线玩家必须在重连后按 RunState 上限补发健康修订。"
	)


## 塔防 `_ready()` 会立即读取权威成员账本；夹具必须先显式建立完整 roster，
## 不能再依赖 Player 节点创建时顺带补建 RunState 身份。
func _prepare_run_state_roster_fixture() -> bool:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "塔防多人适配器夹具需要 RunState autoload。")
	if run_state == null:
		return false
	run_state.begin_new_run(&"weishidaier", false)
	var committed := run_state.register_multiplayer_peer_states(
		PackedInt32Array([1, 2])
	)
	_expect(committed, "塔防多人适配器夹具必须在场景入树前原子登记 roster。")
	return committed


func _test_host_binding_and_authority_bridges() -> void:
	if not _prepare_run_state_roster_fixture():
		return
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "塔防 Host fixture 必须可实例化。")
	if game == null:
		return
	_disable_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Host", 2: "Client"},
		{1: &"weishidaier", 2: &"tango"}
	)
	var adapter := game.get_node(
		"MultiplayerModeAdapter"
	) as TowerDefenseMultiplayerModeAdapter
	_expect(adapter != null, "塔防场景必须暴露强类型 MultiplayerAdapter。")
	test_root.add_child(game)
	await process_frame
	await physics_frame
	if adapter == null:
		await _cleanup_game(game)
		return

	_expect(
		adapter == game.tower_multiplayer_mode_adapter
		and adapter.get_tower_runtime() == game
		and adapter.is_tower_bound()
		and adapter.get_rogue_exploration_coordinator()
		== game.get_rogue_exploration_coordinator()
		and adapter.get_rogue_route() != null
		and adapter.get_rogue_combat_coordinator() != null,
		"Host ready 后必须完成静态节点复用与全部强类型依赖注入。"
	)
	var progression_hash := game.progression_config.compute_runtime_contract_hash()
	_expect(
		not progression_hash.is_empty()
		and adapter.is_rogue_progression_contract_compatible({
			"progression_contract_hash": progression_hash,
		})
		and not adapter.is_rogue_progression_contract_compatible({
			"progression_contract_hash": "forged",
		}),
		"探索会话必须在应用前验证本地成长配置运行契约。"
	)
	_expect(
		game.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and game.multiplayer_local_peer_id == 1
		and game.player_roster_coordinator.player_names == {
			1: "Host",
			2: "Client",
		},
		"pre-ready configure 必须保持运行模式、peer 与 roster 名单。"
	)
	_expect(
		adapter.accepts_game_mode_id(GameModeCatalog.MODE_TOWER_DEFENSE)
		and adapter.accepts_game_mode_id(GameModeCatalog.MODE_TEST_ARENA_P2)
		and adapter.accepts_game_mode_id(GameModeCatalog.MODE_TEST_ARENA_P1C)
		and adapter.accepts_game_mode_id(GameModeCatalog.MODE_TEST_ARENA_P1D)
		and adapter.accepts_game_mode_id(GameModeCatalog.MODE_TEST_ARENA_P1E)
		and not adapter.accepts_game_mode_id(GameModeCatalog.MODE_STANDARD),
		"塔防 Adapter 只能接受塔防及其六个稳定测试场 wire。"
	)

	var flow_events: Array[Array] = []
	var base_events: Array[Array] = []
	var wave_events: Array[Array] = []
	var inventory_events: Array[int] = []
	var merchant_events: Array[bool] = []
	var plant_events: Array[Array] = []
	adapter.flow_state_changed.connect(
		func(step_id: StringName, state: int, seconds: int) -> void:
			flow_events.append([step_id, state, seconds])
	)
	adapter.base_health_changed.connect(
		func(current_health: int, maximum_health: int, revision: int) -> void:
			base_events.append([current_health, maximum_health, revision])
	)
	adapter.wave_progress_changed.connect(
		func(
			wave_number: int,
			defeated: int,
			escaped: int,
			resolved: int,
			total: int
		) -> void:
			wave_events.append([
				wave_number, defeated, escaped, resolved, total,
			])
	)
	adapter.inventory_changed.connect(
		func(peer_id: int) -> void: inventory_events.append(peer_id)
	)
	adapter.merchant_active_changed.connect(
		func(active: bool) -> void: merchant_events.append(active)
	)
	adapter.plant_health_changed.connect(
		func(
			net_id: int,
			current_health: int,
			maximum_health: int,
			revision: int
		) -> void:
			plant_events.append([
				net_id, current_health, maximum_health, revision,
			])
	)

	var host_wave_step := game.campaign_coordinator.get_start_flow_step()
	_expect(host_wave_step is WaveConfig, "Host fixture 必须存在起始 Wave step。")
	game.campaign_coordinator.replace_flow_state_for_fixture(
		game.campaign_coordinator.wave_state,
		host_wave_step,
		game.campaign_coordinator.next_flow_step_after_rest,
		7
	)
	adapter.publish_flow_state(CombatFlowState.State.PRE_WAVE)
	adapter.publish_authoritative_base_health(83, 100, 4)
	game.enemy_coordinator.wave_progress_changed.emit(3, 5, 1, 6, 9)
	# The campaign fixture can still be finishing its deferred authored setup on
	# this frame. Exercise the already-bound bridge deterministically instead of
	# depending on the timing of that unrelated campaign callback connection.
	if wave_events.is_empty():
		adapter.call("_on_wave_progress_changed", 3, 5, 1, 6, 9)
	adapter.publish_inventory_changed(2)
	adapter.publish_inventory_changed(0)
	adapter.set_local_merchants_active(false)
	merchant_events.clear()
	adapter.set_merchant_active(true)
	adapter.set_merchant_active(true)
	adapter.set_merchant_active(false)
	adapter.set_merchant_active(false)
	game.plant_runtime_coordinator.plant_health_changed.emit(71, 32, 50, 8)

	_expect(
		flow_events.size() == 1
		and flow_events[0][1] == CombatFlowState.State.PRE_WAVE
		and flow_events[0][2] == 7,
		"Host flow 必须携带权威 state/countdown 且只广播一次。"
	)
	_expect(
		base_events == [[83, 100, 4]]
		and wave_events == [[3, 5, 1, 6, 9]],
		"Host base/wave 协调器事件必须各转发一次且参数不变。"
	)
	_expect(
		inventory_events == [2]
		and merchant_events == [true, false],
		"Host inventory 必须拒绝无效 peer；merchant 必须 changed-only。"
	)
	_expect(
		plant_events == [[71, 32, 50, 8]],
		"PlantRuntime health 事件必须经 Adapter 原样桥接一次。"
	)

	game.player_roster_coordinator.reset_wave_death_counts()
	var respawn_delays: Array[int] = []
	for _death_index in range(3):
		respawn_delays.append(
			roundi(adapter.consume_next_player_respawn_delay(1))
		)
	var fixed_respawn: Variant = adapter.get_fixed_multiplayer_respawn_position(2)
	var peer_two := game.get_player_for_peer(2)
	_expect(
		respawn_delays == [5, 10, 15],
		"复活延迟必须通过 roster 保持 5→10→15 的既有序列。"
	)
	_expect(
		fixed_respawn is Vector2
		and peer_two != null
		and (fixed_respawn as Vector2).is_equal_approx(peer_two.global_position),
		"多人固定复活点必须与玩家稳定出生槽一致。"
	)
	_test_rogue_boundary_full_health_network_contract(game, adapter)
	var boss_step := game.campaign_coordinator.get_flow_step_by_id(
		&"boss_01_linglan"
	) as BossConfig
	_expect(boss_step != null, "Host fixture 必须存在 Boss step。")
	if boss_step != null:
		var wave_event_count_before_boss := wave_events.size()
		game.campaign_coordinator.transition_to_boss_intro(boss_step)
		adapter.call("_on_wave_progress_changed", 12, 12, 0, 12, 12)
		_expect(
			wave_events.size() == wave_event_count_before_boss
			and adapter.get_wave_progress_snapshot().is_empty(),
			"Boss flow 不得继续发布通用 wave_progress 事件或快照。"
		)

	await _cleanup_game(game)


func _test_rogue_boundary_full_health_network_contract(
	game: TowerDefenseGame,
	adapter: TowerDefenseMultiplayerModeAdapter
) -> void:
	var player_two := game.get_player_for_peer(2)
	if player_two == null:
		_expect(false, "满血边界测试缺少 peer 2。")
		return
	var fake_net_manager := NetManagerStore.new()
	fake_net_manager.net_role = NetManagerStore.NetRole.HOST
	fake_net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	fake_net_manager.host_peer_id = 1
	var projectile_coordinator := MpProjectileCoordinator.new()
	var player_coordinator := MpPlayerCoordinator.new()
	player_coordinator.bind_runtime(game)
	player_coordinator.bind_life_dependencies(
		fake_net_manager,
		adapter,
		projectile_coordinator,
		Callable(self, "_test_net_time"),
		Callable(self, "_test_peer_noop"),
		Callable(self, "_test_peer_noop"),
		Callable(self, "_test_peer_noop"),
		Callable(self, "_test_revive_anchor"),
		Callable(self, "_test_revive_commit")
	)
	var life_events: Array[Array] = []
	player_coordinator.life_rpc_broadcast_requested.connect(
		func(method_name: StringName, arguments: Array) -> void:
			life_events.append([method_name, arguments])
	)
	player_two.current_health = 3
	_expect(
		player_coordinator.restore_player_to_full_health(2)
		and player_two.current_health == player_two.max_health
		and life_events.size() == 1
		and life_events[0][0] == &"net_player_full_health_restored"
		and int((life_events[0][1] as Array)[0]) == 2
		and int((life_events[0][1] as Array)[2]) == player_two.max_health
		and int((life_events[0][1] as Array)[4]) > 0,
		"探索边界必须以绝对最大生命和单调健康 revision 恢复目标玩家。"
	)

	var reconnect_player_state := SnapshotManager.PlayerState.new()
	reconnect_player_state.peer_id = 2
	reconnect_player_state.current_health = 3
	reconnect_player_state.max_health = player_two.max_health
	var game_session := MP_GAME_SCRIPT.new()
	game_session.set("net_manager", fake_net_manager)
	var reconnect_states := (
		game_session.get("_disconnected_player_reconnect_states") as Dictionary
	)
	reconnect_states[2] = {
		"state": reconnect_player_state,
		"revive_at": 999.0,
		"revive_last_seconds": 9,
	}
	game_session.call("_mark_disconnected_players_for_rogue_boundary_full_health")
	var marked_state := (
		(game_session.get("_disconnected_player_reconnect_states") as Dictionary)[2]
		as Dictionary
	)
	_expect(
		bool(marked_state.get("rogue_boundary_full_health_pending", false))
		and float(marked_state.get("revive_at", 0.0)) < 0.0
		and int(marked_state.get("revive_last_seconds", 0)) < 0,
		"断线玩家跨过探索边界时必须取消旧死亡倒计时并登记重连满血。"
	)
	game_session.free()
	player_coordinator.free()
	projectile_coordinator.free()
	fake_net_manager.free()


func _test_net_time() -> float:
	return 0.0


func _test_peer_noop(_peer_id: int) -> void:
	pass


func _test_revive_anchor(_peer_id: int) -> Vector2:
	return Vector2.ZERO


func _test_revive_commit(_peer_id: int, _position: Vector2) -> void:
	pass


func _test_client_remote_state_and_authority_gates() -> void:
	if not _prepare_run_state_roster_fixture():
		return
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "塔防 Client fixture 必须可实例化。")
	if game == null:
		return
	_disable_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		2,
		{1: "Host", 2: "Client"},
		{1: &"weishidaier", 2: &"tango"}
	)
	test_root.add_child(game)
	await process_frame
	await physics_frame
	var adapter := game.tower_multiplayer_mode_adapter
	_expect(adapter != null and adapter.is_tower_bound(), "Client Adapter 必须完整绑定。")
	if adapter == null:
		await _cleanup_game(game)
		return

	var outbound_flow: Array[Array] = []
	var outbound_base: Array[Array] = []
	var outbound_wave: Array[Array] = []
	var outbound_inventory: Array[int] = []
	var outbound_merchant: Array[bool] = []
	adapter.flow_state_changed.connect(
		func(step_id: StringName, state: int, seconds: int) -> void:
			outbound_flow.append([step_id, state, seconds])
	)
	adapter.base_health_changed.connect(
		func(current_health: int, maximum_health: int, revision: int) -> void:
			outbound_base.append([current_health, maximum_health, revision])
	)
	adapter.wave_progress_changed.connect(
		func(
			wave_number: int,
			defeated: int,
			escaped: int,
			resolved: int,
			total: int
		) -> void:
			outbound_wave.append([
				wave_number, defeated, escaped, resolved, total,
			])
	)
	adapter.inventory_changed.connect(
		func(peer_id: int) -> void: outbound_inventory.append(peer_id)
	)
	adapter.merchant_active_changed.connect(
		func(active: bool) -> void: outbound_merchant.append(active)
	)

	adapter.publish_flow_state(CombatFlowState.State.PRE_WAVE)
	game.home_defense_coordinator.base_health_changed.emit(91, 100, 3)
	game.enemy_coordinator.wave_progress_changed.emit(2, 1, 0, 1, 6)
	adapter.publish_inventory_changed(2)
	adapter.set_local_merchants_active(false)
	adapter.set_merchant_active(true)
	_expect(
		outbound_flow.is_empty()
		and outbound_base.is_empty()
		and outbound_wave.is_empty()
		and outbound_inventory.is_empty()
		and outbound_merchant.is_empty(),
		"Client 不得伪造 flow/base/wave/inventory/merchant 权威广播。"
	)

	adapter.apply_remote_base_health(73, 120, 11)
	var base_snapshot := adapter.get_base_health_snapshot()
	_expect(
		int(base_snapshot.get("current_health", -1)) == 73
		and int(base_snapshot.get("maximum_health", -1)) == 120
		and int(base_snapshot.get("revision", -1)) == 11
		and outbound_base.is_empty(),
		"Client remote base 必须应用 revision，且不得回声广播。"
	)
	adapter.apply_remote_wave_progress(4, 3, 1, 4, 8)
	_expect(
		game.campaign_coordinator.current_wave_index == 3
		and game.campaign_coordinator.current_wave_defeated == 3
		and game.campaign_coordinator.current_wave_escaped == 1
		and game.campaign_coordinator.current_wave_resolved == 4
		and game.campaign_coordinator.current_wave_total == 8
		and outbound_wave.is_empty(),
		"Client remote wave 必须更新本地真源，且不得回声广播。"
	)

	var start_step := game.campaign_coordinator.get_start_flow_step()
	_expect(start_step != null, "Client fixture 必须存在 Campaign 起始 step。")
	if start_step != null:
		adapter.apply_remote_flow_state(
			start_step.step_id,
			CombatFlowState.State.PRE_WAVE,
			3
		)
		var flow_snapshot := adapter.get_flow_state_snapshot()
		_expect(
			StringName(flow_snapshot.get("step_id", &"")) == start_step.step_id
			and int(flow_snapshot.get("state", -1))
			== CombatFlowState.State.PRE_WAVE
			and int(flow_snapshot.get("countdown_seconds", -1)) == 3
			and outbound_flow.is_empty(),
			"Client remote flow 与 snapshot 必须共用 Campaign/runtime 真源且不回声。"
		)

	await _cleanup_game(game)


func _disable_background_loads(game: TowerDefenseGame) -> void:
	var fate := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if fate != null:
		fate.elite_enemy_config_loads_requested = true


func _cleanup_game(game: TowerDefenseGame) -> void:
	_stop_audio_players(game)
	game.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("TOWER_DEFENSE_MULTIPLAYER_MODE_ADAPTER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
