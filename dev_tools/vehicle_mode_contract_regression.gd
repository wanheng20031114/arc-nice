extends SceneTree

const VEHICLE_TEXTURE_PATH := "res://resources/texture/player/vehicle/mini_combat_car.png"
const VEHICLE_TEXTURE_IMPORT_PATH := VEHICLE_TEXTURE_PATH + ".import"
const VEHICLE_SCENE_PATH := "res://scene/player/vehicle/player_vehicle.tscn"
const VEHICLE_OVERLAY_SCENE_PATH := (
	"res://scene/vehicle_mode/vehicle_mode_choice_overlay.tscn"
)
const MAIN_MENU_SCENE_PATH := "res://scene/main_menu.tscn"

var _errors: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_verify_vehicle_texture()
	_verify_vehicle_registry_contract()
	_verify_vehicle_scene_contract()
	_verify_vehicle_motion_contract()
	_verify_menu_contract()
	_verify_standard_mode_catalog_unchanged()
	await _verify_vehicle_runtime_ready()
	_verify_menu_runtime_ready()
	await _verify_overlay_runtime_layout()
	if _errors.is_empty():
		print("VEHICLE_MODE_CONTRACT_REGRESSION_OK")
		quit(0)
		return
	for message in _errors:
		push_error(message)
	quit(1)


func _verify_vehicle_texture() -> void:
	var image := Image.new()
	var error := image.load(ProjectSettings.globalize_path(VEHICLE_TEXTURE_PATH))
	if error != OK:
		_errors.append("Vehicle texture could not be loaded: %s" % error_string(error))
		return
	if image.get_width() != 32 or image.get_height() != 32:
		_errors.append("Vehicle texture canvas must be exactly 32x32 pixels.")
	var left := image.get_width()
	var top := image.get_height()
	var right := -1
	var bottom := -1
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			var is_transparent := is_zero_approx(pixel.a)
			var is_opaque := is_equal_approx(pixel.a, 1.0)
			if not is_transparent and not is_opaque:
				_errors.append("Vehicle texture alpha must contain only 0 or 255.")
				return
			if is_transparent:
				if not is_zero_approx(pixel.r + pixel.g + pixel.b):
					_errors.append("Transparent vehicle pixels must have zero RGB residue.")
					return
				continue
			left = mini(left, x)
			top = mini(top, y)
			right = maxi(right, x)
			bottom = maxi(bottom, y)
	if right < left or bottom < top:
		_errors.append("Vehicle texture has no visible subject.")
		return
	if right - left + 1 > 24 or bottom - top + 1 > 24:
		_errors.append("Vehicle visible subject exceeds 24x24 pixels.")
	if (
		left < 5
		or right > image.get_width() - 6
		or top < 5
		or bottom > image.get_height() - 6
	):
		_errors.append("Vehicle texture must preserve transparent shader guard pixels.")
	var import_text := FileAccess.get_file_as_string(VEHICLE_TEXTURE_IMPORT_PATH)
	if (
		'importer="texture"' not in import_text
		or "compress/mode=0" not in import_text
		or "mipmaps/generate=false" not in import_text
	):
		_errors.append("Vehicle texture import must stay lossless without mipmaps.")


func _verify_vehicle_registry_contract() -> void:
	var config := PlayerCharacterRegistry.get_config(
		PlayerCharacterRegistry.VEHICLE_ID
	)
	if config == null:
		_errors.append("Vehicle character config is not registered.")
		return
	if not config.is_valid():
		_errors.append("Vehicle character config is invalid.")
	if config.player_scene != VEHICLE_SCENE_PATH:
		_errors.append("Vehicle config must reference its independent player scene.")
	if config.starting_max_health != 100:
		_errors.append("Vehicle starting health must be 100.")
	if config.starting_attack_damage != 10:
		_errors.append("Vehicle starting attack must be 10.")
	if not is_equal_approx(config.starting_move_speed, 100.0):
		_errors.append("Vehicle starting movement speed must be 100.")
	if not config.supports_ammunition:
		_errors.append("Vehicle must reuse Weishidaier ammunition combat.")
	if PlayerCharacterRegistry.is_character_menu_selectable(
		PlayerCharacterRegistry.VEHICLE_ID
	):
		_errors.append("Vehicle must not leak into the ordinary character menu.")
	if PlayerCharacterRegistry.is_multiplayer_character_id(
		PlayerCharacterRegistry.VEHICLE_ID
	):
		_errors.append("Vehicle must stay outside the frozen multiplayer character codec.")
	for menu_config in PlayerCharacterRegistry.get_character_menu_configs():
		if menu_config.character_id == PlayerCharacterRegistry.VEHICLE_ID:
			_errors.append("Vehicle appeared in ordinary character menu configs.")
	for multiplayer_config in PlayerCharacterRegistry.get_multiplayer_configs():
		if multiplayer_config.character_id == PlayerCharacterRegistry.VEHICLE_ID:
			_errors.append("Vehicle appeared in multiplayer preload configs.")


func _verify_vehicle_scene_contract() -> void:
	var packed_scene := load(VEHICLE_SCENE_PATH) as PackedScene
	if packed_scene == null:
		_errors.append("Vehicle player scene could not be loaded.")
		return
	var vehicle := packed_scene.instantiate() as PlayerVehicle
	if vehicle == null:
		_errors.append("Vehicle scene root must instantiate as PlayerVehicle.")
		return
	if vehicle.character_id != PlayerCharacterRegistry.VEHICLE_ID:
		_errors.append("Vehicle scene root has the wrong character id.")
	if vehicle.physical_defense != 0 or vehicle.magic_defense != 0:
		_errors.append("Vehicle authored physical and magic defense must both be zero.")
	var body_sprite := vehicle.get_node_or_null("BodySprite") as AnimatedSprite2D
	if body_sprite == null:
		_errors.append("Vehicle scene is missing BodySprite.")
	elif body_sprite.texture_filter != CanvasItem.TEXTURE_FILTER_NEAREST:
		_errors.append("Vehicle BodySprite must use nearest-neighbor filtering.")
	elif not body_sprite.material is ShaderMaterial:
		_errors.append("Vehicle BodySprite must retain the shared status shader material.")
	else:
		var material := body_sprite.material as ShaderMaterial
		if not bool(material.get_shader_parameter(&"paint_recolor_enabled")):
			_errors.append("Vehicle paint recoloring must be enabled on BodySprite.")
	var muzzle := vehicle.get_node_or_null("MuzzlePivot/Muzzle") as Marker2D
	if muzzle == null:
		_errors.append("Vehicle scene is missing its authored muzzle marker.")
	elif not muzzle.position.is_equal_approx(Vector2(12.0, 0.0)):
		_errors.append("Vehicle muzzle must sit on the centered +X heading axis.")
	vehicle.free()


func _verify_vehicle_motion_contract() -> void:
	var vehicle := PlayerVehicle.new()
	for _frame in 60:
		vehicle._step_longitudinal_speed(1.0, 100.0, 1.0 / 60.0)
	if not is_equal_approx(vehicle.longitudinal_speed, 100.0):
		_errors.append("Vehicle must accelerate from 0 to 100 in one second.")
	vehicle.longitudinal_speed = 100.0
	vehicle._step_longitudinal_speed(-1.0, 100.0, PlayerVehicle.BRAKE_TO_STOP_DURATION)
	if not is_zero_approx(vehicle.longitudinal_speed):
		_errors.append("Opposite throttle must brake the vehicle within 0.20 seconds.")
	vehicle.longitudinal_speed = 100.0
	vehicle._step_longitudinal_speed(0.0, 100.0, PlayerVehicle.COAST_TO_STOP_DURATION)
	if not is_zero_approx(vehicle.longitudinal_speed):
		_errors.append("Released throttle must coast to rest within 0.45 seconds.")
	vehicle.longitudinal_speed = 0.0
	vehicle._step_longitudinal_speed(1.0, 160.0, 2.0)
	if vehicle.longitudinal_speed > PlayerVehicle.MAX_VEHICLE_SPEED:
		_errors.append("Vehicle speed must remain capped at 100 after movement buffs.")
	vehicle.heading = Vector2.RIGHT
	vehicle._step_heading(1.0, 0.6)
	if not vehicle.heading.is_equal_approx(Vector2.DOWN):
		_errors.append("Vehicle steering must rotate 150 degrees per second.")
	vehicle.free()


func _verify_vehicle_runtime_ready() -> void:
	var packed_scene := load(VEHICLE_SCENE_PATH) as PackedScene
	if packed_scene == null:
		return
	var run_state := get_root().get_node_or_null("RunState") as RunStateStore
	var original_paint_color := RunStateStore.DEFAULT_VEHICLE_PAINT_COLOR
	var test_paint_color := Color("ec584d")
	if run_state != null:
		original_paint_color = run_state.get_vehicle_paint_color()
		run_state.set_vehicle_paint_color(test_paint_color)
	var vehicle := packed_scene.instantiate() as PlayerVehicle
	if vehicle == null:
		if run_state != null:
			run_state.set_vehicle_paint_color(original_paint_color)
		return
	get_root().add_child(vehicle)
	await process_frame
	if vehicle.max_health != 100 or vehicle.current_health != 100:
		_errors.append("Ready vehicle must start with exactly 100 health.")
	if vehicle.attack_damage != 10:
		_errors.append("Ready vehicle must start with exactly 10 attack.")
	if vehicle.physical_defense != 0 or vehicle.magic_defense != 0:
		_errors.append("Ready vehicle must start with zero defense.")
	if not is_equal_approx(vehicle.move_speed, 100.0):
		_errors.append("Ready vehicle base movement speed must be 100.")
	if not is_equal_approx(vehicle._get_muzzle_distance(), 12.0):
		_errors.append("Ready vehicle projectile spawn distance must match its muzzle.")
	var vehicle_material := vehicle.body_sprite.material as ShaderMaterial
	if (
		vehicle_material == null
		or not (vehicle_material.get_shader_parameter(&"paint_color") as Color).is_equal_approx(
			test_paint_color
		)
	):
		_errors.append("Ready vehicle must apply the RunState paint color.")
	vehicle.current_form_mode = PickupConfig.PlayerFormMode.ARMED
	vehicle._update_armed_effect()
	if vehicle.armed_effect_sprite.visible or vehicle.armed_effect_sprite.is_playing():
		_errors.append("Vehicle must not display the inherited humanoid armed effect.")
	var snow_wolf := load(
		"res://resources/config/pickup_triggered_items/snow_wolf_pojun.tres"
	) as PickupConfig
	if snow_wolf == null or not vehicle._apply_character_pickup(snow_wolf, 5.0):
		_errors.append("Vehicle must accept the Standard map's fixed form pickup.")
	elif (
		vehicle.current_shot_pattern != PickupConfig.ShotPattern.NORMAL
		or vehicle.current_form_mode != PickupConfig.PlayerFormMode.ARMED
		or vehicle.form_fire_rate_multiplier <= 1.0
	):
		_errors.append("Vehicle form pickup must retain its boost without SPIRAL ammo semantics.")
	vehicle.longitudinal_speed = 75.0
	vehicle._on_controls_lock_changed(true)
	if not is_zero_approx(vehicle.longitudinal_speed):
		_errors.append("Vehicle control locks must atomically clear longitudinal speed.")
	vehicle.longitudinal_speed = 75.0
	vehicle._clear_character_scene_transients()
	if not is_zero_approx(vehicle.longitudinal_speed):
		_errors.append("Vehicle scene cleanup must clear longitudinal speed.")
	vehicle.heading = Vector2.DOWN
	vehicle._sync_vehicle_visuals()
	if not is_zero_approx(vehicle.grass_healing_particles.global_rotation):
		_errors.append("Vehicle healing particles must remain aligned to world space.")
	vehicle.longitudinal_speed = 75.0
	vehicle._play_death_animation()
	if not is_zero_approx(vehicle.longitudinal_speed) or vehicle.body_sprite.visible:
		_errors.append("Vehicle death presentation must stop and hide the intact car.")
	vehicle.queue_free()
	await process_frame
	if run_state != null:
		run_state.set_vehicle_paint_color(original_paint_color)


func _verify_menu_contract() -> void:
	var menu_scene := load(MAIN_MENU_SCENE_PATH) as PackedScene
	if menu_scene == null:
		_errors.append("Main menu scene could not be loaded after vehicle integration.")
		return
	var menu := menu_scene.instantiate()
	if menu.get_node_or_null(
		"MenuCenter/MenuPanel/MarginContainer/MenuStack/VehicleMode"
	) == null:
		_errors.append("Main menu is missing the authored VehicleMode button.")
	if menu.get_node_or_null("VehicleModeChoiceOverlay") == null:
		_errors.append("Main menu is missing the authored vehicle customization overlay.")
	menu.free()
	var overlay_scene := load(VEHICLE_OVERLAY_SCENE_PATH) as PackedScene
	if overlay_scene == null:
		_errors.append("Vehicle customization overlay scene could not be loaded.")
		return
	var overlay := overlay_scene.instantiate() as VehicleModeChoiceOverlay
	if overlay == null:
		_errors.append("Vehicle customization overlay has the wrong root script.")
		return
	if overlay.get_node_or_null(
		"Root/Center/Panel/Margin/Content/CustomColor/ColorPickerButton"
	) == null:
		_errors.append("Vehicle customization overlay is missing ColorPickerButton.")
	if overlay.get_node_or_null(
		"Root/Center/Panel/Margin/Content/PreviewFrame/PreviewCenter/Preview"
	) == null:
		_errors.append("Vehicle customization overlay is missing the paint preview.")
	overlay.free()


func _verify_menu_runtime_ready() -> void:
	var menu_scene := load(MAIN_MENU_SCENE_PATH) as PackedScene
	if menu_scene == null:
		return
	var menu := menu_scene.instantiate() as MainMenu
	if menu == null:
		return
	get_root().add_child(menu)
	menu._on_vehicle_mode_pressed()
	if not menu.vehicle_mode_choice_overlay.is_open():
		_errors.append("Vehicle customization overlay must open from the main menu.")
	menu.vehicle_mode_choice_overlay._on_preset_pressed(1)
	if not menu.vehicle_mode_choice_overlay.selected_color.is_equal_approx(Color("ec584d")):
		_errors.append("Vehicle paint presets must update the selected color.")
	menu.vehicle_mode_choice_overlay.close()
	menu.free()


func _verify_overlay_runtime_layout() -> void:
	var overlay_scene := load(VEHICLE_OVERLAY_SCENE_PATH) as PackedScene
	if overlay_scene == null:
		return
	var overlay := overlay_scene.instantiate() as VehicleModeChoiceOverlay
	if overlay == null:
		return
	get_root().add_child(overlay)
	overlay.open(RunStateStore.DEFAULT_VEHICLE_PAINT_COLOR)
	await process_frame
	var panel := overlay.get_node_or_null("Root/Center/Panel") as Control
	var viewport_size := get_root().get_visible_rect().size
	if (
		panel == null
		or panel.size.x > viewport_size.x
		or panel.size.y > viewport_size.y
	):
		_errors.append("Vehicle customization panel must fit inside the game viewport.")
	if not overlay.preview.size.is_equal_approx(Vector2(128.0, 128.0)):
		_errors.append("Vehicle paint preview must use an integer 4x nearest scale.")
	overlay._on_preset_pressed(4)
	var preview_material := overlay.preview.material as ShaderMaterial
	if (
		preview_material == null
		or not (preview_material.get_shader_parameter(&"paint_color") as Color).is_equal_approx(
			Color("a36be2")
		)
	):
		_errors.append("Vehicle paint preview must reflect the selected preset.")
	overlay.free()


func _verify_standard_mode_catalog_unchanged() -> void:
	var catalog_errors := GameModeCatalog.validate_catalog()
	for catalog_error in catalog_errors:
		_errors.append("Game mode catalog regression: %s" % catalog_error)
	var definition := GameModeCatalog.get_definition(GameModeCatalog.MODE_STANDARD)
	if definition == null:
		_errors.append("Standard mode definition is missing.")
		return
	if definition.singleplayer_entry_scene_path != (
		"res://scene/game_modes/standard/standard_game.tscn"
	):
		_errors.append("Vehicle mode must keep using the original Standard map scene.")
