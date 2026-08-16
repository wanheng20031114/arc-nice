extends SceneTree

const GAME_SCENE := preload("res://scene/game_modes/standard/standard_game.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const PROJECTILE_COORDINATOR_SOURCE_PATH := (
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const WORLD_FLOW_COORDINATOR_SOURCE_PATH := (
	"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.gd"
)
const TEST_PORT := 29279
const LINGLAN_BOSS_RUNTIME_RESOURCE_PATHS: Array[String] = [
	"res://resources/config/enemies/linglan_boss.tres",
	"res://scene/boss/linglan/linglan_boss_intro_vfx.tscn",
	"res://scene/boss/linglan/boss_health_hud.tscn",
	"res://resources/config/enemies/capoo_sniper.tres",
]
const LINGLAN_TOWER_SLIME_RESOURCE_PATHS: Array[String] = [
	"res://resources/config/enemies/slime.tres",
	"res://resources/config/enemies/slime_green.tres",
	"res://resources/config/enemies/slime_golden.tres",
	"res://resources/config/enemies/slime_frost.tres",
	"res://resources/config/enemies/slime_fire.tres",
]
const TOWER_DEFENSE_HIGH_FREQUENCY_RESOURCE_PATHS: Array[String] = [
	"res://resources/config/campaigns/tower_defense/formal/wave_01.tres",
	"res://resources/config/enemies/yuanshi_insect_basic.tres",
	"res://resources/config/enemies/yuanshi_insect_shell.tres",
	"res://resources/config/enemies/capoo_ak47.tres",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_basic.tscn",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_shell.tscn",
	"res://scene/enemy/capoo/capoo_ak47.tscn",
	"res://scene/enemy/capoo/capoo_ak47_bullet.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn",
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn",
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn",
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn",
	"res://resources/config/enemies/capoo_knight_elite.tres",
	"res://resources/config/enemies/stone_golem_elite.tres",
	"res://resources/config/enemies/combat_robot_elite.tres",
	"res://resources/config/enemies/combat_robot_gunner_elite.tres",
	"res://resources/config/enemies/combat_robot_drone_operator_elite.tres",
	"res://resources/config/enemies/fire_sorcerer_elite.tres",
	"res://resources/config/enemies/frost_sorcerer_elite.tres",
	"res://resources/config/enemies/lightning_sorcerer_elite.tres",
	"res://resources/animation/yuanshi_insect_basic.tres",
	"res://resources/animation/capoo_ak47.tres",
	"res://resources/audio/capoo_ak47_fire.wav",
	"res://resources/audio/1-27 Journey of the Prairie King (Overworld).mp3",
	"res://scene/combat/projectiles/bullet.tscn",
	"res://scene/player/tango/tango_laser_bullet.tscn",
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn",
	"res://resources/audio/Cowboy_gunshot.wav",
	"res://resources/config/plant_defense/agave_cannon.tres",
	"res://scene/plant_defense/agave_cannon.tscn",
	"res://scene/plant_defense/agave_cannonball.tscn",
	"res://resources/config/plant_defense/bamboo_mortar.tres",
	"res://scene/plant_defense/bamboo_mortar.tscn",
	"res://scene/plant_defense/bamboo_mortar_shell.tscn",
	"res://resources/shader/bamboo_mortar_split_lifecycle.gdshader",
	"res://resources/shader/bamboo_mortar_split_lifecycle_material.tres",
	"res://resources/shader/bamboo_mortar_glow.gdshader",
	"res://resources/config/plant_defense/corn_machine_gun.tres",
	"res://scene/plant_defense/corn_machine_gun.tscn",
	"res://resources/config/plant_defense/oak_warehouse.tres",
	"res://scene/plant_defense/oak_warehouse.tscn",
	"res://resources/config/plant_defense/stone_mill.tres",
	"res://scene/plant_defense/stone_mill.tscn",
	"res://resources/config/plant_defense/simple_fence.tres",
	"res://scene/plant_defense/simple_fence.tscn",
	"res://resources/shader/plant_lifecycle.gdshader",
	"res://resources/shader/plant_lifecycle_material.tres",
	"res://resources/shader/plant_lifecycle_noise.tres",
	"res://scene/game_modes/tower_defense/plant/presentation/plant_placement_particles.tscn",
	"res://scene/game_modes/tower_defense/plant/presentation/plant_removal_smoke.tscn",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_spawn_effect.tscn",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_loading_scene_contract()
	_test_load_attempt_lease()
	await _test_runtime_activation_gate()
	_test_mode_specific_mp_game_source()
	_test_host_ready_barrier()
	await _test_mp_game_preparation_barrier()
	await _test_singleplayer_coordinator_flow()
	await _cleanup_test_runtime()
	call_deferred("_finish")


func _cleanup_test_runtime() -> void:
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	if coordinator != null:
		coordinator.set("_state", 0)
		coordinator.set_process(false)
		var overlay := coordinator.get_node_or_null("Overlay") as Control
		if overlay != null:
			overlay.hide()
	var runtime := current_scene
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame


func _test_loading_scene_contract() -> void:
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	_expect(coordinator is CanvasLayer, "Loading coordinator must remain a persistent CanvasLayer.")
	if coordinator == null:
		return
	_expect(
		coordinator.get_node_or_null("Overlay/Layout/Stack/Content/RouteProgress") is ProgressBar,
		"Loading UI must expose its native progress bar."
	)
	_expect(
		coordinator.get_node_or_null("Overlay/Layout/Stack/Content/ActionRow/Back") is Button,
		"Loading errors must expose a native return action."
	)
	var manifest: Array[String] = []
	coordinator.call("_append_character_scene", manifest, &"weishidaier")
	_expect(
		manifest == ["res://scene/player/weishidaier/player_weishidaier.tscn"],
		"Loading manifest must include the selected player scene exactly once."
	)
	coordinator.call("_append_character_scene", manifest, &"weishidaier")
	_expect(manifest.size() == 1, "Loading manifest must deduplicate player scenes.")
	var test_scene_path := "res://scene/game_modes/tower_defense/test_arenas/test_grass_arena.tscn"
	var test_p1b_scene_path := "res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p1b.tscn"
	var test_p1c_scene_path := "res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p1c.tscn"
	var test_p1d_scene_path := "res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p1d.tscn"
	var test_p1e_scene_path := "res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p1e.tscn"
	var test_p2_scene_path := "res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p2.tscn"
	_expect(
		str(coordinator.call("_get_singleplayer_campaign_path", test_scene_path))
		== "res://resources/config/campaigns/test_arena/singleplayer/campaign.tres",
		"Test-arena loading must use its dedicated single-player campaign."
	)
	_expect(
		bool(coordinator.call("_uses_tower_defense_runtime", test_scene_path)),
		"Test-arena loading must include tower-defense runtime resources."
	)
	_expect(
		str(coordinator.call("_get_singleplayer_campaign_path", test_p1b_scene_path))
		== "res://resources/config/campaigns/test_arena/p1b/singleplayer/campaign.tres",
		"Test-arena P1B loading must use its mechanical-life campaign."
	)
	_expect(
		bool(coordinator.call("_uses_tower_defense_runtime", test_p1b_scene_path)),
		"Test-arena P1B loading must include tower-defense runtime resources."
	)
	_expect(
		float(coordinator.call("_get_resource_weight", test_p1b_scene_path)) == 7.0,
		"Test-arena P1B scene must use the tower-defense scene loading weight."
	)
	_expect(
		str(coordinator.call("_get_singleplayer_campaign_path", test_p1c_scene_path))
		== "res://resources/config/campaigns/test_arena/p1c/singleplayer/campaign.tres"
		and bool(coordinator.call("_uses_tower_defense_runtime", test_p1c_scene_path))
		and float(coordinator.call("_get_resource_weight", test_p1c_scene_path)) == 7.0,
		"Test-arena P1C loading must use its cardboard campaign and tower-defense profile."
	)
	_expect(
		str(coordinator.call("_get_singleplayer_campaign_path", test_p1d_scene_path))
		== "res://resources/config/campaigns/test_arena/p1d/singleplayer/campaign.tres"
		and bool(coordinator.call("_uses_tower_defense_runtime", test_p1d_scene_path))
		and float(coordinator.call("_get_resource_weight", test_p1d_scene_path)) == 7.0,
		"Test-arena P1D loading must use its underground-church cardboard campaign and tower-defense profile."
	)
	_expect(
		str(coordinator.call("_get_singleplayer_campaign_path", test_p1e_scene_path))
		== "res://resources/config/campaigns/test_arena/p1e/singleplayer/campaign.tres"
		and bool(coordinator.call("_uses_tower_defense_runtime", test_p1e_scene_path))
		and float(coordinator.call("_get_resource_weight", test_p1e_scene_path)) == 7.0,
		"Test-arena P1E loading must use its main-battle campaign and tower-defense profile."
	)
	var p1e_singleplayer_manifest: Array = coordinator.call(
		"_build_singleplayer_manifest",
		test_p1e_scene_path
	)
	_expect(
		GameModeCatalog.is_development_selectable(
			GameModeCatalog.MODE_TEST_ARENA_P1E
		)
		and p1e_singleplayer_manifest.has(test_p1e_scene_path)
		and p1e_singleplayer_manifest.has(
			"res://resources/config/campaigns/test_arena/p1e/singleplayer/campaign.tres"
		),
		"GameLoadCoordinator must accept P1E and build its single-player manifest."
	)
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	if net_manager != null:
		net_manager.disconnect_from_game()
		net_manager.set(
			"current_game_mode",
			NetManagerStore.GameMode.TEST_ARENA_P1E
		)
		var p1e_multiplayer_manifest: Array = coordinator.call(
			"_build_multiplayer_manifest",
			int(NetManagerStore.GameMode.TEST_ARENA_P1E),
			net_manager
		)
		_expect(
			p1e_multiplayer_manifest.has(
				"res://scene/game_modes/tower_defense/multiplayer/tower_defense_multiplayer_session.tscn"
			)
			and p1e_multiplayer_manifest.has(test_p1e_scene_path)
			and p1e_multiplayer_manifest.has(
				"res://resources/config/campaigns/test_arena/p1e/multiplayer/campaign.tres"
			),
			"GameLoadCoordinator must build the complete P1E multiplayer manifest."
		)
		net_manager.set(
			"current_game_mode",
			NetManagerStore.GameMode.STANDARD
		)
	_expect(
		str(coordinator.call("_get_singleplayer_campaign_path", test_p2_scene_path))
		== "res://resources/config/campaigns/test_arena/p2/singleplayer/campaign.tres",
		"Test-arena P2 loading must use its one-slime campaign."
	)
	_expect(
		bool(coordinator.call("_uses_tower_defense_runtime", test_p2_scene_path)),
		"Test-arena P2 loading must include tower-defense runtime resources."
	)
	_expect(
		float(coordinator.call("_get_resource_weight", test_p2_scene_path)) == 7.0,
		"Test-arena P2 scene must use the tower-defense scene loading weight."
	)
	for multiplayer_contract in [
		[
			NetManagerStore.GameMode.STANDARD,
			"res://scene/game_modes/standard/standard_game.tscn",
			"res://resources/config/campaigns/standard/multiplayer/campaign.tres",
		],
		[
			NetManagerStore.GameMode.TOWER_DEFENSE,
			"res://scene/game_modes/tower_defense/tower_defense_game.tscn",
			"res://resources/config/campaigns/tower_defense/multiplayer/campaign.tres",
		],
		[
			NetManagerStore.GameMode.TEST_ARENA_P1,
			test_scene_path,
			"res://resources/config/campaigns/test_arena/multiplayer/campaign.tres",
		],
		[
			NetManagerStore.GameMode.TEST_ARENA_P1B,
			test_p1b_scene_path,
			"res://resources/config/campaigns/test_arena/p1b/multiplayer/campaign.tres",
		],
		[
			NetManagerStore.GameMode.TEST_ARENA_P1C,
			test_p1c_scene_path,
			"res://resources/config/campaigns/test_arena/p1c/multiplayer/campaign.tres",
		],
		[
			NetManagerStore.GameMode.TEST_ARENA_P1D,
			test_p1d_scene_path,
			"res://resources/config/campaigns/test_arena/p1d/multiplayer/campaign.tres",
		],
		[
			NetManagerStore.GameMode.TEST_ARENA_P2,
			test_p2_scene_path,
			"res://resources/config/campaigns/test_arena/p2/multiplayer/campaign.tres",
		],
	]:
		var game_mode := int(multiplayer_contract[0])
		var runtime_path := str(multiplayer_contract[1])
		var campaign_path := str(multiplayer_contract[2])
		_expect(
			str(coordinator.call("_get_multiplayer_runtime_path", game_mode))
			== runtime_path,
			"Multiplayer mode %d must preload its exact runtime scene." % game_mode
		)
		_expect(
			str(coordinator.call("_get_multiplayer_campaign_path", game_mode))
			== campaign_path,
			"Multiplayer mode %d must preload its exact Campaign." % game_mode
		)
		_expect(
			ResourceLoader.exists(runtime_path)
			and ResourceLoader.exists(campaign_path),
			"Multiplayer mode %d loading manifest resources must exist." % game_mode
		)


func _test_load_attempt_lease() -> void:
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	if coordinator == null:
		return
	var source := FileAccess.get_file_as_string(
		"res://scene/loading/game_load_coordinator.gd"
	)
	_expect(
		source.contains("class LoadAttempt extends RefCounted:")
		and not source.contains("CAMPAIGN_RUNTIME_RESOURCES_META")
		and not source.contains("campaign.set_meta("),
		"加载期资源必须由显式尝试租约持有，不能写入共享 Campaign meta。"
	)
	_expect(
		source.contains('_invalidate_and_release_active_attempt(&"completed")')
		and source.contains('_invalidate_and_release_active_attempt(&"failed")')
		and source.contains('_invalidate_and_release_active_attempt(&"returned")'),
		"成功、失败与返回路径必须统一释放当前加载尝试。"
	)

	var lease_probe_path := "res://scene/loading/game_load_coordinator.gd"
	var manifest: Array[String] = [lease_probe_path]
	coordinator.call("_begin_load", lease_probe_path, manifest, false)
	manifest.append("res://this_mutation_must_not_enter_the_attempt.tres")
	var failed_attempt: RefCounted = coordinator.get("_active_attempt")
	_expect(failed_attempt != null, "测试加载必须创建显式尝试租约。")
	if failed_attempt == null:
		return
	var failed_generation := int(failed_attempt.get("generation"))
	var request: RefCounted = failed_attempt.get("request")
	var request_manifest: Array = request.get("manifest")
	_expect(
		request_manifest == [lease_probe_path],
		"加载尝试必须复制请求清单，外部修改不能改变当前 owner。"
	)
	coordinator.call("_show_error", "加载尝试租约测试错误")
	_expect(
		coordinator.get("_active_attempt") == null
		and bool(failed_attempt.get("released"))
		and failed_attempt.get("release_reason") == &"failed"
		and failed_attempt.get("request") == null
		and bool(request.get("released"))
		and (request.get("manifest") as Array).is_empty()
		and (failed_attempt.get("requested_paths") as Array).is_empty()
		and (failed_attempt.get("loaded_resources") as Dictionary).is_empty(),
		"失败必须原子释放请求清单、线程状态与资源强引用。"
	)
	var retry_request: RefCounted = coordinator.get("_failed_retry_request")
	_expect(
		retry_request != null
		and str(retry_request.get("target_scene_path")) == lease_probe_path,
		"失败界面只能保留当前失败尝试的不可变重试请求。"
	)
	coordinator.call("_on_retry_pressed")
	var retried_attempt: RefCounted = coordinator.get("_active_attempt")
	_expect(
		retried_attempt != null
		and int(retried_attempt.get("generation")) > failed_generation
		and str(
			(retried_attempt.get("request") as RefCounted).get(
				"target_scene_path"
			)
		) == lease_probe_path
		and bool(retry_request.get("released")),
		"重试必须创建新 generation，并消费当前失败尝试的请求快照。"
	)
	coordinator.call("_show_error", "重试后的加载尝试租约测试错误")
	var superseded_retry: RefCounted = coordinator.get("_failed_retry_request")

	# 新请求即使在参数校验阶段失败，也必须先废弃旧失败尝试的重试目标。
	coordinator.begin_singleplayer("res://not_a_registered_game_mode.tscn")
	_expect(
		coordinator.get("_active_attempt") == null
		and coordinator.get("_failed_retry_request") == null
		and superseded_retry != null
		and bool(superseded_retry.get("released"))
		and (superseded_retry.get("manifest") as Array).is_empty()
		and not coordinator.get_node(
			"Overlay/Layout/Stack/Content/ActionRow/Retry"
		).visible,
		"新模式请求不能复用上一失败尝试的目标。"
	)
	var scene_before_late_commit := current_scene
	coordinator.call("_commit_scene_change", failed_generation)
	_expect(
		current_scene == scene_before_late_commit
		and coordinator.get("_active_attempt") == null,
		"已释放 generation 的迟到提交不能复活旧加载尝试。"
	)
	coordinator.call("_clear_failed_retry_request")
	coordinator.set("_state", 0)
	coordinator.get_node("Overlay").hide()

	var coordinator_scene := load(
		"res://scene/loading/game_load_coordinator.tscn"
	) as PackedScene
	_expect(coordinator_scene != null, "退出清理测试必须能实例化加载协调器。")
	if coordinator_scene == null:
		return
	var active_shutdown_probe := coordinator_scene.instantiate()
	active_shutdown_probe.name = &"ActiveLoadAttemptShutdownProbe"
	root.add_child(active_shutdown_probe)
	active_shutdown_probe.call(
		"_begin_load",
		lease_probe_path,
		[lease_probe_path] as Array[String],
		false
	)
	var shutdown_attempt: RefCounted = active_shutdown_probe.get("_active_attempt")
	active_shutdown_probe.free()
	_expect(
		shutdown_attempt != null
		and bool(shutdown_attempt.get("released"))
		and shutdown_attempt.get("release_reason") == &"shutdown"
		and shutdown_attempt.get("request") == null,
		"协调器异常退出必须终结活动尝试及其请求快照。"
	)

	var retry_shutdown_probe := coordinator_scene.instantiate()
	retry_shutdown_probe.name = &"RetryLoadAttemptShutdownProbe"
	root.add_child(retry_shutdown_probe)
	retry_shutdown_probe.call(
		"_begin_load",
		lease_probe_path,
		[lease_probe_path] as Array[String],
		false
	)
	retry_shutdown_probe.call("_show_error", "退出清理重试请求测试错误")
	var shutdown_retry: RefCounted = retry_shutdown_probe.get(
		"_failed_retry_request"
	)
	retry_shutdown_probe.free()
	_expect(
		shutdown_retry != null
		and bool(shutdown_retry.get("released"))
		and (shutdown_retry.get("manifest") as Array).is_empty(),
		"协调器异常退出必须释放失败界面的重试请求。"
	)


func _test_runtime_activation_gate() -> void:
	var game := GAME_SCENE.instantiate() as CombatRuntimeBase
	_expect(game != null, "Standard runtime must instantiate for activation-gate coverage.")
	if game == null:
		return
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Loading Host"},
		{1: &"weishidaier"}
	)
	game.set("auto_start_waves", false)
	game.defer_runtime_activation()
	_expect(
		game.runtime_activation_deferred
		and not game.runtime_activated
		and game.process_mode == Node.PROCESS_MODE_DISABLED,
		"Deferred multiplayer runtime must freeze the complete gameplay subtree."
	)
	root.add_child(game)
	for _frame in range(240):
		if game.is_runtime_preparation_complete():
			break
		await process_frame
	_expect(
		game.is_runtime_preparation_complete()
		and game.process_mode == Node.PROCESS_MODE_DISABLED,
		"Runtime preparation must finish while gameplay processing remains frozen."
	)
	game.activate_runtime()
	_expect(
		not game.runtime_activation_deferred
		and game.runtime_activated
		and game.process_mode == Node.PROCESS_MODE_INHERIT,
		"Barrier completion must reactivate gameplay exactly once."
	)
	_expect_sorcerer_projectile_pools(game, 48, 704)
	_expect_gunner_projectile_pool(game)
	_expect_drone_projectile_pool(game)
	game.queue_free()
	await process_frame


func _test_mode_specific_mp_game_source() -> void:
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	var projectile_source := FileAccess.get_file_as_string(
		PROJECTILE_COORDINATOR_SOURCE_PATH
	)
	var world_flow_source := FileAccess.get_file_as_string(
		WORLD_FLOW_COORDINATOR_SOURCE_PATH
	)
	_expect(not source.is_empty(), "MpGame source must be readable.")
	_expect(
		not projectile_source.is_empty(),
		"ProjectileCoordinator source must be readable."
	)
	_expect(
		not world_flow_source.is_empty(),
		"WorldFlowCoordinator source must be readable."
	)
	_expect(
		not source.contains('preload("res://scene/game_modes/standard/standard_game.tscn")')
		and not source.contains('preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")'),
		"MpGame must not eagerly preload both gameplay modes."
	)
	_expect(
		not source.contains('preload("res://scene/boss/linglan')
		and not source.contains('preload("res://resources/config/bosses/linglan')
		and not projectile_source.contains('preload("res://scene/boss/linglan')
		and not projectile_source.contains(
			'preload("res://resources/config/bosses/linglan'
		),
		"Tower-defense multiplayer must not eagerly load Linglan scenes or configs."
	)
	_expect(
		not projectile_source.contains("const BULLET_SCENE := preload")
		and not projectile_source.contains("const TIYI_SNIPER_BULLET_SCENE := preload")
		and not projectile_source.contains("const TIYI_SNIPER_HIT_EFFECT_SCENE := preload")
		and not projectile_source.contains("const SKILL1_BOMB_SCENE := preload"),
		"ProjectileCoordinator must preserve lazy loading for roster-specific player projectiles."
	)
	_expect(
		source.contains("@onready var projectile_coordinator:")
		and source.contains("$ProjectileCoordinator")
		and source.contains("projectile_coordinator.handle_client_projectile_fired(")
		and source.contains("projectile_coordinator.apply_authority_projectile_fired(")
		and not source.contains("func instantiate_projectile("),
		"MpGame must expose only a thin façade over the static ProjectileCoordinator."
	)
	_expect(
		source.contains("@onready var world_flow_coordinator:")
		and source.contains("$WorldFlowCoordinator")
		and source.contains("world_flow_coordinator.receive_flow_state(")
		and not source.contains("func _on_host_flow_state_changed("),
		"MpGame must expose only a thin façade over the static WorldFlowCoordinator."
	)
	_expect(
		projectile_source.contains("FIRE_SORCERER_FIREBALL_VOLLEY_SCENE")
		and projectile_source.contains(
			"FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE"
		)
		and projectile_source.contains('&"fire_sorcerer_fireball_volley"')
		and projectile_source.contains(
			'&"fire_sorcerer_elite_fireball_volley"'
		)
		and projectile_source.contains(
			"target = _get_player(target_peer_id)"
		)
		and projectile_source.contains(
			"target = _resolve_mode_world_target(target_enemy_net_id)"
		)
		and projectile_source.contains("as FireSorcererFireballVolley")
		and projectile_source.contains("_prepare_enemy_network_projectile(volley)")
		and projectile_source.contains(
			'projectile.has_method("simulate_compensated_motion")'
		),
		(
			"ProjectileCoordinator must instantiate, target, time-compensate, and lifetime-compensate "
			+ "Fire Sorcerer volleys."
		)
	)
	var player_source := FileAccess.get_file_as_string("res://scene/player/player.gd")
	_expect(
		not player_source.contains("const LINGLAN_SKILL2_ROCKET_SCENE := preload"),
		"Base Player must not pull a Linglan rocket scene into tower-defense loading."
	)
	_expect(
		source.contains("game.defer_runtime_activation()")
		and source.contains("net_manager.report_game_loaded()"),
		"MpGame must defer runtime activation before reporting local readiness."
	)
	for runtime_script_path in [
		"res://scene/combat/runtime/wave_combat_runtime_base.gd",
		"res://scene/game_modes/tower_defense/tower_defense_game.gd",
	]:
		var runtime_source := FileAccess.get_file_as_string(runtime_script_path)
		_expect(
			not runtime_source.contains("@export var singleplayer_campaign: WaveCampaignConfig = preload")
			and not runtime_source.contains("@export var multiplayer_campaign: WaveCampaignConfig = preload"),
			"Each runtime must load only the active player-count campaign."
		)


func _test_host_ready_barrier() -> void:
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	_expect(net_manager != null, "NetManager autoload must exist for loading-barrier coverage.")
	if net_manager == null:
		return
	net_manager.disconnect_from_game()
	net_manager.local_player_name = "LoadingSmokeHost"
	net_manager.set_local_character_id(&"weishidaier", true)
	var error := net_manager.host_create_lan_server(TEST_PORT)
	_expect(error == OK, "Loading-barrier smoke must create a local host.")
	if error != OK:
		return
	net_manager.host_start_game()
	var progress := net_manager.get_game_load_progress()
	var session_id := int(progress.get("session_id", 0))
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.LOADING_GAME
		and int(progress.get("ready", -1)) == 0
		and int(progress.get("total", -1)) == 1
		and session_id > 0,
		"Host start must freeze the expected roster before scene loading."
	)
	net_manager.mark_in_game()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.LOADING_GAME,
		"Manual mark_in_game must not bypass an incomplete ready roster."
	)
	net_manager.host_start_game()
	_expect(
		int(net_manager.get_game_load_progress().get("session_id", 0)) == session_id,
		"A duplicate start request must not replace an active loading session."
	)
	net_manager.report_game_loaded()
	var completed_progress := net_manager.get_game_load_progress()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME
		and net_manager.host_game_ready
		and int(completed_progress.get("ready", -1)) == 1
		and int(completed_progress.get("total", -1)) == 1,
		"The final expected peer report must complete the loading barrier."
	)
	net_manager.disconnect_from_game()
	var reset_progress := net_manager.get_game_load_progress()
	_expect(
		int(reset_progress.get("ready", -1)) == 0
		and int(reset_progress.get("total", -1)) == 0
		and int(reset_progress.get("session_id", -1)) == 0,
		"Disconnect must clear the complete loading-session snapshot."
	)


func _test_singleplayer_coordinator_flow() -> void:
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	if coordinator == null:
		return
	var load_errors: Array[String] = []
	var failure_callback := func(message: String) -> void:
		load_errors.append(message)
	coordinator.loading_failed.connect(failure_callback)
	coordinator.begin_singleplayer("res://scene/game_modes/standard/standard_game.tscn")
	var standard_attempt: RefCounted = coordinator.get("_active_attempt")
	var deadline_msec := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline_msec:
		if not coordinator.is_loading():
			break
		await process_frame
	coordinator.loading_failed.disconnect(failure_callback)
	_expect(load_errors.is_empty(), "Single-player coordinator flow must not report a load error.")
	_expect(
		standard_attempt != null
		and bool(standard_attempt.get("released"))
		and standard_attempt.get("release_reason") == &"completed"
		and coordinator.get("_active_attempt") == null
		and coordinator.get("_failed_retry_request") == null,
		"成功完成后必须释放加载尝试，且不能遗留可重试的旧请求。"
	)
	var runtime := current_scene as CombatRuntimeBase
	_expect(
		runtime != null
		and runtime.scene_file_path == "res://scene/game_modes/standard/standard_game.tscn"
		and runtime.is_runtime_preparation_complete()
		and runtime.runtime_activated
		and runtime.process_mode == Node.PROCESS_MODE_INHERIT,
		"Single-player loading must prepare, activate, and reveal the selected runtime."
	)
	for path in LINGLAN_BOSS_RUNTIME_RESOURCE_PATHS:
		_expect(
			ResourceLoader.has_cached(path),
			"Standard loading must retain delayed Boss runtime resource: %s" % path
		)
	_expect_tango_projectile_pool(runtime)
	_expect_gunner_projectile_pool(runtime)
	_expect_drone_projectile_pool(runtime)

	load_errors.clear()
	coordinator.loading_failed.connect(failure_callback)
	coordinator.begin_singleplayer("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
	deadline_msec = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline_msec:
		if not coordinator.is_loading():
			break
		await process_frame
	coordinator.loading_failed.disconnect(failure_callback)
	_expect(load_errors.is_empty(), "Tower-defense coordinator flow must not report a load error.")
	var tower_runtime := current_scene as TowerDefenseGame
	_expect(
		tower_runtime != null
		and tower_runtime.scene_file_path == "res://scene/game_modes/tower_defense/tower_defense_game.tscn"
		and tower_runtime.supports_tower_defense()
		and tower_runtime.is_runtime_preparation_complete()
		and tower_runtime.runtime_activated
		and bool(tower_runtime.get("plant_lifecycle_shader_prewarmed")),
		"Tower-defense loading must finish staged preparation before activation."
	)
	_expect_sorcerer_projectile_pools(tower_runtime, 48, 704)
	_expect_tango_projectile_pool(tower_runtime)
	_expect_gunner_projectile_pool(tower_runtime)
	_expect_drone_projectile_pool(tower_runtime)
	await physics_frame
	await physics_frame
	_expect_lifecycle_prewarm_pool_released(tower_runtime)
	for path in TOWER_DEFENSE_HIGH_FREQUENCY_RESOURCE_PATHS:
		_expect(
			ResourceLoader.has_cached(path),
			"Tower-defense preparation must cache first-use resource: %s" % path
		)
	for path in LINGLAN_BOSS_RUNTIME_RESOURCE_PATHS:
		_expect(
			ResourceLoader.has_cached(path),
			"Tower-defense loading must retain its Linglan Boss runtime resource: %s" % path
		)
	for path in LINGLAN_TOWER_SLIME_RESOURCE_PATHS:
		_expect(
			ResourceLoader.has_cached(path),
			"Tower-defense loading must retain Linglan's random-slime resource: %s" % path
		)

	load_errors.clear()
	coordinator.loading_failed.connect(failure_callback)
	coordinator.begin_singleplayer(
		"res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p2.tscn",
		GameModeDefinition.SelectionAudience.DEVELOPMENT
	)
	deadline_msec = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline_msec:
		if not coordinator.is_loading():
			break
		await process_frame
	coordinator.loading_failed.disconnect(failure_callback)
	_expect(load_errors.is_empty(), "Test-arena P2 coordinator flow must not report a load error.")
	var p2_runtime := current_scene as TestGrassArenaP2
	_expect(
		p2_runtime != null
		and p2_runtime.scene_file_path
		== "res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p2.tscn"
		and p2_runtime.supports_tower_defense()
		and p2_runtime.is_runtime_preparation_complete()
		and p2_runtime.runtime_activated
		and p2_runtime.campaign_coordinator.active_campaign
		== p2_runtime.singleplayer_campaign,
		"P2 loading must retain its dedicated Campaign and activate the inherited tower runtime."
	)


func _test_mp_game_preparation_barrier() -> void:
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	if net_manager == null:
		return
	net_manager.disconnect_from_game()
	net_manager.local_player_name = "MpPreparationHost"
	net_manager.set_local_character_id(&"weishidaier", true)
	var error := net_manager.host_create_lan_server(TEST_PORT + 1)
	_expect(error == OK, "MpGame preparation smoke must create a local host.")
	if error != OK:
		return
	_expect(
		net_manager.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE),
		"MpGame preparation smoke must select tower-defense mode."
	)
	net_manager.host_start_game()
	var mp_game := MP_GAME_SCENE.instantiate()
	root.add_child(mp_game)
	var deadline_msec := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline_msec:
		if net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME:
			break
		await process_frame
	var runtime := mp_game.get("game") as TowerDefenseGame
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME
		and runtime != null
		and runtime.supports_tower_defense()
		and runtime.is_runtime_preparation_complete()
		and runtime.runtime_activated
		and runtime.process_mode == Node.PROCESS_MODE_INHERIT
		and bool(runtime.get("plant_lifecycle_shader_prewarmed")),
		"MpGame must finish preparation while disabled, report ready, then activate."
	)
	mp_game.queue_free()
	await process_frame
	net_manager.disconnect_from_game()

	var test_arena_contracts := [
		[
			NetManagerStore.GameMode.TEST_ARENA_P1,
			"res://scene/game_modes/tower_defense/test_arenas/test_grass_arena.tscn",
			"res://resources/config/campaigns/test_arena/multiplayer/campaign.tres",
		],
		[
			NetManagerStore.GameMode.TEST_ARENA_P1B,
			"res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p1b.tscn",
			"res://resources/config/campaigns/test_arena/p1b/multiplayer/campaign.tres",
		],
		[
			NetManagerStore.GameMode.TEST_ARENA_P1C,
			"res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p1c.tscn",
			"res://resources/config/campaigns/test_arena/p1c/multiplayer/campaign.tres",
		],
		[
			NetManagerStore.GameMode.TEST_ARENA_P1D,
			"res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p1d.tscn",
			"res://resources/config/campaigns/test_arena/p1d/multiplayer/campaign.tres",
		],
		[
			NetManagerStore.GameMode.TEST_ARENA_P2,
			"res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p2.tscn",
			"res://resources/config/campaigns/test_arena/p2/multiplayer/campaign.tres",
		],
	]
	for contract_index in test_arena_contracts.size():
		var contract: Array = test_arena_contracts[contract_index]
		var game_mode := int(contract[0]) as NetManagerStore.GameMode
		var expected_scene_path := str(contract[1])
		var expected_campaign_path := str(contract[2])
		_expect(
			net_manager.set_development_host_game_mode_for_fixture(game_mode),
			"Test-arena fixture must explicitly select development mode %d." % game_mode
		)
		error = net_manager.host_create_lan_server(TEST_PORT + 2 + contract_index, 2)
		_expect(
			error == OK,
			"Test-arena MpGame preparation smoke must create a two-player-capacity Host."
		)
		if error != OK:
			continue
		net_manager.host_start_game()
		var test_mp_game := MP_GAME_SCENE.instantiate()
		root.add_child(test_mp_game)
		deadline_msec = Time.get_ticks_msec() + 30000
		while Time.get_ticks_msec() < deadline_msec:
			if net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME:
				break
			await process_frame
		var test_runtime := test_mp_game.get("game") as TestGrassArena
		_expect(
			net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME
			and net_manager.get_room_max_players() == 2
			and test_runtime != null
			and test_runtime.scene_file_path == expected_scene_path
			and test_runtime.campaign_coordinator.active_campaign != null
			and test_runtime.campaign_coordinator.active_campaign.resource_path
			== expected_campaign_path
			and test_runtime.is_runtime_preparation_complete()
			and test_runtime.runtime_activated
			and is_zero_approx(
				test_runtime.progression_config.enemy_count_per_extra_player_ratio
			),
			(
				"MpGame mode %d must prepare and activate its exact test scene/Campaign "
				+ "without player-count enemy scaling."
			) % game_mode
		)
		test_mp_game.queue_free()
		await process_frame
		net_manager.disconnect_from_game()


func _expect_lifecycle_prewarm_pool_released(runtime: CombatRuntimeBase) -> void:
	var tower_runtime := runtime as TowerDefenseGame
	if tower_runtime == null:
		return
	for scene_path in [
		"res://scene/game_modes/tower_defense/plant/presentation/plant_placement_particles.tscn",
		"res://scene/game_modes/tower_defense/plant/presentation/plant_removal_smoke.tscn",
	]:
		var metrics := tower_runtime.session_object_pool.get_metrics(scene_path)
		_expect(
			int(metrics.get("in_use", -1)) == 0
			and int(metrics.get("pending_release", -1)) == 0,
			"Lifecycle VFX prewarm lease must return to its pool: %s" % scene_path
		)


func _expect_sorcerer_projectile_pools(
	runtime: CombatRuntimeBase,
	expected_prewarm_count: int,
	expected_retained_capacity: int
) -> void:
	if runtime == null:
		return
	var object_pool := runtime.get_node_or_null("SessionObjectPool") as SessionObjectPool
	_expect(object_pool != null, "Runtime must expose its projectile object pool.")
	if object_pool == null:
		return
	for scene_path in [
		"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn",
		"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn",
		"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn",
	]:
		var metrics := object_pool.get_metrics(scene_path)
		_expect(
			int(metrics.get("created", -1)) == expected_prewarm_count
			and int(metrics.get("inactive", -1)) == expected_prewarm_count
			and int(metrics.get("in_use", -1)) == 0
			and int(metrics.get("pending_release", -1)) == 0
			and int(metrics.get("overflow", -1)) == 0
			and int(metrics.get("dropped", -1)) == 0
			and int(metrics.get("retained_capacity", -1))
				== expected_retained_capacity,
			(
				"%s pool must prewarm %d leases with capacity %d."
				% [
					scene_path,
					expected_prewarm_count,
					expected_retained_capacity,
				]
			)
		)


func _expect_tango_projectile_pool(runtime: CombatRuntimeBase) -> void:
	if runtime == null:
		return
	var object_pool := runtime.get_node_or_null("SessionObjectPool") as SessionObjectPool
	_expect(object_pool != null, "Runtime must expose Tango's projectile object pool.")
	if object_pool == null:
		return
	var scene_path := "res://scene/player/tango/tango_laser_bullet.tscn"
	var metrics := object_pool.get_metrics(scene_path)
	_expect(
		int(metrics.get("created", -1)) == 64
		and int(metrics.get("inactive", -1)) == 64
		and int(metrics.get("in_use", -1)) == 0
		and int(metrics.get("pending_release", -1)) == 0
		and int(metrics.get("overflow", -1)) == 0
		and int(metrics.get("dropped", -1)) == 0
		and int(metrics.get("retained_capacity", -1)) == 768,
		"Tango laser pool must prewarm 64 leases with retained capacity 768."
	)


func _expect_gunner_projectile_pool(runtime: CombatRuntimeBase) -> void:
	if runtime == null:
		return
	var object_pool := runtime.get_node_or_null("SessionObjectPool") as SessionObjectPool
	_expect(object_pool != null, "Runtime must expose the gunner projectile object pool.")
	if object_pool == null:
		return
	for scene_path in [
		"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn",
		"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn",
	]:
		var metrics := object_pool.get_metrics(scene_path)
		_expect(
			int(metrics.get("created", -1)) == 0
			and int(metrics.get("inactive", -1)) == 0
			and int(metrics.get("in_use", -1)) == 0
			and int(metrics.get("retained_capacity", -1)) == 96,
			"Gunner bullet pool must register lazily with retained capacity 96: %s"
			% scene_path
		)


func _expect_drone_projectile_pool(runtime: CombatRuntimeBase) -> void:
	if runtime == null:
		return
	var motion_system := runtime.get_node_or_null(
		"CombatRobotDroneMotionSystem"
	) as CombatRobotDroneMotionSystem
	_expect(
		motion_system != null and not motion_system.is_physics_processing(),
		"Runtime must expose an idle event-driven suicide-drone motion system."
	)
	var object_pool := runtime.get_node_or_null("SessionObjectPool") as SessionObjectPool
	_expect(object_pool != null, "Runtime must expose the suicide-drone object pool.")
	if object_pool == null:
		return
	for scene_path in [
		"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn",
		"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn",
	]:
		var metrics := object_pool.get_metrics(scene_path)
		_expect(
			int(metrics.get("created", -1)) == 0
			and int(metrics.get("inactive", -1)) == 0
			and int(metrics.get("in_use", -1)) == 0
			and int(metrics.get("retained_capacity", -1)) == 384,
			"Suicide-drone pool must register lazily with retained capacity 384: %s"
			% scene_path
		)


func _finish() -> void:
	if failures.is_empty():
		print("GAME_LOADING_BARRIER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
