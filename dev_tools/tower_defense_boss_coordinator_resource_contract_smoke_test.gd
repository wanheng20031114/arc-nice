extends SceneTree

const ROOT_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const ROOT_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.gd"
)
const COORDINATOR_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/boss/tower_defense_boss_coordinator.tscn"
)
const COORDINATOR_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/boss/tower_defense_boss_coordinator.gd"
)
const BOSS_PROXY_FIXTURE_SCENE_PATH := (
	"res://dev_tools/fixtures/tower_defense_boss_remote_proxy_fixture.tscn"
)


class RuntimeFixture:
	extends CombatRuntimeBase


	func activate_runtime() -> void:
		pass


	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass


	func get_player_for_peer(_peer_id: int) -> Player:
		return null


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


class EnemyCoordinatorFixture:
	extends TowerDefenseEnemyCoordinator


	func bind_runtime_for_fixture(configured_runtime: CombatRuntimeBase) -> void:
		_runtime = configured_runtime


	func configure_runtime_enemy_modifiers(_enemy_instance: Enemy) -> void:
		pass


class HealthHudFixture:
	extends BossHealthHUD

	var show_calls := 0


	func show_for_boss(_boss: LinglanBoss, _boss_name: String = "") -> void:
		show_calls += 1


class MultiplayerAdapterFixture:
	extends TowerDefenseMultiplayerModeAdapter

	var local_merchant_updates := 0


	func set_local_merchants_active(_active: bool) -> bool:
		local_merchant_updates += 1
		return true


class PresentationFixture:
	extends TowerDefensePresentationCoordinator

	var boss_progress_updates := 0
	var camera_restore_updates := 0


	func show_boss_progress(_defeated: int, _total: int) -> void:
		boss_progress_updates += 1


	func restore_camera_after_boss_intro(_player_instance: Player) -> void:
		camera_restore_updates += 1


var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_static_scene_contract()
	_test_narrow_runtime_contract()
	if failures.is_empty():
		print("TOWER_DEFENSE_BOSS_COORDINATOR_RESOURCE_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_static_scene_contract() -> void:
	var root_scene_source := _read_text(ROOT_SCENE_PATH)
	var root_source := _read_text(ROOT_SOURCE_PATH)
	var coordinator_source := _read_text(COORDINATOR_SOURCE_PATH)
	var coordinator_resource_id := _find_ext_resource_id(
		root_scene_source,
		COORDINATOR_SCENE_PATH
	)
	var coordinator_node_header := _find_node_header(
		root_scene_source,
		"BossCoordinator",
		"."
	)
	_expect(
		not coordinator_resource_id.is_empty()
		and coordinator_node_header.contains(
			'instance=ExtResource("%s")' % coordinator_resource_id
		),
		"塔防主场景必须静态实例化 BossCoordinator。"
	)
	_expect(
		root_source.contains("boss_coordinator.setup("),
		"塔防主运行时必须通过强类型 setup 绑定 BossCoordinator。"
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
			not coordinator_source.contains(forbidden),
			"BossCoordinator 禁止恢复动态外观依赖：%s" % forbidden
		)


func _test_narrow_runtime_contract() -> void:
	var coordinator_scene := load(COORDINATOR_SCENE_PATH) as PackedScene
	_expect(coordinator_scene != null, "BossCoordinator 窄场景无法加载。")
	if coordinator_scene == null:
		return
	var coordinator := coordinator_scene.instantiate() as TowerDefenseBossCoordinator
	_expect(coordinator != null, "BossCoordinator 窄场景类型不正确。")
	if coordinator == null:
		coordinator_scene = null
		return
	var boss_proxy_scene := load(BOSS_PROXY_FIXTURE_SCENE_PATH) as PackedScene
	_expect(boss_proxy_scene != null, "Boss 远端 proxy 窄 fixture 无法加载。")
	if boss_proxy_scene == null:
		coordinator.free()
		coordinator_scene = null
		return

	var runtime := RuntimeFixture.new()
	var boss_container := Node2D.new()
	var enemy_container := Node2D.new()
	var runtime_port := TowerDefenseLinglanBossRuntimePort.new()
	var ground_layer := TileMapLayer.new()
	var campaign := TowerDefenseCampaignCoordinator.new()
	var enemy_coordinator := EnemyCoordinatorFixture.new()
	var home_coordinator := TowerDefenseHomeDefenseCoordinator.new()
	var player_roster := TowerDefensePlayerRosterCoordinator.new()
	var presentation := PresentationFixture.new()
	var multiplayer_adapter := MultiplayerAdapterFixture.new()
	var prewarmer := TowerDefensePrewarmerCoordinator.new()
	var pathfinder := GridPathfinder.new()
	var random_generator := RandomNumberGenerator.new()
	enemy_coordinator.bind_runtime_for_fixture(runtime)
	coordinator.setup(
		runtime,
		true,
		boss_container,
		enemy_container,
		runtime_port,
		ground_layer,
		campaign,
		enemy_coordinator,
		home_coordinator,
		player_roster,
		presentation,
		multiplayer_adapter,
		prewarmer,
		pathfinder,
		random_generator
	)
	_expect(coordinator.is_bound(), "BossCoordinator 强类型依赖未完整绑定。")
	_expect(
		runtime_port.boss_coordinator == coordinator,
		"Boss runtime port 必须反向绑定同一 Coordinator。"
	)

	var boss_enemy_config := EnemyConfig.new()
	boss_enemy_config.enemy_scene = boss_proxy_scene
	boss_enemy_config.is_boss = true
	var boss_config := BossConfig.new()
	boss_config.arena_center = Vector2(123.0, 234.0)
	boss_config.enemy_config = boss_enemy_config
	coordinator.active_boss_config = boss_config
	var health_hud := HealthHudFixture.new()
	coordinator.boss_health_hud = health_hud
	campaign.replace_flow_state_for_fixture(
		CombatFlowState.State.PRE_WAVE,
		boss_config
	)
	coordinator.apply_remote_flow_state(
		CombatFlowState.State.BOSS_INTRO,
		null
	)
	_expect(
		campaign.wave_state == CombatFlowState.State.BOSS_INTRO
		and campaign.current_flow_step == boss_config
		and coordinator.active_boss_config == boss_config,
		"缺少重复配置的远端 INTRO 必须复用已建立的强类型 BossConfig。"
	)
	coordinator.apply_remote_flow_state(
		CombatFlowState.State.BOSS_ACTIVE,
		null
	)
	_expect(
		campaign.wave_state == CombatFlowState.State.BOSS_ACTIVE
		and campaign.current_flow_step == boss_config
		and coordinator.active_boss_config == boss_config,
		"缺少重复配置的远端 ACTIVE 必须复用已建立的强类型 BossConfig。"
	)
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	coordinator.apply_remote_started(0, boss_config, Vector2(8.0, 9.0))
	_expect(
		campaign.wave_state == CombatFlowState.State.BOSS_ACTIVE
		and coordinator.linglan_boss == null,
		"非法 net_id 必须保留流程收敛，但禁止创建 Boss proxy。"
	)
	const POSITIVE_NET_ID := 73
	coordinator.apply_remote_started(
		POSITIVE_NET_ID,
		boss_config,
		Vector2(18.0, 29.0)
	)
	var proxy := enemy_coordinator.get_enemy(POSITIVE_NET_ID) as LinglanBoss
	_expect(
		proxy != null
		and coordinator.linglan_boss == proxy
		and runtime.get_network_enemy(POSITIVE_NET_ID) == proxy
		and runtime.get_network_enemy_net_id_by_instance_id(
			proxy.get_instance_id()
		) == POSITIVE_NET_ID
		and runtime.combat_target_index.get_enemy(POSITIVE_NET_ID) == proxy,
		"正 net_id 的 Boss proxy 必须通过 EnemyCoordinator 完整登记三索引。"
	)
	if proxy != null:
		var proxy_instance_id := proxy.get_instance_id()
		var removed_proxy := enemy_coordinator.take_remote_enemy_for_escape(
			POSITIVE_NET_ID
		)
		_expect(
			removed_proxy == proxy
			and enemy_coordinator.get_enemy(POSITIVE_NET_ID) == null
			and runtime.get_network_enemy_net_id_by_instance_id(
				proxy_instance_id
			) == 0
			and runtime.combat_target_index.get_enemy(POSITIVE_NET_ID) == null,
			"移除远端 Boss proxy 时必须同步清除三索引。"
		)
	_expect(
		multiplayer_adapter.local_merchant_updates == 4
		and presentation.boss_progress_updates == 4
		and presentation.camera_restore_updates == 3
		and health_hud.show_calls == 1,
		(
			"远端 Boss 流程必须经过显式多人和表现边界；实际商人/进度/"
			+ "相机/HUD=%d/%d/%d/%d。"
		)
		% [
			multiplayer_adapter.local_merchant_updates,
			presentation.boss_progress_updates,
			presentation.camera_restore_updates,
			health_hud.show_calls,
		]
	)

	# 所有 Node 都由本用例直接持有，按创建顺序的反向顺序同步释放。
	coordinator.free()
	health_hud.free()
	pathfinder.free()
	prewarmer.free()
	multiplayer_adapter.free()
	presentation.free()
	player_roster.free()
	home_coordinator.free()
	enemy_coordinator.free()
	campaign.free()
	ground_layer.free()
	runtime_port.free()
	enemy_container.free()
	boss_container.free()
	runtime.free()
	boss_proxy_scene = null
	coordinator_scene = null


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("无法读取契约源码：%s" % path)
		return ""
	return file.get_as_text()


func _find_ext_resource_id(scene_source: String, resource_path: String) -> String:
	for raw_line in scene_source.split("\n"):
		var line := String(raw_line).strip_edges()
		if (
			line.begins_with("[ext_resource ")
			and line.contains('path="%s"' % resource_path)
		):
			var id_prefix := ' id="'
			var id_start := line.find(id_prefix)
			if id_start < 0:
				return ""
			id_start += id_prefix.length()
			var id_end := line.find('"', id_start)
			return line.substr(id_start, id_end - id_start) if id_end > id_start else ""
	return ""


func _find_node_header(
	scene_source: String,
	node_name: String,
	parent_path: String
) -> String:
	for raw_line in scene_source.split("\n"):
		var line := String(raw_line).strip_edges()
		if (
			line.begins_with("[node ")
			and line.contains('name="%s"' % node_name)
			and line.contains('parent="%s"' % parent_path)
		):
			return line
	return ""


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
