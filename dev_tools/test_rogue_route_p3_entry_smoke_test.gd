extends SceneTree

const MAIN_MENU_SCENE := preload("res://scene/main_menu.tscn")
const P1A_SCENE_PATH := "res://scene/test_arena/test_grass_arena.tscn"
const P1B_SCENE_PATH := "res://scene/test_arena/test_grass_arena_p1b.tscn"
const P2_SCENE_PATH := "res://scene/test_arena/test_grass_arena_p2.tscn"
const P3_SCENE_PATH := "res://scene/test_arena/test_rogue_route_p3.tscn"
const P1A_CAMPAIGN_PATH := (
	"res://resources/config/campaigns/test_arena/singleplayer/campaign.tres"
)
const P1B_CAMPAIGN_PATH := (
	"res://resources/config/campaigns/test_arena/p1b/singleplayer/campaign.tres"
)
const P2_CAMPAIGN_PATH := (
	"res://resources/config/campaigns/test_arena/p2/singleplayer/campaign.tres"
)
const WEISHIDAIER_SCENE_PATH := (
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)


class SingleplayerLoadProbe:
	extends Node

	var requested_scene_path := ""


	func begin_singleplayer(scene_path: String) -> void:
		requested_scene_path = scene_path


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	_expect(coordinator != null, "P3入口测试必须能够访问常驻加载器。")
	if coordinator != null:
		_test_lightweight_manifest(coordinator)
	await _test_main_menu_selector(coordinator)

	if failures.is_empty():
		print("TEST_ROGUE_ROUTE_P3_ENTRY_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_lightweight_manifest(coordinator: Node) -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.set_selected_character(PlayerCharacterRegistry.WEISHIDAIER_ID)

	var p3_manifest := coordinator.call(
		"_build_singleplayer_manifest",
		P3_SCENE_PATH
	) as Array
	_expect(
		p3_manifest == [P3_SCENE_PATH, WEISHIDAIER_SCENE_PATH],
		"P3轻量加载清单必须仅追加当前选择的角色场景。"
	)
	_expect(
		str(coordinator.call("_get_singleplayer_campaign_path", P3_SCENE_PATH)).is_empty(),
		"P3不得附加战役资源。"
	)
	_expect(
		not bool(coordinator.call("_uses_tower_defense_runtime", P3_SCENE_PATH)),
		"P3不得附加塔防运行时资源。"
	)
	_expect(ResourceLoader.exists(P3_SCENE_PATH), "P3入口指向的场景必须存在。")

	for tower_contract in [
		[P1A_SCENE_PATH, P1A_CAMPAIGN_PATH],
		[P1B_SCENE_PATH, P1B_CAMPAIGN_PATH],
		[P2_SCENE_PATH, P2_CAMPAIGN_PATH],
	]:
		var scene_path := str(tower_contract[0])
		var campaign_path := str(tower_contract[1])
		var manifest := coordinator.call(
			"_build_singleplayer_manifest",
			scene_path
		) as Array
		_expect(
			manifest.has(scene_path)
			and manifest.has(campaign_path)
			and manifest.has(WEISHIDAIER_SCENE_PATH)
			and bool(coordinator.call("_uses_tower_defense_runtime", scene_path)),
			"P1A/P1B/P2必须加载各自战役、所选角色与塔防运行时。"
		)


func _test_main_menu_selector(coordinator: Node) -> void:
	var main_menu := MAIN_MENU_SCENE.instantiate() as MainMenu
	_expect(main_menu != null, "主菜单必须能够实例化。")
	if main_menu == null:
		return
	# 本测试只验证 P3 入口，不启动主菜单延后一帧的完整图鉴预热。
	# 这样结果不会被与路线框架无关的图鉴资源导入状态污染。
	main_menu.set("_is_exiting_tree", true)
	root.add_child(main_menu)
	current_scene = main_menu
	await process_frame

	var selector := main_menu.get_node_or_null(
		"TestArenaChoiceOverlay"
	) as TestArenaChoiceOverlay
	var character_selector := main_menu.get_node_or_null(
		"PlayerCharacterChoiceOverlay"
	) as PlayerCharacterChoiceOverlay
	_expect(selector != null and character_selector != null, "主菜单必须保留两级测试入口。")
	if selector == null or character_selector == null:
		main_menu.queue_free()
		await process_frame
		return

	var p3_title := selector.get_node_or_null(
		"Root/Center/Panel/PanelMargin/Layout/Tabs/P3/PageMargin/Content/ModeTitle"
	) as Label
	var entry_subtitle := selector.get_node_or_null(
		"Root/Center/Panel/PanelMargin/Layout/Heading/Subtitle"
	) as Label
	var p3_description := selector.get_node_or_null(
		"Root/Center/Panel/PanelMargin/Layout/Tabs/P3/PageMargin/Content/Description"
	) as Label
	var p3_button := selector.get_node_or_null(
		"Root/Center/Panel/PanelMargin/Layout/Tabs/P3/PageMargin/Content/EnterButton"
	) as Button
	_expect(
		p3_title != null
		and p3_title.text == "P3 · 肉鸽路线框架"
		and entry_subtitle != null
		and entry_subtitle.text.contains("P1A / P1B / P2 / P3")
		and entry_subtitle.text.contains("均先选择角色")
		and p3_description != null
		and p3_description.text.contains("正中心")
		and p3_description.text.contains("密集分布")
		and p3_description.text.contains("房主")
		and p3_description.text.contains("行动力")
		and p3_description.text.contains("大尺度世界")
		and p3_description.text.contains("自由移动")
		and p3_description.text.contains("镜头跟随")
		and p3_description.text.contains("HUD")
		and p3_button != null,
		"入口与P3页必须完整说明选角、探索尺度、镜头、HUD及房主行动力。"
	)
	if p3_button == null:
		main_menu.queue_free()
		await process_frame
		return

	selector.open(TestArenaChoiceOverlay.ARENA_P3_ID)
	await process_frame
	selector.call("_focus_current_action")
	_expect(
		selector.tabs.current_tab == TestArenaChoiceOverlay.P3_TAB_INDEX
		and p3_button.has_focus(),
		"重新打开测试选择器时必须恢复P3标签及其主操作焦点。"
	)

	var original_coordinator_name := &""
	var load_probe := SingleplayerLoadProbe.new()
	if coordinator != null:
		original_coordinator_name = coordinator.name
		coordinator.name = &"GameLoadCoordinatorEntryTestOriginal"
	load_probe.name = &"GameLoadCoordinator"
	root.add_child(load_probe)

	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.run_started = false
	p3_button.pressed.emit()
	await process_frame
	_expect(
		load_probe.requested_scene_path.is_empty()
		and not selector.is_open()
		and character_selector.is_open()
		and str(main_menu.call("_get_pending_singleplayer_scene_path")) == P3_SCENE_PATH,
		"选择P3必须先进入角色选择，并保留固定P3场景路径。"
	)
	main_menu.call(
		"_on_character_confirmed",
		PlayerCharacterRegistry.WEISHIDAIER_ID
	)
	_expect(
		load_probe.requested_scene_path == P3_SCENE_PATH
		and (
			run_state == null
			or (
				run_state.run_started
				and not bool(run_state.get("_include_starting_inventory_for_new_peers"))
			)
		),
		"确认P3角色后必须建立无初始库存的Run并开始轻量加载。"
	)
	character_selector.close()

	root.remove_child(load_probe)
	load_probe.free()
	if coordinator != null:
		coordinator.name = original_coordinator_name

	for tower_entry in [
		[
			TestArenaChoiceOverlay.ARENA_P1A_ID,
			P1A_SCENE_PATH,
			TestArenaChoiceOverlay.P1A_TAB_INDEX,
			"P1A",
		],
		[
			TestArenaChoiceOverlay.ARENA_P1B_ID,
			P1B_SCENE_PATH,
			TestArenaChoiceOverlay.P1B_TAB_INDEX,
			"P1B",
		],
		[
			TestArenaChoiceOverlay.ARENA_P2_ID,
			P2_SCENE_PATH,
			TestArenaChoiceOverlay.P2_TAB_INDEX,
			"P2",
		],
	]:
		selector.open(StringName(tower_entry[0]))
		await process_frame
		var tab_index := int(tower_entry[2])
		selector.tabs.current_tab = tab_index
		var enter_button := selector.get_node(
			"Root/Center/Panel/PanelMargin/Layout/Tabs/%s/PageMargin/Content/EnterButton"
			% str(tower_entry[3])
		) as Button
		enter_button.pressed.emit()
		await process_frame
		_expect(
			character_selector.is_open()
			and str(main_menu.call("_get_pending_singleplayer_scene_path"))
			== str(tower_entry[1]),
			"P1A/P1B/P2必须进入角色选择并保留各自场景路径。"
		)
		character_selector.close()
		await process_frame
		selector.close()
		await process_frame

	current_scene = null
	main_menu.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
