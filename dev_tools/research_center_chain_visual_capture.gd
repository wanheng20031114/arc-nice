extends SceneTree

const VIEWPORT_SIZE := Vector2i(1152, 648)
const OUTPUT_DIRECTORY := "res://dev_tools/output/research_center"
const OUTPUT_PATH := (
	OUTPUT_DIRECTORY + "/building_defense_iii_1152x648.png"
)
const PANEL_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/research/research_center_panel.tscn"
)
const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/research/research_coordinator.tscn"
)
const PRODUCTION_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)


func _initialize() -> void:
	root.content_scale_size = VIEWPORT_SIZE
	root.size = VIEWPORT_SIZE
	DisplayServer.window_set_size(VIEWPORT_SIZE)
	call_deferred("_capture")


func _capture() -> void:
	var production := PRODUCTION_SCENE.instantiate() as ProductionCoordinator
	var research := COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	var plant_system := PlantSystem.new()
	var panel := PANEL_SCENE.instantiate() as ResearchCenterPanel
	var player := PLAYER_SCENE.instantiate() as Player
	var config := PlantDefenseRegistry.get_config(&"research_center")
	var center := config.plant_scene.instantiate() as ResearchCenter
	for node in [production, research, plant_system, player, center, panel]:
		root.add_child(node)
	await process_frame
	production.production_tick_timer.stop()
	research.research_tick_timer.stop()
	player.position = Vector2(-1024.0, -1024.0)
	center.setup(config, player, [Vector2i.ZERO])
	center.position = Vector2(-1024.0, -1024.0)
	research.setup(production, plant_system, null)
	research.register_player(player)
	center.set_research_services(research, panel)
	_set_research_completed(
		research,
		GlobalResearchRegistry.BUILDING_DEFENSE_ID
	)
	_set_research_completed(
		research,
		GlobalResearchRegistry.BUILDING_DEFENSE_II_ID
	)
	research.call("_apply_global_bonuses")
	panel.open_for(center, player)
	panel._select_global_research(
		GlobalResearchRegistry.BUILDING_DEFENSE_III_ID
	)
	for _frame in range(5):
		await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	)
	var result := root.get_texture().get_image().save_png(OUTPUT_PATH)
	if result != OK:
		push_error("无法保存科研中心三级科研验收图：%s" % error_string(result))
		quit(1)
		return
	print("RESEARCH_CENTER_CHAIN_VISUAL_CAPTURE_OK %s" % OUTPUT_PATH)
	quit()


func _set_research_completed(
	research: ResearchCoordinator,
	research_id: StringName
) -> void:
	var config := GlobalResearchRegistry.get_config(research_id)
	research.global_research_states[research_id] = (
		ResearchCoordinator.GlobalResearchState.COMPLETED
	)
	research.global_research_elapsed[research_id] = config.duration_seconds
