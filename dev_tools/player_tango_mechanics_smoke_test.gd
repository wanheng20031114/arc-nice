extends SceneTree

const TANGO_SCENE := preload("res://scene/player/tango/player_tango.tscn")
const TANGO_IDLE_TEXTURE_PATH := (
	"res://resources/texture/player/tango/tango_idle_front_32.png"
)


class TangoTickProbe:
	extends PlayerTango

	var damage_tick_count := 0


	func _apply_beam_damage_tick() -> int:
		damage_tick_count += 1
		return 0


class TangoBeamEnemy:
	extends Enemy

	var total_damage_taken := 0
	var last_damage_type := EnemyConfig.DamageType.MAGIC


	func _ready() -> void:
		pass


	func _physics_process(_delta: float) -> void:
		pass


	func _on_combat_damage_applied(result: DamageResult) -> void:
		total_damage_taken += result.applied_damage
		last_damage_type = result.request.damage_type as EnemyConfig.DamageType


var failures: Array[String] = []
var test_root: Node2D = null
var player: PlayerTango = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerTangoMechanicsSmokeRoot"
	root.add_child(test_root)
	current_scene = test_root

	player = TANGO_SCENE.instantiate() as PlayerTango
	_expect(player != null, "Tango scene must instantiate as PlayerTango.")
	if player == null:
		await _finish()
		return
	test_root.add_child(player)
	await process_frame
	await physics_frame
	_stop_audio_players(player)
	player.set_process(false)
	player.set_physics_process(false)

	_test_character_contract()
	_test_authored_casting_units_and_orbit()
	await _test_charge_release_contract()
	_test_full_charge_damage_tick_schedule()
	await _test_authored_beam_overlap_and_damage()
	_test_animation_and_pixel_contract()
	await _finish()


func _test_character_contract() -> void:
	var config := PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.TANGO_ID)
	_expect(config != null, "Tango must have a registered character config.")
	if config != null:
		_expect(config.starting_max_health == 60, "Tango config must start at 60 health.")
		_expect(config.starting_attack_damage == 10, "Tango config must start at 10 attack.")
		_expect(
			config.player_scene == "res://scene/player/tango/player_tango.tscn",
			"Tango config must point to the authored Tango scene."
		)
	_expect(player.get_character_id() == PlayerCharacterRegistry.TANGO_ID, "Tango must keep its explicit character id.")
	_expect(player.max_health == 60 and player.current_health == 60, "Tango must enter play at 60/60 health.")
	_expect(player.attack_damage == 10, "Tango must enter play with 10 base attack.")
	_expect(not player.has_skill1(), "Tango skill1 must remain locked until it is implemented.")
	_expect(
		not player.supports_research_technology()
		and player.get_next_research_technology_cost() == 0,
		"Tango must not sell an inert personal research branch before skill1 exists."
	)
	_expect(
		player.skill1_charge_bar == null or not player.skill1_charge_bar.visible,
		"Tango's unavailable skill1 bar must remain hidden."
	)

	# Distinct bonuses make the damage snapshot prove that the beam selects the
	# physical channel rather than merely matching the unmodified base attack.
	player.collectible_physical_damage_bonus = 3
	player.collectible_magic_damage_bonus = 100
	player.call("_start_beam_sequence", Vector2.RIGHT, 0.0, true)
	_expect(
		int(player.get("_beam_damage_snapshot")) == 13,
		"Tango beam damage must snapshot the physical attack channel."
	)
	player.collectible_physical_damage_bonus = 0
	player.collectible_magic_damage_bonus = 0
	player.call("_reset_tango_combat_state", true)


func _test_authored_casting_units_and_orbit() -> void:
	var unit_names := [&"UnitA", &"UnitB", &"UnitC"]
	var units: Array[AnimatedSprite2D] = []
	for unit_name in unit_names:
		var unit := player.get_node_or_null("CastingUnits/%s" % unit_name) as AnimatedSprite2D
		_expect(unit != null, "%s must be a pre-authored AnimatedSprite2D." % unit_name)
		if unit == null:
			continue
		units.append(unit)
		_expect(
			unit.owner == player,
			"%s must belong to the packed Tango scene rather than being generated at runtime."
			% unit_name
		)
		for animation_name in [&"orbit", &"charge", &"fire"]:
			_expect(
				unit.sprite_frames.has_animation(animation_name),
				"%s must provide the %s animation." % [unit_name, animation_name]
			)
	_expect(units.size() == 3, "Tango must own exactly three authored casting units.")

	var phase_step := PlayerTango.UNIT_PHASE_STEP
	_expect(
		is_equal_approx(phase_step, TAU / 3.0),
		"Casting-unit phase step must be exactly 120 degrees."
	)
	for index in range(3):
		var current_phase := float(index) * phase_step
		var next_phase := float(index + 1) * phase_step
		_expect(
			is_equal_approx(fposmod(next_phase - current_phase, TAU), TAU / 3.0),
			"Each adjacent casting-unit phase must remain exactly 120 degrees apart."
		)
	_expect(
		is_equal_approx(PlayerTango.UNIT_ORBIT_PERIOD, 6.0),
		"Casting units must keep the authored slow six-second orbit."
	)

	player.set("_unit_orbit_phase", 0.0)
	player.call("_update_orbit_visuals", 0.0)
	for index in units.size():
		var phase := float(index) * phase_step
		var expected_position := Vector2(
			roundf(cos(phase) * PlayerTango.UNIT_ORBIT_RADIUS.x),
			roundf(sin(phase) * PlayerTango.UNIT_ORBIT_RADIUS.y)
		)
		_expect(
			units[index].position == expected_position,
			"Casting unit %d must occupy its pixel-rounded 120-degree orbit position."
			% index
		)


func _test_charge_release_contract() -> void:
	var attack_bar := player.attack_interval_bar as PlayerAttackIntervalBar
	_expect(attack_bar != null, "Tango must expose its authored primary charge bar.")
	player.call("_reset_tango_combat_state", true)
	player.call("_update_attack_interval_bar")
	_expect(
		is_zero_approx(player.get_tango_charge_ratio()),
		"Tango's charge ratio must be zero while orbiting."
	)
	if attack_bar != null:
		_expect(
			is_zero_approx(attack_bar.cooldown_progress) and not attack_bar.is_ready,
			"Tango's visible primary bar must rest at zero instead of showing ready/full."
		)

	player.call("_handle_primary_attack_input", Vector2.RIGHT)
	player.call("_update_character_resources", 0.19)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.CHARGING,
		"Holding attack for 0.19 seconds must still be charging."
	)
	player.call("_handle_primary_attack_input", Vector2.ZERO)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.ORBIT
		and is_zero_approx(player.get_tango_beam_length())
		and is_zero_approx(player.get_tango_beam_duration()),
		"Releasing at 0.19 seconds must cancel without creating a beam."
	)

	player.call("_handle_primary_attack_input", Vector2.RIGHT)
	player.call("_update_character_resources", 0.2)
	player.call("_handle_primary_attack_input", Vector2.ZERO)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.CONVERGING,
		"Releasing at the inclusive 0.2-second threshold must begin convergence."
	)
	_expect(
		is_zero_approx(player.get_tango_release_ratio())
		and is_equal_approx(player.get_tango_beam_length(), 48.0)
		and is_equal_approx(player.get_tango_beam_duration(), 0.1),
		"Minimum legal charge must produce a 48px beam lasting 0.1 seconds."
	)

	player.call("_reset_tango_combat_state", true)
	player.call("_start_beam_sequence", Vector2.RIGHT, 0.5, false)
	player.call("_update_character_combat_state", PlayerTango.UNIT_CONVERGE_DURATION)
	await process_frame
	_expect(
		player.beam_area.monitoring and player.beam_visual_root.visible,
		"A predicted Tango beam must enable its authored Area2D and Line2D visuals."
	)
	player.reject_predicted_tango_charge()
	await process_frame
	_expect(
		not player.beam_area.monitoring
		and player.beam_collision.disabled
		and not player.beam_visual_root.visible
		and player.get_tango_casting_state() == PlayerTango.CastingState.ORBIT,
		"A Host rejection/cancellation must unconditionally stop a predicted beam."
	)

	player.call("_start_beam_sequence", Vector2.RIGHT, 0.4, false)
	player.confirm_predicted_tango_charge_started(7)
	player.call("_update_character_combat_state", PlayerTango.UNIT_CONVERGE_DURATION * 0.5)
	var converge_elapsed_before := float(player.get("_unit_converge_elapsed"))
	player.reconcile_predicted_tango_laser_fired(Vector2.RIGHT, 0.8, 7)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.CONVERGING
		and is_equal_approx(
			float(player.get("_unit_converge_elapsed")),
			converge_elapsed_before
		)
		and is_equal_approx(player.get_tango_beam_length(), 86.4),
		"A local Host confirmation must correct prediction values without restarting convergence."
	)
	player.call("_reset_tango_combat_state", true)
	player.set("_latest_remote_action_sequence", 0)
	player.set("_latest_remote_action_phase", 0)
	player.apply_multiplayer_tango_charge_snapshot(0.4, 2)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.CHARGING
		and is_equal_approx(player.get_tango_charge_ratio(), 0.4)
		and Vector2(player.get("_charge_direction")) == Vector2.UP,
		"A joining client must reconstruct Tango's active charge visual from its snapshot."
	)
	player.set("_latest_remote_action_phase", 2)
	player.apply_multiplayer_tango_charge_snapshot(0.8, 0)
	_expect(
		attack_bar == null or is_zero_approx(attack_bar.cooldown_progress),
		"A stale positive snapshot must not flash Tango's charge bar after a terminal event."
	)
	player.call("_reset_tango_combat_state", true)

	player.call("_handle_primary_attack_input", Vector2.RIGHT)
	player.call("_update_character_resources", 0.5)
	player.set_combat_actions_locked(true)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.ORBIT
		and player.casting_units.visible,
		"Locking combat must cancel the charge while keeping the always-orbiting units visible."
	)
	player.set_combat_actions_locked(false)
	player.call("_handle_primary_attack_input", Vector2.RIGHT)
	player.call("_update_character_resources", 2.5)
	player.call("_handle_primary_attack_input", Vector2.ZERO)
	_expect(
		is_equal_approx(player.get_tango_release_ratio(), 1.0)
		and is_equal_approx(player.get_tango_beam_length(), 96.0)
		and is_equal_approx(player.get_tango_beam_duration(), 1.0),
		"A 2.5-second full charge must produce a 96px beam lasting one second."
	)
	player.call("_reset_tango_combat_state", true)


func _test_full_charge_damage_tick_schedule() -> void:
	var probe := TangoTickProbe.new()
	probe.set("_casting_state", PlayerTango.CastingState.FIRING)
	probe.set("_beam_duration", 1.0)
	probe.set("_beam_elapsed", 0.0)
	probe.set("_beam_next_damage_time", PlayerTango.BEAM_DAMAGE_INTERVAL)
	probe.set("_beam_is_authoritative", true)
	probe.set("_beam_damage_snapshot", 10)
	probe.call("_update_active_beam", 1.0)
	_expect(
		probe.damage_tick_count == 10,
		"A full one-second beam must resolve exactly ten 0.1-second damage ticks."
	)
	_expect(
		int(probe.get("_casting_state")) == PlayerTango.CastingState.ORBIT,
		"The full-charge beam must return to orbit after its tenth tick."
	)
	probe.free()


func _test_authored_beam_overlap_and_damage() -> void:
	var inside_enemy := _spawn_beam_enemy(Vector2(50.0, 0.0))
	var outside_enemy := _spawn_beam_enemy(Vector2(116.0, 0.0))
	player.call("_reset_tango_combat_state", true)
	_expect(
		player.try_authoritative_tango_charge_started(Vector2.RIGHT),
		"The authored beam overlap test must begin an authoritative charge."
	)
	var release_result := player.try_authoritative_tango_charge_released(
		Vector2.RIGHT,
		1.0
	)
	_expect(
		bool(release_result.get("accepted", false)),
		"The authored beam overlap test must accept a full-charge release."
	)
	player.call("_update_character_combat_state", PlayerTango.UNIT_CONVERGE_DURATION)
	await process_frame
	await physics_frame
	await physics_frame
	for _tick in range(10):
		player.call("_update_character_combat_state", PlayerTango.BEAM_DAMAGE_INTERVAL)
	_expect(
		inside_enemy.total_damage_taken == 100
		and inside_enemy.last_damage_type == EnemyConfig.DamageType.PHYSICAL,
		"An enemy inside the authored full beam must receive ten physical 10-damage ticks (got %d)."
		% inside_enemy.total_damage_taken
	)
	_expect(
		outside_enemy.total_damage_taken == 0,
		"An enemy beyond the authored six-grid beam must receive no damage."
	)
	inside_enemy.queue_free()
	outside_enemy.queue_free()
	await process_frame


func _spawn_beam_enemy(spawn_position: Vector2) -> TangoBeamEnemy:
	var enemy := TangoBeamEnemy.new()
	enemy.current_health = 1000
	enemy.collision_layer = 4
	enemy.collision_mask = 0
	var animated_sprite := AnimatedSprite2D.new()
	animated_sprite.name = "AnimatedSprite2D"
	enemy.add_child(animated_sprite)
	var speed_trail := Node2D.new()
	speed_trail.name = "MoveSpeedTrailEffect"
	enemy.add_child(speed_trail)
	var collision := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 1.0
	collision.shape = circle
	enemy.add_child(collision)
	var touch_area := Area2D.new()
	touch_area.name = "TouchDamageArea"
	enemy.add_child(touch_area)
	var hit_particles := GPUParticles2D.new()
	hit_particles.name = "HitParticles"
	enemy.add_child(hit_particles)
	var hit_audio := AudioStreamPlayer2D.new()
	hit_audio.name = "HitAudio"
	enemy.add_child(hit_audio)
	var death_audio := AudioStreamPlayer2D.new()
	death_audio.name = "DeathAudio"
	enemy.add_child(death_audio)
	test_root.add_child(enemy)
	enemy.position = spawn_position
	return enemy


func _test_animation_and_pixel_contract() -> void:
	var frames := player.body_sprite.sprite_frames
	var expected_animations := {
		&"idle_down": {"frames": 1, "fps": 1.0, "loop": true},
		&"idle_up": {"frames": 1, "fps": 1.0, "loop": true},
		&"idle_right": {"frames": 1, "fps": 1.0, "loop": true},
		&"idle_left": {"frames": 1, "fps": 1.0, "loop": true},
		&"normal_down": {"frames": 8, "fps": 14.0, "loop": true},
		&"normal_up": {"frames": 8, "fps": 14.0, "loop": true},
		&"normal_right": {"frames": 8, "fps": 14.0, "loop": true},
		&"normal_left": {"frames": 8, "fps": 14.0, "loop": true},
		&"death": {"frames": 8, "fps": 12.0, "loop": false},
	}
	for animation_name_variant in expected_animations:
		var animation_name := animation_name_variant as StringName
		var contract: Dictionary = expected_animations[animation_name]
		_expect(frames.has_animation(animation_name), "Tango must provide %s." % animation_name)
		if not frames.has_animation(animation_name):
			continue
		_expect(
			frames.get_frame_count(animation_name) == int(contract["frames"]),
			"Tango %s must contain %d frames."
			% [animation_name, int(contract["frames"])]
		)
		_expect(
			is_equal_approx(frames.get_animation_speed(animation_name), float(contract["fps"])),
			"Tango %s must run at %.1f FPS."
			% [animation_name, float(contract["fps"])]
		)
		_expect(
			frames.get_animation_loop(animation_name) == bool(contract["loop"]),
			"Tango %s loop mode must match its authored contract." % animation_name
		)
		for frame_index in frames.get_frame_count(animation_name):
			var frame_texture := frames.get_frame_texture(animation_name, frame_index)
			var frame_image := _extract_frame_image(frame_texture)
			_expect(
				frame_image != null,
				"Tango %s frame %d must resolve to image pixels."
				% [animation_name, frame_index]
			)
			if frame_image == null:
				continue
			var used_rect := frame_image.get_used_rect()
			_expect(
				not used_rect.has_area() or used_rect.size.y <= 24,
				"Tango %s frame %d must keep the subject at or below 24px high (got %d)."
				% [animation_name, frame_index, used_rect.size.y]
			)

	var idle_texture := load(TANGO_IDLE_TEXTURE_PATH) as Texture2D
	var idle_image := idle_texture.get_image() if idle_texture != null else null
	_expect(idle_image != null, "Tango's corrected idle texture must be readable.")
	if idle_image != null:
		var active_cyan := Color8(56, 236, 243, 255)
		for y in [9, 10]:
			_expect(
				idle_image.get_pixel(15, y) == active_cyan
				and idle_image.get_pixel(18, y) == active_cyan,
				"Tango's left and right eye pixels must share the same bright cyan."
			)


func _extract_frame_image(texture: Texture2D) -> Image:
	if texture == null:
		return null
	var atlas_texture := texture as AtlasTexture
	if atlas_texture == null:
		return texture.get_image()
	if atlas_texture.atlas == null:
		return null
	var atlas_image := atlas_texture.atlas.get_image()
	if atlas_image == null:
		return null
	var region := Rect2i(
		roundi(atlas_texture.region.position.x),
		roundi(atlas_texture.region.position.y),
		roundi(atlas_texture.region.size.x),
		roundi(atlas_texture.region.size.y)
	)
	return atlas_image.get_region(region)


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
		node.call("stop")
	for child in node.get_children():
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if test_root != null and is_instance_valid(test_root):
		_stop_audio_players(test_root)
		test_root.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("PLAYER_TANGO_MECHANICS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
