extends CanvasLayer
class_name TowerDefenseMinimap

const SAMPLE_INTERVAL_SECONDS := 0.05

@onready var minimap_canvas: TowerDefenseMinimapCanvas = (
	$TopLeftMargin/Content/MapPanel/MinimapCanvas
)
@onready var coordinate_label: Label = (
	$TopLeftMargin/Content/CoordinateLabel
)
@onready var sample_timer: Timer = $SampleTimer


func setup(
	local_player: Player,
	map_camera: Camera2D,
	ground_tile_map_layer: TileMapLayer,
	dual_grid_terrain: DualGridTilemap,
	overlay_tile_map_layer: TileMapLayer,
	players_root: Node,
	enemy_container: Node2D,
	boss_container: Node2D,
	plant_system: PlantSystem
) -> void:
	minimap_canvas.setup(
		local_player,
		map_camera,
		ground_tile_map_layer,
		dual_grid_terrain,
		overlay_tile_map_layer,
		players_root,
		enemy_container,
		boss_container,
		plant_system
	)
	sample_timer.start()


func _on_sample_timer_timeout() -> void:
	minimap_canvas.sample_next_phase()


func _on_minimap_canvas_tile_coordinate_changed(tile_coordinate: Vector2i) -> void:
	coordinate_label.text = "当前坐标：%d, %d" % [tile_coordinate.x, tile_coordinate.y]
