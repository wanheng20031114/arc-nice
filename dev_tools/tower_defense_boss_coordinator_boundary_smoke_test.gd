extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const BOSS_CONFIG := preload(
	"res://resources/config/bosses/boss_01_linglan.tres"
)
const SLIME_CONFIG := preload(
	"res://resources/config/enemies/slime.tres"
)
const ROOT_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.gd"
)
const ROOT_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const COORDINATOR_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/boss/tower_defense_boss_coordinator.gd"
)
const COORDINATOR_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/boss/tower_defense_boss_coordinator.tscn"
)
const PORT_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/boss/tower_defense_linglan_boss_runtime_port.gd"
)
const ENEMY_COORDINATOR_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/enemy/tower_defense_enemy_coordinator.gd"
)

var failures: Array[String] = []
var exit_code := 0
var exit_timer: Timer


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_static_structure_and_order_guards()
	await _test_runtime_binding_and_behavior()
	if failures.is_empty():
		print("TOWER_DEFENSE_BOSS_COORDINATOR_BOUNDARY_SMOKE_TEST_OK")
		_schedule_exit(0)
		return
	for failure in failures:
		push_error(failure)
	_schedule_exit(1)


func _test_static_structure_and_order_guards() -> void:
	var root_source := _read_text(ROOT_SOURCE_PATH)
	var root_scene_source := _read_text(ROOT_SCENE_PATH)
	var coordinator_source := _read_text(COORDINATOR_SOURCE_PATH)
	var coordinator_scene_source := _read_text(COORDINATOR_SCENE_PATH)
	var port_source := _read_text(PORT_SOURCE_PATH)
	var enemy_coordinator_source := _read_text(ENEMY_COORDINATOR_SOURCE_PATH)
	_expect(
		root_scene_source.contains(
			'[node name="BossCoordinator" parent="." instance=ExtResource("68_boss_coordinator")]'
		),
		"TowerDefenseGame 必须静态实例化 BossCoordinator。"
	)
	_expect(
		coordinator_scene_source.contains("uid=\"uid://"),
		"BossCoordinator 场景必须持有稳定 scene UID。"
	)
	_expect(
		coordinator_scene_source.contains("type=\"Script\" uid=\"uid://"),
		"BossCoordinator 场景的脚本引用必须携带稳定 UID。"
	)
	_expect(
		root_scene_source.contains(
			'type="PackedScene" uid="uid://b84n1wng7l2np" '
			+ 'path="res://scene/game_modes/tower_defense/boss/'
			+ 'tower_defense_boss_coordinator.tscn"'
		),
		"TowerDefenseGame 对 BossCoordinator 的引用必须携带 scene UID。"
	)
	_expect(
		root_source.contains("boss_coordinator.setup(")
		and coordinator_source.contains("func setup(")
		and coordinator_source.contains("var runtime: CombatRuntimeBase")
		and coordinator_source.contains(
			"var presentation_coordinator: TowerDefensePresentationCoordinator"
		)
		and coordinator_source.contains(
			"var multiplayer_adapter: TowerDefenseMultiplayerModeAdapter"
		)
		and coordinator_source.contains(
			"presentation_coordinator.restore_camera_after_boss_intro("
		)
		and coordinator_source.contains("runtime_port.bind_boss_coordinator(self)"),
		"BossCoordinator 必须由 root 显式注入中性 runtime、表现/多人边界和 runtime port。"
	)
	for root_boss_mirror in [
		"var _linglan_boss_started",
		"var linglan_boss_started:",
		"var _active_boss_config",
		"var active_boss_config:",
		"var _linglan_boss:",
		"var linglan_boss:",
		"var _linglan_boss_intro_vfx:",
		"var linglan_boss_intro_vfx:",
		"var _boss_health_hud:",
		"var boss_health_hud:",
		"var _linglan_skill4_orb_anchor_global_position",
		"var linglan_skill4_orb_anchor_global_position:",
		"var _linglan_skill4_orb_authored_center",
		"var linglan_skill4_orb_authored_center:",
		"var _linglan_skill4_orb_anchor_valid",
		"var linglan_skill4_orb_anchor_valid:",
		"var _linglan_slime_configs",
		"var linglan_slime_configs:",
		"var _linglan_enrage_sniper_config",
		"var linglan_enrage_sniper_config:",
		"var _boss_runtime_scene_loads_requested",
		"var boss_runtime_scene_loads_requested:",
		"var _boss_runtime_resources_by_path",
		"var boss_runtime_resources_by_path:",
	]:
		_expect(
			not root_source.contains(root_boss_mirror),
			"TowerDefenseGame 不得继续镜像 Boss 状态：%s" % root_boss_mirror
		)
	for root_boss_facade in [
		"func _configure_linglan_boss(",
		"func _cache_linglan_slime_configs(",
		"func get_linglan_enrage_sniper_config(",
		"func _deferred_request_boss_runtime_scene_loads(",
		"func _get_first_boss_config(",
		"func _get_configured_bosses(",
		"func _boss_config_has_required_data(",
		"func _get_boss_enemy_config(",
		"func _get_boss_enemy_config_path(",
		"func _get_boss_arena_center(",
		"func _get_linglan_spawn_global_position(",
		"func _get_boss_arena_floor_rect(",
		"func _get_boss_floor_source_id(",
		"func _get_boss_floor_atlas_coords(",
		"func _should_clear_boss_inner_overlay_cells(",
		"func _get_boss_display_name(",
		"func _get_boss_intro_vfx_scene_path(",
		"func _get_boss_hud_scene_path(",
		"func _ensure_linglan_boss_runtime_nodes(",
		"func _ensure_boss_health_hud_runtime_node(",
		"func _begin_linglan_boss_intro(",
		"func _on_linglan_boss_intro_finished(",
		"func _activate_linglan_boss(",
		"func _on_linglan_boss_defeated(",
		"func _complete_linglan_boss_after_delay(",
		"func _remove_remaining_boss_adds(",
		"func _prepare_linglan_boss_arena(",
		"func spawn_linglan_skill2_enemies(",
		"func spawn_linglan_random_slime(",
		"func spawn_linglan_airdrop_sniper(",
		"func get_linglan_skill2_target_player(",
		"func get_linglan_skill2_target_global_position(",
		"func get_linglan_skill3_target_global_position(",
		"func get_linglan_skill4_target_global_position(",
		"func get_linglan_skill4_laser_bounds(",
		"func get_linglan_skill4_orb_spawn_global_position(",
		"func _play_remote_boss_intro(",
		"func _on_remote_linglan_boss_intro_finished(",
		"func _restore_remote_camera_if_boss_intro_complete(",
		"func _show_tower_defense_boss_progress(",
		"func _focus_camera_on_boss_intro(",
		"func _restore_camera_after_boss_intro(",
		"func _update_boss_music(",
		"func _rebroadcast_linglan_boss_started_after_sync_window(",
		"func _emit_tower_boss_started_authoritatively(",
		"func apply_remote_boss_started(",
		"func _instantiate_remote_linglan_boss_proxy(",
	]:
		_expect(
			not root_source.contains(root_boss_facade),
			"TowerDefenseGame 不得继续转发 Boss 行为：%s" % root_boss_facade
		)
	for coordinator_owned_state in [
		"var linglan_boss_started := false",
		"var active_boss_config: BossConfig",
		"var linglan_boss: LinglanBoss",
		"var linglan_boss_intro_vfx: LinglanBossIntroVFX",
		"var linglan_slime_configs: Array[EnemyConfig] = []",
		"var runtime_resources_by_path: Dictionary[String, Resource] = {}",
	]:
		_expect(
			coordinator_source.contains(coordinator_owned_state),
			"BossCoordinator 必须直接持有 Boss 状态：%s" % coordinator_owned_state
		)
	for forbidden in [
		"get_tree().current_scene",
		"get_node(\"../",
		"has_method(",
		".call(",
		"runtime._",
		"multiplayer_gateway",
	]:
		_expect(
			not coordinator_source.contains(forbidden)
			and not port_source.contains(forbidden),
			"BossCoordinator/runtime port 禁止动态依赖或网络外观直连：%s" % forbidden
		)

	var intro_source := _function_source(
		coordinator_source, "func begin_intro(", "func apply_remote_flow_state("
	)
	_expect_order(
		intro_source,
		[
			"ensure_runtime_nodes",
			"reset_wave_death_counts",
			"linglan_boss_started = true",
			"campaign_coordinator.transition_to_boss_intro(",
			"enemy_coordinator.clear_queue()",
			"enemy_coordinator.clear_active_enemies()",
			"home_defense_coordinator.clear_resolved_enemy_ids()",
			"enemy_coordinator.clear_hud_alive_enemies()",
			"multiplayer_adapter.set_merchant_active(false)",
			"presentation_coordinator.show_boss_progress(0, 1)",
			"presentation_coordinator.update_boss_music(boss_config)",
			"presentation_coordinator.focus_camera_on_boss_intro(spawn_position)",
			"multiplayer_adapter.publish_flow_state(CombatFlowState.State.BOSS_INTRO)",
			"linglan_boss_intro_vfx.play_intro(spawn_position)",
		],
		"host Boss intro"
	)
	var remote_flow_source := _function_source(
		coordinator_source,
		"func apply_remote_flow_state(",
		"func apply_remote_started("
	)
	var remote_intro_source := _function_source(
		remote_flow_source,
		"CombatFlowState.State.BOSS_INTRO:",
		"CombatFlowState.State.BOSS_ACTIVE:"
	)
	_expect_order(
		remote_intro_source,
		[
			"campaign_coordinator.transition_to_boss_intro(",
			"multiplayer_adapter.set_local_merchants_active(false)",
			"presentation_coordinator.show_boss_progress(0, 1)",
			"active_boss_config = boss_config",
			"presentation_coordinator.update_boss_music(boss_config)",
			"prepare_arena(boss_config)",
			"play_remote_intro(boss_config)",
		],
		"client BOSS_INTRO"
	)
	var remote_active_source := remote_flow_source.substr(
		remote_flow_source.find("CombatFlowState.State.BOSS_ACTIVE:")
	)
	_expect_order(
		remote_active_source,
		[
			"campaign_coordinator.transition_to_boss_active(",
			"multiplayer_adapter.set_local_merchants_active(false)",
			"presentation_coordinator.show_boss_progress(0, 1)",
			"restore_remote_camera_if_intro_complete()",
			"active_boss_config = boss_config",
			"presentation_coordinator.update_boss_music(boss_config)",
		],
		"client BOSS_ACTIVE"
	)
	var activate_source := _function_source(
		coordinator_source, "func activate_boss(", "func finish_intro("
	)
	_expect_order(
		activate_source,
		[
			"enemy_coordinator.register_external_enemy(linglan_boss)",
			"linglan_boss.tree_exited.connect(exited_callback)",
			"enemy_coordinator.finalize_authoritative_enemy_spawn(",
			"presentation_coordinator.show_boss_progress(0, 1)",
			"multiplayer_adapter.publish_flow_state(CombatFlowState.State.BOSS_ACTIVE)",
			"multiplayer_adapter.publish_boss_started(",
		],
		"host Boss activate"
	)
	var proxy_source := _function_source(
		coordinator_source,
		"func instantiate_remote_proxy(",
		"func _try_spawn_boss_add_at_marker("
	)
	_expect_order(
		proxy_source,
		[
			"boss_enemy.setup(",
			"enemy_coordinator.configure_runtime_enemy_modifiers(boss_enemy)",
			"boss_enemy.configure_multiplayer_proxy()",
			'boss_enemy.set_meta("net_id", net_id)',
			"enemy_coordinator.register_remote_proxy_indices(boss_enemy, net_id)",
		],
		"client Boss proxy"
	)
	var proxy_index_source := _function_source(
		enemy_coordinator_source,
		"func register_remote_proxy_indices(",
		"func collect_snapshot_states("
	)
	_expect_order(
		proxy_index_source,
		[
			"_runtime.register_network_enemy(net_id, enemy)",
		],
		"client Boss proxy EnemyCoordinator indices"
	)
	var add_source := _function_source(
		coordinator_source,
		"func _try_spawn_boss_add_at_position(",
		"func _spawn_airdrop_warning("
	)
	_expect_order(
		add_source,
		[
			"enemy_coordinator.register_external_enemy(enemy_instance)",
			"_connect_boss_add_signals(enemy_instance, enemy_id)",
			"enemy_coordinator.finalize_authoritative_enemy_spawn(",
			"enemy_coordinator.spawn_enemy_spawn_effect(spawn_position)",
		],
		"Boss add"
	)
	var airdrop_source := _function_source(
		coordinator_source,
		"func _finish_airdrop_sniper_spawn(",
		"func _get_random_arena_position("
	)
	_expect_order(
		airdrop_source,
		[
			"enemy_coordinator.register_external_enemy(enemy_instance)",
			"_connect_boss_add_signals(enemy_instance, enemy_id)",
			"enemy_coordinator.finalize_authoritative_enemy_spawn(",
			"enemy_coordinator.spawn_enemy_spawn_effect(landing_position)",
		],
		"Boss airdrop"
	)
	var load_source := _function_source(
		coordinator_source,
		"func _load_threaded_or_direct(",
		"static func _append_unique_path("
	)
	_expect(
		load_source.contains("ResourceLoader.THREAD_LOAD_IN_PROGRESS")
		and load_source.contains("ResourceLoader.THREAD_LOAD_LOADED")
		and load_source.contains("return ResourceLoader.load_threaded_get(path)"),
		"threaded IN_PROGRESS/LOADED 必须继续使用 load_threaded_get。"
	)
	var resource_paths_source := _function_source(
		coordinator_source,
		"func get_runtime_resource_paths(",
		"func get_configured_bosses("
	)
	_expect(
		resource_paths_source.contains(
			"paths.append(LINGLAN_ENRAGE_SNIPER_CONFIG_PATH)"
		),
		"半血狙击手路径必须保持旧版无条件 append 语义。"
	)
	_expect(
		not coordinator_source.contains("_defeat_completion_generation")
		and coordinator_source.contains("create_timer(1.3)"),
		"Boss defeat 必须保留首个 1.3 秒 timer，不得用 generation 推迟完成。"
	)


func _test_runtime_binding_and_behavior() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "塔防主场景无法实例化。")
	if game == null:
		return
	game.auto_start_waves = false
	var static_coordinator := game.get_node_or_null(
		"BossCoordinator"
	) as TowerDefenseBossCoordinator
	_expect(static_coordinator != null, "ready 前必须已有静态 BossCoordinator 子节点。")
	if static_coordinator == null:
		game.free()
		return
	static_coordinator.linglan_boss_started = true
	static_coordinator.active_boss_config = BOSS_CONFIG
	static_coordinator.linglan_skill4_orb_anchor_global_position = Vector2(31.0, 47.0)
	static_coordinator.linglan_skill4_orb_anchor_valid = true
	var retained_slimes: Array[EnemyConfig] = [SLIME_CONFIG]
	var retained_resources: Dictionary[String, Resource] = {
		"res://boss_boundary_probe": SLIME_CONFIG,
	}
	static_coordinator.linglan_slime_configs = retained_slimes
	static_coordinator.runtime_resources_by_path = retained_resources

	root.add_child(game)
	current_scene = game
	await process_frame
	var coordinator := game.boss_coordinator
	_expect(coordinator == static_coordinator, "root onready 必须绑定静态 BossCoordinator。")
	_expect(coordinator != null and coordinator.is_bound(), "BossCoordinator 依赖绑定不完整。")
	_expect(
		game.linglan_boss_runtime_port.boss_coordinator == coordinator,
		"TowerDefenseLinglanBossRuntimePort 未绑定 BossCoordinator。"
	)
	_expect(
		is_same(retained_slimes, coordinator.linglan_slime_configs),
		"BossCoordinator 直接持有的史莱姆配置 Array 必须跨 ready 保持同一引用。"
	)
	_expect(
		is_same(retained_resources, coordinator.runtime_resources_by_path),
		"BossCoordinator 直接持有的预热资源 Dictionary 必须跨 ready 保持同一引用。"
	)
	_expect(
		coordinator.linglan_boss_started
		and coordinator.active_boss_config == BOSS_CONFIG
		and coordinator.linglan_skill4_orb_anchor_global_position == Vector2(31.0, 47.0)
		and coordinator.linglan_skill4_orb_anchor_valid,
		"ready 前 Boss 标量状态没有完整迁移到 coordinator。"
	)
	var replacement_slimes: Array[EnemyConfig] = []
	var replacement_resources: Dictionary[String, Resource] = {}
	coordinator.linglan_slime_configs = replacement_slimes
	coordinator.runtime_resources_by_path = replacement_resources
	_expect(
		is_same(replacement_slimes, coordinator.linglan_slime_configs)
		and is_same(replacement_resources, coordinator.runtime_resources_by_path),
		"ready 后 BossCoordinator 容器整体赋值必须保持同一引用。"
	)
	game.state_timer.start(5.0)
	coordinator.apply_remote_flow_state(
		CombatFlowState.State.BOSS_INTRO, null
	)
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.BOSS_INTRO
		and game.state_timer.is_stopped()
		and coordinator.active_boss_config == BOSS_CONFIG,
		"null BossConfig 的 remote INTRO 仍须更新基础状态且保留旧配置。"
	)
	game.state_timer.start(5.0)
	coordinator.apply_remote_flow_state(
		CombatFlowState.State.BOSS_ACTIVE, null
	)
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.BOSS_ACTIVE
		and game.state_timer.is_stopped()
		and coordinator.active_boss_config == BOSS_CONFIG,
		"null BossConfig 的 remote ACTIVE 仍须更新基础状态且保留旧配置。"
	)

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	coordinator.apply_remote_started(0, BOSS_CONFIG, Vector2(123.0, 234.0))
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.BOSS_ACTIVE
		and game.campaign_coordinator.current_flow_step == BOSS_CONFIG
		and coordinator.active_boss_config == BOSS_CONFIG,
		"net_id=0 的迟到/异常 Boss started 仍须先更新 client 状态。"
	)
	_expect(
		game.enemy_coordinator.get_enemy(0) == null and coordinator.linglan_boss == null,
		"net_id=0 必须在 proxy 创建边界被拒绝。"
	)

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	coordinator.begin_intro(BOSS_CONFIG)
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.BOSS_INTRO
		and coordinator.linglan_boss != null,
		"塔防 Boss intro 未进入预期状态或未准备实体。"
	)
	coordinator.finish_intro()
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.BOSS_ACTIVE
		and coordinator.linglan_boss != null
		and game.enemy_coordinator.has_active_enemy(
			coordinator.linglan_boss.get_instance_id()
		),
		"Boss activate 必须在 EnemyCoordinator 活跃索引登记实体。"
	)
	var active_boss := coordinator.linglan_boss
	coordinator.handle_boss_defeated(active_boss)
	await create_timer(0.30).timeout
	coordinator.handle_boss_defeated(active_boss)
	await create_timer(1.05).timeout
	_expect(
		game.campaign_coordinator.wave_state != CombatFlowState.State.BOSS_ACTIVE,
		"重复 defeat 信号不得把首次 1.3 秒完成点推迟到第二次信号之后。"
	)
	# Drain the second legacy-compatible timer scheduled by the duplicate signal.
	await create_timer(0.35).timeout
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	coordinator.apply_remote_started(73, BOSS_CONFIG, Vector2(222.0, 333.0))
	var proxy := game.enemy_coordinator.get_enemy(73) as LinglanBoss
	_expect(proxy != null and coordinator.linglan_boss == proxy, "正 net_id 未创建 Boss proxy。")
	if proxy != null:
		_expect(
			game.get_network_enemy(73) == proxy
			and game.combat_target_index.get_enemy(73) == proxy
			and game.get_network_enemy_net_id_by_instance_id(proxy.get_instance_id()) == 73,
			"Boss proxy 必须按共享三索引契约完整登记。"
		)

	_stop_audio_recursive(game)
	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("无法读取验证源码：%s" % path)
		return ""
	return file.get_as_text()


func _function_source(source: String, start_marker: String, end_marker: String) -> String:
	var start := source.find(start_marker)
	var end := source.find(end_marker, start + start_marker.length())
	if start < 0 or end <= start:
		failures.append("无法提取函数区间：%s -> %s" % [start_marker, end_marker])
		return ""
	return source.substr(start, end - start)


func _expect_order(source: String, markers: Array[String], label: String) -> void:
	var cursor := -1
	for marker in markers:
		var position := source.find(marker, cursor + 1)
		if position < 0:
			failures.append("%s 缺少顺序标记：%s" % [label, marker])
			return
		if position <= cursor:
			failures.append("%s 顺序发生变化：%s" % [label, marker])
			return
		cursor = position


func _stop_audio_recursive(node: Node) -> void:
	var player_2d := node as AudioStreamPlayer2D
	if player_2d != null:
		player_2d.stop()
		player_2d.stream = null
	var player := node as AudioStreamPlayer
	if player != null:
		player.stop()
		player.stream = null
	for child in node.get_children():
		_stop_audio_recursive(child)


func _schedule_exit(code: int) -> void:
	exit_code = code
	exit_timer = Timer.new()
	exit_timer.one_shot = true
	exit_timer.wait_time = 0.1
	root.add_child(exit_timer)
	exit_timer.timeout.connect(_quit_after_async_release)
	exit_timer.start()


func _quit_after_async_release() -> void:
	exit_timer.stop()
	exit_timer.queue_free()
	quit(exit_code)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
