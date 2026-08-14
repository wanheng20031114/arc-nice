extends SceneTree

const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const STANDARD_GAME_SOURCE_PATH := (
	"res://scene/game_modes/standard/standard_game.gd"
)
const STANDARD_GAME_SCENE_PATH := (
	"res://scene/game_modes/standard/standard_game.tscn"
)
const ADAPTER_SOURCE_PATH := (
	"res://scene/game_modes/standard/multiplayer/standard_multiplayer_mode_adapter.gd"
)
const ADAPTER_SCENE_PATH := (
	"res://scene/game_modes/standard/multiplayer/standard_multiplayer_mode_adapter.tscn"
)
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const EXPECTED_STANDARD_SCENE_UID := "uid://dcqarxlpbdh8y"
const EXPECTED_ADAPTER_SCENE_UID := "uid://dgn1s7k5oav2c"
const EXPECTED_MP_GAME_RPC_COUNT := 144

var failures: Array[String] = []
var test_root: Node2D = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "StandardMultiplayerModeAdapterSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_static_boundaries()
	await _test_host_wiring_order_and_authority_bridge()
	await _test_client_remote_flow_bridge()

	test_root.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("STANDARD_MULTIPLAYER_MODE_ADAPTER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_static_boundaries() -> void:
	var adapter_source := FileAccess.get_file_as_string(ADAPTER_SOURCE_PATH)
	var root_source := FileAccess.get_file_as_string(STANDARD_GAME_SOURCE_PATH)
	var standard_scene := FileAccess.get_file_as_string(STANDARD_GAME_SCENE_PATH)
	var adapter_scene := FileAccess.get_file_as_string(ADAPTER_SCENE_PATH)
	_expect(not adapter_source.is_empty(), "无法读取 Standard adapter 源码。")
	_expect(not root_source.is_empty(), "无法读取 StandardGame 源码。")
	for forbidden_dependency in [
		"StandardGame",
		"current_scene",
		"get_parent(",
		"get_node(",
		"get_node_or_null(",
		"has_method(",
		".call(",
	]:
		_expect(
			not adapter_source.contains(forbidden_dependency),
			"Standard adapter 不得反向猜测模式根：%s。" % forbidden_dependency
		)
	for migrated_implementation in [
		"func _on_multiplayer_player_died",
		"func _on_all_multiplayer_players_dead",
		"func _on_boss_flow_state_requested",
		"func _on_boss_started",
		"func apply_remote_merchant_active",
		"func apply_remote_boss_started",
		"func _on_debug_collectible_requested",
		"func _on_wave_hud_return_to_lobby_requested",
	]:
		_expect(
			not root_source.contains(migrated_implementation),
			"StandardGame 根仍保留已迁移编排：%s。" % migrated_implementation
		)
	_expect(
		root_source.count("\n") + 1 <= 1100,
		"StandardGame 本阶段应收敛到 1100 行以内。"
	)
	_expect(
		standard_scene.begins_with(
			"[gd_scene format=4 uid=\"%s\"]" % EXPECTED_STANDARD_SCENE_UID
		),
		"StandardGame 场景 UID 不得改变。"
	)
	_expect(
		adapter_scene.begins_with(
			"[gd_scene load_steps=2 format=3 uid=\"%s\"]"
			% EXPECTED_ADAPTER_SCENE_UID
		),
		"Standard adapter 场景 UID 不得改变。"
	)
	_expect(
		standard_scene.count("[node name=\"MultiplayerModeAdapter\"") == 1
		and adapter_scene.count("[node name=\"MultiplayerModeAdapter\"") == 1,
		"只能复用唯一静态 MultiplayerModeAdapter 节点。"
	)
	_expect(
		standard_scene.count(
			"from=\"PlayerProfilePanel\" to=\"MultiplayerModeAdapter\""
		) == 5,
		"Profile 五个请求必须静态直连既有 Standard adapter。"
	)
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 72
		and GameModeCatalog.MODE_STANDARD == 0,
		"Standard wire=0 与协议 v72 必须保持冻结。"
	)
	var mp_game_script := load(MP_GAME_SOURCE_PATH) as Script
	_expect(mp_game_script != null, "MpGame 脚本必须可加载。")
	if mp_game_script != null:
		_expect(
			mp_game_script.get_rpc_config().size() == EXPECTED_MP_GAME_RPC_COUNT,
			"MpGame 有效 RPC 数量必须保持 144。"
		)


func _test_host_wiring_order_and_authority_bridge() -> void:
	var game := STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame host fixture 必须可实例化。")
	if game == null:
		return
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Host", 2: "Client"},
		{1: &"weishidaier", 2: &"tango"}
	)
	_expect(
		game.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and game.multiplayer_local_peer_id == 1
		and game.player_roster_coordinator.player_names == {
			1: "Host",
			2: "Client",
		},
		"pre-ready configure 必须保持 mode→peer→merchant→roster 的结果。"
	)
	var adapter := game.standard_multiplayer_mode_adapter
	var merchant_events: Array[String] = []
	var profile_events: Array[String] = []
	var combat_events: Array[String] = []
	var return_event_count := {"value": 0}
	adapter.merchant_active_changed.connect(
		func(active: bool) -> void:
			merchant_events.append("merchant:%s" % active)
	)
	adapter.flow_state_changed.connect(
		func(_step_id: StringName, state: int, _seconds: int) -> void:
			combat_events.append("flow:%d" % state)
	)
	adapter.boss_started.connect(
		func(net_id: int, _config: BossConfig, _position: Vector2) -> void:
			combat_events.append("boss:%d" % net_id)
	)
	adapter.defeat_started.connect(
		func() -> void:
			combat_events.append("defeat")
	)
	adapter.profile_upgrade_requested.connect(
		func(stat_type: int) -> void:
			profile_events.append("upgrade:%d" % stat_type)
	)
	adapter.profile_inventory_item_use_requested.connect(
		func(slot_index: int) -> void:
			profile_events.append("use:%d" % slot_index)
	)
	adapter.profile_inventory_item_discard_requested.connect(
		func(slot_index: int) -> void:
			profile_events.append("discard:%d" % slot_index)
	)
	adapter.profile_simple_crafting_requested.connect(
		func(recipe_id: StringName, token: int) -> void:
			profile_events.append("craft:%s:%d" % [recipe_id, token])
	)
	adapter.profile_simple_crafting_cancel_requested.connect(
		func(token: int) -> void:
			profile_events.append("cancel:%d" % token)
	)
	adapter.return_to_lobby_requested.connect(
		func() -> void:
			return_event_count["value"] = int(return_event_count["value"]) + 1
	)

	test_root.add_child(game)
	await process_frame
	await physics_frame
	_expect(
		adapter == game.get_node("MultiplayerModeAdapter")
		and adapter.is_standard_bound(),
		"既有静态 Standard adapter 必须完成强类型依赖注入。"
	)
	merchant_events.clear()

	game.call("_set_merchant_active", true)
	game.call("_set_merchant_active", true)
	game.call("_set_merchant_active", false)
	game.call("_set_merchant_active", false)
	_expect(
		merchant_events == ["merchant:true", "merchant:false"],
		"商人状态必须保持 changed-only 且一次转发。"
	)

	game.player_profile_panel.multiplayer_upgrade_requested.emit(2)
	game.player_profile_panel.multiplayer_inventory_item_use_requested.emit(3)
	game.player_profile_panel.multiplayer_inventory_item_discard_requested.emit(4)
	game.player_profile_panel.multiplayer_simple_crafting_requested.emit(
		&"simple_probe",
		51
	)
	game.player_profile_panel.multiplayer_simple_crafting_cancel_requested.emit(51)
	_expect(
		profile_events == [
			"upgrade:2",
			"use:3",
			"discard:4",
			"craft:simple_probe:51",
			"cancel:51",
		],
		"Profile 请求必须保持 upgrade→use→discard→craft→cancel 顺序与参数。"
	)

	game.merchant_coordinator.record_luoxi_collectible_claim(7)
	game.player_roster_coordinator.peer_restored.emit(7, 17)
	_expect(
		game.merchant_coordinator.get_luoxi_collectible_claim_count(7) == 0
		and game.merchant_coordinator.get_luoxi_collectible_claim_count(17) == 1,
		"peer restored 必须由 adapter 原子迁移 Luoxi claim ledger。"
	)

	var boss_config := game.boss_coordinator.get_first_boss_config()
	_expect(boss_config != null, "Standard host fixture 必须有可用 BossConfig。")
	if boss_config != null:
		game.boss_coordinator.flow_state_requested.emit(
			CombatFlowState.State.BOSS_INTRO,
			boss_config,
			false
		)
		_expect(
			game.wave_state == CombatFlowState.State.BOSS_INTRO
			and game.current_flow_step == boss_config
			and game.current_wave_total == 1
			and combat_events == [
				"flow:%d" % CombatFlowState.State.BOSS_INTRO,
			],
			"Boss intro 编排必须先提交 runtime 状态，再发 flow。"
		)
		combat_events.clear()
		var enemy_config := game.boss_coordinator.get_boss_enemy_config(boss_config)
		var boss := (
			enemy_config.enemy_scene.instantiate() as LinglanBoss
			if enemy_config != null and enemy_config.enemy_scene != null
			else null
		)
		_expect(boss != null, "Boss started bridge 必须能实例化权威实体探针。")
		if boss != null:
			boss.position = Vector2(88.0, 99.0)
			game.boss_coordinator.boss_started.emit(boss, boss_config)
			var boss_net_id := int(boss.get_meta("net_id", 0))
			_expect(
				boss_net_id > 0
				and game.multiplayer_enemies_by_net_id.get(boss_net_id) == boss
				and combat_events == [
					"flow:%d" % CombatFlowState.State.BOSS_ACTIVE,
					"boss:%d" % boss_net_id,
				],
				"Boss started 必须保持注册索引→flow→boss broadcast 顺序。"
			)
			game.call("_on_boss_enemy_removed", boss.get_instance_id())
			boss.free()

	adapter.handle_return_to_lobby_requested()
	_expect(
		int(return_event_count["value"]) == 1,
		"多人返回请求必须只向会话 façade 发出一次。"
	)
	game.player_roster_coordinator.all_players_dead.emit()
	_expect(
		game.wave_state == CombatFlowState.State.DEFEAT
		and combat_events.back() == "defeat",
		"全员死亡必须由 adapter 驱动通用 defeat 入口且只走既有信号。"
	)
	# Let the frozen 0.75 s Boss re-broadcast window resolve its coroutine before
	# freeing the fixture, so the dedicated headless process exits leak-free.
	await create_timer(0.8).timeout

	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_client_remote_flow_bridge() -> void:
	var game := STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame client fixture 必须可实例化。")
	if game == null:
		return
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
	var adapter := game.standard_multiplayer_mode_adapter
	_expect(adapter != null and adapter.is_standard_bound(), "Client adapter 必须完成绑定。")
	if adapter == null:
		game.queue_free()
		await process_frame
		return

	game.merchant_coordinator.set_local_merchants_active(true)
	game.wave_state = CombatFlowState.State.PRE_WAVE
	game.state_timer.start(10.0)
	adapter.apply_remote_merchant_active(false)
	_expect(
		not game.merchant.is_active
		and not game.luoxi_merchant.is_active
		and game.state_timer.is_stopped(),
		"client merchant=false 必须先关闭本地商人，再停止准备/场间计时。"
	)

	var start_step := game.flow_graph.start_step
	adapter.apply_remote_flow_state(
		start_step.step_id,
		CombatFlowState.State.PRE_WAVE,
		3
	)
	var snapshot := adapter.get_flow_state_snapshot()
	_expect(
		StringName(snapshot.get("step_id", &"")) == start_step.step_id
		and int(snapshot.get("state", -1)) == CombatFlowState.State.PRE_WAVE
		and int(snapshot.get("countdown_seconds", -1)) == 3,
		"remote flow 与 snapshot 必须共用中性 WaveCombatRuntimeBase 真源。"
	)

	var boss_config := game.boss_coordinator.get_first_boss_config()
	_expect(boss_config != null, "Standard client fixture 必须有可用 BossConfig。")
	if boss_config != null:
		adapter.apply_remote_boss_started(0, boss_config, Vector2(33.0, 44.0))
		_expect(
			game.current_flow_step == boss_config
			and game.wave_state == CombatFlowState.State.BOSS_ACTIVE
			and game.boss_coordinator.active_boss_config == boss_config,
			"remote boss 必须按 current step→coordinator→remote flow 顺序应用。"
		)

	adapter.apply_remote_defeat()
	_expect(
		game.wave_state == CombatFlowState.State.DEFEAT,
		"remote defeat 必须委托中性 WaveCombatRuntimeBase 终局入口。"
	)
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _stop_audio_players(root_node: Node) -> void:
	for child in root_node.get_children():
		if child is AudioStreamPlayer or child is AudioStreamPlayer2D:
			child.stop()
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
