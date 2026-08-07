extends SceneTree

const BRIEFING_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_node_briefing.tscn"
)
const BRIEFING_SCRIPT := preload(
	"res://scene/game_modes/rogue/route/rogue_route_node_briefing.gd"
)
const NORMAL_ADAPTER_SCRIPT := preload(
	"res://scene/game_modes/rogue/route/rogue_normal_combat_briefing_adapter.gd"
)
const NORMAL_NODE_CONFIG: RogueRouteNodeTypeConfig = preload(
	"res://resources/config/rogue_route/normal_combat.tres"
)
const ENCOUNTER_CONFIG: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const TEST_HERO_VISUAL: Texture2D = preload(
	"res://resources/texture/rogue_route/normal_combat.png"
)

var failures: Array[String] = []
var confirmed_count := 0
var canceled_count := 0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var adapter := NORMAL_ADAPTER_SCRIPT.new(
		ENCOUNTER_CONFIG,
		TEST_HERO_VISUAL
	)
	_expect(
		adapter.get_node_type() == RogueRouteGraph.NodeType.NORMAL_COMBAT,
		"普通作战适配器必须只声明普通作战节点类型。"
	)
	_expect(
		adapter.supports_node_type(RogueRouteGraph.NodeType.NORMAL_COMBAT)
		and not adapter.supports_node_type(
			RogueRouteGraph.NodeType.EMERGENCY_COMBAT
		),
		"适配器接口必须能够区分普通作战与预留的紧急作战。"
	)

	var model := adapter.build_model(NORMAL_NODE_CONFIG, 8, 1)
	_expect(model != null, "有效的普通作战配置必须能够生成简报模型。")
	if model == null:
		_finish()
		return
	_expect(model.is_valid(), "普通作战适配器生成的模型必须通过强类型校验。")
	_expect(
		model.title == "普通作战" and model.summary == "狭路相逢",
		"模型标题与摘要必须来自现有节点和遭遇配置。"
	)
	_expect(
		model.objective == "消灭全部战斗机器人"
		and model.time_limit_seconds == 90
		and model.enemy_count == 10,
		"目标、时限和敌人数必须来自现有波次与遭遇配置。"
	)
	_expect(
		model.reward_summary == "额外 +500 息壤 · 随机 1 件普通收藏品"
		and model.action_point_delta == -1
		and model.primary_action_text == "进入作战",
		"奖励、行动力变化和唯一主操作文案必须准确。"
	)
	_expect(
		adapter.build_model(NORMAL_NODE_CONFIG, 0, 1) == null,
		"行动力不足时普通作战适配器不得生成可确认模型。"
	)
	var wrong_node_config := (
		NORMAL_NODE_CONFIG.duplicate() as RogueRouteNodeTypeConfig
	)
	wrong_node_config.node_type = RogueRouteGraph.NodeType.EMERGENCY_COMBAT
	_expect(
		adapter.build_model(wrong_node_config, 8, 1) == null,
		"普通作战适配器不得接管紧急作战占位节点。"
	)

	var briefing := BRIEFING_SCENE.instantiate() as BRIEFING_SCRIPT
	root.add_child(briefing)
	await process_frame
	_expect(not briefing.visible, "简报层初始必须隐藏。")
	_expect(
		briefing.layer == 50
		and briefing.process_mode == Node.PROCESS_MODE_ALWAYS,
		"简报必须位于 layer 50，并在暂停时持续处理输入与动效。"
	)
	_expect(
		briefing.panel_stage.size.is_equal_approx(Vector2(920.0, 520.0)),
		"原生简报面板尺寸必须严格为 920×520。"
	)
	_expect(
		briefing.get_node_or_null("Root/PanelStage/Frame") is NinePatchRect
		and briefing.hero_visual is TextureRect
		and briefing.hero_visual.stretch_mode
		== TextureRect.STRETCH_KEEP_ASPECT_COVERED
		and briefing.hero_reveal_mask is ColorRect,
		"简报必须以原生 TextureRect cover 模式和 ColorRect 遮罩承载主视觉。"
	)

	briefing.confirmed.connect(func() -> void: confirmed_count += 1)
	briefing.canceled.connect(func() -> void: canceled_count += 1)
	briefing.present(model, true)
	await process_frame
	await process_frame
	_expect(briefing.visible and briefing.can_decide(), "房主 present 后必须可决策。")
	_expect(
		briefing.title_label.text == "普通作战"
		and briefing.summary_label.text == "狭路相逢"
		and briefing.objective_label.text == "消灭全部战斗机器人",
		"简报表现层必须完整呈现模型的标题、摘要和目标。"
	)
	_expect(
		briefing.time_limit_label.text == "90 秒"
		and briefing.enemy_count_label.text == "10"
		and briefing.reward_label.text == model.reward_summary
		and briefing.action_point_label.text == "-1",
		"简报表现层必须准确格式化全部决策信息。"
	)
	_expect(
		briefing.hero_visual.texture == TEST_HERO_VISUAL
		and briefing.node_icon.texture == NORMAL_NODE_CONFIG.icon,
		"表现层必须使用模型提供的主视觉与节点图标。"
	)
	var action_point_icon := briefing.get_node_or_null(
		"Root/PanelStage/Frame/ContentMargin/Content/InfoStack/InfoBottom/ActionPointCard/Margin/Row/Icon"
	) as TextureRect
	_expect(
		action_point_icon != null
		and action_point_icon.texture != null
		and action_point_icon.texture.resource_path
		== "res://resources/texture/rogue_route/hud/hud_action_points_v4.png"
		and action_point_icon.custom_minimum_size.is_equal_approx(Vector2(40.0, 40.0))
		and action_point_icon.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and action_point_icon.stretch_mode == TextureRect.STRETCH_KEEP_CENTERED,
		"作战简报必须复用顶部 HUD 的 40×40 行动力像素图标，且不得进行非整数缩放。"
	)
	_expect(
		root.gui_get_focus_owner() == briefing.confirm_button,
		"房主打开简报时，唯一主操作必须获得键鼠/手柄焦点。"
	)

	briefing.confirm_button.pressed.emit()
	briefing.confirm_button.pressed.emit()
	_expect(
		confirmed_count == 1 and briefing.is_decision_locked(),
		"连续确认只能发出一次 confirmed，并立即锁定决策输入。"
	)
	_expect(
		briefing.visible
		and briefing.confirm_button.disabled
		and briefing.cancel_button.disabled,
		"确认后必须等待外部权威流程同步关闭，不得允许第二次提交。"
	)
	briefing.dismiss()

	briefing.present(model, true)
	var cancel_event := InputEventAction.new()
	cancel_event.action = &"ui_cancel"
	cancel_event.pressed = true
	briefing._input(cancel_event)
	briefing._input(cancel_event)
	_expect(
		canceled_count == 1 and briefing.is_decision_locked(),
		"房主的返回键取消只能发出一次 canceled，并锁定后续输入。"
	)
	briefing.dismiss()

	briefing.present(model, false)
	await process_frame
	_expect(
		briefing.visible
		and not briefing.can_decide()
		and briefing.decision_status_label.text == "等待房主决定",
		"客户端必须看到同一简报和明确的等待房主状态。"
	)
	_expect(
		not briefing.close_button.visible
		and briefing.cancel_button.disabled
		and briefing.confirm_button.disabled
		and root.gui_get_focus_owner() not in [
			briefing.cancel_button,
			briefing.confirm_button,
		],
		"客户端的关闭与决策按钮必须不可操作且不得占用焦点。"
	)
	briefing._input(cancel_event)
	var shade_click := InputEventMouseButton.new()
	shade_click.button_index = MOUSE_BUTTON_LEFT
	shade_click.pressed = true
	briefing.map_shade.gui_input.emit(shade_click)
	_expect(
		briefing.visible
		and not briefing.is_decision_locked()
		and canceled_count == 1,
		"客户端的返回键或遮罩点击不得取消房主的待决简报。"
	)
	briefing.dismiss()

	var rest_position := briefing.panel_stage.position
	briefing.present(model, true)
	_expect(
		briefing.panel_stage.position.is_equal_approx(
			rest_position + BRIEFING_SCRIPT.PANEL_OPEN_OFFSET
		)
		and is_zero_approx(briefing.panel_stage.modulate.a)
		and is_equal_approx(briefing.hero_reveal_mask.scale.x, 1.0)
		and is_equal_approx(
			briefing.hero_reveal_mask.pivot_offset.x,
			briefing.hero_reveal_mask.size.x
		),
		"打开时面板必须从下方淡入，主视觉必须先被右轴遮罩完整覆盖。"
	)
	paused = true
	await create_timer(0.42).timeout
	paused = false
	_expect(
		briefing.panel_stage.position.is_equal_approx(rest_position)
		and is_equal_approx(briefing.panel_stage.modulate.a, 1.0)
		and is_zero_approx(briefing.hero_reveal_mask.scale.x),
		"暂停状态下，0.25 秒揭示与分段信息淡入仍必须完成。"
	)
	for card_name in [
		&"ObjectiveCard",
		&"TimeCard",
		&"EnemyCard",
		&"RewardCard",
		&"ActionPointCard",
	]:
		var card := briefing.get_node_or_null(
			NodePath("%" + String(card_name))
		) as Control
		_expect(
			card != null and is_equal_approx(card.modulate.a, 1.0),
			"信息卡 %s 的分段淡入必须完成。" % card_name
		)

	briefing.dismiss()
	root.remove_child(briefing)
	briefing.free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_ROUTE_NODE_BRIEFING_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
