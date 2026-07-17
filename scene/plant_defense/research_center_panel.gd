extends CanvasLayer
class_name ResearchCenterPanel

signal opened
signal closed

enum Page {
	GLOBAL_TECH,
	PLAYER_TECH,
}

const DESIGN_SIZE := Vector2(728.0, 544.0)
const PLANK := ResearchCoordinator.PLANK
const SAPLING := ResearchCoordinator.SAPLING
const WATER_BOTTLE := ResearchCoordinator.WATER_BOTTLE
const REQUIREMENT_ITEMS: Array[PickupConfig] = [PLANK, SAPLING, WATER_BOTTLE]
const REQUIREMENT_COUNTS := [50, 20, 20]
const NODE_OFF_COLOR := Color(0.32, 0.43, 0.56, 0.82)
const NODE_ON_COLORS := [
	Color(0.25, 0.8, 1.35, 1.0),
	Color(0.35, 1.05, 1.55, 1.0),
	Color(0.65, 1.3, 1.8, 1.0),
]
const LINE_OFF_COLOR := Color(0.13, 0.28, 0.42, 0.8)
const LINE_ON_COLOR := Color(0.18, 0.88, 1.35, 1.0)

@onready var overlay: Control = $Overlay
@onready var panel_root: Control = $Overlay/PanelRoot
@onready var title_label: Label = $Overlay/PanelRoot/Title
@onready var global_tab: Button = $Overlay/PanelRoot/GlobalTab
@onready var player_tab: Button = $Overlay/PanelRoot/PlayerTab
@onready var close_button: Button = $Overlay/PanelRoot/CloseButton
@onready var global_page: Control = $Overlay/PanelRoot/GlobalPage
@onready var global_description: Label = $Overlay/PanelRoot/GlobalPage/Description
@onready var material_slots: Array[InventorySlot] = [
	$Overlay/PanelRoot/GlobalPage/PlankSlot,
	$Overlay/PanelRoot/GlobalPage/SaplingSlot,
	$Overlay/PanelRoot/GlobalPage/WaterBottleSlot,
]
@onready var material_labels: Array[Label] = [
	$Overlay/PanelRoot/GlobalPage/PlankCount,
	$Overlay/PanelRoot/GlobalPage/SaplingCount,
	$Overlay/PanelRoot/GlobalPage/WaterBottleCount,
]
@onready var global_progress: ProgressBar = $Overlay/PanelRoot/GlobalPage/ProgressBar
@onready var global_progress_label: Label = $Overlay/PanelRoot/GlobalPage/ProgressLabel
@onready var player_page: Control = $Overlay/PanelRoot/PlayerPage
@onready var player_tech_name: Label = $Overlay/PanelRoot/PlayerPage/TechName
@onready var player_tech_description: Label = $Overlay/PanelRoot/PlayerPage/TechDescription
@onready var xirang_label: Label = $Overlay/PanelRoot/PlayerPage/XirangLabel
@onready var root_core: Panel = $Overlay/PanelRoot/PlayerPage/RootCore
@onready var branch_lines: Array[Line2D] = [
	$Overlay/PanelRoot/PlayerPage/BranchLeft,
	$Overlay/PanelRoot/PlayerPage/BranchTop,
	$Overlay/PanelRoot/PlayerPage/BranchRight,
]
@onready var tech_nodes: Array[Panel] = [
	$Overlay/PanelRoot/PlayerPage/TechNode1,
	$Overlay/PanelRoot/PlayerPage/TechNode2,
	$Overlay/PanelRoot/PlayerPage/TechNode3,
]
@onready var node_effect_labels: Array[Label] = [
	$Overlay/PanelRoot/PlayerPage/NodeEffect1,
	$Overlay/PanelRoot/PlayerPage/NodeEffect2,
	$Overlay/PanelRoot/PlayerPage/NodeEffect3,
]
@onready var status_label: Label = $Overlay/PanelRoot/StatusLabel
@onready var action_button: Button = $Overlay/PanelRoot/ActionButton

var building: ResearchCenter = null
var tracked_player: Player = null
var active_page: Page = Page.GLOBAL_TECH
var transient_status := ""
var transient_status_token := 0
var pending_multiplayer_player_level := -1


func _ready() -> void:
	global_tab.pressed.connect(_switch_page.bind(Page.GLOBAL_TECH))
	player_tab.pressed.connect(_switch_page.bind(Page.PLAYER_TECH))
	close_button.pressed.connect(close)
	action_button.pressed.connect(_on_action_pressed)
	for slot_index in material_slots.size():
		material_slots[slot_index].set_item(
			REQUIREMENT_ITEMS[slot_index],
			REQUIREMENT_COUNTS[slot_index]
		)
	_set_open_state(false)


func _process(_delta: float) -> void:
	if not is_open():
		return
	_refresh_dynamic_state()


func _unhandled_input(event: InputEvent) -> void:
	if is_open() and PlantDefense.is_building_modal_close_event(event):
		get_viewport().set_input_as_handled()
		close()


func open_for(new_building: ResearchCenter, player: Player) -> void:
	if new_building == null or player == null:
		return
	if is_open():
		close()
	building = new_building
	tracked_player = player
	active_page = Page.GLOBAL_TECH
	transient_status = ""
	pending_multiplayer_player_level = -1
	_bind_runtime_signals()
	tracked_player.set_controls_locked(true)
	_set_open_state(true)
	_refresh_all()
	building.on_shared_research_panel_opened(self)
	opened.emit()


func close() -> void:
	if not is_open():
		return
	var previous_building := building
	var previous_player := tracked_player
	_unbind_runtime_signals()
	building = null
	tracked_player = null
	transient_status = ""
	pending_multiplayer_player_level = -1
	_set_open_state(false)
	if previous_player != null and is_instance_valid(previous_player):
		previous_player.set_controls_locked(false)
	if previous_building != null and is_instance_valid(previous_building):
		previous_building.on_shared_research_panel_closed(self)
	closed.emit()


func is_open() -> bool:
	return visible and building != null and tracked_player != null


func is_bound_to_building(candidate: ResearchCenter) -> bool:
	return is_open() and building == candidate


func _switch_page(page: Page) -> void:
	active_page = page
	transient_status = ""
	_refresh_all()


func _refresh_all() -> void:
	if building == null or tracked_player == null:
		return
	title_label.text = "科研中心"
	global_page.visible = active_page == Page.GLOBAL_TECH
	player_page.visible = active_page == Page.PLAYER_TECH
	global_tab.button_pressed = active_page == Page.GLOBAL_TECH
	player_tab.button_pressed = active_page == Page.PLAYER_TECH
	_refresh_dynamic_state()


func _refresh_dynamic_state() -> void:
	if building == null or tracked_player == null:
		return
	var coordinator := building.research_coordinator
	if coordinator == null:
		status_label.text = "科研网络尚未连接。"
		action_button.disabled = true
		return
	if active_page == Page.GLOBAL_TECH:
		_refresh_global_page(coordinator)
	else:
		_refresh_player_page(coordinator)


func _refresh_global_page(coordinator: ResearchCoordinator) -> void:
	global_description.text = "提交50木板、20树苗和20水瓶；完成后本局所有建筑永久获得物理防御+10。点击开始时立即扣除材料。"
	var all_materials_ready := true
	for index in REQUIREMENT_ITEMS.size():
		var total := coordinator.get_global_material_total(REQUIREMENT_ITEMS[index])
		var required := int(REQUIREMENT_COUNTS[index])
		material_labels[index].text = "%s  %d / %d" % [
			REQUIREMENT_ITEMS[index].display_name,
			total,
			required,
		]
		material_labels[index].modulate = (
			Color(0.55, 1.0, 0.78, 1.0)
			if total >= required
			else Color(1.0, 0.6, 0.55, 1.0)
		)
		all_materials_ready = all_materials_ready and total >= required
	global_progress.value = coordinator.get_global_progress_ratio() * 100.0
	match coordinator.global_state:
		ResearchCoordinator.GlobalResearchState.AVAILABLE:
			global_progress_label.text = "尚未开始"
			action_button.text = "开始研究"
			action_button.disabled = (
				not all_materials_ready
				or building.multiplayer_research_request_pending
			)
			_set_status("材料将在点击后立即从共享仓库扣除。")
		ResearchCoordinator.GlobalResearchState.RESEARCHING:
			var remaining := ceili(
				ResearchCoordinator.GLOBAL_RESEARCH_DURATION_SECONDS
				- coordinator.global_elapsed_seconds
			)
			global_progress_label.text = "研究中 · 剩余 %d 秒" % maxi(remaining, 0)
			action_button.text = "研究进行中"
			action_button.disabled = true
			_set_status("全局科技正在推演，已提交材料不会退还。")
		ResearchCoordinator.GlobalResearchState.COMPLETED:
			global_progress_label.text = "研究完成 · 全建筑物防 +10"
			action_button.text = "已完成"
			action_button.disabled = true
			_set_status("全局科技已永久生效，不能重复研究。")


func _refresh_player_page(coordinator: ResearchCoordinator) -> void:
	var level := coordinator.get_player_technology_level(tracked_player)
	var effects := _get_player_effect_texts()
	player_tech_name.text = _get_player_technology_name()
	player_tech_description.text = _get_player_technology_description()
	xirang_label.text = "个人息壤：%d" % tracked_player.get_xirang()
	for index in tech_nodes.size():
		var unlocked := index < level
		tech_nodes[index].modulate = (
			NODE_ON_COLORS[index] if unlocked else NODE_OFF_COLOR
		)
		branch_lines[index].default_color = (
			LINE_ON_COLOR if unlocked else LINE_OFF_COLOR
		)
		node_effect_labels[index].text = effects[index]
		node_effect_labels[index].modulate = (
			Color(0.7, 0.96, 1.0, 1.0)
			if unlocked
			else Color(0.45, 0.58, 0.7, 1.0)
		)
	root_core.modulate = (
		Color(0.25, 0.85, 1.2, 1.0)
		if level > 0
		else NODE_OFF_COLOR
	)
	if level >= Player.RESEARCH_TECHNOLOGY_MAX_LEVEL:
		action_button.text = "技术已满级"
		action_button.disabled = true
		_set_status("三处技术节点均已点亮。")
		return
	var cost := int(Player.RESEARCH_TECHNOLOGY_COSTS[level])
	action_button.text = "升级 · %d息壤" % cost
	action_button.disabled = (
		tracked_player.get_xirang() < cost
		or building.multiplayer_research_request_pending
	)
	_set_status("下一节点消耗玩家自己的息壤，升级后立即生效。")


func _on_action_pressed() -> void:
	if building == null or tracked_player == null:
		return
	if active_page == Page.GLOBAL_TECH:
		var result := building.try_start_global_research()
		_show_result(result, true)
		return
	var previous_level := tracked_player.get_research_technology_level()
	var result := building.try_purchase_player_technology(tracked_player)
	if result == ResearchCoordinator.RESULT_REQUEST_SENT:
		pending_multiplayer_player_level = previous_level
	_show_result(result, false)
	if result == ResearchCoordinator.RESULT_SUCCESS:
		_animate_unlocked_level(previous_level)


func _show_result(result: StringName, global_action: bool) -> void:
	match result:
		ResearchCoordinator.RESULT_SUCCESS:
			_show_transient_status(
				"研究已经启动，材料已扣除。"
				if global_action
				else "个人技术节点点亮成功。"
			)
		ResearchCoordinator.RESULT_MISSING_INPUT:
			_show_transient_status("共享仓库中的研究材料不足。")
		ResearchCoordinator.RESULT_INSUFFICIENT_XIRANG:
			_show_transient_status("个人息壤不足。")
		ResearchCoordinator.RESULT_MAX_LEVEL, ResearchCoordinator.RESULT_COMPLETED:
			_show_transient_status("该项研究已经完成。")
		ResearchCoordinator.RESULT_IN_PROGRESS:
			_show_transient_status("研究已经在进行中。")
		ResearchCoordinator.RESULT_REQUEST_SENT:
			_show_transient_status("研究请求已提交，等待主机确认。")
		_:
			_show_transient_status("当前无法提交研究请求。")
	_refresh_dynamic_state()


func _animate_unlocked_level(previous_level: int) -> void:
	if previous_level < 0 or previous_level >= tech_nodes.size():
		return
	var node := tech_nodes[previous_level]
	var line := branch_lines[previous_level]
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2(0.55, 0.55)
	node.modulate = Color(0.8, 1.7, 2.2, 1.0)
	line.default_color = Color(0.65, 1.7, 2.2, 1.0)
	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "scale", Vector2.ONE, 0.34)
	tween.tween_property(
		node,
		"modulate",
		NODE_ON_COLORS[previous_level],
		0.5
	)
	tween.tween_property(line, "default_color", LINE_ON_COLOR, 0.5)


func _get_player_technology_name() -> String:
	match tracked_player.get_character_id():
		&"tiyi":
			return "凝滞锁定"
		&"hoe_cat":
			return "旋风护体"
		_:
			return "爆燃弹头"


func _get_player_technology_description() -> String:
	match tracked_player.get_character_id():
		&"tiyi":
			return "技能锁定敌人期间持续施加减速；技能结束或目标移除时效果立刻解除。"
		&"hoe_cat":
			return "旋风斩命中结算后获得持续2秒的临时物理防御。"
		_:
			return "技能爆炸命中的敌人获得持续5秒的燃烧效果。"


func _get_player_effect_texts() -> Array[String]:
	match tracked_player.get_character_id():
		&"tiyi":
			return ["减速25%", "减速50%", "减速80%"]
		&"hoe_cat":
			return ["物防+15", "物防+30", "物防+50"]
		_:
			return ["燃烧10级", "燃烧20级", "燃烧30级"]


func _set_status(default_text: String) -> void:
	status_label.text = transient_status if not transient_status.is_empty() else default_text


func _show_transient_status(message: String) -> void:
	transient_status = message
	transient_status_token += 1
	var token := transient_status_token
	get_tree().create_timer(2.0).timeout.connect(
		func() -> void:
			if token != transient_status_token:
				return
			transient_status = ""
			_refresh_dynamic_state()
	)


func _bind_runtime_signals() -> void:
	var coordinator := building.research_coordinator
	if coordinator != null:
		if not coordinator.research_state_changed.is_connected(_refresh_all):
			coordinator.research_state_changed.connect(_refresh_all)
		if (
			coordinator.production_coordinator != null
			and not coordinator.production_coordinator.storage_totals_changed.is_connected(
				_refresh_all
			)
		):
			coordinator.production_coordinator.storage_totals_changed.connect(_refresh_all)
	if not tracked_player.xirang_changed.is_connected(_on_xirang_changed):
		tracked_player.xirang_changed.connect(_on_xirang_changed)
	if not tracked_player.research_technology_level_changed.is_connected(_on_level_changed):
		tracked_player.research_technology_level_changed.connect(_on_level_changed)
	if not building.multiplayer_research_result.is_connected(_on_multiplayer_research_result):
		building.multiplayer_research_result.connect(_on_multiplayer_research_result)


func _unbind_runtime_signals() -> void:
	if building != null and building.research_coordinator != null:
		var coordinator := building.research_coordinator
		if coordinator.research_state_changed.is_connected(_refresh_all):
			coordinator.research_state_changed.disconnect(_refresh_all)
		if (
			coordinator.production_coordinator != null
			and coordinator.production_coordinator.storage_totals_changed.is_connected(
				_refresh_all
			)
		):
			coordinator.production_coordinator.storage_totals_changed.disconnect(_refresh_all)
	if tracked_player != null:
		if tracked_player.xirang_changed.is_connected(_on_xirang_changed):
			tracked_player.xirang_changed.disconnect(_on_xirang_changed)
		if tracked_player.research_technology_level_changed.is_connected(_on_level_changed):
			tracked_player.research_technology_level_changed.disconnect(_on_level_changed)
	if (
		building != null
		and building.multiplayer_research_result.is_connected(
			_on_multiplayer_research_result
		)
	):
		building.multiplayer_research_result.disconnect(_on_multiplayer_research_result)


func _on_xirang_changed(_total: int, _delta: int) -> void:
	_refresh_dynamic_state()


func _on_level_changed(_level: int) -> void:
	_refresh_dynamic_state()


func _on_multiplayer_research_result(success: bool, reason: StringName) -> void:
	var level_to_animate := pending_multiplayer_player_level
	pending_multiplayer_player_level = -1
	_show_result(
		ResearchCoordinator.RESULT_SUCCESS if success else reason,
		active_page == Page.GLOBAL_TECH
	)
	if success and level_to_animate >= 0:
		_animate_unlocked_level(level_to_animate)


func _set_open_state(open: bool) -> void:
	visible = open
	set_process(open)
	set_process_unhandled_input(open)
	if open:
		_update_panel_transform()


func _update_panel_transform() -> void:
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	var scale_factor := minf(
		viewport_size.x / DESIGN_SIZE.x,
		viewport_size.y / DESIGN_SIZE.y
	)
	panel_root.scale = Vector2.ONE * scale_factor
	panel_root.position = (viewport_size - DESIGN_SIZE * scale_factor) * 0.5
