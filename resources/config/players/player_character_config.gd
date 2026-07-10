extends Resource
class_name PlayerCharacterConfig

@export var character_id: StringName = &""
@export var display_name: String = ""
@export var english_name: String = ""
@export var title: String = ""
@export_multiline var description: String = ""
@export var playstyle: String = ""

@export_group("Runtime")
@export_file("*.tscn") var player_scene: String = ""
@export_file("*.png", "*.webp", "*.svg") var portrait_texture: String = ""
@export var portrait_offset: Vector2 = Vector2.ZERO

@export_group("Skill")
@export var skill_display_name: String = ""
@export_multiline var skill_description: String = ""
@export_file("*.png", "*.webp", "*.svg") var skill_icon_texture: String = ""

@export_group("Starting Stats")
@export_range(1, 9999, 1, "or_greater") var starting_max_health: int = 50
@export_range(1, 9999, 1, "or_greater") var starting_attack_damage: int = 10
@export_range(1.0, 99999.0, 1.0, "or_greater") var starting_attack_speed: float = 400.0
@export_range(1.0, 1000.0, 1.0, "or_greater") var attack_speed_units_per_attack: float = 100.0
@export_range(0.0, 9999.0, 1.0, "or_greater") var starting_move_speed: float = 120.0

@export_group("Card Palette")
@export var card_background_color: Color = Color(0.09, 0.10, 0.12, 0.98)
@export var card_edge_color: Color = Color(0.72, 0.64, 0.42, 1.0)
@export var card_hover_edge_color: Color = Color(0.96, 0.86, 0.56, 1.0)
@export var card_accent_color: Color = Color(0.96, 0.86, 0.56, 1.0)
@export var card_button_color: Color = Color(0.48, 0.39, 0.18, 1.0)
@export var card_text_color: Color = Color(0.96, 0.94, 0.88, 1.0)


func is_valid() -> bool:
	return character_id != &"" and not player_scene.is_empty()
