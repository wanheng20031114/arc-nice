extends Node2D
class_name PlantPlacementPreview

const DEFAULT_TILE_SIZE := Vector2(16.0, 16.0)
const RANGE_FILL_COLOR := Color(0.3, 0.92, 0.48, 0.075)
const RANGE_EDGE_COLOR := Color(0.46, 1.0, 0.6, 0.7)
const FOOTPRINT_FILL_COLOR := Color(0.32, 1.0, 0.48, 0.12)
const FOOTPRINT_EDGE_COLOR := Color(0.66, 1.0, 0.72, 0.9)

@onready var ghost_sprite: Sprite2D = $GhostSprite

var attack_range := 0.0
var footprint_size := DEFAULT_TILE_SIZE * 2.0


func _ready() -> void:
	hide_preview()


func configure(
	config: PlantDefenseConfig,
	tile_size: Vector2 = DEFAULT_TILE_SIZE
) -> void:
	if config == null:
		ghost_sprite.texture = null
		ghost_sprite.scale = Vector2.ONE
		ghost_sprite.position = Vector2.ZERO
		attack_range = 0.0
		footprint_size = Vector2.ZERO
		queue_redraw()
		return
	ghost_sprite.texture = config.icon
	ghost_sprite.position = config.placement_preview_offset
	var texture_size := config.icon.get_size()
	if texture_size.x > 0.0 and texture_size.y > 0.0:
		ghost_sprite.scale = Vector2(
			config.placement_preview_display_size.x / texture_size.x,
			config.placement_preview_display_size.y / texture_size.y
		)
	else:
		ghost_sprite.scale = Vector2.ONE
	attack_range = maxf(config.attack_range, 0.0)
	footprint_size = tile_size.abs() * Vector2(config.footprint_size)
	queue_redraw()


func show_at(world_position: Vector2) -> void:
	global_position = world_position
	show()


func hide_preview() -> void:
	hide()


func _draw() -> void:
	if attack_range > 0.0:
		draw_circle(Vector2.ZERO, attack_range, RANGE_FILL_COLOR, true, -1.0, false)
		draw_arc(Vector2.ZERO, attack_range, 0.0, TAU, 96, RANGE_EDGE_COLOR, 1.0, false)
	var footprint_rect := Rect2(-footprint_size * 0.5, footprint_size)
	draw_rect(footprint_rect, FOOTPRINT_FILL_COLOR, true)
	draw_rect(footprint_rect, FOOTPRINT_EDGE_COLOR, false, 1.0, false)
