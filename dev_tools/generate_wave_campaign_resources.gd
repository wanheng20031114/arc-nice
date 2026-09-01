extends SceneTree

const SOURCE_WAVE_PATTERN := "res://resources/config/waves/wave_%02d.tres"
const CAMPAIGN_ROOT := "res://resources/config/campaigns"
const STANDARD_BOSS_CONFIG := preload("res://resources/config/bosses/boss_01_linglan.tres")
const WAVE_CAMPAIGN_CONFIG_SCRIPT := preload(
	"res://resources/config/waves/wave_campaign_config.gd"
)
const WAVE_CONTENT_CONTRACT := preload(
	"res://dev_tools/wave_campaign_content_contract.gd"
)
const FORCE_ARGUMENT := "--force"
const CHECK_ARGUMENT := "--check"
const STANDARD_SHARED_POLICY := &"standard_shared"

const CAMPAIGNS := [
	{
		"mode": "standard",
		"players": "singleplayer",
		"campaign_id": &"standard_singleplayer",
		"display_name": "普通模式 / 单人",
		"spawn_point_mask": WaveConfig.STANDARD_SPAWN_POINT_MASK,
		"boss_config": STANDARD_BOSS_CONFIG,
		"wave_policy": STANDARD_SHARED_POLICY,
	},
	{
		"mode": "standard",
		"players": "multiplayer",
		"campaign_id": &"standard_multiplayer",
		"display_name": "普通模式 / 多人",
		"spawn_point_mask": WaveConfig.STANDARD_SPAWN_POINT_MASK,
		"boss_config": STANDARD_BOSS_CONFIG,
		"wave_policy": STANDARD_SHARED_POLICY,
	},
]


func _init() -> void:
	var arguments := OS.get_cmdline_user_args()
	var should_generate := arguments.has(FORCE_ARGUMENT)
	var should_check := arguments.has(CHECK_ARGUMENT)
	if should_generate == should_check:
		push_error(
			"请使用 -- --check 校验快照，或使用 -- --force 显式重新生成。"
		)
		quit(2)
		return

	var failures := PackedStringArray()
	if should_check:
		for definition in CAMPAIGNS:
			_check_campaign(definition, failures)
	else:
		for definition in CAMPAIGNS:
			_generate_campaign(definition, failures)
	if failures.is_empty():
		print(
			"CHECK_STANDARD_WAVE_CAMPAIGN_RESOURCES_OK"
			if should_check
			else "GENERATE_WAVE_CAMPAIGN_RESOURCES_OK"
		)
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _generate_campaign(definition: Dictionary, failures: PackedStringArray) -> void:
	var directory := _get_campaign_directory(definition)
	var absolute_directory := ProjectSettings.globalize_path(directory)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		failures.append("无法创建 Campaign 目录 %s：%s" % [directory, error_string(directory_error)])
		return
	var wave_directory := directory
	var wave_subdirectory := String(definition.get("wave_subdirectory", ""))
	if not wave_subdirectory.is_empty():
		wave_directory = "%s/%s" % [directory, wave_subdirectory]
		var wave_directory_error := DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(wave_directory)
		)
		if wave_directory_error != OK:
			failures.append(
				"无法创建波次目录 %s：%s"
				% [wave_directory, error_string(wave_directory_error)]
			)
			return

	var campaign_waves: Array[WaveConfig] = []
	for wave_number in range(1, 13):
		var campaign_wave := _build_campaign_wave(definition, wave_number, failures)
		if campaign_wave == null:
			return
		var wave_path := "%s/wave_%02d.tres" % [wave_directory, wave_number]
		var wave_error := ResourceSaver.save(campaign_wave, wave_path)
		if wave_error != OK:
			failures.append("无法保存 %s：%s" % [wave_path, error_string(wave_error)])
			return
		campaign_waves.append(load(wave_path) as WaveConfig)

	var flow_graph := FlowGraphConfig.new()
	flow_graph.graph_name = "%s战斗流程" % String(definition["display_name"])
	flow_graph.start_step = campaign_waves[0]
	var flow_steps: Array[FlowStepConfig] = []
	flow_steps.assign(campaign_waves)
	var boss_config := definition["boss_config"] as BossConfig
	if boss_config != null:
		flow_steps.append(boss_config)
	flow_graph.steps = flow_steps
	var flow_path := "%s/flow.tres" % directory
	var flow_error := ResourceSaver.save(flow_graph, flow_path)
	if flow_error != OK:
		failures.append("无法保存 %s：%s" % [flow_path, error_string(flow_error)])
		return

	var campaign := WAVE_CAMPAIGN_CONFIG_SCRIPT.new()
	campaign.campaign_id = definition["campaign_id"] as StringName
	campaign.flow_graph = load(flow_path) as FlowGraphConfig
	var campaign_path := "%s/campaign.tres" % directory
	var campaign_error := ResourceSaver.save(campaign, campaign_path)
	if campaign_error != OK:
		failures.append("无法保存 %s：%s" % [campaign_path, error_string(campaign_error)])


func _check_campaign(definition: Dictionary, failures: PackedStringArray) -> void:
	var directory := _get_campaign_directory(definition)
	var campaign_path := "%s/campaign.tres" % directory
	var campaign := load(campaign_path) as WaveCampaignConfig
	if campaign == null:
		failures.append("无法加载 Campaign 快照：%s" % campaign_path)
		return
	if campaign.campaign_id != definition["campaign_id"]:
		failures.append("Campaign id 与生成定义不一致：%s" % campaign_path)
	var validation_errors := campaign.validate_campaign()
	for validation_error in validation_errors:
		failures.append("%s：%s" % [campaign_path, validation_error])
	if campaign.flow_graph == null:
		return
	var expected_flow_path := "%s/flow.tres" % directory
	if campaign.flow_graph.resource_path != expected_flow_path:
		failures.append("Campaign 引用了错误的流程图快照：%s" % campaign_path)
	if campaign.flow_graph.graph_name != "%s战斗流程" % String(definition["display_name"]):
		failures.append("流程图名称与生成定义不一致：%s" % campaign.flow_graph.resource_path)

	var actual_waves := campaign.get_waves()
	if actual_waves.size() != 12:
		failures.append("Campaign 快照必须包含 12 个波次：%s" % campaign_path)
		return
	if campaign.flow_graph.start_step != actual_waves[0]:
		failures.append("流程图必须从第 1 波开始：%s" % campaign.flow_graph.resource_path)

	var wave_directory := directory
	var wave_subdirectory := String(definition.get("wave_subdirectory", ""))
	if not wave_subdirectory.is_empty():
		wave_directory = "%s/%s" % [directory, wave_subdirectory]
	for wave_number in range(1, 13):
		var expected_wave := _build_campaign_wave(definition, wave_number, failures)
		if expected_wave == null:
			return
		var expected_path := "%s/wave_%02d.tres" % [wave_directory, wave_number]
		var actual_wave := actual_waves[wave_number - 1]
		if actual_wave.resource_path != expected_path:
			failures.append("流程图引用了错误的波次快照：%s" % expected_path)
			continue
		if (
			WAVE_CONTENT_CONTRACT.get_wave_signature(expected_wave)
			!= WAVE_CONTENT_CONTRACT.get_wave_signature(actual_wave)
		):
			failures.append("波次快照已偏离源资源或显式策略：%s" % expected_path)
		if definition["wave_policy"] == STANDARD_SHARED_POLICY:
			_assert_formal_label(expected_wave, SOURCE_WAVE_PATTERN % wave_number, failures)
			_assert_formal_label(actual_wave, expected_path, failures)

	var expected_boss := definition["boss_config"] as BossConfig
	var actual_bosses := campaign.get_bosses()
	var expected_step_count := 12 + (1 if expected_boss != null else 0)
	if campaign.flow_graph.steps.size() != expected_step_count:
		failures.append("流程图包含生成定义之外的节点：%s" % campaign.flow_graph.resource_path)
	if expected_boss == null:
		if not actual_bosses.is_empty():
			failures.append("无首领策略的 Campaign 不应包含首领：%s" % campaign_path)
	elif (
		actual_bosses.size() != 1
		or actual_bosses[0].resource_path != expected_boss.resource_path
	):
		failures.append("Campaign 首领快照与生成定义不一致：%s" % campaign_path)


func _get_campaign_directory(definition: Dictionary) -> String:
	return "%s/%s/%s" % [
		CAMPAIGN_ROOT,
		String(definition["mode"]),
		String(definition["players"]),
	]


func _build_campaign_wave(
	definition: Dictionary,
	wave_number: int,
	failures: PackedStringArray
) -> WaveConfig:
	var source_path := SOURCE_WAVE_PATTERN % wave_number
	var source_wave := load(source_path) as WaveConfig
	if source_wave == null:
		failures.append("无法加载源波次：%s" % source_path)
		return null
	var campaign_wave := source_wave.duplicate(true) as WaveConfig
	campaign_wave.spawn_point_mask = int(definition["spawn_point_mask"])

	# 单人与多人共享正式源；任何玩法差异都必须在定义中选择显式策略。
	match StringName(definition["wave_policy"]):
		STANDARD_SHARED_POLICY:
			pass
		_:
			failures.append(
				"Campaign %s 使用了未知波次策略。" % String(definition["campaign_id"])
			)
			return null
	return campaign_wave


func _assert_formal_label(
	wave_config: WaveConfig,
	resource_path: String,
	failures: PackedStringArray
) -> void:
	if WAVE_CONTENT_CONTRACT.has_test_label(wave_config):
		failures.append("正式 Standard 波次禁止测试标签：%s" % resource_path)
