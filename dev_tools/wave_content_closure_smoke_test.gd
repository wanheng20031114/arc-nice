extends SceneTree

const CAMPAIGN_ROOT := "res://resources/config/campaigns"
const EXPECTED_CAMPAIGN_COUNT := 26
const EXPECTED_CHECK_GROUPS := 6
const VALID_ENEMY_SCENE_PATH := "res://scene/enemy/slime/slime_basic.tscn"
const VALID_PICKUP_PATH := "res://resources/config/materials/material_wood.tres"
const BOSS_ENEMY_CONFIG_PATH := "res://resources/config/enemies/linglan_boss.tres"

var failures: Array[String] = []
var completed_check_groups := 0


func _init() -> void:
	_test_all_campaign_resources()
	_test_entry_order_and_ranges()
	_test_bad_enemy_config()
	_test_boss_content_closure()
	_test_drop_table_cycle()
	_test_bad_drop_rules()
	if completed_check_groups != EXPECTED_CHECK_GROUPS:
		failures.append(
			"校验脚本未完成所有检查组：%d/%d。"
			% [completed_check_groups, EXPECTED_CHECK_GROUPS]
		)
	if failures.is_empty():
		print("WAVE_CONTENT_CLOSURE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_all_campaign_resources() -> void:
	var campaign_paths := PackedStringArray()
	_collect_campaign_paths(CAMPAIGN_ROOT, campaign_paths)
	_expect(
		campaign_paths.size() == EXPECTED_CAMPAIGN_COUNT,
		"应递归找到 %d 个 Campaign，实际为 %d。"
		% [EXPECTED_CAMPAIGN_COUNT, campaign_paths.size()]
	)
	for campaign_path in campaign_paths:
		var campaign := load(campaign_path) as WaveCampaignConfig
		_expect(campaign != null, "Campaign 无法加载：%s" % campaign_path)
		if campaign == null:
			continue
		var errors := campaign.validate_campaign()
		_expect(
			errors.is_empty(),
			"Campaign 内容闭包校验失败：%s\n%s"
			% [campaign_path, "\n".join(errors)]
		)
	completed_check_groups += 1


func _test_entry_order_and_ranges() -> void:
	var entries: Array[WaveEnemyEntry] = []
	entries.append(null)
	var invalid_entry := WaveEnemyEntry.new()
	invalid_entry.enemy_config = load(
		"res://resources/config/enemies/slime.tres"
	) as EnemyConfig
	invalid_entry.count = 0
	invalid_entry.xirang_kill_reward_override = -2
	entries.append(invalid_entry)
	var campaign := _make_campaign(entries)
	var expected := PackedStringArray([
		"Campaign[fixture].flow_graph.steps[0].enemy_entries[0]：不能为空。",
		"Campaign[fixture].flow_graph.steps[0].enemy_entries[1]：count 必须至少为 1。",
		(
			"Campaign[fixture].flow_graph.steps[0].enemy_entries[1]："
			+ "xirang_kill_reward_override 不能小于 -1。"
		),
	])
	var first_errors := campaign.validate_campaign()
	var second_errors := campaign.validate_campaign()
	_expect(first_errors == expected, "空条目与数值边界错误顺序不符合契约。")
	_expect(second_errors == first_errors, "同一 Campaign 的错误顺序必须确定。")
	completed_check_groups += 1


func _test_bad_enemy_config() -> void:
	var enemy := _make_valid_enemy()
	enemy.enemy_scene = null
	enemy.max_health = 0
	enemy.move_speed = NAN
	enemy.terrain_traversal_types = 0
	enemy.drop_table = null
	var errors := _make_campaign_with_enemy(enemy).validate_campaign()
	var enemy_path := (
		"Campaign[fixture].flow_graph.steps[0].enemy_entries[0].enemy_config"
	)
	var expected := PackedStringArray([
		"%s：缺少 enemy_scene。" % enemy_path,
		"%s：max_health 必须至少为 1。" % enemy_path,
		"%s：move_speed 必须是非负有限数。" % enemy_path,
		"%s：terrain_traversal_types 不能为空。" % enemy_path,
		"%s.drop_table：不能为空。" % enemy_path,
	])
	_expect(errors == expected, "EnemyConfig 关键运行时契约错误不稳定。")
	completed_check_groups += 1


func _test_drop_table_cycle() -> void:
	var first_table := EnemyDropTable.new()
	var second_table := EnemyDropTable.new()
	first_table.base_table = second_table
	second_table.base_table = first_table
	var enemy := _make_valid_enemy()
	enemy.drop_table = first_table
	var errors := _make_campaign_with_enemy(enemy).validate_campaign()
	var drop_path := (
		"Campaign[fixture].flow_graph.steps[0].enemy_entries[0].enemy_config.drop_table"
	)
	var expected := PackedStringArray([
		(
			"%s.base_table.base_table：base_table 形成循环，指回 %s。"
			% [drop_path, drop_path]
		),
	])
	_expect(errors == expected, "DropTable base_table 循环必须给出结构化路径。")
	# RefCounted 循环不会自动释放，夹具在退出前显式拆链。
	first_table.base_table = null
	second_table.base_table = null
	completed_check_groups += 1


func _test_boss_content_closure() -> void:
	var path_only_boss := BossConfig.new()
	path_only_boss.enemy_config_path = BOSS_ENEMY_CONFIG_PATH
	var path_resolved_enemy := path_only_boss.get_enemy_config()
	_expect(
		path_resolved_enemy != null
		and path_resolved_enemy.is_boss
		and path_only_boss.enemy_config == null,
		"Boss 路径解析必须保持 exported enemy_config 单源不回写。"
	)

	var boss := BossConfig.new()
	boss.step_id = &"boss_01"
	boss.enemy_config = path_resolved_enemy
	boss.enemy_config_path = BOSS_ENEMY_CONFIG_PATH
	boss.intro_vfx_scene_path = "res://missing/boss_intro.tscn"
	boss.boss_hud_scene_path = "res://resources/config/enemies/slime.tres"
	boss.music_volume_db = NAN
	boss.music_loop_offset = -0.25
	var campaign := _make_campaign_with_boss(boss)
	var errors := campaign.validate_campaign()
	var boss_path := "Campaign[fixture].flow_graph.steps[1]"
	var expected := PackedStringArray([
		"%s：enemy_config 与 enemy_config_path 只能配置一个。" % boss_path,
		"%s.intro_vfx_scene_path：指向的场景不存在。" % boss_path,
		"%s.boss_hud_scene_path：必须指向 PackedScene。" % boss_path,
		"%s：music_volume_db 必须是 -40 到 12 之间的有限数。" % boss_path,
		"%s：music_loop_offset 必须是非负有限数。" % boss_path,
	])
	_expect(errors == expected, "Boss 单源、场景路径与音乐参数错误不稳定。")
	_expect(boss.get_enemy_config() == null, "Boss 双源配置不得选择性运行。")

	var missing_path_boss := BossConfig.new()
	missing_path_boss.step_id = &"boss_missing_enemy"
	missing_path_boss.enemy_config_path = "res://missing/boss_enemy.tres"
	var missing_path_errors := _make_campaign_with_boss(
		missing_path_boss
	).validate_campaign()
	_expect(
		missing_path_errors == PackedStringArray([
			(
				"Campaign[fixture].flow_graph.steps[1].enemy_config_path"
				+ "：指向的资源不存在。"
			),
		]),
		"Boss enemy_config_path 必须拒绝不存在的资源。"
	)
	var wrong_type_boss := BossConfig.new()
	wrong_type_boss.step_id = &"boss_wrong_enemy_type"
	wrong_type_boss.enemy_config_path = VALID_PICKUP_PATH
	var wrong_type_errors := _make_campaign_with_boss(
		wrong_type_boss
	).validate_campaign()
	_expect(
		wrong_type_errors == PackedStringArray([
			(
				"Campaign[fixture].flow_graph.steps[1].enemy_config_path"
				+ "：必须指向 EnemyConfig。"
			),
		]),
		"Boss enemy_config_path 必须拒绝非 EnemyConfig 资源。"
	)
	completed_check_groups += 1


func _test_bad_drop_rules() -> void:
	var table := EnemyDropTable.new()
	table.rules.append(null)
	var non_finite_rule := EnemyDropRule.new()
	non_finite_rule.chance = NAN
	table.rules.append(non_finite_rule)
	var out_of_range_rule := EnemyDropRule.new()
	out_of_range_rule.pickup_config = load(VALID_PICKUP_PATH) as PickupConfig
	out_of_range_rule.chance = 1.5
	out_of_range_rule.required_tags = PackedStringArray(["", "slime", "slime"])
	table.rules.append(out_of_range_rule)
	var enemy := _make_valid_enemy()
	enemy.drop_table = table
	var errors := _make_campaign_with_enemy(enemy).validate_campaign()
	var rules_path := (
		"Campaign[fixture].flow_graph.steps[0].enemy_entries[0].enemy_config"
		+ ".drop_table.rules"
	)
	var expected := PackedStringArray([
		"%s[0]：不能为空。" % rules_path,
		"%s[1].pickup_config：不能为空。" % rules_path,
		"%s[1]：chance 必须是有限数。" % rules_path,
		"%s[2]：chance 必须位于 0 到 1 之间。" % rules_path,
		"%s[2].required_tags[0]：不能为空。" % rules_path,
		"%s[2].required_tags[2]：不能重复。" % rules_path,
	])
	_expect(errors == expected, "DropRule 空值、概率和标签错误顺序不符合契约。")
	_expect(
		table.validate_config().size() == expected.size(),
		"DropTable 独立校验必须覆盖与 Campaign 闭包相同的规则。"
	)
	completed_check_groups += 1


func _make_campaign_with_enemy(enemy: EnemyConfig) -> WaveCampaignConfig:
	var entry := WaveEnemyEntry.new()
	entry.enemy_config = enemy
	var entries: Array[WaveEnemyEntry] = [entry]
	return _make_campaign(entries)


func _make_campaign_with_boss(boss: BossConfig) -> WaveCampaignConfig:
	var campaign := _make_campaign_with_enemy(
		load("res://resources/config/enemies/slime.tres") as EnemyConfig
	)
	var wave := campaign.flow_graph.steps[0] as WaveConfig
	var boss_exit := FlowExitConfig.new()
	boss_exit.target_step_id = boss.step_id
	wave.exits = [boss_exit]
	campaign.flow_graph.steps.append(boss)
	return campaign


func _make_campaign(entries: Array[WaveEnemyEntry]) -> WaveCampaignConfig:
	var wave := WaveConfig.new()
	wave.step_id = &"wave_01"
	wave.wave_name = "闭包校验夹具"
	wave.enemy_entries = entries
	var graph := FlowGraphConfig.new()
	graph.start_step = wave
	graph.steps = [wave]
	var campaign := WaveCampaignConfig.new()
	campaign.campaign_id = &"fixture"
	campaign.flow_graph = graph
	return campaign


func _make_valid_enemy() -> EnemyConfig:
	var enemy := EnemyConfig.new()
	enemy.display_name = "校验夹具敌人"
	enemy.enemy_scene = load(VALID_ENEMY_SCENE_PATH) as PackedScene
	return enemy


func _collect_campaign_paths(
	directory_path: String,
	result: PackedStringArray
) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		failures.append("无法打开 Campaign 目录：%s" % directory_path)
		return
	var child_directories := PackedStringArray()
	var campaign_files := PackedStringArray()
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if not entry_name.begins_with("."):
			if directory.current_is_dir():
				child_directories.append(entry_name)
			elif entry_name == "campaign.tres":
				campaign_files.append(entry_name)
		entry_name = directory.get_next()
	directory.list_dir_end()
	child_directories.sort()
	campaign_files.sort()
	for campaign_file in campaign_files:
		result.append(directory_path.path_join(campaign_file))
	for child_directory in child_directories:
		_collect_campaign_paths(directory_path.path_join(child_directory), result)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
