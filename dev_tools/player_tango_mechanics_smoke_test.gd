extends SceneTree

const TANGO_SCENE := preload("res://scene/player/tango/player_tango.tscn")
const TANGO_IDLE_TEXTURE_PATH := (
	"res://resources/texture/player/tango/tango_idle_front_32.png"
)
const TANGO_LASER_BULLET_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const TANGO_LASER_MATERIAL := preload(
	"res://resources/shader/tango_laser_bullet_single_pass.tres"
)
const TANGO_MOVE_BOB_OFFSETS := [0, 1, 1, 0, 0, 1, 1, 0]
const TANGO_DOWN_BODY_X_OFFSETS := [0, -1, -1, -1, 0, 1, 1, 1]
const TANGO_DOWN_EXPECTED_CONTACTS := [
	[10, 11, 12, 13, 14, 17, 18, 19, 20],
	[10, 11, 12, 13, 14, 17],
	[11, 12, 13, 14, 15],
	[14, 15, 20, 21],
	[14, 15, 18, 19, 20, 21, 22],
	[15, 18, 19, 20, 21, 22],
	[17, 18, 19, 20, 21],
	[11, 12, 17, 18],
]
const TANGO_FIXED_BODY_BOTTOM := 23


class TangoScheduleProbe:
	extends PlayerTango

	var emitted_volley_count := 0


	func _emit_tango_volley() -> void:
		emitted_volley_count += 1
		_barrage_volley_count += 1


	func _get_effective_fire_interval() -> float:
		return 100.0 / 240.0


class TangoBulletEnemy:
	extends Enemy

	var total_damage_taken := 0
	var last_damage_type := EnemyConfig.DamageType.MAGIC
	var last_source_type := StringName()


	func _ready() -> void:
		pass


	func _physics_process(_delta: float) -> void:
		pass


	func _on_combat_damage_applied(result: DamageResult) -> void:
		total_damage_taken += result.applied_damage
		last_damage_type = result.request.damage_type as EnemyConfig.DamageType
		last_source_type = result.request.source_type


var failures: Array[String] = []
var test_root: Node2D = null
var player: PlayerTango = null
var pixel_only := false


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

	pixel_only = OS.get_cmdline_user_args().has("--pixel-only")
	if not pixel_only:
		_test_character_contract()
		_test_authored_casting_units_and_orbit()
		_test_electric_surge_character_contract()
		await _test_charge_release_contract()
		_test_barrage_tier_and_schedule_contract()
		await _test_laser_bullet_scene_and_damage()
	_test_animation_and_pixel_contract()
	await _finish()


func _test_character_contract() -> void:
	var config := PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.TANGO_ID)
	_expect(config != null, "Tango must have a registered character config.")
	if config != null:
		_expect(config.starting_max_health == 60, "Tango config must start at 60 health.")
		_expect(config.starting_attack_damage == 10, "Tango config must start at 10 attack.")
		_expect(
			is_equal_approx(config.starting_attack_speed, 240.0)
			and is_equal_approx(config.attack_speed_units_per_attack, 100.0),
			"Tango must start at 240 attack speed with 100 units per volley."
		)
		_expect(
			config.player_scene == "res://scene/player/tango/player_tango.tscn",
			"Tango config must point to the authored Tango scene."
		)
		_expect(
			config.skill_display_name == "电能涌动"
			and config.skill_description.contains("8秒")
			and config.skill_description.contains("半径72")
			and config.skill_description.contains("20点固定法术伤害")
			and config.skill_icon_texture == (
				"res://resources/texture/player/tango/skill1_icon.png"
			),
			"Tango config must publish the complete Electric Surge skill contract."
		)
	_expect(player.get_character_id() == PlayerCharacterRegistry.TANGO_ID, "Tango must keep its explicit character id.")
	_expect(player.max_health == 60 and player.current_health == 60, "Tango must enter play at 60/60 health.")
	_expect(player.attack_damage == 10, "Tango must enter play with 10 base attack.")
	_expect(
		is_equal_approx(player.call("_get_effective_fire_interval"), 100.0 / 240.0),
		"Tango's default interval must be 0.4167 seconds per three-shot volley."
	)
	_expect(
		not player.supports_projectile_attack_patterns(),
		"Tango must not advertise unsynchronised piercing/homing shot patterns."
	)
	_expect(player.has_skill1(), "Tango Electric Surge must be unlocked at character start.")
	_expect(
		is_equal_approx(player.skill1_charge_duration, 18.0),
		"Tango Electric Surge must use an 18-second base recharge."
	)
	_expect(
		not player.supports_research_technology()
		and player.get_next_research_technology_cost() == 0,
		"Tango must not sell a personal research branch before it is designed."
	)
	_expect(
		player.skill1_charge_bar != null and player.skill1_charge_bar.visible,
		"Tango's unlocked Electric Surge charge bar must be visible."
	)
	var surge_timer := player.get_node_or_null("ElectricSurgeDurationTimer") as Timer
	_expect(
		surge_timer != null
		and surge_timer.owner == player
		and surge_timer.one_shot
		and is_equal_approx(surge_timer.wait_time, 8.0),
		"Electric Surge must own an authored one-shot eight-second lifetime timer."
	)

	# Distinct bonuses prove that the barrage snapshots the physical channel.
	player.collectible_physical_damage_bonus = 3
	player.collectible_magic_damage_bonus = 100
	player.call(
		"_start_barrage_sequence",
		Vector2.RIGHT,
		_charge_seconds_to_release_ratio(0.5),
		true
	)
	_expect(
		player.get_tango_barrage_damage() == 13,
		"Tango barrage damage must snapshot the physical attack channel."
	)
	player.collectible_physical_damage_bonus = 0
	player.collectible_magic_damage_bonus = 0
	player.call("_reset_tango_combat_state", true)


func _test_electric_surge_character_contract() -> void:
	player.call("_reset_tango_combat_state", true)
	var base_interval := float(player.call("_get_effective_fire_interval"))
	var unattached_enemy := TangoBulletEnemy.new()
	var attached_enemy := TangoBulletEnemy.new()
	attached_enemy.elemental_attachment_mask = Enemy.ELEMENTAL_ATTACHMENT_ELECTRIC
	player.skill1_charge = player.skill1_charge_duration
	var activation_origin := Vector2(64, 48)
	_expect(
		player.try_start_authoritative_electric_surge(41, activation_origin),
		"A fully charged authoritative Electric Surge activation must succeed."
	)
	_expect(
		player.is_electric_surge_active()
		and player.get_electric_surge_activation_id() == 41
		and player.get_electric_surge_origin() == activation_origin
		and player.get_electric_surge_remaining_seconds() > 7.9,
		"Electric Surge must expose a recoverable eight-second active state."
	)
	_expect(
		is_zero_approx(player.skill1_charge),
		"Authoritative Electric Surge must consume the ready skill charge."
	)
	_expect(
		is_equal_approx(
			float(player.call("_get_effective_fire_interval")),
			base_interval / 1.5
		),
		"Electric Surge must raise Tango's attack cadence by exactly 50%."
	)
	_expect(
		player.resolve_attack_damage_against_enemy(100, unattached_enemy) == 100
		and player.resolve_attack_damage_against_enemy(100, attached_enemy) == 120,
		"Electric Surge must add 20% attack damage only against electric-attached enemies."
	)

	_expect(
		player.try_authoritative_tango_charge_started(Vector2.UP),
		"Electric Surge must accept an attack immediately without entering charge."
	)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.CONVERGING
		and is_equal_approx(player.get_tango_release_ratio(), 1.0)
		and is_equal_approx(player.get_tango_barrage_duration(), 5.0)
		and player.get_tango_barrage_damage() == 15,
		"Electric Surge attacks must start as authoritative full-charge barrages."
	)
	player.call("_reset_tango_combat_state", true)
	player.set("_latest_remote_action_sequence", 0)
	player.set("_latest_remote_action_phase", 0)
	player.play_remote_tango_charge_started(Vector2.LEFT, 1)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.CONVERGING
		and is_equal_approx(player.get_tango_release_ratio(), 1.0),
		"A remote Electric Surge attack must predict the same full-charge barrage."
	)
	player.reconcile_predicted_tango_charge_started(Vector2.DOWN, 2)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.CHARGING
		and bool(player.get("_local_charge_input_active"))
		and Vector2(player.get("_charge_direction")) == Vector2.DOWN
		and is_zero_approx(player.get_tango_barrage_duration())
		and int(player.get("_latest_remote_action_sequence")) == 2
		and int(player.get("_latest_remote_action_phase")) == 1,
		(
			"A Host ordinary-charge confirmation at the eight-second boundary must "
			+ "fully replace the client's instant full-charge barrage prediction."
		)
	)
	player.call("_update_character_resources", 0.3)
	var confirmed_charge_elapsed := float(player.get("_charge_elapsed"))
	player.reconcile_predicted_tango_charge_started(Vector2.LEFT, 3)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.CHARGING
		and is_equal_approx(
			float(player.get("_charge_elapsed")),
			confirmed_charge_elapsed
		)
		and Vector2(player.get("_charge_direction")) == Vector2.DOWN
		and int(player.get("_latest_remote_action_sequence")) == 3,
		"Confirming an existing ordinary charge must not restart or redirect it."
	)
	player.call("_reset_tango_combat_state", true)
	player.set("_latest_remote_action_sequence", 0)
	player.set("_latest_remote_action_phase", 0)

	player.call("_on_electric_surge_duration_timer_timeout")
	_expect(
		not player.is_electric_surge_active()
		and is_equal_approx(
			float(player.call("_get_effective_fire_interval")),
			base_interval
		)
		and player.resolve_attack_damage_against_enemy(100, attached_enemy) == 100,
		"Electric Surge expiry must remove both its fire-rate and marked-target bonuses."
	)
	for child in test_root.get_children():
		if child is TangoElectricSurgeField:
			child.free()

	player.play_remote_electric_surge_started(42, Vector2(8, 12), 3.0)
	_expect(
		player.is_electric_surge_active()
		and player.get_electric_surge_activation_id() == 42
		and player.get_electric_surge_remaining_seconds() <= 3.0,
		"A joining replica must restore Electric Surge from its remaining duration."
	)
	var recovered_visual_found := false
	for child in test_root.get_children():
		if (
			child is TangoElectricSurgeField
			and child.global_position == Vector2(8, 12)
		):
			recovered_visual_found = true
			break
	_expect(
		recovered_visual_found,
		"A joining replica must rebuild the visual-only field at its fixed origin."
	)
	player.cancel_remote_electric_surge(41)
	_expect(
		player.is_electric_surge_active(),
		"A stale remote cancellation must not end the current Electric Surge."
	)
	player.cancel_remote_electric_surge(42)
	_expect(
		not player.is_electric_surge_active(),
		"The matching remote cancellation must clear Electric Surge immediately."
	)
	player.play_remote_electric_surge_started(43, Vector2.ZERO, 3.0)
	player.set_controls_locked(true)
	_expect(
		not player.is_electric_surge_active(),
		"Locking Tango's controls must clear the active Electric Surge buff."
	)
	player.set_controls_locked(false)
	for child in test_root.get_children():
		if child is TangoElectricSurgeField:
			child.free()
	unattached_enemy.free()
	attached_enemy.free()


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
		_expect(
			is_equal_approx(unit.sprite_frames.get_animation_speed(&"orbit"), 5.0),
			"The idle casting-unit flash must run at the slower 5 FPS cadence."
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
	_expect(
		player.get_node_or_null("BeamArea") == null,
		"The deprecated continuous BeamArea/Line2D attack must be absent."
	)
	var fire_positions := player.call(
		"_get_unit_fire_positions",
		Vector2.RIGHT
	) as Array[Vector2]
	_expect(
		fire_positions == [Vector2(19, 0), Vector2(17, 5), Vector2(18, -5)],
		"Three units must form a parallel lane with deliberate forward staggering."
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
		and is_zero_approx(player.get_tango_barrage_duration()),
		"Releasing at 0.19 seconds must cancel without starting a barrage."
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
		and is_equal_approx(player.get_tango_release_charge_seconds(), 0.2)
		and is_equal_approx(player.get_tango_barrage_duration(), 2.0)
		and player.get_tango_barrage_damage() == 8,
		"Minimum legal charge must create a two-second 75% physical barrage."
	)
	player.call("_set_character_visual_offset", Vector2(30, 20))
	player.call("_update_character_combat_state", PlayerTango.UNIT_CONVERGE_DURATION)
	var first_volley := _get_live_tango_laser_bullets()
	_expect(first_volley.size() == 3, "The first firing tick must emit exactly three bullets.")
	var expected_spawn_positions := [
		Vector2(25, 0), Vector2(23, 5), Vector2(24, -5)
	]
	for bullet_index in first_volley.size():
		var bullet := first_volley[bullet_index]
		_expect(
			bullet.direction == Vector2.RIGHT
			and bullet.damage == 8
			and bullet.global_position == expected_spawn_positions[bullet_index],
			(
				"Volley bullet %d must preserve its parallel staggered muzzle contract; "
				+ "got %s, expected %s."
			)
			% [
				bullet_index,
				bullet.global_position,
				expected_spawn_positions[bullet_index],
			]
		)
		bullet.retire()
	player.call("_set_character_visual_offset", Vector2.ZERO)
	await process_frame

	player.call("_reset_tango_combat_state", true)
	player.call("_start_barrage_sequence", Vector2.RIGHT, 0.5, false)
	player.call("_update_character_combat_state", PlayerTango.UNIT_CONVERGE_DURATION)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.FIRING
		and _get_live_tango_laser_bullets().is_empty(),
		"A predicted barrage must animate locally without spawning damaging bullets."
	)
	player.reject_predicted_tango_charge()
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.ORBIT,
		"A Host rejection must unconditionally stop a predicted barrage."
	)

	player.call("_start_barrage_sequence", Vector2.RIGHT, 0.4, false)
	player.confirm_predicted_tango_charge_started(7)
	player.call("_update_character_combat_state", PlayerTango.UNIT_CONVERGE_DURATION * 0.5)
	var converge_elapsed_before := float(player.get("_unit_converge_elapsed"))
	player.reconcile_predicted_tango_barrage_started(Vector2.RIGHT, 0.8, 7)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.CONVERGING
		and is_equal_approx(
			float(player.get("_unit_converge_elapsed")),
			converge_elapsed_before
		)
		and is_equal_approx(player.get_tango_release_ratio(), 0.8)
		and player.get_tango_barrage_duration() > 4.0,
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
	player.call("_update_character_resources", 2.4)
	player.call("_handle_primary_attack_input", Vector2.ZERO)
	_expect(
		is_equal_approx(player.get_tango_release_ratio(), 1.0)
		and is_equal_approx(player.get_tango_release_charge_seconds(), 2.4)
		and is_equal_approx(player.get_tango_barrage_duration(), 5.0)
		and player.get_tango_barrage_damage() == 15,
		"A 2.4-second full charge must produce a five-second 150% barrage."
	)
	player.call("_reset_tango_combat_state", true)

	player.call(
		"_start_barrage_sequence",
		Vector2.RIGHT,
		_charge_seconds_to_release_ratio(0.5),
		false
	)
	player.call("_update_character_combat_state", PlayerTango.UNIT_CONVERGE_DURATION)
	player.set("_attack_aim_uses_mouse", true)
	Input.action_press("shoot_up")
	player.call("_update_local_barrage_aim")
	Input.action_release("shoot_up")
	_expect(
		Vector2(player.get("_barrage_direction")) == Vector2.UP
		and not player.uses_passive_tango_mouse_aim()
		and player.unit_a.position == Vector2(0, -19)
		and player.unit_b.position == Vector2(5, -17)
		and player.unit_c.position == Vector2(-5, -18),
		"The real stick-input path must take live aim and preserve the three-lane formation."
	)
	player.call("_handle_primary_attack_input", Vector2.ZERO)
	_expect(
		Vector2(player.get("_barrage_direction")) == Vector2.UP,
		"A centred stick must preserve the last valid firing direction."
	)
	var mouse_motion := InputEventMouseMotion.new()
	mouse_motion.position = Vector2(-100, 0)
	player.call("_input", mouse_motion)
	player.call("_update_local_barrage_aim")
	_expect(
		player.uses_passive_tango_mouse_aim()
		and Vector2(player.get("_barrage_direction")) == Vector2.LEFT
		and Vector2(player.call("_get_current_shoot_input")) == Vector2.LEFT,
		"Mouse motion must retake live aim after release and after a stick adjustment."
	)
	player.call("_update_character_combat_state", player.get_tango_barrage_duration())
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.RETURNING,
		"A completed barrage must enter the authored quick return state first."
	)
	player.call("_update_character_combat_state", PlayerTango.UNIT_RETURN_DURATION * 0.5)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.RETURNING,
		"The return animation must not teleport directly back to orbit."
	)
	player.call("_update_character_combat_state", PlayerTango.UNIT_RETURN_DURATION * 0.5)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.ORBIT,
		"The units must resume their 120-degree orbit after the return animation."
	)
	player.call("_handle_primary_attack_input", Vector2.RIGHT)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.ORBIT,
		"A held controller aim must not auto-start a new charge after firing."
	)
	player.call("_handle_primary_attack_input", Vector2.ZERO)
	player.call("_handle_primary_attack_input", Vector2.RIGHT)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.CHARGING,
		"Returning the controller aim to neutral must re-arm the next charge."
	)
	player.call("_reset_tango_combat_state", true)
	player.set("_latest_remote_action_sequence", 0)
	player.set("_latest_remote_action_phase", 0)
	player.apply_remote_tango_barrage_snapshot(Vector2.RIGHT, 1.0, 20, 4.0)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.FIRING
		and is_equal_approx(float(player.get("_barrage_elapsed")), 1.0)
		and player.unit_a.position == Vector2(19, 0),
		"A volley that beats the reliable release must recover the current firing visual."
	)
	player.apply_remote_tango_barrage_snapshot(Vector2.LEFT, 1.0, 19, 4.0)
	_expect(
		Vector2(player.get("_barrage_direction")) == Vector2.RIGHT,
		"A delayed volley from an older charge sequence must not turn the cannons."
	)
	player.apply_remote_tango_barrage_snapshot(Vector2.UP, 1.0, 20, 3.0)
	_expect(
		Vector2(player.get("_barrage_direction")) == Vector2.UP
		and is_equal_approx(float(player.get("_barrage_elapsed")), 2.0),
		"A newer snapshot from the same barrage must advance time and live aim."
	)
	player.apply_remote_tango_barrage_snapshot(Vector2.UP, 1.0, 20, -0.09)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.RETURNING
		and is_equal_approx(float(player.get("_unit_return_elapsed")), 0.09),
		"A slightly late final volley must reconstruct the quick return phase."
	)
	player.apply_remote_tango_barrage_snapshot(Vector2.UP, 1.0, 20, -0.2)
	_expect(
		player.get_tango_casting_state() == PlayerTango.CastingState.ORBIT,
		"A volley older than the return animation must leave the units in orbit."
	)
	player.call("_reset_tango_combat_state", true)
	player.set("_latest_remote_action_sequence", 0)
	player.set("_latest_remote_action_phase", 0)


func _test_barrage_tier_and_schedule_contract() -> void:
	var tier_cases := [
		{"seconds": 0.2, "damage": 8, "duration": 2.0},
		{"seconds": 0.499, "damage": 8, "duration": 2.0},
		{"seconds": 0.5, "damage": 10, "duration": 2.0},
		{
			"seconds": 2.399,
			"damage": 10,
			"duration": _expected_barrage_duration(2.399),
		},
		{"seconds": 2.4, "damage": 15, "duration": 5.0},
	]
	for tier_case in tier_cases:
		player.call("_reset_tango_combat_state", true)
		var charge_seconds := float(tier_case["seconds"])
		player.call(
			"_start_barrage_sequence",
			Vector2.RIGHT,
			_charge_seconds_to_release_ratio(charge_seconds),
			false
		)
		_expect(
			player.get_tango_barrage_damage() == int(tier_case["damage"])
			and is_equal_approx(
				player.get_tango_barrage_duration(),
				float(tier_case["duration"])
			),
			"Charge %.3f must resolve the expected damage tier and duration."
			% charge_seconds
		)

	var two_second_probe := _run_schedule_probe(2.0, [2.0])
	_expect(
		two_second_probe.emitted_volley_count == 5,
		"A two-second barrage must emit five three-shot volleys."
	)
	two_second_probe.free()
	var full_big_step_probe := _run_schedule_probe(5.0, [5.0])
	var small_steps: Array[float] = []
	for _step in range(60):
		small_steps.append(5.0 / 60.0)
	var full_small_step_probe := _run_schedule_probe(5.0, small_steps)
	_expect(
		full_big_step_probe.emitted_volley_count == 12
		and full_small_step_probe.emitted_volley_count == 12,
		"A five-second full charge must emit 12 volleys under both large and small steps."
	)
	full_big_step_probe.free()
	full_small_step_probe.free()
	player.call("_reset_tango_combat_state", true)


func _run_schedule_probe(duration: float, steps: Array[float]) -> TangoScheduleProbe:
	var probe := TangoScheduleProbe.new()
	probe.set("_casting_state", PlayerTango.CastingState.FIRING)
	probe.set("_barrage_duration", duration)
	probe.set("_barrage_elapsed", 0.0)
	probe.set("_barrage_next_volley_time", 0.0)
	for step in steps:
		probe.call("_update_active_barrage", step)
	return probe


func _test_laser_bullet_scene_and_damage() -> void:
	var bullet := TANGO_LASER_BULLET_SCENE.instantiate() as TangoLaserBullet
	_expect(bullet != null, "Tango's independent laser-bullet scene must instantiate.")
	if bullet == null:
		return
	var sprite := bullet.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var sweep := bullet.get_node_or_null("ShapeCast2D") as ShapeCast2D
	_expect(
		is_equal_approx(bullet.speed, 480.0)
		and is_equal_approx(bullet.max_lifetime, 0.722),
		"Tango's small laser bullet must keep its authored speed and view-bounded lifetime."
	)
	_expect(
		sprite != null
		and sprite.sprite_frames.get_frame_count(&"fly") == 4
		and sprite.material == TANGO_LASER_MATERIAL,
		"The bullet must use four ImageGen-derived frames and the shared cyan single-pass glow."
	)
	_expect(
		sweep != null and not sweep.enabled and sweep.collision_mask == 5,
		"The bullet must use only explicit ShapeCast sweeps against world and enemy layers."
	)
	_expect(
		_count_point_lights(bullet) == 0
		and bullet.find_child("ProjectileHalo", true, false) == null
		and bullet.find_child("EmissionOverlay", true, false) == null,
		"High-frequency Tango bullets must keep diffusion in one draw without per-shot lights."
	)
	if sprite != null:
		for frame_index in sprite.sprite_frames.get_frame_count(&"fly"):
			var frame_image := _extract_frame_image(
				sprite.sprite_frames.get_frame_texture(&"fly", frame_index)
			)
			var used_rect := frame_image.get_used_rect() if frame_image != null else Rect2i()
			_expect(
				frame_image != null
				and frame_image.get_size() == Vector2i(24, 8)
				and used_rect.size.x <= 20
				and used_rect.size.y <= 5,
				"Laser frame %d must remain a compact native 24x8 line projectile."
				% frame_index
			)

	var enemy := _spawn_bullet_enemy(Vector2(32, 0))
	bullet.set_physics_process(false)
	bullet.setup(Vector2.RIGHT, 8, false)
	bullet.source_type = &"tango_laser_bullet"
	bullet.setup_collectible_owner(player)
	test_root.add_child(bullet)
	await physics_frame
	bullet.call("_physics_process", 0.1)
	_expect(
		not bullet.pool_active,
		"The disabled automatic ShapeCast must still sweep and consume a high-speed bullet."
	)
	_expect(
		enemy.total_damage_taken == 8
		and enemy.last_damage_type == EnemyConfig.DamageType.PHYSICAL
		and enemy.last_source_type == &"tango_laser_bullet",
		"A swept low-charge bullet must deal one physical Tango-source 8-damage hit."
	)
	enemy.queue_free()
	await process_frame

	var blocked_enemy := _spawn_bullet_enemy(Vector2(32, 64))
	var wall := _spawn_sweep_wall(Vector2(16, 64))
	var blocked_bullet := TANGO_LASER_BULLET_SCENE.instantiate() as TangoLaserBullet
	blocked_bullet.set_physics_process(false)
	blocked_bullet.setup(Vector2.RIGHT, 15, false)
	blocked_bullet.global_position = Vector2(0, 64)
	test_root.add_child(blocked_bullet)
	await physics_frame
	blocked_bullet.call("_physics_process", 0.1)
	_expect(
		not blocked_bullet.pool_active and blocked_enemy.total_damage_taken == 0,
		"A nearer world body must consume the sweep before an enemy behind it."
	)
	blocked_enemy.queue_free()
	wall.queue_free()
	await process_frame

	var muzzle_blocked_enemy := _spawn_bullet_enemy(Vector2(32, 128))
	var muzzle_wall := _spawn_sweep_wall(Vector2(16, 128))
	var muzzle_bullet := TANGO_LASER_BULLET_SCENE.instantiate() as TangoLaserBullet
	muzzle_bullet.set_physics_process(false)
	muzzle_bullet.setup(Vector2.RIGHT, 15, false)
	test_root.add_child(muzzle_bullet)
	await physics_frame
	var clamped_spawn := muzzle_bullet.clamp_spawn_position_to_clear_path(
		Vector2(0, 128),
		Vector2(25, 128)
	)
	_expect(
		clamped_spawn.x < 20.0,
		"A real 25px Tango muzzle path must clamp before a close wall instead of spawning beyond it."
	)
	muzzle_bullet.global_position = clamped_spawn
	muzzle_bullet.call("_physics_process", 0.1)
	_expect(
		not muzzle_bullet.pool_active and muzzle_blocked_enemy.total_damage_taken == 0,
		"A muzzle-path wall must consume the bullet before the enemy behind it."
	)
	muzzle_blocked_enemy.queue_free()
	muzzle_wall.queue_free()
	await process_frame


func _spawn_bullet_enemy(spawn_position: Vector2) -> TangoBulletEnemy:
	var enemy := TangoBulletEnemy.new()
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


func _spawn_sweep_wall(spawn_position: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	var collision := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(8, 16)
	collision.shape = rectangle
	wall.add_child(collision)
	test_root.add_child(wall)
	wall.position = spawn_position
	return wall


func _charge_seconds_to_release_ratio(seconds: float) -> float:
	return clampf(
		(seconds - PlayerTango.MIN_CHARGE_DURATION)
		/ (PlayerTango.MAX_CHARGE_DURATION - PlayerTango.MIN_CHARGE_DURATION),
		0.0,
		1.0
	)


func _expected_barrage_duration(seconds: float) -> float:
	return lerpf(
		PlayerTango.MIN_BARRAGE_DURATION,
		PlayerTango.MAX_BARRAGE_DURATION,
		clampf(
			(seconds - PlayerTango.LOW_CHARGE_DAMAGE_THRESHOLD)
			/ (
				PlayerTango.MAX_CHARGE_DURATION
				- PlayerTango.LOW_CHARGE_DAMAGE_THRESHOLD
			),
			0.0,
			1.0
		)
	)


func _get_live_tango_laser_bullets() -> Array[TangoLaserBullet]:
	var bullets: Array[TangoLaserBullet] = []
	for child in test_root.get_children():
		var bullet := child as TangoLaserBullet
		if bullet != null and bullet.pool_active:
			bullets.append(bullet)
	return bullets


func _count_point_lights(node: Node) -> int:
	var count := 1 if node is PointLight2D else 0
	for child in node.get_children():
		count += _count_point_lights(child)
	return count


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

	var stable_move_animations: Array[StringName] = [
		&"normal_down", &"normal_up", &"normal_right", &"normal_left"
	]
	for animation_name in stable_move_animations:
		var canonical_image := _extract_frame_image(
			frames.get_frame_texture(animation_name, 0)
		)
		if canonical_image == null:
			continue
		for frame_index in range(1, frames.get_frame_count(animation_name)):
			var frame_image := _extract_frame_image(
				frames.get_frame_texture(animation_name, frame_index)
			)
			if frame_image == null:
				continue
			var body_x: int = (
				TANGO_DOWN_BODY_X_OFFSETS[frame_index]
				if animation_name == &"normal_down"
				else 0
			)
			_expect(
				_image_matches_rigid_body(
					canonical_image,
					frame_image,
					Vector2i(
						body_x,
						TANGO_MOVE_BOB_OFFSETS[frame_index]
					)
				),
				"Tango %s frame %d must preserve and rigidly bob its canonical body."
				% [animation_name, frame_index]
			)

	var down_images: Array[Image] = []
	for frame_index in range(frames.get_frame_count(&"normal_down")):
		down_images.append(
			_extract_frame_image(
				frames.get_frame_texture(&"normal_down", frame_index)
			)
		)
	if not down_images.has(null) and down_images.size() == 8:
		var down_alpha_changes: Array[int] = []
		for frame_index in range(8):
			down_alpha_changes.append(
				_count_alpha_changes(
					down_images[frame_index],
					down_images[(frame_index + 1) % 8],
					Rect2i(0, 24, 32, 8)
				)
			)
		_expect(
			down_alpha_changes.min() >= 5 and down_alpha_changes.max() <= 15,
			"Tango's down gait must distribute leg movement across all eight frames."
		)
		for frame_index in range(8):
			var contacts: Array[int] = []
			for x in range(32):
				if not is_zero_approx(down_images[frame_index].get_pixel(x, 27).a):
					contacts.append(x)
			_expect(
				contacts == TANGO_DOWN_EXPECTED_CONTACTS[frame_index],
				"Tango down frame %d must preserve its contact/load/roll/push footprint."
				% frame_index
			)
		_expect(
			_count_alpha_changes(
				down_images[1], down_images[2], Rect2i(9, 24, 8, 4)
			) == 5,
			"Tango's planted left leg must deform from load to roll."
		)
		_expect(
			_count_alpha_changes(
				down_images[5], down_images[6], Rect2i(16, 24, 8, 4)
			) == 6,
			"Tango's planted right leg must deform from load to roll."
		)

	var idle_texture := load(TANGO_IDLE_TEXTURE_PATH) as Texture2D
	var idle_image := idle_texture.get_image() if idle_texture != null else null
	_expect(idle_image != null, "Tango's corrected idle texture must be readable.")
	if idle_image != null:
		var active_cyan := Color8(56, 236, 243, 255)
		for y in [11, 12]:
			var eye_columns: Array[int] = []
			for x in range(idle_image.get_width()):
				if idle_image.get_pixel(x, y) == active_cyan:
					eye_columns.append(x)
			_expect(
				eye_columns == [15, 18],
				"Tango's front eyes must be two equally bright, one-pixel columns."
			)
		var down_contact := _extract_frame_image(
			frames.get_frame_texture(&"normal_down", 0)
		)
		_expect(
			down_contact != null
			and _images_match_visible_pixels(
				idle_image, down_contact, Rect2i(0, 0, 32, 32)
			),
			"Tango's down contact frame must exactly match the repaired front frame."
		)


func _images_match_visible_pixels(left: Image, right: Image, region: Rect2i) -> bool:
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var left_pixel := left.get_pixel(x, y)
			var right_pixel := right.get_pixel(x, y)
			# Godot's alpha-border import may assign RGB values to fully transparent
			# cells. Those values cannot render and are not sprite-pixel changes.
			if is_zero_approx(left_pixel.a) and is_zero_approx(right_pixel.a):
				continue
			if left_pixel != right_pixel:
				return false
	return true


func _image_matches_rigid_body(
	canonical: Image, frame: Image, body_offset: Vector2i
) -> bool:
	# First verify every visible canonical pixel at its translated location.
	for y in range(TANGO_FIXED_BODY_BOTTOM):
		for x in range(32):
			var expected_pixel := canonical.get_pixel(x, y)
			if is_zero_approx(expected_pixel.a):
				continue
			var actual_position := Vector2i(x, y) + body_offset
			if (
				actual_position.x < 0
				or actual_position.x >= frame.get_width()
				or actual_position.y < 0
				or actual_position.y >= frame.get_height()
				or expected_pixel
				!= frame.get_pixel(actual_position.x, actual_position.y)
			):
				return false

	# Above the hip seam there may be no unowned pixels or stale body remnants.
	for y in range(TANGO_FIXED_BODY_BOTTOM):
		for x in range(32):
			var source_position := Vector2i(x, y) - body_offset
			var expected_pixel := Color(0, 0, 0, 0)
			if (
				source_position.x >= 0
				and source_position.x < canonical.get_width()
				and source_position.y >= 0
				and source_position.y < TANGO_FIXED_BODY_BOTTOM
			):
				expected_pixel = canonical.get_pixel(
					source_position.x, source_position.y
				)
			var actual_pixel := frame.get_pixel(x, y)
			if is_zero_approx(expected_pixel.a):
				if not is_zero_approx(actual_pixel.a):
					return false
			elif expected_pixel != actual_pixel:
				return false
	return true


func _count_alpha_changes(left: Image, right: Image, region: Rect2i) -> int:
	var changes := 0
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var left_visible := not is_zero_approx(left.get_pixel(x, y).a)
			var right_visible := not is_zero_approx(right.get_pixel(x, y).a)
			if left_visible != right_visible:
				changes += 1
	return changes


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
		print(
			"PLAYER_TANGO_PIXEL_SMOKE_TEST_OK"
			if pixel_only
			else "PLAYER_TANGO_MECHANICS_SMOKE_TEST_OK"
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
