extends SceneTree

const ENCYCLOPEDIA_SCENE := preload(
	"res://scene/encyclopedia/encyclopedia_screen.tscn"
)
const BASE_VIEWPORT := Vector2i(1152, 648)
const MAX_WAIT_FRAMES := 40

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_size = BASE_VIEWPORT
	root.size = BASE_VIEWPORT
	var screen := ENCYCLOPEDIA_SCENE.instantiate() as EncyclopediaScreen
	root.add_child(screen)
	current_scene = screen

	var initial_enemy_count := await _wait_for_first_batch(screen)
	var initial_enemy_rows := maxi(
		EncyclopediaScreen.INITIAL_GRID_ROWS,
		int(ceil(
			float(EncyclopediaScreen.GRID_BUILD_BATCH_SIZE)
			/ float(screen.entry_grid.columns)
		))
	)
	var expected_initial_count := mini(
		60,
		screen.entry_grid.columns * initial_enemy_rows
	)
	_expect(
		initial_enemy_count == expected_initial_count,
		"敌人首批卡片数量应按两行预算创建，而不是同步创建完整目录。"
	)
	_expect(
		initial_enemy_count < 60,
		"敌人首批构建必须在完整 60 张卡片之前让出主线程。"
	)
	await _wait_for_build_complete(screen)
	_expect(
		(screen.get("_cards") as Array).size() == 60,
		"分帧构建结束后必须补齐全部敌人卡片。"
	)

	# 切换到最大目录，确认首批出现后仍有剩余工作留到后续帧。
	screen.call("_apply_section", CodexSection.COLLECTIBLE)
	var initial_collectible_count := await _wait_for_first_batch(screen)
	_expect(
		initial_collectible_count > 0 and initial_collectible_count < 125,
		"收藏品目录必须先显示首批卡片，再逐帧补齐剩余内容。"
	)
	# 在旧协程仍有待建条目时立刻切分类，旧 generation 必须彻底失效。
	screen.call("_apply_section", CodexSection.BUILDING)
	await _wait_for_build_complete(screen)
	var building_cards := screen.get("_cards") as Array
	var only_buildings := building_cards.size() == 16
	for card_variant in building_cards:
		var card := card_variant as EncyclopediaEntryCard
		if card.entry_data.section != CodexSection.BUILDING:
			only_buildings = false
			break
	_expect(
		only_buildings,
		"分类切换后旧 generation 不得继续插入收藏品卡片。"
	)

	screen.call("_apply_section", CodexSection.COLLECTIBLE)
	await _wait_for_first_batch(screen)

	# 连续输入时，旧 generation 不得继续把过时结果写回网格。
	screen.call("_on_search_changed", "油灯")
	screen.call("_on_search_changed", "__不存在的档案__")
	await _wait_frames(3)
	_expect(
		(screen.get("_cards") as Array).is_empty()
		and (screen.get("_pending_grid_entries") as Array).is_empty()
		and screen.result_count.text == "显示 0 / 125",
		"快速连续搜索必须只保留最后一次 generation 的空结果。"
	)

	# 清空搜索后，除首批外，每帧新增量不得超过固定批次预算。
	screen.call("_on_search_changed", "")
	var reset_first_count := await _wait_for_first_batch(screen)
	_expect(reset_first_count < 125, "重置搜索也不能单帧重建全部卡片。")
	var previous_count := reset_first_count
	for _frame in MAX_WAIT_FRAMES:
		await process_frame
		var current_count := (screen.get("_cards") as Array).size()
		_expect(
			current_count - previous_count
			<= EncyclopediaScreen.GRID_BUILD_BATCH_SIZE,
			"首批之后单帧新增卡片不得超过批次预算。"
		)
		previous_count = current_count
		if current_count == 125:
			break
	_expect(previous_count == 125, "收藏品目录最终必须补齐全部 125 张卡片。")

	# 保存滚动位置时保持在顶部构建，等内容完整后只恢复一次。
	var section_states := screen.get("_section_states") as Dictionary
	var collectible_state := section_states[CodexSection.COLLECTIBLE] as Dictionary
	collectible_state["scroll"] = 72
	screen.call("_refresh_grid", false)
	await _wait_for_first_batch(screen)
	_expect(
		screen.grid_scroll.scroll_vertical == 0,
		"恢复旧目录时首批阶段应保持稳定，不得逐批夹取滚动位置。"
	)
	await _wait_frames(3)
	_expect(
		not screen.is_grid_build_complete()
		and screen.grid_scroll.scroll_vertical == 0,
		"目录构建期间不应让滚动位置逐帧跳动。"
	)
	await _wait_for_build_complete(screen)
	_expect(
		screen.grid_scroll.scroll_vertical == 72,
		"目录构建完成后必须一次恢复保存的滚动位置。"
	)

	# 构建期间的实际玩家滚动拥有更高优先级，不能在末帧被旧快照覆盖。
	collectible_state["scroll"] = 72
	screen.call("_refresh_grid", false)
	await _wait_for_first_batch(screen)
	await _wait_frames(3)
	screen.grid_scroll.scroll_vertical = 16
	await process_frame
	_expect(
		not bool(screen.get("_pending_scroll_restore")),
		"玩家在构建期间滚动后必须取消旧滚动快照。"
	)
	await _wait_for_build_complete(screen)
	_expect(
		screen.grid_scroll.scroll_vertical == 16,
		"增量构建结束不得覆盖玩家刚刚选择的滚动位置。"
	)

	var pooled_child_count := screen.entry_grid.get_child_count()
	screen.call("_on_search_changed", "油灯")
	await _wait_frames(3)
	screen.call("_on_search_changed", "")
	await _wait_for_build_complete(screen)
	_expect(
		screen.entry_grid.get_child_count() == pooled_child_count,
		"搜索刷新应复用卡片池，不能重复扩张节点数量。"
	)

	var catalog := screen.get("_catalog") as CodexCatalog
	catalog.clear_cache()
	screen.set("_catalog", null)
	catalog = null
	current_scene = null
	screen.queue_free()
	screen = null
	await _wait_frames(3)
	if _failures.is_empty():
		print("ENCYCLOPEDIA_INCREMENTAL_GRID_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _wait_for_first_batch(screen: EncyclopediaScreen) -> int:
	for _frame in MAX_WAIT_FRAMES:
		await process_frame
		var count := (screen.get("_cards") as Array).size()
		if count > 0:
			return count
	_expect(false, "等待首批图鉴卡片超时。")
	return 0


func _wait_for_build_complete(screen: EncyclopediaScreen) -> void:
	for _frame in MAX_WAIT_FRAMES:
		if screen.is_grid_build_complete():
			return
		await process_frame
	_expect(false, "等待图鉴分帧构建完成超时。")


func _wait_frames(frame_count: int) -> void:
	for _frame in frame_count:
		await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
