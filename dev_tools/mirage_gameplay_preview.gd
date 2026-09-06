extends "res://scene/pvp/mirage_pvp.gd"
## Finite capture of the actual game scene: purchase, combat and fog of war.

func _ready() -> void:
	super._ready()
	await get_tree().physics_frame
	set_physics_process(false)
	local_player.camera.position_smoothing_enabled = false
	hud.set_buy_open(true)
	await get_tree().create_timer(0.35).timeout
	await _capture("buy_panel")
	hud.set_buy_open(false)
	hud.banner.hide()
	phase = "live"
	phase_time_left = 81.0
	local_player.global_position = Vector2(1008, 1221)
	local_player.network_position = local_player.global_position
	local_player.aim_direction = Vector2(1, -0.35).normalized()
	local_player.loadout["ak"] = Rules.new_weapon("ak")
	local_player.equip("ak")
	local_player.authority_tick(0.0, false)
	players[2].global_position = Vector2(1205, 1160)
	players[2].network_position = players[2].global_position
	players[2].authority_tick(0.0, false)
	local_player.camera.global_position = local_player.global_position
	map.update_archway_visibility(local_player.global_position)
	_refresh_hud()
	await get_tree().create_timer(0.35).timeout
	await _capture("a_site_gameplay")
	local_player.global_position = Vector2(1140, 825)
	local_player.network_position = local_player.global_position
	players[2].global_position = Vector2(710, 800)
	local_player.camera.global_position = local_player.global_position
	_refresh_hud()
	await get_tree().create_timer(0.35).timeout
	await _capture("mid_visibility")
	print("MIRAGE_GAMEPLAY_CAPTURE: purchase, A site and Mid complete")
	get_tree().quit()


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var error := get_viewport().get_texture().get_image().save_png("res://dev_tools/generated_sources/mirage_pvp/" + name + ".png")
	assert(error == OK)
