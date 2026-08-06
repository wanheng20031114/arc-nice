extends SceneTree

const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const TIYI_PLAYER_SCRIPT := preload("res://scene/player/tiyi/player_tiyi.gd")
const AGAVE_CONFIG := preload("res://resources/config/plant_defense/agave_cannon.tres")
const DAMAGE_NUMBER_POOL_SCRIPT := preload("res://scene/combat/feedback/damage_number_pool.gd")


class DamageNumberOwner:
	extends Node2D

	var damage_number_pool: Node = null

	func show_combat_number(
		amount: int,
		spawn_position: Vector2,
		number_kind: DamageNumberPool.CombatNumberKind,
		motion_direction: Vector2 = Vector2.ZERO,
		damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
	) -> bool:
		if damage_number_pool == null:
			return false
		return damage_number_pool.call(
			"show_combat_number",
			amount,
			spawn_position,
			number_kind,
			motion_direction,
			damage_type,
			display_priority
		) == true

	func show_damage_number(
		amount: int,
		spawn_position: Vector2,
		impact_direction: Vector2 = Vector2.ZERO,
		damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
	) -> bool:
		return show_combat_number(
			amount,
			spawn_position,
			DamageNumberPool.CombatNumberKind.DAMAGE,
			impact_direction,
			damage_type,
			display_priority
		)

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var owner := DamageNumberOwner.new()
	test_root = owner
	test_root.name = "DamageNumberSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	var damage_number_pool := DAMAGE_NUMBER_POOL_SCRIPT.new() as DamageNumberPool
	_expect(damage_number_pool != null, "DamageNumberPool should instantiate.")
	if damage_number_pool != null:
		damage_number_pool.name = "DamageNumberPool"
		test_root.add_child(damage_number_pool)
		owner.damage_number_pool = damage_number_pool
	await process_frame

	if damage_number_pool != null:
		_expect(
			int(damage_number_pool.call("get_slot_capacity"))
				== int(damage_number_pool.get("pool_size")),
			"DamageNumberPool should preallocate its configured slot capacity."
		)
		_expect(
			damage_number_pool.get_child_count() == 0,
			"DamageNumberPool must batch its visuals without per-number child nodes."
		)
		_expect(
			damage_number_pool.slot_text_lines.size() == damage_number_pool.pool_size,
			"Every fixed slot must own one persistent TextLine shaping cache."
		)
		await _test_visual_redraw_cadence()

	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "Enemy scene must instantiate.")
	test_root.add_child(enemy)
	enemy.global_position = Vector2(64.0, 64.0)
	enemy.setup(ENEMY_CONFIG, null, null)
	var enemy_hit_audio := enemy.get_node("HitAudio") as AudioStreamPlayer2D
	if enemy_hit_audio != null:
		enemy_hit_audio.stream = null

	var before_count := int(damage_number_pool.call("get_active_count"))
	var damaged := enemy.apply_damage(10, Vector2.RIGHT)
	_expect(damaged, "Enemy damage should apply.")
	_expect(enemy.last_damage_taken > 0, "Enemy must record confirmed final damage.")
	await process_frame
	var after_count := int(damage_number_pool.call("get_active_count"))
	_expect(after_count == before_count + 1, "DamageNumber should be spawned after confirmed damage.")
	var physical_snapshot: Dictionary = damage_number_pool.call(
		"get_first_active_debug_snapshot",
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(not physical_snapshot.is_empty(), "Spawned physical damage slot should be inspectable.")
	_test_damage_number_style(damage_number_pool, physical_snapshot)
	if damage_number_pool != null:
		_expect(
			damage_number_pool.call(
				"show_damage_number",
				7,
				Vector2(92.0, 64.0),
				Vector2.LEFT,
				EnemyConfig.DamageType.MAGIC
			) == true,
			"DamageNumberPool should accept a magic damage type."
		)
		var magic_snapshot: Dictionary = damage_number_pool.call(
			"get_first_active_debug_snapshot",
			EnemyConfig.DamageType.MAGIC
		)
		_expect(not magic_snapshot.is_empty(), "Magic damage slot should be inspectable.")
		_test_magic_damage_number_style(magic_snapshot)
		var tiyi := TIYI_PLAYER_SCRIPT.new() as PlayerTiyi
		_expect(tiyi != null, "Tiyi should instantiate for the shared magic-style contract.")
		if tiyi != null:
			_expect(
				tiyi._get_primary_attack_damage_type() == EnemyConfig.DamageType.MAGIC,
				"Tiyi's primary attack must keep using the shared magic damage type."
			)
			tiyi.free()
	if damage_number_pool != null:
		await process_frame
		await _test_player_and_plant_damage_numbers(owner, damage_number_pool)
		await process_frame
		await physics_frame
		_test_damage_number_pool_budget(damage_number_pool)
		await _test_damage_number_pool_second_reserve()
		await _test_combat_number_kinds_share_budget()
		await physics_frame
		await _test_offscreen_budget_priority(damage_number_pool)
		await physics_frame
		await _test_full_pool_replacement_and_lifecycle(damage_number_pool)

	_stop_audio_players(test_root)
	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame
	if failures.is_empty():
		print("DAMAGE_NUMBER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_visual_redraw_cadence() -> void:
	var cadence_pool := DAMAGE_NUMBER_POOL_SCRIPT.new() as DamageNumberPool
	_expect(cadence_pool != null, "Cadence fixture must instantiate a damage-number pool.")
	if cadence_pool == null:
		return
	cadence_pool.name = "DamageNumberCadencePool"
	test_root.add_child(cadence_pool)
	await process_frame

	for sample_index in range(30):
		# Damage and green healing feedback share the exact same smooth cadence.
		var number_kind := (
			DamageNumberPool.CombatNumberKind.HEALING
			if sample_index % 3 == 2
			else DamageNumberPool.CombatNumberKind.DAMAGE
		)
		var damage_type := (
			EnemyConfig.DamageType.MAGIC
			if sample_index % 3 == 1
			else EnemyConfig.DamageType.PHYSICAL
		)
		cadence_pool.budget_frame = -1
		_expect(
			cadence_pool.show_combat_number(
				sample_index + 1,
				Vector2(64.0, 64.0),
				number_kind,
				Vector2.ZERO,
				damage_type
			),
			"Cadence fixture must admit every in-view pressure sample."
		)
		cadence_pool._process(1.0 / 60.0)

	var redraws := cadence_pool.get_redraw_request_count()
	_expect(
		redraws >= 30 and redraws <= 31
		and cadence_pool.has_active_text("1")
		and cadence_pool.has_active_text("+30"),
		"Ordinary damage and healing feedback must rebuild smoothly at 60 Hz, got %d redraws."
		% redraws
	)
	cadence_pool.queue_free()
	await process_frame

	var pressure_pool := DAMAGE_NUMBER_POOL_SCRIPT.new() as DamageNumberPool
	pressure_pool.name = "DamageNumberPressureCadencePool"
	pressure_pool.max_numbers_per_frame = pressure_pool.pool_size
	pressure_pool.max_numbers_per_second = pressure_pool.pool_size * 2
	pressure_pool.important_frame_reserve = 0
	pressure_pool.important_per_second_reserve = 0
	test_root.add_child(pressure_pool)
	await process_frame
	var pressure_count := DamageNumberPool.SMOOTH_ACTIVE_LIMIT + 18
	for sample_index in range(pressure_count):
		var number_kind := (
			DamageNumberPool.CombatNumberKind.HEALING
			if sample_index % 3 == 2
			else DamageNumberPool.CombatNumberKind.DAMAGE
		)
		var damage_type := (
			EnemyConfig.DamageType.MAGIC
			if sample_index % 3 == 1
			else EnemyConfig.DamageType.PHYSICAL
		)
		_expect(
			pressure_pool.show_combat_number(
				sample_index + 1,
				Vector2(64.0, 64.0),
				number_kind,
				Vector2.ZERO,
				damage_type
			),
			"High-pressure cadence fixture must fill every requested shared slot."
		)
	for _frame_index in range(30):
		pressure_pool._process(1.0 / 60.0)
	var pressure_redraws := pressure_pool.get_redraw_request_count()
	var pressure_physical := pressure_pool.get_first_active_debug_snapshot(
		EnemyConfig.DamageType.PHYSICAL
	)
	var pressure_magic := pressure_pool.get_first_active_debug_snapshot(
		EnemyConfig.DamageType.MAGIC
	)
	var pressure_healing := pressure_pool.get_first_active_combat_number_debug_snapshot(
		DamageNumberPool.CombatNumberKind.HEALING
	)
	_expect(
		pressure_pool.get_active_count() == pressure_count
		and pressure_pool.has_active_text("1")
		and pressure_pool.has_active_text("+3")
		and pressure_pool.pressure_visual_cadence
		and pressure_redraws >= 15
		and pressure_redraws <= 17,
		"Large mixed combat-number bursts must retain the 30 Hz protection, got %d redraws."
		% pressure_redraws
	)
	_expect(
		not pressure_physical.is_empty()
		and not pressure_magic.is_empty()
		and not pressure_healing.is_empty()
		and is_equal_approx(
			float(pressure_physical.get("elapsed", -1.0)),
			float(pressure_magic.get("elapsed", -2.0))
		)
		and is_equal_approx(
			float(pressure_physical.get("elapsed", -1.0)),
			float(pressure_healing.get("elapsed", -3.0))
		),
		"Physical, magic and healing numbers must advance through one shared cadence."
	)
	for slot_index in range(pressure_pool.slot_active.size()):
		if pressure_pool.active_count <= DamageNumberPool.PRESSURE_EXIT_ACTIVE_LIMIT:
			break
		if pressure_pool.slot_active[slot_index] == 0:
			continue
		pressure_pool.slot_active[slot_index] = 0
		pressure_pool.slot_elapsed[slot_index] = 0.0
		pressure_pool.slot_texts[slot_index] = ""
		pressure_pool.active_count -= 1
	var exit_redraws_before := pressure_pool.get_redraw_request_count()
	for _frame_index in range(6):
		pressure_pool._process(1.0 / 60.0)
	_expect(
		not pressure_pool.pressure_visual_cadence
		and pressure_pool.get_redraw_request_count() - exit_redraws_before == 6,
		"Combat text must return to per-frame smoothing after pressure falls to the exit threshold."
	)
	pressure_pool.queue_free()
	await process_frame


func _test_damage_number_style(damage_number_pool: Node2D, snapshot: Dictionary) -> void:
	_expect(
		DamageNumberPool.DAMAGE_FONT.resource_path
			== "res://resources/font/ResourceHanRoundedCN-Medium.ttf",
		"DamageNumber should use the rounded font instead of the pixel font."
	)
	_expect(DamageNumberPool.FONT_SIZE == 9, "DamageNumber font should stay at its authored size.")
	_expect(DamageNumberPool.OUTLINE_SIZE == 2, "DamageNumber outline should stay readable.")
	_expect(DamageNumberPool.BASE_SIZE.y >= 20.0, "DamageNumber draw box must leave vertical room.")
	_expect(DamageNumberPool.BASE_SIZE.x >= 38.0, "DamageNumber draw box must leave horizontal room.")
	_expect(
		damage_number_pool.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR,
		"DamageNumber batch should use linear texture filtering."
	)
	var font_color := snapshot.get("font_color", Color.TRANSPARENT) as Color
	_expect(font_color.r > 0.9 and font_color.g < 0.25 and font_color.b < 0.2, "DamageNumber should be red.")
	var outline_color := snapshot.get("outline_color", Color.TRANSPARENT) as Color
	_expect(outline_color.r > outline_color.g and outline_color.r > outline_color.b, "DamageNumber outline should be dark red.")


func _test_magic_damage_number_style(snapshot: Dictionary) -> void:
	var font_color := snapshot.get("font_color", Color.TRANSPARENT) as Color
	_expect(
		font_color.is_equal_approx(DamageNumberPool.MAGIC_FONT_COLOR),
		"Magic DamageNumber must use the exact shared purple used by Tiyi's basic attack."
	)
	var outline_color := snapshot.get("outline_color", Color.TRANSPARENT) as Color
	_expect(
		outline_color.is_equal_approx(DamageNumberPool.MAGIC_OUTLINE_COLOR),
		"Magic DamageNumber must use the exact shared dark-purple outline."
	)


func _find_active_damage_snapshot(
	damage_number_pool: DamageNumberPool,
	expected_text: String,
	damage_type: EnemyConfig.DamageType
) -> Dictionary:
	for slot_index in range(damage_number_pool.slot_active.size()):
		if (
			damage_number_pool.slot_active[slot_index] != 0
			and damage_number_pool.slot_number_kinds[slot_index]
			== DamageNumberPool.CombatNumberKind.DAMAGE
			and damage_number_pool.slot_texts[slot_index] == expected_text
			and damage_number_pool.slot_damage_types[slot_index] == damage_type
		):
			return damage_number_pool.call("_get_slot_debug_snapshot", slot_index)
	return {}


func _test_healing_number_style(snapshot: Dictionary) -> void:
	var font_color := snapshot.get("font_color", Color.TRANSPARENT) as Color
	_expect(
		font_color.is_equal_approx(Color("#AFDD22")),
		"Healing combat numbers must use the authored #AFDD22 green."
	)
	var outline_color := snapshot.get("outline_color", Color.TRANSPARENT) as Color
	_expect(
		outline_color.g > outline_color.r
		and outline_color.g > outline_color.b
		and maxf(outline_color.r, maxf(outline_color.g, outline_color.b)) <= 0.25,
		"Healing combat numbers must use a dark green outline."
	)


func _test_player_and_plant_damage_numbers(
	owner: DamageNumberOwner,
	damage_number_pool: DamageNumberPool
) -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "Player scene must instantiate for damage-number feedback.")
	if player != null:
		owner.add_child(player)
		player.global_position = Vector2(112.0, 72.0)
		player.set_physics_process(false)
		await process_frame
		player.peer_id = 0
		player.current_health = player.max_health
		player.physical_defense = 0
		player.magic_defense = 50
		player.dodge_chance = 0.0
		player.collectible_ranged_dodge_chance = 0.0
		player.collectible_ranged_front_damage_multiplier = 1.0
		player.collectible_ranged_back_damage_multiplier = 1.0
		player.invincibility_time_left = 0.0
		player.damage_reduction_modifiers.clear()
		var player_count_before := damage_number_pool.get_active_count()
		_expect(
			player.apply_damage(
				26,
				EnemyConfig.DamageType.MAGIC,
				{"is_ranged": true, "source_direction": Vector2.RIGHT}
			),
			"A confirmed single-player hit must damage the player."
		)
		_expect(
			player.last_damage_taken == 13
			and damage_number_pool.get_active_count() == player_count_before + 1
			and damage_number_pool.has_active_text("13"),
			"Player feedback must display the actual post-defense health loss."
		)
		var player_magic_snapshot := _find_active_damage_snapshot(
			damage_number_pool,
			"13",
			EnemyConfig.DamageType.MAGIC
		)
		_expect(
			not player_magic_snapshot.is_empty(),
			"Enemy magic damage to a player must retain its magic type in the shared pool."
		)
		if not player_magic_snapshot.is_empty():
			_test_magic_damage_number_style(player_magic_snapshot)
		var player_count_before_overheal := damage_number_pool.get_active_count()
		_expect(
			player._try_heal(999)
			and player.last_healing_received == 13
			and damage_number_pool.get_active_count() == player_count_before_overheal,
			"Player overhealing must queue only the actual missing-health amount."
		)
		await process_frame
		_expect(
			damage_number_pool.get_active_count() == player_count_before_overheal + 1
			and damage_number_pool.has_active_text("+13"),
			"Player overhealing must display the clamped actual value with a plus sign."
		)
		var healing_snapshot := damage_number_pool.get_first_active_combat_number_debug_snapshot(
			DamageNumberPool.CombatNumberKind.HEALING
		)
		_expect(
			not healing_snapshot.is_empty()
			and healing_snapshot.get("text", "") == "+13",
			"A healing slot must expose its kind and signed text through the shared debug API."
		)
		if not healing_snapshot.is_empty():
			_test_healing_number_style(healing_snapshot)
		var player_count_at_full_health := damage_number_pool.get_active_count()
		_expect(
			not player._try_heal(1)
			and player.last_healing_received == 0,
			"A full-health player must reject healing without reporting a value."
		)
		await process_frame
		_expect(
			damage_number_pool.get_active_count() == player_count_at_full_health,
			"Rejected full-health healing must not allocate a combat-number slot."
		)
		var count_during_invincibility := damage_number_pool.get_active_count()
		_expect(
			not player.apply_damage(99)
			and player.last_damage_taken == 0
			and damage_number_pool.get_active_count() == count_during_invincibility,
			"Invincible player hits must not create damage numbers."
		)
		player.invincibility_time_left = 0.0
		player.current_health = 3
		var count_before_lethal_hit := damage_number_pool.get_active_count()
		_expect(
			player.apply_damage(999)
			and player.last_damage_taken == 3
			and damage_number_pool.get_active_count() == count_before_lethal_hit + 1
			and damage_number_pool.has_active_text("3"),
			"A lethal player hit must display only the actual remaining health loss."
		)
		var player_count_while_dead := damage_number_pool.get_active_count()
		_expect(
			not player._try_heal(50)
			and player.last_healing_received == 0,
			"A dead player must reject ordinary healing."
		)
		await process_frame
		_expect(
			damage_number_pool.get_active_count() == player_count_while_dead,
			"Rejected dead-player healing must not allocate a combat-number slot."
		)
		player.queue_free()
		await process_frame

	var plant := PlantDefense.new()
	owner.add_child(plant)
	plant.global_position = Vector2(132.0, 88.0)
	plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	plant.physical_defense = 3
	plant.magic_defense = 50
	var plant_count_before := damage_number_pool.get_active_count()
	_expect(
		plant.receive_damage(
			10,
			null,
			Vector2.LEFT,
			EnemyConfig.DamageType.PHYSICAL
		)
		and plant.receive_damage(
			10,
			null,
			Vector2.RIGHT,
			EnemyConfig.DamageType.MAGIC
		),
		"Authoritative plants must accept both physical and magic test hits."
	)
	_expect(
		damage_number_pool.get_active_count() == plant_count_before,
		"Multiple same-turn plant hits must wait for one deferred aggregate."
	)
	await process_frame
	var aggregate_uses_dominant_type := false
	for slot_index in range(damage_number_pool.slot_active.size()):
		if (
			damage_number_pool.slot_active[slot_index] != 0
			and damage_number_pool.slot_texts[slot_index] == "12"
			and damage_number_pool.slot_damage_types[slot_index]
			== EnemyConfig.DamageType.PHYSICAL
		):
			aggregate_uses_dominant_type = true
			break
	_expect(
		damage_number_pool.get_active_count() == plant_count_before + 1
		and aggregate_uses_dominant_type,
		"Same-turn mixed plant hits must create one sum colored by the dominant type."
	)
	var plant_magic_count_before := damage_number_pool.get_active_count()
	_expect(
		plant.receive_damage(
			10,
			null,
			Vector2.RIGHT,
			EnemyConfig.DamageType.MAGIC
		),
		"An authoritative plant must accept a standalone enemy magic hit."
	)
	await process_frame
	var plant_magic_snapshot := _find_active_damage_snapshot(
		damage_number_pool,
		"5",
		EnemyConfig.DamageType.MAGIC
	)
	_expect(
		damage_number_pool.get_active_count() == plant_magic_count_before + 1
		and not plant_magic_snapshot.is_empty(),
		"Enemy magic damage to a building must retain its magic type in the shared pool."
	)
	if not plant_magic_snapshot.is_empty():
		_test_magic_damage_number_style(plant_magic_snapshot)
	var count_before_mixed_feedback := damage_number_pool.get_active_count()
	var child_count_before_mixed_feedback := damage_number_pool.get_child_count()
	_expect(
		plant.receive_damage(
			5,
			null,
			Vector2.LEFT,
			EnemyConfig.DamageType.PHYSICAL
		)
		and plant.receive_healing(3)
		and plant.receive_healing(4),
		"A plant must accept same-turn damage and multiple healing events."
	)
	_expect(
		damage_number_pool.get_active_count() == count_before_mixed_feedback,
		"Same-turn plant damage and healing must share one deferred flush."
	)
	await process_frame
	var found_mixed_damage := false
	var found_aggregated_healing := false
	for slot_index in range(damage_number_pool.slot_active.size()):
		if damage_number_pool.slot_active[slot_index] == 0:
			continue
		if (
			damage_number_pool.slot_number_kinds[slot_index]
			== DamageNumberPool.CombatNumberKind.DAMAGE
			and damage_number_pool.slot_texts[slot_index] == "2"
		):
			found_mixed_damage = true
		elif (
			damage_number_pool.slot_number_kinds[slot_index]
			== DamageNumberPool.CombatNumberKind.HEALING
			and damage_number_pool.slot_texts[slot_index] == "+7"
		):
			found_aggregated_healing = true
	_expect(
		damage_number_pool.get_active_count() == count_before_mixed_feedback + 2
		and found_mixed_damage
		and found_aggregated_healing
		and damage_number_pool.get_child_count() == child_count_before_mixed_feedback,
		"Plant damage and aggregated +healing must create two fixed-pool slots without child nodes."
	)
	plant.current_health = 4
	_expect(
		plant.receive_unmitigated_damage(50),
		"Unmitigated plant decay must use the shared feedback path."
	)
	await process_frame
	_expect(
		damage_number_pool.has_active_text("4"),
		"A lethal plant hit must display only the actual remaining health loss."
	)

	var proxy_plant := PlantDefense.new()
	owner.add_child(proxy_plant)
	proxy_plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO], true, 100, 1, 100)
	var proxy_count_before := damage_number_pool.get_active_count()
	_expect(
		not proxy_plant.receive_damage(10)
		and damage_number_pool.get_active_count() == proxy_count_before,
		"Client proxy plants must not predict or duplicate authoritative feedback."
	)
	proxy_plant.begin_removal(PlantDefense.RemovalMode.SILENT)

	var pressure_plant := PlantDefense.new()
	owner.add_child(pressure_plant)
	pressure_plant.global_position = Vector2(148.0, 88.0)
	pressure_plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	pressure_plant.max_health = 2000
	pressure_plant.current_health = 2000
	pressure_plant.physical_defense = 0
	var pressure_count_before := damage_number_pool.get_active_count()
	var pressure_child_count := damage_number_pool.get_child_count()
	for _hit_index in range(1000):
		pressure_plant.receive_damage(1)
	await process_frame
	_expect(
		damage_number_pool.get_active_count() == pressure_count_before + 1
		and damage_number_pool.has_active_text("1000")
		and damage_number_pool.get_child_count() == pressure_child_count,
		"One thousand same-turn plant hits must collapse to one fixed-pool text request."
	)
	var pressure_healing_count_before := damage_number_pool.get_active_count()
	for _heal_index in range(1000):
		pressure_plant.receive_healing(1)
	await process_frame
	_expect(
		damage_number_pool.get_active_count() == pressure_healing_count_before + 1
		and damage_number_pool.has_active_text("+1000")
		and damage_number_pool.get_child_count() == pressure_child_count,
		"One thousand same-turn plant heals must collapse to one shared fixed-pool text request."
	)
	pressure_plant.begin_removal(PlantDefense.RemovalMode.SILENT)


func _test_damage_number_pool_budget(damage_number_pool: DamageNumberPool) -> void:
	var child_count_before := damage_number_pool.get_child_count()
	var max_per_frame := int(damage_number_pool.get("max_numbers_per_frame"))
	var important_reserve := mini(
		int(damage_number_pool.get("important_frame_reserve")),
		max_per_frame
	)
	var normal_limit := max_per_frame - important_reserve
	var normal_shown_count := 0
	for index in range(max_per_frame + 1):
		if damage_number_pool.call(
			"show_damage_number",
			1 + index,
			Vector2(80.0 + float(index), 80.0),
			Vector2.RIGHT
		) == true:
			normal_shown_count += 1
	_expect(
		normal_shown_count == normal_limit,
		"Normal damage numbers must leave the authored important-feedback reserve."
	)
	var important_shown_count := 0
	for index in range(important_reserve + 1):
		if damage_number_pool.show_damage_number(
			100 + index,
			Vector2(96.0 + float(index), 80.0),
			Vector2.LEFT,
			EnemyConfig.DamageType.PHYSICAL,
			DamageNumberPool.DisplayPriority.IMPORTANT
		):
			important_shown_count += 1
	_expect(
		important_shown_count == important_reserve,
		"Important feedback must fill only its reserved share of the unchanged frame cap."
	)
	_expect(damage_number_pool.get_child_count() == child_count_before, "DamageNumberPool should reuse fixed data slots.")


func _test_damage_number_pool_second_reserve() -> void:
	var reserve_pool := DAMAGE_NUMBER_POOL_SCRIPT.new() as DamageNumberPool
	reserve_pool.pool_size = 8
	reserve_pool.max_numbers_per_frame = 8
	reserve_pool.max_numbers_per_second = 5
	reserve_pool.important_frame_reserve = 0
	reserve_pool.important_per_second_reserve = 2
	test_root.add_child(reserve_pool)
	await process_frame
	var normal_shown := 0
	for index in range(4):
		if reserve_pool.show_damage_number(
			10 + index,
			Vector2(64.0 + float(index), 64.0)
		):
			normal_shown += 1
	var important_shown := 0
	for index in range(3):
		if reserve_pool.show_damage_number(
			20 + index,
			Vector2(72.0 + float(index), 64.0),
			Vector2.ZERO,
			EnemyConfig.DamageType.PHYSICAL,
			DamageNumberPool.DisplayPriority.IMPORTANT
		):
			important_shown += 1
	_expect(
		normal_shown == 3
		and important_shown == 2
		and reserve_pool.shown_this_second == 5
		and reserve_pool.normal_shown_this_second == 3,
		"Per-second priority reserve must preserve two important slots without raising the cap."
	)
	reserve_pool.queue_free()
	await process_frame


func _test_combat_number_kinds_share_budget() -> void:
	var shared_pool := DAMAGE_NUMBER_POOL_SCRIPT.new() as DamageNumberPool
	shared_pool.pool_size = 4
	shared_pool.max_numbers_per_frame = 2
	shared_pool.max_numbers_per_second = 2
	shared_pool.important_frame_reserve = 0
	shared_pool.important_per_second_reserve = 0
	test_root.add_child(shared_pool)
	await process_frame
	_expect(
		shared_pool.show_combat_number(
			8,
			Vector2(64.0, 64.0),
			DamageNumberPool.CombatNumberKind.DAMAGE
		)
		and shared_pool.show_combat_number(
			6,
			Vector2(72.0, 64.0),
			DamageNumberPool.CombatNumberKind.HEALING
		)
		and not shared_pool.show_combat_number(
			4,
			Vector2(80.0, 64.0),
			DamageNumberPool.CombatNumberKind.DAMAGE
		),
		"Damage and healing must consume the same unchanged render-frame and second budgets."
	)
	_expect(
		shared_pool.get_active_count() == 2
		and shared_pool.shown_this_frame == 2
		and shared_pool.shown_this_second == 2
		and shared_pool.has_active_text("8")
		and shared_pool.has_active_text("+6")
		and shared_pool.get_child_count() == 0,
		"Both combat-number kinds must remain in one allocation-free fixed pool."
	)
	shared_pool.queue_free()
	await process_frame


func _test_offscreen_budget_priority(damage_number_pool: DamageNumberPool) -> void:
	var camera := Camera2D.new()
	camera.enabled = true
	test_root.add_child(camera)
	camera.global_position = Vector2(64.0, 64.0)
	await process_frame

	damage_number_pool.set("max_numbers_per_frame", 2)
	damage_number_pool.set("important_frame_reserve", 0)
	damage_number_pool.set("important_per_second_reserve", 0)
	damage_number_pool.set("budget_frame", Engine.get_process_frames())
	damage_number_pool.set("shown_this_frame", 0)
	damage_number_pool.set("normal_shown_this_frame", 0)
	damage_number_pool.set("budget_second_started_msec", Time.get_ticks_msec())
	damage_number_pool.set("shown_this_second", 0)
	damage_number_pool.set("normal_shown_this_second", 0)
	var skipped_before := int(damage_number_pool.get("offscreen_requests_skipped"))
	_expect(
		not bool(damage_number_pool.call(
			"show_damage_number",
			99,
			Vector2(100000.0, 100000.0),
			Vector2.RIGHT
		)),
		"A far-offscreen damage number must be skipped."
	)
	_expect(
		int(damage_number_pool.get("offscreen_requests_skipped")) == skipped_before + 1,
		"Offscreen damage-number skips must be observable for performance audits."
	)
	_expect(
		bool(damage_number_pool.call(
			"show_damage_number",
			1,
			Vector2(64.0, 64.0),
			Vector2.RIGHT
		))
		and bool(damage_number_pool.call(
			"show_damage_number",
			2,
			Vector2(72.0, 64.0),
			Vector2.RIGHT
		)),
		"Offscreen requests must not consume either visible slot in the frame budget."
	)
	_expect(
		not bool(damage_number_pool.call(
			"show_damage_number",
			3,
			Vector2(80.0, 64.0),
			Vector2.RIGHT
		)),
		"Visible requests must still obey the configured per-frame ceiling."
	)
	camera.queue_free()


func _test_full_pool_replacement_and_lifecycle(
	damage_number_pool: DamageNumberPool
) -> void:
	# Expiring a full production batch in one update must clear every slot and
	# disable the only remaining process callback.
	damage_number_pool._process(DamageNumberPool.LIFETIME)
	_expect(
		damage_number_pool.get_active_count() == 0,
		"All damage-number slots must expire after the authored lifetime."
	)
	_expect(
		not damage_number_pool.is_processing(),
		"The shared batch process must stop once its final slot expires."
	)

	var replacement_pool := DAMAGE_NUMBER_POOL_SCRIPT.new() as DamageNumberPool
	replacement_pool.pool_size = 2
	replacement_pool.max_numbers_per_frame = 3
	replacement_pool.max_numbers_per_second = 3
	replacement_pool.important_frame_reserve = 0
	replacement_pool.important_per_second_reserve = 0
	test_root.add_child(replacement_pool)
	await process_frame
	_expect(replacement_pool.show_damage_number(1, Vector2(64.0, 64.0)), "Slot 1 must activate.")
	_expect(replacement_pool.show_damage_number(2, Vector2(64.0, 64.0)), "Slot 2 must activate.")
	replacement_pool.slot_elapsed[0] = 0.1
	replacement_pool.slot_elapsed[1] = 0.2
	_expect(
		replacement_pool.show_damage_number(3, Vector2(64.0, 64.0)),
		"A full pool must recycle its oldest visual slot."
	)
	_expect(
		replacement_pool.get_active_count() == 2
		and replacement_pool.has_active_text("1")
		and replacement_pool.has_active_text("3")
		and not replacement_pool.has_active_text("2"),
		"Oldest-slot replacement must keep capacity and active_count stable."
	)
	for text_line in replacement_pool.slot_text_lines:
		_expect(
			text_line != null and text_line.get_size().x > 0.0,
			"Every active replacement slot must retain shaped TextLine data."
		)
	replacement_pool.queue_free()


func _stop_audio_players(node: Node) -> void:
	if node == null:
		return
	if node is AudioStreamPlayer:
		var audio_player := node as AudioStreamPlayer
		audio_player.stop()
		audio_player.stream = null
	elif node is AudioStreamPlayer2D:
		var audio_player_2d := node as AudioStreamPlayer2D
		audio_player_2d.stop()
		audio_player_2d.stream = null
	elif node is AudioStreamPlayer3D:
		var audio_player_3d := node as AudioStreamPlayer3D
		audio_player_3d.stop()
		audio_player_3d.stream = null
	for child in node.get_children():
		_stop_audio_players(child)
