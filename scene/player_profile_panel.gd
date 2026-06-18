extends CanvasLayer
class_name PlayerProfilePanel

const DESIGN_SIZE := Vector2(724.0, 543.0)

@onready var overlay: Control = $Overlay
@onready var panel_root: Control = $Overlay/PanelRoot
@onready var close_button: Button = $Overlay/PanelRoot/CloseButton
@onready var portrait: AnimatedSprite2D = $Overlay/PanelRoot/Portrait
@onready var attack_value: Label = $Overlay/PanelRoot/AttackValue
@onready var health_value: Label = $Overlay/PanelRoot/HealthValue
@onready var attack_speed_value: Label = $Overlay/PanelRoot/AttackSpeedValue
@onready var method_value: Label = $Overlay/PanelRoot/MethodValue
@onready var inventory_grid: GridContainer = $Overlay/PanelRoot/InventoryGrid
@onready var upgrade_surface: NinePatchRect = $Overlay/PanelRoot/UpgradeSurface
@onready var upgrade_panel: VBoxContainer = $Overlay/PanelRoot/UpgradePanel
@onready var tab_bar: TabBar = $Overlay/PanelRoot/TabBar
@onready var attack_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/AttackRow
@onready var health_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/HealthRow
@onready var speed_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/SpeedRow
@onready var dodge_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/DodgeRow
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
@onready var net_manager: Node = get_node("/root/NetManager")

var tracked_player: Player = null
var slots: Array[InventorySlot] = []
var selected_slot_index := -1
var current_tab := 0  # 0 = 背包, 1 = 升级


func _ready() -> void:
	overlay.visible = false
	close_button.pressed.connect(close)
	get_viewport().size_changed.connect(_update_panel_transform)
	_collect_slots()
	_update_panel_transform()
	run_state.ensure_run_started()
	run_state.inventory_changed.connect(_refresh_inventory)
	run_state.upgrade_changed.connect(_refresh_upgrades)

	tab_bar.tab_changed.connect(_on_tab_changed)

	# 升级行信号
	attack_row.upgrade_requested.connect(_on_upgrade_requested)
	health_row.upgrade_requested.connect(_on_upgrade_requested)
	speed_row.upgrade_requested.connect(_on_upgrade_requested)
	dodge_row.upgrade_requested.connect(_on_upgrade_requested)

	# 为升级行设置息壤图标
	var xirang_icon := preload("res://resources/texture/xirang_icon.png")
	attack_row.cost_icon.texture = xirang_icon
	health_row.cost_icon.texture = xirang_icon
	speed_row.cost_icon.texture = xirang_icon
	dodge_row.cost_icon.texture = xirang_icon

	_apply_tab_state()


func bind_player(player: Player) -> void:
	if tracked_player != null:
		if overlay.visible:
			close()
		if tracked_player.health_changed.is_connected(_on_health_changed):
			tracked_player.health_changed.disconnect(_on_health_changed)
		if tracked_player.attack_speed_changed.is_connected(_on_attack_speed_changed):
			tracked_player.attack_speed_changed.disconnect(_on_attack_speed_changed)
		if tracked_player.xirang_changed.is_connected(_on_xirang_changed):
			tracked_player.xirang_changed.disconnect(_on_xirang_changed)
		if tracked_player.died.is_connected(_on_player_died):
			tracked_player.died.disconnect(_on_player_died)

	tracked_player = player
	if tracked_player == null:
		close()
		return

	tracked_player.health_changed.connect(_on_health_changed)
	tracked_player.attack_speed_changed.connect(_on_attack_speed_changed)
	tracked_player.xirang_changed.connect(_on_xirang_changed)
	tracked_player.died.connect(_on_player_died)
	portrait.sprite_frames = tracked_player.body_sprite.sprite_frames
	portrait.play(&"normal_down")
	attack_value.text = str(tracked_player.attack_damage)
	_on_attack_speed_changed(tracked_player.get_attacks_per_second())
	method_value.text = tracked_player.attack_method_name
	_on_health_changed(tracked_player.current_health, tracked_player.max_health)
	_refresh_inventory()
	_refresh_upgrades()


func open() -> void:
	if tracked_player == null or tracked_player.is_dead:
		return
	if overlay.visible:
		return

	overlay.visible = true
	tracked_player.set_controls_locked(true)
	_refresh_inventory()
	_refresh_upgrades()
	_refresh_stat_display()
	if current_tab == 0:
		_focus_first_available_slot()


func close() -> void:
	if not overlay.visible:
		return

	overlay.visible = false
	selected_slot_index = -1
	get_viewport().gui_release_focus()
	if tracked_player != null and not tracked_player.is_dead:
		tracked_player.set_controls_locked(false)


func toggle() -> void:
	if overlay.visible:
		close()
	else:
		open()


func is_open() -> bool:
	return overlay.visible


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("bag"):
		toggle()
		get_viewport().set_input_as_handled()
		return

	if not overlay.visible:
		return

	if event.is_action_pressed("quit") or event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept") and selected_slot_index >= 0 and current_tab == 0:
		_try_use_slot(selected_slot_index)
		get_viewport().set_input_as_handled()


func _collect_slots() -> void:
	slots.clear()
	for child in inventory_grid.get_children():
		var slot := child as InventorySlot
		if slot == null:
			continue
		slot.slot_selected.connect(_on_slot_selected)
		slot.item_activated.connect(_try_use_slot)
		slots.append(slot)


func _refresh_inventory() -> void:
	for slot_index in range(slots.size()):
		slots[slot_index].set_item(run_state.get_item(slot_index))
		slots[slot_index].set_selected(slot_index == selected_slot_index)


func _refresh_upgrades() -> void:
	_refresh_upgrade_row(attack_row, RunStateStore.StatType.ATTACK)
	_refresh_upgrade_row(health_row, RunStateStore.StatType.HEALTH)
	_refresh_upgrade_row(speed_row, RunStateStore.StatType.ATTACK_SPEED)
	_refresh_upgrade_row(dodge_row, RunStateStore.StatType.DODGE)


func _refresh_upgrade_row(row: UpgradeRow, stat_type: int) -> void:
	var current_level: int = run_state.get_upgrade_level(stat_type)
	var current_cost: int = run_state.get_upgrade_cost(stat_type)
	var can_afford := (
		tracked_player != null
		and current_cost >= 0
		and tracked_player.current_xirang >= current_cost
	)
	row.set_upgrade_state(current_level, current_cost, can_afford)


func _refresh_stat_display() -> void:
	if tracked_player == null:
		return
	attack_value.text = str(tracked_player.attack_damage)
	_on_health_changed(tracked_player.current_health, tracked_player.max_health)
	_on_attack_speed_changed(tracked_player.get_attacks_per_second())


func _on_slot_selected(slot_index: int) -> void:
	selected_slot_index = slot_index
	for slot in slots:
		slot.set_selected(slot.slot_index == selected_slot_index)


func _try_use_slot(slot_index: int) -> void:
	selected_slot_index = slot_index
	if run_state.try_use_item(slot_index, tracked_player):
		_refresh_inventory()
		_refresh_stat_display()


func _focus_first_available_slot() -> void:
	for slot in slots:
		if slot.item != null:
			selected_slot_index = slot.slot_index
			slot.grab_focus()
			_refresh_inventory()
			return

	selected_slot_index = 0
	if not slots.is_empty():
		slots[0].grab_focus()
		_refresh_inventory()


func _on_health_changed(current: int, maximum: int) -> void:
	health_value.text = "%d / %d" % [current, maximum]


func _on_attack_speed_changed(attacks_per_second: float) -> void:
	attack_speed_value.text = "%.2f/s" % attacks_per_second


func _on_xirang_changed(_total: int, _added_amount: int) -> void:
	_refresh_upgrades()


func _on_player_died() -> void:
	close()


func _on_upgrade_requested(stat_type: int) -> void:
	if tracked_player == null:
		return
	if net_manager != null and net_manager.is_client():
		var current_scene := get_tree().current_scene
		if current_scene != null and current_scene.has_method("request_multiplayer_upgrade"):
			current_scene.call("request_multiplayer_upgrade", stat_type)
		return

	if run_state.try_upgrade(stat_type, tracked_player):
		_refresh_upgrades()
		_refresh_stat_display()
		# 播放升级成功音效
		if tracked_player.powerup_audio != null:
			tracked_player.powerup_audio.play()


# ──── 标签页切换 ────

func _on_tab_changed(tab_index: int) -> void:
	if tab_index == current_tab:
		return
	current_tab = tab_index
	_apply_tab_state()
	if current_tab == 0:
		_focus_first_available_slot()
	else:
		_refresh_upgrades()


func _apply_tab_state() -> void:
	inventory_grid.visible = current_tab == 0
	upgrade_surface.visible = current_tab == 1
	upgrade_panel.visible = current_tab == 1
	tab_bar.current_tab = current_tab


func _update_panel_transform() -> void:
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	var scale_factor := minf(
		viewport_size.x / DESIGN_SIZE.x,
		viewport_size.y / DESIGN_SIZE.y
	) * 0.94
	scale_factor = minf(scale_factor, 1.0)
	panel_root.scale = Vector2.ONE * scale_factor
	panel_root.position = (viewport_size - DESIGN_SIZE * scale_factor) * 0.5
