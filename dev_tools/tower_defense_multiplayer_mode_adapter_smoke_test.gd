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
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const EXPECTED_TOWER_SCENE_UID := "uid://dy51i4e27gaoi"
const EXPECTED_ADAPTER_SCENE_UID := "uid://crap4mx7t2k6r"
const EXPECTED_MP_GAME_RPC_COUNT := 126

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
		NET_CONSTANTS.PROTOCOL_VERSION == 59
		and GameModeCatalog.MODE_TOWER_DEFENSE == 1,
		"塔防 wire=1 与协议 v59 必须保持冻结。"
	)
	var mp_game_script := load(MP_GAME_SOURCE_PATH) as Script
	_expect(mp_game_script != null, "MpGame 脚本必须可加载。")
	if mp_game_script != null:
		_expect(
			mp_game_script.get_rpc_config().size() == EXPECTED_MP_GAME_RPC_COUNT,
			"MpGame 有效 RPC 数量必须保持 126。"
		)


func _test_host_binding_and_authority_bridges() -> void:
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
		and adapter.is_tower_bound(),
		"Host ready 后必须完成静态节点复用与全部强类型依赖注入。"
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
		and not adapter.accepts_game_mode_id(GameModeCatalog.MODE_STANDARD),
		"塔防 Adapter 只能接受塔防及其五个稳定测试场 wire。"
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

	game.countdown_seconds = 7
	adapter.publish_flow_state(CombatFlowState.State.PRE_WAVE)
	game.home_defense_coordinator.base_health_changed.emit(83, 100, 4)
	game.enemy_coordinator.wave_progress_changed.emit(3, 5, 1, 6, 9)
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

	await _cleanup_game(game)


func _test_client_remote_state_and_authority_gates() -> void:
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
		game.current_wave_index == 3
		and game.current_wave_defeated == 3
		and game.current_wave_escaped == 1
		and game.current_wave_resolved == 4
		and game.current_wave_total == 8
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
