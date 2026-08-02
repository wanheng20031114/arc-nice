extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const COLLECTIBLE_ARROW_PROJECTILE_SCRIPT := preload("res://scene/collectible_arrow_projectile.gd")
const LINGLAN_SKILL2_ROCKET_SCRIPT := preload("res://scene/boss/linglan/linglan_skill2_sakura_rocket.gd")
const REQUIRED_NEW_COLLECTIBLE_EFFECT_IDS := [
	&"banana",
	&"orange",
	&"blood_trident",
	&"flame_trident",
	&"pure_charge_crystal",
	&"roller_skates",
	&"power_wheel",
	&"capacity_spring",
	&"dual_row_feeder",
	&"dual_ammo_chamber",
	&"triple_ammo_chamber",
	&"gun_oil",
	&"quick_load_belt",
	&"auto_loader",
	&"high_speed_loader",
	&"simple_magazine",
	&"extended_magazine",
	&"drum_magazine",
]

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CollectibleRuntimeAuditSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_frost_sources_stack_and_expire_independently()
	await _test_frost_expiry_outlives_source_player()
	await _test_frost_expiry_tolerates_removed_enemy()
	await _test_status_expiry_precedes_same_frame_tick_damage()
	await _test_same_effect_neutral_overwrite_removes_modifiers()
	await _test_every_collectible_runtime_effect()

	test_root.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("COLLECTIBLE_RUNTIME_AUDIT_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_every_collectible_runtime_effect() -> void:
	var pool := LuoxiMerchant.get_collectible_pool()
	_expect(pool.size() == 123, "Runtime audit must load 123 effect-bearing collectibles from the standard pool.")
	var seen_paths: Dictionary = {}
	var seen_effect_ids: Dictionary = {}
	for item_variant in pool:
		var item := item_variant as PickupConfig
		_expect(item != null, "Collectible pool entry must be a PickupConfig.")
		if item == null:
			continue
		_expect(not seen_paths.has(item.resource_path), "%s must not appear twice in Luoxi pool." % item.resource_path)
		seen_paths[item.resource_path] = true
		seen_effect_ids[StringName(item.collectible_effect_id)] = true
		await _audit_single_collectible(item)
	for effect_id in REQUIRED_NEW_COLLECTIBLE_EFFECT_IDS:
		_expect(
			seen_effect_ids.has(effect_id),
			"Runtime audit must include the new %s collectible." % effect_id
		)


func _test_frost_sources_stack_and_expire_independently() -> void:
	Player.set_collectible_slow_batch_expiry_enabled(true)
	Player.set_collectible_slow_expiry_metrics_enabled(true)
	Enemy.set_slow_only_status_process_optimization_enabled(true)
	var player := _spawn_player()
	var enemy := _spawn_enemy(Vector2(20.0, 0.0), player)
	var second_enemy := _spawn_enemy(Vector2(28.0, 0.0), player)
	await process_frame
	enemy.current_health = 500
	second_enemy.current_health = 500

	# These two applications happen consecutively in the same frame. The former
	# millisecond-derived IDs collided here and let the first timer erase both.
	player.call("_apply_collectible_area_frost", Vector2.ZERO, 48.0, 1, 0.8, 0.05)
	player.call("_apply_collectible_area_frost", Vector2.ZERO, 48.0, 1, 0.5, 0.18)
	_expect(
		enemy.move_speed_modifiers.size() == 2,
		"Same-frame frost applications must receive distinct temporary source IDs."
	)
	_expect(
		second_enemy.move_speed_modifiers.size() == 2,
		"Every enemy in consecutive frost batches must retain both unique sources."
	)
	_expect(
		not enemy.is_processing() and not second_enemy.is_processing(),
		"Enemies with only static slow overlays must not run a render-frame status callback."
	)
	var scheduled_metrics := Player.get_collectible_slow_expiry_metrics()
	_expect(
		int(scheduled_metrics.get("target_registrations", -1)) == 4
		and int(scheduled_metrics.get("timer_count", -1)) == 2
		and int(scheduled_metrics.get("batch_timer_count", -1)) == 2
		and int(scheduled_metrics.get("legacy_timer_count", -1)) == 0,
		"Two two-target frost casts must schedule two batch timers instead of four per-target timers: %s."
		% [scheduled_metrics]
	)
	var combined_multiplier := 1.0
	for source_id in enemy.move_speed_modifiers:
		_expect(int(source_id) < 0, "Transient frost source IDs must stay outside the positive persistent-effect namespace.")
		combined_multiplier *= float(enemy.move_speed_modifiers[source_id])
	_expect(
		is_equal_approx(combined_multiplier, 0.4),
		"Concurrent frost sources must multiply their movement-speed modifiers."
	)

	await create_timer(0.09).timeout
	# Budgeted expiry is enqueued by a SceneTreeTimer after node processing. Two
	# process-frame signals allow the shared scheduler to run once and then make
	# that result observable to this coroutine.
	await process_frame
	await process_frame
	_expect(
		enemy.move_speed_modifiers.size() == 1,
		"The earlier frost timer must remove only its own source."
	)
	_expect(
		second_enemy.move_speed_modifiers.size() == 1,
		"The earlier batch must remove its source from every still-valid target."
	)
	if enemy.move_speed_modifiers.size() == 1:
		_expect(
			is_equal_approx(float(enemy.move_speed_modifiers.values()[0]), 0.5),
			"The later frost source must remain active after the earlier source expires."
		)

	await create_timer(0.14).timeout
	await process_frame
	await process_frame
	_expect(
		enemy.move_speed_modifiers.is_empty() and second_enemy.move_speed_modifiers.is_empty(),
		"Each frost source must expire independently at the end of its own duration."
	)
	var expired_metrics := Player.get_collectible_slow_expiry_metrics()
	_expect(
		int(expired_metrics.get("expiry_callback_count", -1)) == 2
		and int(expired_metrics.get("removed_modifier_count", -1)) == 4,
		"Each frost batch must use one callback while removing all four target/source pairs: %s."
		% [expired_metrics]
	)
	Player.set_collectible_slow_expiry_metrics_enabled(false)
	_cleanup_test_children()
	await process_frame


func _test_frost_expiry_outlives_source_player() -> void:
	for batched_expiry_enabled in [false, true]:
		Player.set_collectible_slow_batch_expiry_enabled(batched_expiry_enabled)
		var player := _spawn_player()
		var enemy := _spawn_enemy(Vector2(20.0, 0.0), player)
		await process_frame
		enemy.current_health = 500
		player.call(
			"_apply_collectible_area_frost",
			Vector2.ZERO,
			48.0,
			1,
			0.5,
			0.05
		)
		_expect(
			enemy.move_speed_modifiers.size() == 1,
			"Frost must be active before its source player leaves the scene."
		)
		player.queue_free()
		await process_frame
		await create_timer(0.09).timeout
		await process_frame
		await process_frame
		_expect(
			enemy.move_speed_modifiers.is_empty(),
			(
				"Frost expiry must not depend on the source Player lifetime "
				+ "(batched=%s)."
			)
			% [str(batched_expiry_enabled)]
		)
		enemy.queue_free()
		await process_frame
	Player.set_collectible_slow_batch_expiry_enabled(true)
	_cleanup_test_children()
	await process_frame


func _test_frost_expiry_tolerates_removed_enemy() -> void:
	Player.set_collectible_slow_batch_expiry_enabled(true)
	var player := _spawn_player()
	var enemy := _spawn_enemy(Vector2(20.0, 0.0), player)
	await process_frame
	enemy.current_health = 500
	player.call(
		"_apply_collectible_area_frost",
		Vector2.ZERO,
		48.0,
		1,
		0.5,
		0.05
	)
	_expect(
		enemy.move_speed_modifiers.size() == 1,
		"Frost must register its expiry before the target enemy is removed."
	)
	enemy.queue_free()
	await process_frame
	await create_timer(0.09).timeout
	await process_frame
	await process_frame
	_expect(
		int(root.get_node("StatusEffectExpiryScheduler").call("get_pending_job_count")) == 0,
		"A freed enemy WeakRef must not strand its shared expiry job."
	)
	player.queue_free()
	await process_frame


func _test_status_expiry_precedes_same_frame_tick_damage() -> void:
	var player := _spawn_player()
	var enemy := _spawn_enemy(Vector2(20.0, 0.0), player)
	await process_frame
	enemy.set_process(false)
	enemy.current_health = 100
	enemy.add_physical_defense_modifier(990100, 5)
	enemy.apply_collectible_status(
		&"mark",
		990101,
		0.1,
		0,
		0.5,
		EnemyConfig.DamageType.MAGIC,
		1.0,
		0,
		2.0
	)
	enemy.apply_collectible_status(
		&"crack",
		990102,
		0.1,
		0,
		0.5,
		EnemyConfig.DamageType.MAGIC,
		1.0,
		-4
	)
	enemy.apply_collectible_status(
		&"bleed",
		990103,
		1.0,
		10,
		0.1,
		EnemyConfig.DamageType.PHYSICAL
	)
	root.get_node("EnemyCollectibleStatusScheduler").call("advance_for_test", 0.1)
	_expect(
		enemy.current_health == 95,
		"An expiring mark and armor break must be removed before same-frame physical DoT; expected 5 damage."
	)
	_expect(
		not enemy.collectible_status_effects.has("990101:mark")
		and not enemy.collectible_status_effects.has("990102:crack")
		and enemy.collectible_status_effects.has("990103:bleed"),
		"Expired modifier statuses must be removed while the surviving DoT remains active."
	)
	_expect(
		enemy.get_effective_physical_defense() == 5
		and is_equal_approx(enemy.get_damage_taken_multiplier(), 1.0),
		"Same-frame expiry must restore defense and damage multiplier before resolving DoT."
	)
	_cleanup_test_children()
	await process_frame


func _test_same_effect_neutral_overwrite_removes_modifiers() -> void:
	var player := _spawn_player()
	var enemy := _spawn_enemy(Vector2(20.0, 0.0), player)
	await process_frame
	enemy.set_process(false)
	const BASELINE_DEFENSE_SOURCE_ID := 991000
	const STATUS_SOURCE_ID := 991001
	enemy.add_physical_defense_modifier(BASELINE_DEFENSE_SOURCE_ID, 5)
	enemy.apply_collectible_status(
		&"overwrite_probe",
		STATUS_SOURCE_ID,
		1.0,
		0,
		0.5,
		EnemyConfig.DamageType.MAGIC,
		0.5,
		-3,
		1.75
	)
	_expect(
		is_equal_approx(enemy.get_effective_move_speed_multiplier(), 0.5)
		and enemy.get_effective_physical_defense() == 2
		and is_equal_approx(enemy.get_damage_taken_multiplier(), 1.75),
		"The initial collectible status must install all three non-neutral modifiers."
	)

	enemy.apply_collectible_status(
		&"overwrite_probe",
		STATUS_SOURCE_ID,
		1.0,
		0,
		0.5,
		EnemyConfig.DamageType.MAGIC,
		1.0,
		0,
		1.0
	)
	_expect(
		enemy.move_speed_modifiers.is_empty()
		and enemy.physical_defense_modifiers.size() == 1
		and enemy.physical_defense_modifiers.has(BASELINE_DEFENSE_SOURCE_ID)
		and enemy.damage_taken_multiplier_modifiers.is_empty(),
		"Replacing the same effect with neutral values must revoke every modifier owned by the previous record."
	)
	_expect(
		is_equal_approx(enemy.get_effective_move_speed_multiplier(), 1.0)
		and enemy.get_effective_physical_defense() == 5
		and is_equal_approx(enemy.get_damage_taken_multiplier(), 1.0),
		"Neutral overwrite must immediately restore movement, defense, and incoming-damage baselines."
	)

	root.get_node("EnemyCollectibleStatusScheduler").call("advance_for_test", 1.01)
	_expect(
		enemy.collectible_status_effects.is_empty()
		and enemy.move_speed_modifiers.is_empty()
		and enemy.physical_defense_modifiers.size() == 1
		and enemy.damage_taken_multiplier_modifiers.is_empty(),
		"The neutral replacement must expire without resurrecting or stranding its prior modifiers."
	)
	_cleanup_test_children()
	await process_frame


func _audit_single_collectible(item: PickupConfig) -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	var player := _spawn_player()
	await process_frame
	var ammo_player := player as AmmoRangedPlayer

	var base_attack := player.attack_damage
	var base_max_health := player.max_health
	var base_move_speed := player.move_speed
	var base_physical_defense := player.physical_defense
	var base_magic_defense := player.magic_defense
	var base_attack_speed := player.get_attack_speed()
	var base_dash_distance := player.get_dash_distance()
	var base_dash_cooldown := player.get_dash_cooldown()
	var base_ammo_capacity := ammo_player.get_ammo_capacity()
	var base_reload_duration := ammo_player.get_effective_reload_duration()

	_expect(run_state.try_add_item(item), "%s must fit into an empty inventory." % item.display_name)
	_expect(item.collectible_max_copies >= 0, "%s active-effect copy cap must not be negative." % item.display_name)
	_expect(
		item.collectible_max_copies == 0 or item.collectible_stacks_by_copy,
		"%s must stack effects by copy when it defines an active-effect copy cap." % item.display_name
	)
	var dynamic_xirang := maxi(item.attack_speed_xirang_step, item.defense_xirang_step)
	if dynamic_xirang > 0:
		player.grant_cheat_xirang(dynamic_xirang)
	await process_frame

	var dynamic_attack_speed_bonus := 0.0
	if item.attack_speed_xirang_step > 0:
		dynamic_attack_speed_bonus = (
			floori(float(player.current_xirang) / float(item.attack_speed_xirang_step))
			* item.attack_speed_bonus_per_xirang_step
		)
	var dynamic_defense_bonus := 0
	if item.defense_xirang_step > 0:
		dynamic_defense_bonus = (
			floori(float(player.current_xirang) / float(item.defense_xirang_step))
			* item.defense_bonus_per_xirang_step
		)
	var condition_active := bool(player.call("_is_collectible_condition_active", item))
	var conditional_attack_bonus := item.conditional_attack_bonus if condition_active else 0
	var conditional_max_health_bonus := item.conditional_max_health_bonus if condition_active else 0
	var conditional_move_speed_bonus := item.conditional_move_speed_bonus if condition_active else 0.0
	var conditional_physical_defense_bonus := item.conditional_physical_defense_bonus if condition_active else 0
	var conditional_magic_defense_bonus := item.conditional_magic_defense_bonus if condition_active else 0
	var conditional_physical_damage_bonus := item.conditional_physical_damage_bonus if condition_active else 0
	var conditional_magic_damage_bonus := item.conditional_magic_damage_bonus if condition_active else 0
	var conditional_skill_charge_bonus := item.conditional_skill_charge_bonus_per_second if condition_active else 0.0
	var conditional_bullet_pierce_chance := item.conditional_bullet_pierce_chance if condition_active else 0.0

	_expect(
		player.attack_damage == base_attack + item.collectible_attack_bonus + conditional_attack_bonus,
		"%s attack bonus must apply." % item.display_name
	)
	_expect(
		player.max_health == base_max_health + item.collectible_max_health_bonus + conditional_max_health_bonus,
		"%s max health bonus must apply." % item.display_name
	)
	_expect(
		is_equal_approx(player.move_speed, base_move_speed + item.collectible_move_speed_bonus + conditional_move_speed_bonus),
		"%s move speed bonus must apply." % item.display_name
	)
	_expect(
		is_equal_approx(player.get_dash_distance(), base_dash_distance + item.collectible_dash_distance_bonus),
		"%s dash distance bonus must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			player.get_dash_cooldown(),
			maxf(
				base_dash_cooldown
				- minf(
					item.collectible_dash_cooldown_reduction,
					PickupConfig.MAX_DASH_COOLDOWN_REDUCTION_PER_COLLECTIBLE
				),
				0.0
			)
		),
		"%s dash cooldown reduction must apply." % item.display_name
	)
	_expect(
		player.physical_defense == base_physical_defense + item.collectible_physical_defense_bonus + dynamic_defense_bonus + conditional_physical_defense_bonus,
		"%s physical defense bonus must apply." % item.display_name
	)
	_expect(
		player.magic_defense == clampi(base_magic_defense + item.collectible_magic_defense_bonus + dynamic_defense_bonus + conditional_magic_defense_bonus, 0, 100),
		"%s magic defense bonus must apply." % item.display_name
	)
	_expect(
		player.get_outgoing_damage(10, EnemyConfig.DamageType.PHYSICAL) == 10 + item.collectible_physical_damage_bonus + conditional_physical_damage_bonus,
		"%s physical outgoing damage bonus must apply." % item.display_name
	)
	_expect(
		player.get_outgoing_damage(10, EnemyConfig.DamageType.MAGIC) == 10 + item.collectible_magic_damage_bonus + conditional_magic_damage_bonus,
		"%s magic outgoing damage bonus must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			float(player.get("collectible_skill_charge_bonus_per_second")),
			item.collectible_skill_charge_bonus_per_second + conditional_skill_charge_bonus
		),
		"%s skill charge bonus must apply." % item.display_name
	)
	_expect(
		is_equal_approx(float(player.get("collectible_base_upgrade_free_chance")), item.base_upgrade_free_chance),
		"%s free base upgrade chance must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			float(player.get("collectible_skill_charge_preserve_chance")),
			clampf(item.skill_charge_preserve_chance, 0.0, 1.0)
		),
		"%s skill charge preserve chance must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			float(player.get("collectible_damage_against_burning_multiplier")),
			maxf(item.damage_against_burning_multiplier, 0.0)
		),
		"%s burning-target damage multiplier must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			float(player.get("collectible_damage_against_bleeding_multiplier")),
			maxf(item.damage_against_bleeding_multiplier, 0.0)
		),
		"%s bleeding-target damage multiplier must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			float(player.get("collectible_ranged_front_damage_multiplier")),
			maxf(item.incoming_ranged_front_damage_multiplier, 1.0)
		),
		"%s front ranged damage multiplier must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			float(player.get("collectible_ranged_back_damage_multiplier")),
			minf(item.incoming_ranged_back_damage_multiplier, 1.0)
		),
		"%s back ranged damage multiplier must apply." % item.display_name
	)
	_expect(
		is_equal_approx(float(player.get("collectible_ranged_dodge_chance")), item.incoming_ranged_dodge_chance),
		"%s ranged dodge chance must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			player.call("_get_inventory_bullet_pierce_chance"),
			clampf(item.bullet_pierce_chance + conditional_bullet_pierce_chance, 0.0, 1.0)
		),
		"%s bullet pierce chance must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			player.call("_get_inventory_bullet_homing_chance"),
			clampf(item.bullet_homing_chance, 0.0, 1.0)
		),
		"%s bullet homing chance must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			player.call("_get_inventory_ammo_free_shot_chance"),
			clampf(item.ammo_free_shot_chance, 0.0, 1.0)
		),
		"%s ammo-free shot chance must apply." % item.display_name
	)
	_expect(
		is_equal_approx(
			player.get_attack_speed(),
			base_attack_speed + item.collectible_attack_speed_bonus + dynamic_attack_speed_bonus
		),
		"%s dynamic attack speed bonus must apply." % item.display_name
	)
	var expected_ammo_capacity := floori(
		float(base_ammo_capacity + item.collectible_ammo_capacity_additive_bonus)
		* (1.0 + item.collectible_ammo_capacity_bonus_ratio)
	)
	_expect(
		ammo_player.get_ammo_capacity() == expected_ammo_capacity,
		"%s effective ammo capacity must apply additive capacity before the percentage multiplier." % item.display_name
	)
	_expect(
		is_equal_approx(
			ammo_player.get_effective_reload_duration(),
			base_reload_duration * (1.0 - item.collectible_reload_time_reduction)
		),
		"%s effective reload reduction must apply." % item.display_name
	)
	if (
		item.damage_against_burning_multiplier > 1.0
		or item.damage_against_bleeding_multiplier > 1.0
	):
		_audit_status_target_damage(player, item)

	if item.collectible_effect_id == PickupConfig.COLLECTIBLE_EFFECT_ADMIN_DOLL:
		_expect(
			player.has_collectible_effect(PickupConfig.COLLECTIBLE_EFFECT_ADMIN_DOLL),
			"Admin doll special effect id must be visible to merchant logic."
		)
	if not item.conditional_effect_id.is_empty():
		await _audit_conditional_effect(player, item)
	if not item.trigger_effect_id.is_empty():
		await _audit_trigger_effect(player, item)
	if not item.on_hit_effect_id.is_empty():
		await _audit_on_hit_effect(player, item)
	if not item.kill_effect_id.is_empty():
		await _audit_kill_effect(player, item)
	if not item.periodic_effect_id.is_empty():
		await _audit_periodic_effect(player, item)
	if not item.skill_effect_id.is_empty():
		await _audit_skill_effect(player, item)

	player.queue_free()
	await process_frame
	await physics_frame
	_cleanup_test_children()


func _audit_status_target_damage(player: Player, item: PickupConfig) -> void:
	var enemy := _spawn_enemy(Vector2(40.0, 0.0), player)
	_expect(
		player.resolve_attack_damage_against_enemy(100, enemy) == 100,
		"%s status multiplier must not affect an unmarked enemy." % item.display_name
	)
	if item.damage_against_burning_multiplier > 1.0:
		enemy.collectible_status_effects[&"audit_burn"] = {
			"status_id": &"burn",
			"time_left": 1.0,
		}
	if item.damage_against_bleeding_multiplier > 1.0:
		enemy.collectible_status_effects[&"audit_bleed"] = {
			"status_id": &"bleed",
			"time_left": 1.0,
		}
	var expected_damage := roundi(
		100.0
		* item.damage_against_burning_multiplier
		* item.damage_against_bleeding_multiplier
	)
	_expect(
		player.resolve_attack_damage_against_enemy(100, enemy) == expected_damage,
		"%s status-target damage multiplier must affect matching enemies." % item.display_name
	)
	enemy.queue_free()


func _audit_conditional_effect(player: Player, item: PickupConfig) -> void:
	_force_condition_inactive(player, item)
	await process_frame
	var before_attack := player.attack_damage
	var before_max_health := player.max_health
	var before_move_speed := player.move_speed
	var before_physical_defense := player.physical_defense
	var before_magic_defense := player.magic_defense
	var before_physical_damage := player.get_outgoing_damage(10, EnemyConfig.DamageType.PHYSICAL)
	var before_magic_damage := player.get_outgoing_damage(10, EnemyConfig.DamageType.MAGIC)
	var before_charge_bonus := float(player.get("collectible_skill_charge_bonus_per_second"))
	var before_pierce_chance := float(player.call("_get_inventory_bullet_pierce_chance"))

	_force_condition_active(player, item)
	await process_frame
	_expect(
		bool(player.call("_is_collectible_condition_active", item)),
		"%s conditional design must become active under its configured condition." % item.display_name
	)
	if item.conditional_attack_bonus > 0:
		_expect(player.attack_damage >= before_attack + item.conditional_attack_bonus, "%s conditional attack bonus must apply." % item.display_name)
	if item.conditional_max_health_bonus > 0:
		_expect(player.max_health >= before_max_health + item.conditional_max_health_bonus, "%s conditional max health bonus must apply." % item.display_name)
	if item.conditional_move_speed_bonus > 0.0:
		_expect(player.move_speed >= before_move_speed + item.conditional_move_speed_bonus, "%s conditional move speed bonus must apply." % item.display_name)
	if item.conditional_physical_defense_bonus > 0:
		_expect(player.physical_defense >= before_physical_defense + item.conditional_physical_defense_bonus, "%s conditional physical defense bonus must apply." % item.display_name)
	if item.conditional_magic_defense_bonus > 0:
		_expect(player.magic_defense >= before_magic_defense + item.conditional_magic_defense_bonus, "%s conditional magic defense bonus must apply." % item.display_name)
	if item.conditional_physical_damage_bonus > 0:
		_expect(player.get_outgoing_damage(10, EnemyConfig.DamageType.PHYSICAL) >= before_physical_damage + item.conditional_physical_damage_bonus, "%s conditional physical damage bonus must apply." % item.display_name)
	if item.conditional_magic_damage_bonus > 0:
		_expect(player.get_outgoing_damage(10, EnemyConfig.DamageType.MAGIC) >= before_magic_damage + item.conditional_magic_damage_bonus, "%s conditional magic damage bonus must apply." % item.display_name)
	if item.conditional_skill_charge_bonus_per_second > 0.0:
		_expect(
			float(player.get("collectible_skill_charge_bonus_per_second")) >= before_charge_bonus + item.conditional_skill_charge_bonus_per_second,
			"%s conditional skill charge bonus must apply." % item.display_name
		)
	if item.conditional_bullet_pierce_chance > 0.0:
		_expect(
			is_equal_approx(
				float(player.call("_get_inventory_bullet_pierce_chance")),
				clampf(before_pierce_chance + item.conditional_bullet_pierce_chance, 0.0, 1.0)
			),
			"%s conditional bullet pierce chance must apply." % item.display_name
		)


func _force_condition_inactive(player: Player, item: PickupConfig) -> void:
	match item.conditional_effect_id:
		PickupConfig.CONDITION_HEALTH_BELOW:
			player.current_health = player.max_health
		PickupConfig.CONDITION_XIRANG_AT_LEAST:
			player.current_xirang = 0
		PickupConfig.CONDITION_SKILL_UNLOCKED:
			pass
	player.call("_refresh_collectible_stats", false)


func _force_condition_active(player: Player, item: PickupConfig) -> void:
	match item.conditional_effect_id:
		PickupConfig.CONDITION_HEALTH_BELOW:
			var threshold_health := floori(float(player.max_health) * item.conditional_health_ratio_threshold)
			player.current_health = maxi(threshold_health - 1, 1)
			player.call("_refresh_collectible_stats", false)
		PickupConfig.CONDITION_XIRANG_AT_LEAST:
			player.current_xirang = maxi(item.conditional_xirang_threshold, 1)
			player.call("_refresh_collectible_stats", false)
		PickupConfig.CONDITION_SKILL_UNLOCKED:
			player.unlock_skill1()
		_:
			player.call("_refresh_collectible_stats", false)


func _audit_trigger_effect(player: Player, item: PickupConfig) -> void:
	var trigger := item.trigger_effect_id
	var health_before := player.current_health
	var xirang_before := player.current_xirang
	var charge_before := player.skill1_charge
	var enemy: Enemy = null

	if trigger.ends_with("_heal"):
		player.current_health = maxi(player.max_health - item.trigger_heal - 5, 1)
		health_before = player.current_health
	if trigger.ends_with("_xirang"):
		xirang_before = player.current_xirang
	if trigger.ends_with("_charge"):
		if not player.skill1_unlocked:
			player.unlock_skill1()
		player.skill1_charge = 0.0
		player.call("_update_skill1_charge_bar")
		charge_before = player.skill1_charge
	if trigger.ends_with("_thunder"):
		enemy = _spawn_enemy(Vector2(48.0, 0.0), player)
		enemy.current_health = 500
	if trigger.ends_with("_frost"):
		enemy = _spawn_enemy(Vector2(24.0, 0.0), player)
		enemy.current_health = 500

	await _activate_trigger_event(player, item)
	await process_frame

	if trigger.ends_with("_heal"):
		_expect(player.current_health > health_before, "%s trigger design must heal." % item.display_name)
	if trigger.ends_with("_xirang"):
		_expect(player.current_xirang > xirang_before, "%s trigger design must grant xirang." % item.display_name)
	if trigger.ends_with("_charge"):
		_expect(player.skill1_charge > charge_before, "%s trigger design must restore skill charge." % item.display_name)
	if trigger.ends_with("_thunder"):
		_expect(enemy != null and enemy.last_damage_taken > 0, "%s trigger thunder design must damage an enemy." % item.display_name)
	if trigger.ends_with("_frost"):
		_expect(enemy != null and enemy.last_damage_taken > 0, "%s trigger frost design must damage an enemy." % item.display_name)
		_expect(enemy != null and enemy.move_speed_modifiers.size() > 0, "%s trigger frost design must slow an enemy." % item.display_name)


func _activate_trigger_event(player: Player, item: PickupConfig) -> void:
	if item.trigger_effect_id.begins_with("shot_"):
		for _shot_index in range(maxi(item.trigger_shot_interval, 1)):
			player.call("_trigger_collectible_shot_effects")
	elif item.trigger_effect_id.begins_with("hurt_"):
		player.call("_trigger_collectible_hurt_effects")
	elif item.trigger_effect_id.begins_with("skill_"):
		if not player.skill1_unlocked:
			player.unlock_skill1()
		player.call("_activate_collectible_skill_effects")


func _audit_on_hit_effect(player: Player, item: PickupConfig) -> void:
	var enemy := _spawn_enemy(Vector2(40.0, 0.0), player)
	enemy.current_health = 500
	var base_enemy_physical_defense := enemy.get_effective_physical_defense()
	var crack_test_baseline_source_id := 990001
	var crack_test_floor_source_id := 990002
	if item.on_hit_effect_id == PickupConfig.HIT_EFFECT_CRACK:
		enemy.add_physical_defense_modifier(crack_test_baseline_source_id, 5)
		base_enemy_physical_defense = enemy.get_effective_physical_defense()
	var ally: Player = null
	match item.on_hit_effect_id:
		PickupConfig.HIT_EFFECT_LEECH:
			player.current_health = maxi(player.max_health - item.on_hit_heal - 5, 1)
		PickupConfig.HIT_EFFECT_SIPHON:
			if not player.skill1_unlocked:
				player.unlock_skill1()
			player.skill1_charge = 0.0
			player.call("_update_skill1_charge_bar")
		PickupConfig.HIT_EFFECT_EXECUTE:
			var max_enemy_health := enemy.config.max_health if enemy.config != null else 500
			enemy.current_health = maxi(floori(float(max_enemy_health) * item.on_hit_execute_health_ratio) - 1, 1)
		PickupConfig.HIT_EFFECT_BLOOM:
			ally = _spawn_player(Vector2(44.0, 0.0))
	if ally != null:
		await process_frame
		ally.current_health = maxi(ally.max_health - item.on_hit_heal - 5, 1)
	var health_before := player.current_health
	var charge_before := player.skill1_charge
	var xirang_before := player.current_xirang
	var ally_health_before := ally.current_health if ally != null else 0
	var shock_enemy: Enemy = null
	if item.on_hit_effect_id == PickupConfig.HIT_EFFECT_SHOCK:
		shock_enemy = _spawn_enemy(Vector2(52.0, 0.0), player)
		shock_enemy.current_health = 500
	var applied_item := item
	if item.on_hit_effect_id == PickupConfig.HIT_EFFECT_CRACK:
		applied_item = item.duplicate() as PickupConfig
		applied_item.on_hit_chance = 1.0

	for _attempt in range(240):
		var cooldown_key := str(player.call("_get_collectible_aux_key", applied_item, "hit:%s" % applied_item.on_hit_effect_id))
		player.collectible_trigger_deadlines.erase(cooldown_key)
		player.call("_apply_collectible_on_hit_effect", applied_item, enemy, 10)
		await process_frame
		var produced_result := _has_on_hit_effect_result(
			player,
			item,
			enemy,
			shock_enemy,
			ally,
			health_before,
			charge_before,
			xirang_before,
			ally_health_before
		)
		if item.on_hit_effect_id == PickupConfig.HIT_EFFECT_CRACK:
			produced_result = (
				enemy.get_effective_physical_defense()
				== maxi(base_enemy_physical_defense + item.on_hit_physical_defense_modifier, 0)
			)
		if produced_result:
			if item.on_hit_effect_id == PickupConfig.HIT_EFFECT_CRACK:
				_expect(
					enemy.get_effective_physical_defense()
					== maxi(base_enemy_physical_defense + item.on_hit_physical_defense_modifier, 0),
					"%s crack effect must lower effective physical defense by its configured modifier."
					% item.display_name
				)
				enemy.add_physical_defense_modifier(crack_test_floor_source_id, -999)
				_expect(
					enemy.get_effective_physical_defense() == 0,
					"Enemy physical defense modifiers must allow armor break but clamp the final defense to zero."
				)
				enemy.remove_physical_defense_modifier(crack_test_floor_source_id)
				await create_timer(maxf(item.on_hit_duration, 0.05) + 0.15).timeout
				_expect(
					enemy.get_effective_physical_defense() == base_enemy_physical_defense,
					"%s crack effect must restore effective physical defense after its duration."
					% item.display_name
				)
				enemy.remove_physical_defense_modifier(crack_test_baseline_source_id)
			return
	if item.on_hit_effect_id == PickupConfig.HIT_EFFECT_CRACK:
		enemy.remove_physical_defense_modifier(crack_test_baseline_source_id)
	_expect(false, "%s on-hit effect must produce its configured result." % item.display_name)


func _has_on_hit_effect_result(
	player: Player,
	item: PickupConfig,
	enemy: Enemy,
	shock_enemy: Enemy,
	ally: Player,
	health_before: int,
	charge_before: float,
	xirang_before: int,
	ally_health_before: int
) -> bool:
	match item.on_hit_effect_id:
		PickupConfig.HIT_EFFECT_BURN, PickupConfig.HIT_EFFECT_BLEED:
			return enemy.collectible_status_effects.size() > 0
		PickupConfig.HIT_EFFECT_CHILL:
			return enemy.move_speed_modifiers.size() > 0
		PickupConfig.HIT_EFFECT_SHOCK:
			return shock_enemy != null and shock_enemy.last_damage_taken > 0
		PickupConfig.HIT_EFFECT_MARK:
			return enemy.damage_taken_multiplier_modifiers.size() > 0
		PickupConfig.HIT_EFFECT_CRACK:
			return enemy.physical_defense_modifiers.size() > 0
		PickupConfig.HIT_EFFECT_LEECH:
			return player.current_health > health_before
		PickupConfig.HIT_EFFECT_SIPHON:
			return player.skill1_charge > charge_before
		PickupConfig.HIT_EFFECT_EXECUTE:
			return enemy.is_dead
		PickupConfig.HIT_EFFECT_BLOOM:
			return ally != null and ally.current_health > ally_health_before
		PickupConfig.HIT_EFFECT_XIRANG:
			return player.current_xirang > xirang_before
	return false


func _audit_kill_effect(player: Player, item: PickupConfig) -> void:
	var enemy := _spawn_enemy(Vector2(40.0, 0.0), player)
	enemy.current_health = 0
	enemy.is_dead = true
	var ally: Player = null
	var area_enemy: Enemy = null
	match item.kill_effect_id:
		PickupConfig.KILL_EFFECT_HEAL:
			player.current_health = maxi(player.max_health - item.kill_heal - 5, 1)
		PickupConfig.KILL_EFFECT_CHARGE:
			if not player.skill1_unlocked:
				player.unlock_skill1()
			player.skill1_charge = 0.0
			player.call("_update_skill1_charge_bar")
		PickupConfig.KILL_EFFECT_THUNDER, PickupConfig.KILL_EFFECT_FROST, PickupConfig.KILL_EFFECT_BURST:
			area_enemy = _spawn_enemy(Vector2(48.0, 0.0), player)
			area_enemy.current_health = 500
		PickupConfig.KILL_EFFECT_BLOOM:
			ally = _spawn_player(Vector2(44.0, 0.0))
	if ally != null:
		await process_frame
		ally.current_health = maxi(ally.max_health - item.kill_heal - 5, 1)
	var health_before := player.current_health
	var xirang_before := player.current_xirang
	var charge_before := player.skill1_charge
	var effective_speed_before := float(player.call("_get_effective_move_speed"))
	var ally_health_before := ally.current_health if ally != null else 0

	player.call("_apply_collectible_kill_effect", item, enemy)
	await process_frame

	match item.kill_effect_id:
		PickupConfig.KILL_EFFECT_HEAL:
			_expect(player.current_health > health_before, "%s kill effect must heal." % item.display_name)
		PickupConfig.KILL_EFFECT_XIRANG:
			_expect(player.current_xirang > xirang_before, "%s kill effect must grant xirang." % item.display_name)
		PickupConfig.KILL_EFFECT_CHARGE:
			_expect(player.skill1_charge > charge_before, "%s kill effect must restore skill charge." % item.display_name)
		PickupConfig.KILL_EFFECT_THUNDER, PickupConfig.KILL_EFFECT_BURST:
			_expect(area_enemy != null and area_enemy.last_damage_taken > 0, "%s kill effect must damage nearby enemies." % item.display_name)
		PickupConfig.KILL_EFFECT_FROST:
			_expect(area_enemy != null and area_enemy.last_damage_taken > 0, "%s kill frost effect must damage nearby enemies." % item.display_name)
			_expect(area_enemy != null and area_enemy.move_speed_modifiers.size() > 0, "%s kill frost effect must slow nearby enemies." % item.display_name)
		PickupConfig.KILL_EFFECT_HASTE:
			_expect(float(player.call("_get_effective_move_speed")) > effective_speed_before, "%s kill haste effect must increase movement speed." % item.display_name)
		PickupConfig.KILL_EFFECT_BLOOM:
			_expect(ally != null and ally.current_health > ally_health_before, "%s kill bloom effect must heal nearby allies." % item.display_name)
		_:
			_expect(false, "%s uses an unknown kill effect id." % item.display_name)


func _audit_periodic_effect(player: Player, item: PickupConfig) -> void:
	match item.periodic_effect_id:
		PickupConfig.PERIODIC_EFFECT_THUNDER:
			var enemy := _spawn_enemy(Vector2(48.0, 0.0), player)
			enemy.current_health = 500
			player.call("_trigger_thunder_crystal", item)
			await process_frame
			_expect(enemy.last_damage_taken > 0, "%s thunder periodic effect must damage an enemy." % item.display_name)
		PickupConfig.PERIODIC_EFFECT_FROST:
			var enemy := _spawn_enemy(Vector2(32.0, 0.0), player)
			enemy.current_health = 500
			player.call("_trigger_frost_crystal", item)
			await process_frame
			_expect(enemy.last_damage_taken > 0, "%s frost periodic effect must damage an enemy." % item.display_name)
			_expect(enemy.move_speed_modifiers.size() > 0, "%s frost periodic effect must slow an enemy." % item.display_name)
		PickupConfig.PERIODIC_EFFECT_HEAL:
			var ally := _spawn_player(Vector2(24.0, 0.0))
			ally.current_health = maxi(ally.max_health - item.periodic_heal - 5, 1)
			var health_before := ally.current_health
			player.call("_trigger_life_crystal", item)
			await process_frame
			_expect(ally.current_health > health_before, "%s heal periodic effect must heal an ally." % item.display_name)
		PickupConfig.PERIODIC_EFFECT_ARCHER:
			var enemy_count := maxi(item.periodic_target_count, 1)
			for enemy_index in range(enemy_count):
				_spawn_enemy(Vector2(48.0 + enemy_index * 20.0, 0.0), player)
			player.call("_trigger_archer", item)
			await process_frame
			var arrow_count := 0
			for child in test_root.get_children():
				if child.get_script() == COLLECTIBLE_ARROW_PROJECTILE_SCRIPT:
					arrow_count += 1
			_expect(arrow_count == enemy_count, "%s archer periodic effect must spawn the configured arrows." % item.display_name)
		PickupConfig.PERIODIC_EFFECT_SAKURA_ROCKET:
			var near_enemy := _spawn_enemy(Vector2(42.0, 0.0), player)
			near_enemy.current_health = 500
			var far_enemy := _spawn_enemy(Vector2(120.0, 0.0), player)
			far_enemy.current_health = 500
			player.call("_trigger_sakura_rocket", item)
			await process_frame
			var rocket_count := 0
			var rocket: LinglanSkill2SakuraRocket = null
			for child in test_root.get_children():
				if child.get_script() == LINGLAN_SKILL2_ROCKET_SCRIPT:
					rocket_count += 1
					if rocket == null:
						rocket = child as LinglanSkill2SakuraRocket
			_expect(rocket_count == 1, "%s sakura periodic effect must spawn one rocket." % item.display_name)
			if rocket != null:
				_expect(rocket.target_node == near_enemy, "%s sakura rocket must target the nearest enemy." % item.display_name)
				_expect(rocket.enemies_only, "%s sakura rocket must be enemy-only." % item.display_name)
				_expect(rocket.damage_type == EnemyConfig.DamageType.MAGIC, "%s sakura rocket must deal magic damage." % item.display_name)
				_expect(
					is_equal_approx(
						rocket.explosion_radius,
						LinglanSkill2SakuraRocket.COLLECTIBLE_SAKURA_EXPLOSION_RADIUS
					),
					"%s sakura rocket explosion radius must be Weishidaier Skill1 radius plus 3." % item.display_name
				)
				_expect(
					rocket.damage == player.get_outgoing_damage(item.periodic_damage, EnemyConfig.DamageType.MAGIC),
					"%s sakura rocket damage must use configured magic periodic damage." % item.display_name
				)
		_:
			_expect(false, "%s uses an unknown periodic effect id." % item.display_name)


func _audit_skill_effect(player: Player, item: PickupConfig) -> void:
	match item.skill_effect_id:
		PickupConfig.SKILL_EFFECT_MOON_SHIELD:
			var existing_shield := player.get_node_or_null("CollectibleMoonShield")
			if existing_shield != null:
				existing_shield.queue_free()
				await process_frame
			player.call("_activate_collectible_skill_effects")
			await process_frame
			_expect(
				player.get_node_or_null("CollectibleMoonShield") != null,
				"%s skill effect must spawn a moon shield." % item.display_name
			)
		PickupConfig.SKILL_EFFECT_SWIFT:
			player.set("collectible_swift_time_left", 0.0)
			player.set("collectible_swift_move_speed_multiplier", 1.0)
			var base_speed := float(player.call("_get_effective_move_speed"))
			player.call("_activate_collectible_skill_effects")
			await process_frame
			_expect(
				float(player.call("_get_effective_move_speed")) > base_speed,
				"%s skill effect must increase movement speed." % item.display_name
			)
		_:
			_expect(false, "%s uses an unknown skill effect id." % item.display_name)


func _spawn_player(position: Vector2 = Vector2.ZERO) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	return player


func _spawn_enemy(position: Vector2, player: Player) -> Enemy:
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(BASIC_CONFIG, player, null)
	return enemy


func _cleanup_test_children() -> void:
	for child in test_root.get_children():
		if is_instance_valid(child):
			child.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
