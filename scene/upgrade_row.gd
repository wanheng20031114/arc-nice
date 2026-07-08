extends PanelContainer
class_name UpgradeRow

signal upgrade_requested(stat_type: int)

@export var stat_name: String = ""
@export var stat_type: int = 0
@export var max_level: int = 5
@export var icon_texture: Texture2D
@export var completed_color := Color(0.33, 0.8, 0.68, 1.0)

@onready var icon: TextureRect = $Margin/Content/IconFrame/IconMargin/Icon
@onready var name_label: Label = $Margin/Content/InfoColumn/NameLabel
@onready var progress_container: HBoxContainer = $Margin/Content/InfoColumn/ProgressRow/BlockContainer
@onready var level_label: Label = $Margin/Content/InfoColumn/ProgressRow/LevelLabel
@onready var cost_icon: TextureRect = $Margin/Content/ActionColumn/CostColumn/CostIcon
@onready var cost_label: Label = $Margin/Content/ActionColumn/CostColumn/CostLabel
@onready var upgrade_button: Button = $Margin/Content/ActionColumn/UpgradeButton

var progress_blocks: Array[UpgradeProgressBlock] = []


func _ready() -> void:
	upgrade_button.set_meta(&"skip_ui_click_audio", true)
	name_label.text = stat_name
	if icon_texture != null:
		icon.texture = icon_texture

	upgrade_button.pressed.connect(_on_upgrade_button_pressed)

	# 收集所有进度方块并根据 max_level 隐藏多余的
	progress_blocks.clear()
	for child in progress_container.get_children():
		var block := child as UpgradeProgressBlock
		if block == null:
			continue
		progress_blocks.append(block)

	for block_index in range(progress_blocks.size()):
		if block_index >= max_level:
			progress_blocks[block_index].visible = false

	set_upgrade_state(0, 0, false)


func set_upgrade_state(
	current_level: int,
	current_cost: int,
	can_afford: bool,
) -> void:
	level_label.text = "%d/%d" % [current_level, max_level]

	for block_index in range(progress_blocks.size()):
		var block := progress_blocks[block_index]
		if block_index >= max_level:
			continue

		if block_index < current_level:
			block.set_state(
				UpgradeProgressBlock.State.COMPLETED,
				completed_color,
			)
		elif block_index == current_level and can_afford:
			block.set_state(
				UpgradeProgressBlock.State.AFFORDABLE,
				completed_color,
			)
		else:
			block.set_state(
				UpgradeProgressBlock.State.EMPTY,
				completed_color,
			)

	var is_max_level := current_level >= max_level or current_cost < 0
	upgrade_button.disabled = is_max_level or not can_afford
	cost_icon.visible = not is_max_level
	cost_label.visible = not is_max_level
	if is_max_level:
		upgrade_button.text = "已满"
	else:
		cost_label.text = str(current_cost)
		upgrade_button.text = "升级"


func _on_upgrade_button_pressed() -> void:
	upgrade_requested.emit(stat_type)
