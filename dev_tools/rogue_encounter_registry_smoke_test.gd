extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	_test_pool_and_deterministic_selection()
	_test_content_configs()
	if failures.is_empty():
		print("ROGUE_ENCOUNTER_REGISTRY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_pool_and_deterministic_selection() -> void:
	var entries := RogueEncounterRegistry.get_pool_entries(
		RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL
	)
	_expect(
		entries == [
			RogueEncounterRegistry.CHICKEN_BRO,
			RogueEncounterRegistry.SLIME_TALKERS,
			RogueEncounterRegistry.GHOST_SHADOW,
			RogueEncounterRegistry.FLUORESCENT_PIT,
		],
		"四种神奇遭遇必须等权注册且保持稳定顺序。"
	)
	var selected: Dictionary = {}
	for seed_value in range(128):
		var first := RogueEncounterRegistry.select_encounter(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			seed_value
		)
		var replay := RogueEncounterRegistry.select_encounter(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			seed_value
		)
		_expect(first == replay, "相同节点seed必须稳定选择同一遭遇内容。")
		selected[first] = true
	_expect(
		selected.has(RogueEncounterRegistry.CHICKEN_BRO)
		and selected.has(RogueEncounterRegistry.SLIME_TALKERS)
		and selected.has(RogueEncounterRegistry.GHOST_SHADOW)
		and selected.has(RogueEncounterRegistry.FLUORESCENT_PIT),
		"固定seed样本必须能够覆盖池中的四种遭遇。"
	)


func _test_content_configs() -> void:
	var chicken := RogueEncounterRegistry.get_encounter_config(
		RogueEncounterRegistry.CHICKEN_BRO
	)
	var slimes := RogueEncounterRegistry.get_encounter_config(
		RogueEncounterRegistry.SLIME_TALKERS
	)
	var ghost := RogueEncounterRegistry.get_encounter_config(
		RogueEncounterRegistry.GHOST_SHADOW
	)
	var pit := RogueEncounterRegistry.get_encounter_config(
		RogueEncounterRegistry.FLUORESCENT_PIT
	)
	_expect(
		str(chicken.get("intro_text", ""))
		== "鸡哥：练习时长2年半，会唱跳rap篮球。"
		and not bool(chicken.get("intro_is_narration", true)),
		"鸡哥开场对白必须保持原文与角色对白属性。"
	)
	_expect(
		str(slimes.get("intro_text", ""))
		== "你遇到了一群会说话的史莱姆"
		and bool(slimes.get("intro_is_narration", false))
		and str(slimes.get("intro_speaker", "")).is_empty(),
		"史莱姆开场必须是无角色名前缀的旁白。"
	)
	_expect(
		str(slimes.get("portrait_texture_path", ""))
		== "res://resources/texture/rogue_encounter/talking_slime_group.png",
		"史莱姆内容必须引用专用群像素材。"
	)
	_expect(
		str(ghost.get("display_name", "")) == "鬼影"
		and str(ghost.get("portrait_texture_path", ""))
		== "res://resources/texture/rogue_encounter/ghost_shadow.png"
		and str(ghost.get("intro_text", "")) == "你遇到了一个鬼影"
		and bool(ghost.get("intro_is_narration", false))
		and str(ghost.get("intro_speaker", "")).is_empty(),
		"鬼影必须引用专用立绘并使用旁白式开场。"
	)
	_expect(
		str(pit.get("display_name", "")) == "荧光坑洞"
		and str(pit.get("portrait_texture_path", ""))
		== "res://resources/texture/rogue_encounter/fluorescent_pit.png"
		and str(pit.get("encounter_hint", "")) == "深不见底的遗址裂隙"
		and str(pit.get("intro_text", ""))
		== "一道幽蓝的微光从坑洞深处传来"
		and bool(pit.get("intro_is_narration", false)),
		"荧光坑洞必须使用专用素材、提示与旁白开场。"
	)
	var chicken_options := RogueEncounterRegistry.get_option_configs(
		RogueEncounterRegistry.CHICKEN_BRO
	)
	var slime_options := RogueEncounterRegistry.get_option_configs(
		RogueEncounterRegistry.SLIME_TALKERS
	)
	var ghost_options := RogueEncounterRegistry.get_option_configs(
		RogueEncounterRegistry.GHOST_SHADOW
	)
	var pit_options := RogueEncounterRegistry.get_option_configs(
		RogueEncounterRegistry.FLUORESCENT_PIT
	)
	_expect(chicken_options.size() == 2, "鸡哥必须继续显示两个选项。")
	_expect(slime_options.size() == 3, "史莱姆遭遇必须显示三个选项。")
	_expect(ghost_options.size() == 2, "鬼影遭遇必须显示两个选项。")
	_expect(pit_options.size() == 2, "荧光坑洞必须显示两个选项。")
	_expect(
		RogueEncounterRegistry.get_option_ids(
			RogueEncounterRegistry.SLIME_TALKERS
		) == [
			RogueEncounterRegistry.OPTION_HELP_SLIMES,
			RogueEncounterRegistry.OPTION_KICK_SLIMES,
			RogueEncounterRegistry.OPTION_LEAVE_SLIMES,
		],
		"史莱姆选项ID顺序必须稳定。"
	)
	_expect(
		str(slime_options[0].get("title", "")) == "给予一些帮助"
		and str(slime_options[0].get("description", ""))
		== "赠予这些史莱姆10个水瓶"
		and str(slime_options[1].get("title", "")) == "一脚踢死"
		and str(slime_options[1].get("description", ""))
		== "杀死这些史莱姆"
		and str(slime_options[2].get("title", ""))
		== "这和我有什么关系？"
		and str(slime_options[2].get("description", "")) == "离开该节点",
		"史莱姆三个选项必须与策划文案一致。"
	)
	_expect(
		RogueEncounterRegistry.get_option_ids(
			RogueEncounterRegistry.GHOST_SHADOW
		) == [
			RogueEncounterRegistry.OPTION_GHOST_RUN_AWAY,
			RogueEncounterRegistry.OPTION_GHOST_WHO_ARE_YOU,
		]
		and str(ghost_options[0].get("title", "")) == "逃跑"
		and str(ghost_options[0].get("description", ""))
		== "鬼知道会发生什么，赶快逃"
		and str(ghost_options[1].get("title", "")) == "你是？"
		and str(ghost_options[1].get("description", "")).is_empty(),
		"鬼影选项ID与文案必须稳定，“你是？”不得显示小字。"
	)
	_expect(
		RogueEncounterRegistry.get_option_ids(
			RogueEncounterRegistry.FLUORESCENT_PIT
		) == [
			RogueEncounterRegistry.OPTION_EXPLORE_PIT,
			RogueEncounterRegistry.OPTION_LEAVE_PIT,
		]
		and str(pit_options[0].get("title", "")) == "往下探探！"
		and str(pit_options[0].get("description", ""))
		== "谁也无法阻挡我们的好奇心！"
		and str(pit_options[1].get("title", "")) == "还是先走吧"
		and str(pit_options[1].get("description", ""))
		== "这么深的坑还是别继续了",
		"荧光坑洞选项ID、顺序与策划文案必须稳定。"
	)
	var mutated := RogueEncounterRegistry.get_encounter_config(
		RogueEncounterRegistry.CHICKEN_BRO
	)
	mutated["display_name"] = "被篡改"
	_expect(
		str(RogueEncounterRegistry.get_encounter_config(
			RogueEncounterRegistry.CHICKEN_BRO
		).get("display_name", "")) == "鸡哥",
		"Registry 返回值必须深拷贝，调用方不得污染全局内容配置。"
	)
	_expect(
		RogueEncounterRegistry.get_encounter_config(&"missing").is_empty()
		and RogueEncounterRegistry.get_option_ids(&"missing").is_empty(),
		"未知遭遇不得获得伪造配置或选项。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
