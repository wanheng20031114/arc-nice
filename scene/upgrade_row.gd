extends PanelContainer
class_name UpgradeRow

signal upgrade_requested(stat_type: int)

@export var stat_name: String = ""
@export var stat_type: int = 0
@export var max_level: int = 5
@export var icon_texture: Texture2D

@onready var icon: TextureRect = $Content/Icon
@onready var name_label: Label = $Content/InfoColumn/NameLabel
@onready var progress_container: HBoxContainer = $Content/InfoColumn/ProgressRow/BlockContainer
@onready var level_label: Label = $Content/InfoColumn/ProgressRow/LevelLabel
@onready var cost_icon: TextureRect = $Content/CostColumn/CostIcon
@onready var cost_label: Label = $Content/CostColumn/CostLabel
@onready var upgrade_button: Button = $Content/UpgradeButton

var progress_blocks: Array[ColorRect] = []


func _ready() -> void:
	name_label.text = stat_name
	if icon_texture != null:
		icon.texture = icon_texture

	upgrade_button.pressed.connect(_on_upgrade_button_pressed)

	# 收集所有进度方块并根据 max_level 隐藏多余的
	progress_blocks.clear()
	for child in progress_container.get_children():
		var block := child as ColorRect
		if block == null:
			continue
		progress_blocks.append(block)

	for block_index in range(progress_blocks.size()):
		if block_index >= max_level:
			progress_blocks[block_index].visible = false

	set_level(0)


func set_level(current_level: int) -> void:
	level_label.text = "%d/%d" % [current_level, max_level]

	for block_index in range(progress_blocks.size()):
		var block := progress_blocks[block_index]
		if block_index >= max_level:
			continue
		var block_material := block.material as ShaderMaterial
		if block_index < current_level:
			block.color = Color(0.35, 0.85, 0.7, 1.0)
			if block_material != null:
				block_material.set_shader_parameter("glow_enabled", true)
		else:
			block.color = Color(0.18, 0.2, 0.22, 0.7)
			if block_material != null:
				block_material.set_shader_parameter("glow_enabled", false)

	# 满级时禁用升级按钮
	upgrade_button.disabled = current_level >= max_level
	if current_level >= max_level:
		upgrade_button.text = "已满"
	else:
		upgrade_button.text = "升级"


func _on_upgrade_button_pressed() -> void:
	upgrade_requested.emit(stat_type)
