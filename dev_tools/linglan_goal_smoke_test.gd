extends SceneTree

const LINGLAN_SCENE := preload("res://scene/boss/linglan/linglan_boss.tscn")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const SKILL1_CONFIG := preload("res://resources/config/bosses/linglan_skill1.tres")
const SKILL2_CONFIG := preload("res://resources/config/bosses/linglan_skill2.tres")
const SKILL4_CONFIG := preload("res://resources/config/bosses/linglan_skill4.tres")
const DEFAULT_FLOW := preload("res://resources/config/flow/default_combat_flow.tres")
const AIRDROP_WARNING_SCENE := preload("res://scene/boss/linglan/linglan_airdrop_warning_marker.tscn")
const ENRAGE_SNIPER_CONFIG := preload("res://resources/config/enemies/capoo_sniper.tres")

var failures: Array[String] = []


class BossHost:
	extends "res://dev_tools/fixtures/linglan_combat_test_runtime.gd"

	var airdrop_records: Array[Dictionary] = []
	var slime_spawn_positions: Array[Vector2] = []
	var home_objective_target: Node2D = null

	func spawn_linglan_airdrop_sniper(
		enemy_config: EnemyConfig,
		warning_scene: PackedScene,
		warning_duration: float,
		drop_height: float,
		drop_duration: float
	) -> void:
		airdrop_records.append({
			"enemy_config": enemy_config,
			"warning_scene": warning_scene,
			"warning_duration": warning_duration,
			"drop_height": drop_height,
			"drop_duration": drop_duration,
		})

	func get_linglan_enrage_sniper_config() -> EnemyConfig:
		return ENRAGE_SNIPER_CONFIG

	func get_linglan_skill2_target_global_position(_target_cell: Vector2i) -> Vector2:
		return Vector2(64.0, 64.0)

	func get_linglan_skill3_target_global_position(_target_cell: Vector2i) -> Vector2:
		return Vector2(80.0, 64.0)

	func get_linglan_skill4_target_global_position(
		_target_cell_a: Vector2i,
		_target_cell_b: Vector2i
	) -> Vector2:
		return Vector2(96.0, 64.0)

	func get_linglan_home_objective_target(_from_position: Vector2) -> Node2D:
		return home_objective_target

	func spawn_linglan_random_slime(spawn_position: Vector2) -> void:
		slime_spawn_positions.append(spawn_position)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_skill_configs()
	_test_default_flow_and_waves()
	await _test_boss_scheduler_and_airdrop()
	_test_airdrop_warning_scene()

	if failures.is_empty():
		print("LINGLAN_GOAL_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_skill_configs() -> void:
	_expect(SKILL1_CONFIG.ring_direction_count == 20, "Skill1 must keep 20 simultaneous directions.")
	_expect(is_equal_approx(SKILL1_CONFIG.attack_speed, 1800.0), "Skill1 attack speed must be 1800.")
	_expect(is_equal_approx(SKILL1_CONFIG.get_fire_interval(), 1.0 / 18.0), "Skill1 must fire 18 rings per second.")
	_expect(is_equal_approx(SKILL1_CONFIG.projectile_lifetime, 1.2), "Skill1 bullets must travel for 1.2s before shrinking.")
	var tower_visible_half_extent := Vector2(1152.0, 648.0) / 4.0
	var farthest_visible_radius := tower_visible_half_extent.length()
	var skill1_despawn_radius := (
		SKILL1_CONFIG.projectile_spawn_distance
		+ SKILL1_CONFIG.get_projectile_travel_distance()
	)
	_expect(
		skill1_despawn_radius > farthest_visible_radius
		and skill1_despawn_radius <= farthest_visible_radius + 64.0,
		"Skill1 bullets must cross the zoom-2 viewport's farthest corner only slightly before shrinking."
	)
	_expect(
		SKILL2_CONFIG.spawn_enemy_config != null
		and SKILL2_CONFIG.spawn_enemy_config.resource_path == "res://resources/config/enemies/yuanshi_insect_shell.tres",
		"Skill2 must summon hard-shell ore insects."
	)
	_expect(SKILL4_CONFIG.orb_count_per_side == 7, "Skill4 orb rows per side must be reduced to 7.")
	_expect(SKILL4_CONFIG.laser_field_scene == null, "Skill4 must not retain a laser-frame scene.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_lifetime, 12.0), "Skill4 orbs must travel for 12s before shrinking.")
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = 1024
	_expect(SKILL4_CONFIG.get_random_orb_rows(random_generator).size() == 7, "Skill4 must pick 7 rows per orb wave.")


func _test_default_flow_and_waves() -> void:
	var flow_errors := DEFAULT_FLOW.validate_graph()
	_expect(flow_errors.is_empty(), "Default flow graph must validate: %s" % str(flow_errors))
	_expect(DEFAULT_FLOW.steps.size() == 13, "Default flow must contain 12 waves plus Linglan.")
	_expect(DEFAULT_FLOW.get_step_by_id(&"wave_12") != null, "Default flow must include wave_12.")

	for wave_number in range(1, 13):
		var wave := load("res://resources/config/waves/wave_%02d.tres" % wave_number) as WaveConfig
		_expect(wave != null, "Wave %02d must load." % wave_number)
		if wave == null:
			continue
		var expected_rest_duration := 20.0 if wave_number <= 5 else 30.0
		_expect(
			wave.post_clear_rest_duration == expected_rest_duration,
			"Wave %02d rest duration mismatch." % wave_number
		)
		var expected_next := &"boss_01_linglan" if wave_number == 12 else StringName("wave_%02d" % (wave_number + 1))
		var default_exit := wave.get_default_exit()
		_expect(default_exit != null, "Wave %02d must have a default exit." % wave_number)
		if default_exit != null:
			_expect(default_exit.get_target_step_id() == expected_next, "Wave %02d default exit mismatch." % wave_number)

	_expect(_get_wave_total(1) == 1, "Formal Wave 01 slime total count mismatch.")
	_expect(_get_wave_total(8) == 420, "Wave 08 total count mismatch.")
	_expect(_get_wave_total(12) == 560, "Wave 12 total count mismatch.")


func _test_boss_scheduler_and_airdrop() -> void:
	var host := BossHost.new()
	host.linglan_tower_defense_rules = true
	root.add_child(host)
	var home_target := Node2D.new()
	home_target.name = "HomeObjective"
	host.add_child(home_target)
	home_target.global_position = Vector2(-320.0, 0.0)
	host.home_objective_target = home_target
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan boss scene must instantiate.")
	if boss == null:
		host.queue_free()
		return

	host.add_child(boss)
	await process_frame
	await physics_frame
	boss.config = LINGLAN_CONFIG
	boss.activate_boss(
		null,
		null,
		host,
		host.linglan_boss_runtime_port
	)
	await process_frame

	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.ADVANCE_TO_HOME
		and boss.queued_skill_number == 1,
		"Tower-defense Linglan must advance toward the blue gate before Skill1."
	)
	boss._physics_process(0.1)
	_expect(
		boss.velocity.x < 0.0 and is_equal_approx(boss.velocity.length(), 20.0),
		"Tower-defense Linglan must run toward the blue gate at speed 20."
	)
	boss._physics_process(7.91)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL1,
		"The opening advance must last 8s before Skill1 starts."
	)

	boss.skill1_finished = true
	boss._physics_process(0.016)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.ADVANCE_TO_HOME
		and boss.queued_skill_number == 2,
		"Skill1 completion must enter the 8s blue-gate advance."
	)
	boss._physics_process(8.01)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL2,
		"After the 8s advance, the opening sequence must continue to Skill2."
	)
	boss.skill2_target_global_position = boss.global_position
	boss.touching_players[99] = null
	boss.call("_update_skill2_move", 0.016)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL2,
		"A front-line Skill2 must start even while Linglan is touching a player or tower."
	)
	boss.touching_players.clear()
	boss.skill2_elapsed = boss.skill2_config.get_total_duration()
	boss.skill2_spawn_ticks_completed = boss.skill2_config.attack_count
	boss.skill2_shots_fired = boss.skill2_config.attack_count
	boss.call("_update_skill2", 0.0)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.ADVANCE_TO_HOME
		and boss.queued_skill_number == 3,
		"Skill2 completion must enter the shared blue-gate advance."
	)
	boss.call("_update_tower_advance", 7.99)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.ADVANCE_TO_HOME,
		"Skill2's blue-gate advance must remain active until 8s."
	)
	boss.call("_update_tower_advance", 0.02)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL3,
		"Skill2's 8s advance must hand off to Skill3."
	)

	boss.skill3_target_global_position = boss.global_position
	boss.call("_update_skill3_move", 0.016)
	boss.skill3_elapsed = boss.skill3_config.duration
	boss.skill3_shots_fired = boss.skill3_config.get_shot_count()
	boss.call("_update_skill3", 0.0)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.ADVANCE_TO_HOME
		and boss.queued_skill_number == 4,
		"Skill3 completion must enter the shared blue-gate advance."
	)
	boss.call("_update_tower_advance", 7.99)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.ADVANCE_TO_HOME,
		"Skill3's blue-gate advance must remain active until 8s."
	)
	boss.call("_update_tower_advance", 0.02)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL4,
		"Skill3's 8s advance must hand off to Skill4."
	)

	boss.skill4_target_global_position = boss.global_position
	boss.call("_update_skill4_move", 0.016)
	var skill4_config := boss.skill4_config as LinglanSkill4Config
	if skill4_config != null:
		boss.skill4_elapsed = skill4_config.get_total_duration()
		boss.skill4_orb_spawn_ticks_completed = skill4_config.get_orb_wave_count()
	boss.call("_update_skill4", 0.0)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.ADVANCE_TO_HOME,
		"Skill4 completion must enter the shared blue-gate advance."
	)
	boss.call("_update_tower_advance", 7.99)
	_expect(
		boss.boss_skill_phase == LinglanBoss.BossSkillPhase.ADVANCE_TO_HOME,
		"Skill4's blue-gate advance must remain active until 8s."
	)
	boss.call("_update_tower_advance", 0.02)
	_expect(
		boss.boss_skill_phase != LinglanBoss.BossSkillPhase.ADVANCE_TO_HOME,
		"Skill4's 8s advance must hand off to the next scheduled skill."
	)

	boss.boss_skill_phase = LinglanBoss.BossSkillPhase.DONE
	host.slime_spawn_positions.clear()
	boss.tower_slime_summon_timer = 5.0
	boss._physics_process(4.9)
	_expect(host.slime_spawn_positions.is_empty(), "Random slime summon must wait 5s.")
	boss._physics_process(0.2)
	_expect(
		host.slime_spawn_positions.size() == 1
		and host.slime_spawn_positions[0].is_equal_approx(boss.global_position),
		"Linglan must summon one random slime at her position every 5s."
	)
	boss._physics_process(5.0)
	_expect(
		host.slime_spawn_positions.size() == 2,
		"Linglan must keep summoning one random slime every 5s."
	)

	boss.current_health = 499
	boss._physics_process(9.9)
	_expect(host.airdrop_records.is_empty(), "Half-health sniper airdrop must wait 10s.")
	boss._physics_process(0.2)
	_expect(host.airdrop_records.size() == 1, "Half-health sniper airdrop must trigger every 10s.")
	if not host.airdrop_records.is_empty():
		var record := host.airdrop_records[0]
		_expect(
			(record.get("enemy_config") as EnemyConfig).resource_path == "res://resources/config/enemies/capoo_sniper.tres",
			"Half-health airdrop must spawn Capoo sniper."
		)
		_expect(record.get("warning_scene") == AIRDROP_WARNING_SCENE, "Airdrop must use the warning marker scene.")
	boss._physics_process(10.0)
	_expect(
		host.airdrop_records.size() == 2,
		"Half-health Capoo sniper airdrops must continue every 10s."
	)

	host.queue_free()
	await process_frame


func _test_airdrop_warning_scene() -> void:
	var marker := AIRDROP_WARNING_SCENE.instantiate() as Node2D
	_expect(marker != null, "Airdrop warning marker scene must instantiate.")
	if marker == null:
		return
	root.add_child(marker)
	marker.start(0.1)
	await process_frame
	_expect(marker.is_processing(), "Airdrop warning marker must process while active.")
	marker.queue_free()
	await process_frame


func _get_wave_total(wave_number: int) -> int:
	var wave := load("res://resources/config/waves/wave_%02d.tres" % wave_number) as WaveConfig
	if wave == null:
		return -1
	return wave.get_total_enemy_count()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
