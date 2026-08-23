extends SceneTree

const NORMAL_CONFIG: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/underground_sewer_01.tres"
)
const EMERGENCY_CONFIG: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/emergency_underground_sewer_01.tres"
)
const NORMAL_REWARD: RogueCombatRewardConfig = preload(
	"res://resources/config/rogue_combat/reward_encounter_01.tres"
)
const EMERGENCY_REWARD: RogueCombatRewardConfig = preload(
	"res://resources/config/rogue_combat/reward_emergency_combat.tres"
)
const GAME_SCENE: PackedScene = preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_04.tscn"
)
const YUANSHI_INSECT_FAST: EnemyConfig = preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const YUANSHI_INSECT_FIRE_RANGED: EnemyConfig = preload(
	"res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"
)
const YUANSHI_INSECT_BOMBER: EnemyConfig = preload(
	"res://resources/config/enemies/yuanshi_insect_bomber.tres"
)
const CAPOO_MAGE: EnemyConfig = preload(
	"res://resources/config/enemies/capoo_mage.tres"
)
const STONE_GOLEM: EnemyConfig = preload(
	"res://resources/config/enemies/stone_golem.tres"
)
const COMBAT_ROBOT_GUNNER_ELITE: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_gunner_elite.tres"
)
const YUANSHI_FIRE_PROJECTILE_SCENE: PackedScene = preload(
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn"
)
const COMBAT_ROBOT_GUNNER_ELITE_BULLET_SCENE: PackedScene = preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn"
)
const GAME_SCENE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game_04.tscn"
)
const BACKGROUND_PATH := (
	"res://resources/texture/rogue_combat/underground_sewer/"
	+ "underground_sewer_background.png"
)
const EXPECTED_SPAWN_POINT_MASK := (
	WaveConfig.SPAWN_POINT_1_MASK | WaveConfig.SPAWN_POINT_2_MASK
)
const FIRE_PROJECTILE_PREWARM_COUNT := 48
const FIRE_PROJECTILE_RETAINED_CAPACITY := 192
const ELITE_GUNNER_BULLET_POOL_CAPACITY := 144
const NORMAL_COUNTS: Array[int] = [20, 20, 4, 3]
const EMERGENCY_AUTHORED_COUNTS: Array[int] = [20, 2, 15, 10]

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_encounter_configs()
	_test_briefing_visuals()
	_test_normal_campaign()
	_test_emergency_campaign()
	_test_occurrence_counts()
	_test_game_04_scene_contract()
	await _test_projectile_pool_overrides()
	_finish()


func _test_encounter_configs() -> void:
	_expect(
		NORMAL_CONFIG.validate_config().is_empty()
		and NORMAL_CONFIG.is_ready_to_enable(),
		"地下水道普通作战配置必须完整有效：%s"
		% [NORMAL_CONFIG.validate_config()]
	)
	_expect(
		NORMAL_CONFIG.encounter_id == &"underground_sewer_01"
		and NORMAL_CONFIG.event_title == "地下水道"
		and NORMAL_CONFIG.combat_scene_path == GAME_SCENE_PATH
		and NORMAL_CONFIG.preparation_seconds == 3
		and NORMAL_CONFIG.combat_limit_seconds == 90
		and NORMAL_CONFIG.reward_config == NORMAL_REWARD
		and NORMAL_CONFIG.extra_xirang == 500
		and NORMAL_CONFIG.enemy_count_increase_minimum_percent == 0
		and NORMAL_CONFIG.enemy_count_increase_maximum_percent == 0,
		"地下水道普通作战必须绑定game04、普通奖励、3秒准备、90秒时限且不增幅敌人数。"
	)
	_expect(
		EMERGENCY_CONFIG.validate_config().is_empty()
		and EMERGENCY_CONFIG.is_ready_to_enable(),
		"地下水道紧急作战配置必须完整有效：%s"
		% [EMERGENCY_CONFIG.validate_config()]
	)
	_expect(
		EMERGENCY_CONFIG.encounter_id == &"emergency_underground_sewer_01"
		and EMERGENCY_CONFIG.event_title == "紧急作战：地下水道"
		and EMERGENCY_CONFIG.combat_scene_path == GAME_SCENE_PATH
		and EMERGENCY_CONFIG.preparation_seconds == 3
		and EMERGENCY_CONFIG.combat_limit_seconds == 90
		and EMERGENCY_CONFIG.reward_config == EMERGENCY_REWARD
		and EMERGENCY_CONFIG.extra_xirang == 1000
		and EMERGENCY_CONFIG.enemy_count_increase_minimum_percent == 0
		and EMERGENCY_CONFIG.enemy_count_increase_maximum_percent == 0,
		"地下水道紧急作战必须复用game04、紧急奖励，并严格保持固定敌人编成。"
	)
	_expect(
		NORMAL_CONFIG.get_spawn_point_mask() == EXPECTED_SPAWN_POINT_MASK
		and EMERGENCY_CONFIG.get_spawn_point_mask()
		== EXPECTED_SPAWN_POINT_MASK,
		"地下水道普通与紧急作战都只能启用Spawn1、Spawn2（mask=3）。"
	)


func _test_briefing_visuals() -> void:
	for config in [NORMAL_CONFIG, EMERGENCY_CONFIG]:
		var visual := config.briefing_visual as AtlasTexture
		_expect(visual != null, "%s简报必须使用背景AtlasTexture裁片。" % config.event_title)
		if visual == null:
			continue
		_expect(
			visual.region == Rect2(48, 72, 320, 72)
			and visual.atlas != null
			and visual.atlas.resource_path == BACKGROUND_PATH,
			"%s简报必须精确裁取地下水道正式背景。" % config.event_title
		)


func _test_normal_campaign() -> void:
	var campaign := NORMAL_CONFIG.campaign
	_expect(campaign != null, "地下水道普通作战必须绑定独立Campaign。")
	if campaign == null:
		return
	_expect(
		campaign.validate_campaign().is_empty()
		and campaign.campaign_id == &"rogue_combat_underground_sewer_01"
		and campaign.flow_graph != null
		and campaign.flow_graph.graph_name == "Rouge 普通作战：地下水道",
		"地下水道普通Campaign与FlowGraph必须使用专属稳定身份。"
	)
	var wave := _get_only_wave(campaign, "地下水道普通作战")
	if wave == null:
		return
	_expect_common_wave_contract(wave, "地下水道普通作战")
	_expect_wave_entries(
		wave,
		[
			YUANSHI_INSECT_FAST,
			YUANSHI_INSECT_FIRE_RANGED,
			YUANSHI_INSECT_BOMBER,
			CAPOO_MAGE,
		],
		NORMAL_COUNTS,
		"地下水道普通作战"
	)


func _test_emergency_campaign() -> void:
	var campaign := EMERGENCY_CONFIG.campaign
	_expect(campaign != null, "地下水道紧急作战必须绑定独立Campaign。")
	if campaign == null:
		return
	_expect(
		campaign.validate_campaign().is_empty()
		and campaign.campaign_id
		== &"rogue_combat_emergency_underground_sewer_01"
		and campaign.flow_graph != null
		and campaign.flow_graph.graph_name == "Rouge 紧急作战：地下水道",
		"地下水道紧急Campaign与FlowGraph必须使用专属稳定身份。"
	)
	var wave := _get_only_wave(campaign, "地下水道紧急作战")
	if wave == null:
		return
	_expect_common_wave_contract(wave, "地下水道紧急作战")
	_expect_wave_entries(
		wave,
		[
			YUANSHI_INSECT_FAST,
			STONE_GOLEM,
			YUANSHI_INSECT_FIRE_RANGED,
			COMBAT_ROBOT_GUNNER_ELITE,
		],
		EMERGENCY_AUTHORED_COUNTS,
		"地下水道紧急作战"
	)


func _test_occurrence_counts() -> void:
	var normal_occurrence := NORMAL_CONFIG.build_occurrence_campaign(
		"normal:underground_sewer:count-contract"
	)
	_expect(normal_occurrence != null, "地下水道普通作战必须能构建本次节点Campaign。")
	if normal_occurrence != null:
		_expect(
			_get_wave_counts(normal_occurrence.get_waves()[0]) == NORMAL_COUNTS,
			"普通地下水道本次节点必须保持20/20/4/3，共47只敌人。"
		)

	for sample_index in range(64):
		var occurrence_key := "emergency:underground_sewer:%d" % sample_index
		var first := EMERGENCY_CONFIG.build_occurrence_campaign(occurrence_key)
		var repeated := EMERGENCY_CONFIG.build_occurrence_campaign(occurrence_key)
		_expect(first != null and repeated != null, "地下水道紧急作战必须能构建确定性本次节点。")
		if first == null or repeated == null:
			continue
		var first_counts := _get_wave_counts(first.get_waves()[0])
		var repeated_counts := _get_wave_counts(repeated.get_waves()[0])
		_expect(
			first_counts == repeated_counts,
			"相同occurrence key必须得到相同地下水道紧急敌人数。"
		)
		_expect(
			first_counts == EMERGENCY_AUTHORED_COUNTS
			and _sum_counts(first_counts) == 47,
			"地下水道紧急作战每次都必须严格保持20/2/15/10，共47只敌人。"
		)
	_expect(
		_get_wave_counts(EMERGENCY_CONFIG.campaign.get_waves()[0])
		== EMERGENCY_AUTHORED_COUNTS,
		"构建紧急本次节点不得污染20/2/15/10的authored Wave。"
	)


func _test_game_04_scene_contract() -> void:
	var game := GAME_SCENE.instantiate() as RogueCombatGame
	_expect(game != null, "地下水道Game04场景必须可实例化。")
	if game == null:
		return
	_expect(
		game.singleplayer_campaign == NORMAL_CONFIG.campaign
		and game.multiplayer_campaign == NORMAL_CONFIG.campaign,
		"Game04单人与多人默认入口必须绑定地下水道普通Campaign。"
	)
	_expect(
		game.validate_encounter_scene_contract(
			NORMAL_CONFIG.get_spawn_point_mask()
		).is_empty()
		and game.validate_encounter_scene_contract(
			EMERGENCY_CONFIG.get_spawn_point_mask()
		).is_empty(),
		"Game04必须同时满足普通与紧急地下水道的两点出生场景合同。"
	)
	game.free()


func _test_projectile_pool_overrides() -> void:
	for source_path in [
		"res://scene/game_modes/rogue/combat/rogue_combat_singleplayer_coordinator.gd",
		"res://scene/game_modes/rogue/combat/rogue_combat_multiplayer_coordinator.gd",
	]:
		var source := FileAccess.get_file_as_string(source_path)
		_expect(
			source.contains("UNDERGROUND_SEWER_COMBAT_CONFIG_ID")
			and source.contains("EMERGENCY_UNDERGROUND_SEWER_COMBAT_CONFIG_ID")
			and source.contains(
				"UNDERGROUND_SEWER_FIRE_PROJECTILE_PREWARM_COUNT := 48"
			)
			and source.contains(
				"UNDERGROUND_SEWER_FIRE_PROJECTILE_RETAINED_CAPACITY := 192"
			)
			and source.contains(
				"_apply_underground_sewer_projectile_pool_overrides("
			)
			and not source.contains("register_combat_robot_gunner")
			and not source.contains("ELITE_BULLET_POOL_CAPACITY"),
			"%s必须只保留原石虫火焰弹池，不得恢复旧枪手弹丸池。" % source_path
		)

	var pool := SessionObjectPool.new()
	root.add_child(pool)
	# 模拟WaveCombatRuntimeBase先注册公共池，再由地下水道遭遇原地提升预热容量。
	pool.register_scene(YUANSHI_FIRE_PROJECTILE_SCENE, 24, 192)
	pool.register_scene(
		YUANSHI_FIRE_PROJECTILE_SCENE,
		FIRE_PROJECTILE_PREWARM_COUNT,
		FIRE_PROJECTILE_RETAINED_CAPACITY
	)
	pool.register_scene(
		COMBAT_ROBOT_GUNNER_ELITE_BULLET_SCENE,
		0,
		96
	)
	pool.register_scene(
		COMBAT_ROBOT_GUNNER_ELITE_BULLET_SCENE,
		ELITE_GUNNER_BULLET_POOL_CAPACITY,
		ELITE_GUNNER_BULLET_POOL_CAPACITY
	)
	_expect_pool_metrics(
		pool,
		YUANSHI_FIRE_PROJECTILE_SCENE,
		FIRE_PROJECTILE_PREWARM_COUNT,
		FIRE_PROJECTILE_RETAINED_CAPACITY,
		"地下水道火焰原石虫弹丸池"
	)
	_expect_pool_metrics(
		pool,
		COMBAT_ROBOT_GUNNER_ELITE_BULLET_SCENE,
		ELITE_GUNNER_BULLET_POOL_CAPACITY,
		ELITE_GUNNER_BULLET_POOL_CAPACITY,
		"紧急地下水道精英枪手弹丸池"
	)

	for round_index in range(2):
		var leased: Array[Node] = []
		for projectile_index in range(FIRE_PROJECTILE_PREWARM_COUNT):
			leased.append(pool.acquire(YUANSHI_FIRE_PROJECTILE_SCENE))
		for projectile_index in range(ELITE_GUNNER_BULLET_POOL_CAPACITY):
			leased.append(pool.acquire(COMBAT_ROBOT_GUNNER_ELITE_BULLET_SCENE))
		var lease_ids: Dictionary = {}
		for projectile in leased:
			if projectile != null:
				lease_ids[projectile.get_instance_id()] = true
		_expect(
			lease_ids.size() == leased.size(),
			"第%d轮地下水道弹丸池必须提供完整且不重复的预热租约。" % (round_index + 1)
		)
		for projectile in leased:
			_expect(
				projectile != null and pool.release(projectile),
				"第%d轮地下水道弹丸租约必须可完整归还。" % (round_index + 1)
			)
		await physics_frame
		await physics_frame

	_expect_pool_metrics(
		pool,
		YUANSHI_FIRE_PROJECTILE_SCENE,
		FIRE_PROJECTILE_PREWARM_COUNT,
		FIRE_PROJECTILE_RETAINED_CAPACITY,
		"两轮后的地下水道火焰原石虫弹丸池"
	)
	_expect_pool_metrics(
		pool,
		COMBAT_ROBOT_GUNNER_ELITE_BULLET_SCENE,
		ELITE_GUNNER_BULLET_POOL_CAPACITY,
		ELITE_GUNNER_BULLET_POOL_CAPACITY,
		"两轮后的紧急地下水道精英枪手弹丸池"
	)
	pool.queue_free()
	await process_frame


func _expect_pool_metrics(
	pool: SessionObjectPool,
	scene: PackedScene,
	expected_created: int,
	expected_capacity: int,
	label: String
) -> void:
	var metrics := pool.get_metrics(scene.resource_path)
	_expect(
		int(metrics.get("created", -1)) == expected_created
		and int(metrics.get("inactive", -1)) == expected_created
		and int(metrics.get("retained_capacity", -1)) == expected_capacity
		and int(metrics.get("in_use", -1)) == 0
		and int(metrics.get("pending_release", -1)) == 0
		and int(metrics.get("overflow", -1)) == 0
		and int(metrics.get("dropped", -1)) == 0,
		"%s必须保持预热、回收容量、零溢出与零丢弃合同：%s" % [label, metrics]
	)


func _get_only_wave(campaign: WaveCampaignConfig, label: String) -> WaveConfig:
	var waves := campaign.get_waves()
	_expect(waves.size() == 1, "%s Campaign必须只有一个终点波次。" % label)
	if waves.size() != 1:
		return null
	var wave := waves[0]
	_expect(
		campaign.flow_graph.start_step == wave
		and campaign.flow_graph.steps.size() == 1
		and wave.exits.is_empty(),
		"%s必须从唯一且无出口的终点波次开始。" % label
	)
	return wave


func _expect_common_wave_contract(wave: WaveConfig, label: String) -> void:
	_expect(
		wave.enemy_entries.size() == 4
		and wave.get_total_enemy_count() == 47
		and wave.spawn_point_mask == EXPECTED_SPAWN_POINT_MASK
		and wave.get_enabled_spawn_point_names() == [&"Spawn1", &"Spawn2"]
		and wave.spawn_point_order
		== WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG
		and wave.spawn_order == WaveConfig.SpawnOrder.SHUFFLED
		and is_equal_approx(wave.spawn_interval, 0.2)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == 15,
		"%s必须严格为4条目、47敌人、mask3、0.2秒批1、cap15与均衡乱序。" % label
	)


func _expect_wave_entries(
	wave: WaveConfig,
	expected_configs: Array,
	expected_counts: Array[int],
	label: String
) -> void:
	_expect(wave.enemy_entries.size() == expected_configs.size(), "%s敌人条目数错误。" % label)
	for entry_index in range(mini(wave.enemy_entries.size(), expected_configs.size())):
		var entry := wave.enemy_entries[entry_index]
		_expect(
			entry != null
			and entry.enemy_config == expected_configs[entry_index]
			and entry.count == expected_counts[entry_index],
			"%s第%d条敌人配置或数量错误。" % [label, entry_index + 1]
		)


func _get_wave_counts(wave: WaveConfig) -> Array[int]:
	var result: Array[int] = []
	for entry in wave.enemy_entries:
		result.append(entry.count)
	return result


func _sum_counts(counts: Array[int]) -> int:
	var result := 0
	for count in counts:
		result += count
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("ROGUE_UNDERGROUND_SEWER_RESOURCE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
