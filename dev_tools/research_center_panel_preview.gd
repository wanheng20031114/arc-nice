extends SceneTree

const PANEL_SCENE := preload("res://scene/plant_defense/research_center_panel.tscn")
const COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/research_coordinator.tscn"
)
const PRODUCTION_SCENE := preload(
	"res://scene/plant_defense/production_coordinator.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const OUTPUT_DIRECTORY := (
	"res://dev_assets/source_images/plant_defense/research_center"
)


func _initialize() -> void:
	root.size = Vector2i(728, 544)
	var production := PRODUCTION_SCENE.instantiate() as ProductionCoordinator
	var research := COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	var plant_system := PlantSystem.new()
	var panel := PANEL_SCENE.instantiate() as ResearchCenterPanel
	var player := PLAYER_SCENE.instantiate() as Player
	var config := PlantDefenseRegistry.get_config(&"research_center")
	var center := config.plant_scene.instantiate() as ResearchCenter
	root.add_child(production)
	root.add_child(research)
	root.add_child(plant_system)
	root.add_child(player)
	root.add_child(center)
	root.add_child(panel)
	await process_frame
	production.production_tick_timer.stop()
	research.research_tick_timer.stop()
	center.setup(config, player, [Vector2i.ZERO])
	research.setup(production, plant_system, null)
	research.register_player(player)
	center.set_research_services(research, panel)
	panel.open_for(center, player)
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(
		OUTPUT_DIRECTORY + "/research_center_panel_global_preview.png"
	)
	panel._select_global_research(
		GlobalResearchRegistry.PLAYER_MOVE_SPEED_ID
	)
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(
		OUTPUT_DIRECTORY + "/research_center_panel_move_speed_preview.png"
	)
	research.player_technology_levels[0] = 3
	player.set_research_technology_level(3)
	panel._switch_page(ResearchCenterPanel.Page.PLAYER_TECH)
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(
		OUTPUT_DIRECTORY + "/research_center_panel_player_preview.png"
	)
	quit()
