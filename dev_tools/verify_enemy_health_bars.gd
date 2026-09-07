extends SceneTree

## Run with: Godot.exe --headless --path . --script res://dev_tools/verify_enemy_health_bars.gd
## Uses the authored enemy scenes and real health entrypoints. Combat processing,
## particles, audio and rewards are disabled so this remains a focused UI check.

const BOSS_HUD_SCENE_PATH := "res://scene/boss/linglan/boss_health_hud.tscn"

var failures := 0
var assertions := 0
var tested_enemies := 0
var tested_bosses := 0
var tested_lethal_cases := 0
var observed_widths: Dictionary[int, bool] = {}
var current_case := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var configs: Dictionary[String, EnemyConfig] = {}
	_collect_configs("res://resources/config/enemies", configs)
	_collect_configs("res://resources/config/bosses", configs)
	_expect(not configs.is_empty(), "Discovered enemy configurations")
	var paths := configs.keys()
	paths.sort()
	for path: String in paths:
		current_case = path
		var enemy_config := configs[path]
		_test_enemy(enemy_config)
		if enemy_config.is_boss or enemy_config.explode_on_death or tested_enemies % 10 == 0:
			_test_lethal_damage(enemy_config)
		enemy_config = null
		await process_frame
	_expect(observed_widths.size() > 1, "Different enemy sizes produce adaptive bar widths")
	# Release test-owned resources while the SceneTree and rendering server are
	# still alive; allow killed HUD tweens and deferred shape updates to drain.
	configs.clear()
	paths.clear()
	await process_frame
	await process_frame
	print(
		"ENEMY_HEALTH_BARS: %d enemies, %d boss HUDs, %d lethal cases, %d assertions, %d failures"
		% [tested_enemies, tested_bosses, tested_lethal_cases, assertions, failures]
	)
	quit(0 if failures == 0 else 1)


func _collect_configs(directory_path: String, configs: Dictionary[String, EnemyConfig]) -> void:
	for child_directory: String in DirAccess.get_directories_at(directory_path):
		_collect_configs(directory_path.path_join(child_directory), configs)
	for filename: String in DirAccess.get_files_at(directory_path):
		if filename.get_extension() != "tres":
			continue
		var path := directory_path.path_join(filename)
		var resource := load(path)
		if resource is EnemyConfig:
			configs[path] = resource as EnemyConfig
		elif resource is BossConfig:
			var boss_config := resource as BossConfig
			var enemy_config := boss_config.get_enemy_config()
			_expect(enemy_config != null, "%s resolves its enemy config" % path)
			if enemy_config != null:
				var key := enemy_config.resource_path
				configs[key if not key.is_empty() else path] = enemy_config


func _spawn_enemy(authored_config: EnemyConfig) -> Enemy:
	_expect(authored_config.enemy_scene != null, "Authored enemy scene exists")
	if authored_config.enemy_scene == null:
		return null
	var enemy := authored_config.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Authored scene inherits Enemy")
	if enemy == null:
		return null
	var isolated_config := authored_config.duplicate() as EnemyConfig
	isolated_config.drop_table = null
	isolated_config.xirang_kill_reward = 0
	enemy.config = isolated_config
	enemy.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(enemy)
	enemy.visible = true
	enemy.hit_audio.stream = null
	enemy.death_audio.stream = null
	return enemy


func _test_enemy(authored_config: EnemyConfig) -> void:
	var enemy := _spawn_enemy(authored_config)
	if enemy == null:
		return
	var bar := enemy.get_node_or_null("HealthBar") as ProgressBar
	_expect(bar != null, "Scene inherits the native HealthBar node")
	if bar == null:
		enemy.free()
		return
	tested_enemies += 1
	var hud: BossHealthHUD = null
	if enemy is LinglanBoss:
		var hud_scene := load(BOSS_HUD_SCENE_PATH) as PackedScene
		hud = hud_scene.instantiate() as BossHealthHUD
		root.add_child(hud)
		hud.show_for_boss(enemy as LinglanBoss)
		tested_bosses += 1
	var maximum := enemy.get_runtime_max_health()
	_expect_presentation(enemy, bar, hud, "Full health at ready")
	_expect(bar.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Bar does not consume input")
	_expect(bar.size.x > 0.0 and bar.size.y > 0.0, "Bar has positive dimensions")
	_expect(absf(bar.position.x + bar.size.x * 0.5) <= 1.0, "Bar stays centered above the body")
	_expect(bar.position.y + bar.size.y < 0.0, "Bar is placed above the body origin")
	observed_widths[roundi(bar.size.x)] = true
	var authored_bar_rect := bar.get_rect()

	var result := enemy.apply_combat_damage(_damage_request(1))
	_expect(result.accepted and result.applied_damage == 1, "Real damage entrypoint removes one HP")
	_expect(enemy.current_health == maximum - 1, "Damage changes authoritative health")
	_expect_presentation(enemy, bar, hud, "After one damage")
	if enemy is CombatRobotMainBattleElite:
		_test_main_battle_body_follow(enemy, bar)
	enemy.apply_combat_damage(_damage_request(2))
	_expect(enemy.restore_health(1) == 1, "Partial healing restores health")
	_expect_presentation(enemy, bar, hud, "Partially healed")
	enemy.restore_health(maximum)
	_expect(enemy.current_health == maximum, "Healing clamps at maximum")
	_expect_presentation(enemy, bar, hud, "Fully healed")

	# Increasing the cap can change visibility even when HP/revision do not change.
	var previous_revision := enemy.health_revision
	enemy.set_runtime_max_health_multiplier(2.0)
	_expect(enemy.current_health == maximum, "Cap-only increase preserves absolute health")
	_expect(enemy.health_revision == previous_revision, "Cap-only increase keeps health revision")
	_expect_presentation(enemy, bar, hud, "Maximum increased without changing current HP")
	enemy.restore_health(maximum)
	_expect_presentation(enemy, bar, hud, "Healed to increased maximum")
	enemy.set_runtime_max_health_multiplier(0.5, true)
	_expect_presentation(enemy, bar, hud, "Ratio-preserving maximum decrease at full health")
	enemy.apply_combat_damage(_damage_request(1))
	enemy.set_runtime_max_health_multiplier(1.0, true)
	_expect_presentation(enemy, bar, hud, "Ratio-preserving maximum change while wounded")

	# Ready-time config and a later production setup both reset the same widget.
	enemy.setup(enemy.config, null)
	_expect(enemy.current_health == maximum, "Setup restores configured maximum health")
	_expect_presentation(enemy, bar, hud, "Setup after health mutations")
	_expect(bar.get_rect().is_equal_approx(authored_bar_rect), "Setup keeps authored layout stable")
	var sprite := enemy.animated_sprite
	sprite.frame = sprite.sprite_frames.get_frame_count(sprite.animation) - 1
	sprite.flip_h = not sprite.flip_h
	_expect(bar.get_rect().is_equal_approx(authored_bar_rect), "Animation frame/facing do not move the bar")

	enemy.configure_multiplayer_proxy()
	var revision := enemy.health_revision + 10
	_expect(enemy.try_apply_multiplayer_health_snapshot(maximum - 1, revision), "New snapshot is accepted")
	_expect_presentation(enemy, bar, hud, "Wounded multiplayer snapshot")
	_expect(not enemy.try_apply_multiplayer_health_snapshot(maximum, revision - 1), "Stale snapshot is rejected")
	_expect(not enemy.try_apply_multiplayer_health_snapshot(maximum, revision), "Duplicate snapshot is rejected")
	_expect(enemy.current_health == maximum - 1, "Rejected snapshots preserve current health")
	_expect_presentation(enemy, bar, hud, "After rejected snapshots")
	_expect(enemy.try_apply_multiplayer_health_snapshot(0, revision + 1), "Zero-HP snapshot is accepted")
	_expect_presentation(enemy, bar, hud, "Zero health before death notification")
	_expect(enemy.try_apply_multiplayer_health_snapshot(maximum, revision + 2), "Full-HP snapshot is accepted")
	_expect_presentation(enemy, bar, hud, "Full multiplayer snapshot")
	enemy.try_apply_multiplayer_health_snapshot(maximum - 1, revision + 3)
	enemy.play_multiplayer_death_sequence()
	_expect(enemy.is_dead, "Proxy death marks the enemy dead")
	_expect_presentation(enemy, bar, hud, "Proxy death while previous snapshot still had HP")
	if hud != null:
		_expect(enemy.current_health > 0, "Proxy death retains the last positive health snapshot")
		hud.hide_all()
		hud.show_for_boss(enemy as LinglanBoss)
		_expect_presentation(enemy, bar, hud, "HUD bound after proxy death with cached positive HP")
		_expect(not hud.root_control.visible, "Already-dead boss does not reveal HUD decoration")
		hud.hide_all()
		hud.free()
	enemy.free()


func _test_main_battle_body_follow(enemy: Enemy, bar: ProgressBar) -> void:
	var sprite := enemy.animated_sprite
	var standing_rect := bar.get_rect()
	sprite.play(&"skill2_takeoff")
	sprite.frame = 0
	var takeoff_start_y := bar.position.y
	sprite.frame = 4
	_expect(bar.position.y < takeoff_start_y, "Main battle bar follows the ascending takeoff body")
	_expect(bar.size == standing_rect.size, "Takeoff preserves the standing bar dimensions")
	# Changing animations at frame zero need not emit frame_changed. The bar must
	# still reset from the takeoff pose through animation_changed.
	sprite.frame = 0
	_expect(not bar.get_rect().is_equal_approx(standing_rect), "Takeoff frame zero has its own body height")
	sprite.play(enemy.config.move_animation_name)
	_expect(sprite.frame == 0, "Animation switch preserves frame zero for this regression case")
	_expect(bar.get_rect().is_equal_approx(standing_rect), "Returning to move restores standing bar position")


func _test_lethal_damage(authored_config: EnemyConfig) -> void:
	var enemy := _spawn_enemy(authored_config)
	if enemy == null:
		return
	var bar := enemy.get_node_or_null("HealthBar") as ProgressBar
	if bar == null:
		enemy.free()
		return
	# Hit-count enemies (cardboard monsters) settle exactly one HP per accepted
	# hit. Set up one remaining HP through the public health snapshot entrypoint,
	# then let a real hit perform the lethal transition for every family.
	_expect(enemy.try_apply_multiplayer_health_snapshot(1, enemy.health_revision + 1), "Lethal case starts from one HP")
	_expect_presentation(enemy, bar, null, "Before authoritative lethal hit")
	var result := enemy.apply_combat_damage(_damage_request(1))
	_expect(result.accepted and result.lethal, "Authoritative lethal hit is accepted")
	_expect(enemy.is_dead and enemy.current_health == 0, "Lethal hit settles death and zero health")
	_expect_presentation(enemy, bar, null, "Authoritative lethal hit")
	tested_lethal_cases += 1
	enemy.free()


func _damage_request(amount: int) -> DamageRequest:
	var request := DamageRequest.new(amount)
	request.with_flag(CombatTypes.DamageFlag.BYPASS_MITIGATION)
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
	return request


func _expect_presentation(enemy: Enemy, bar: ProgressBar, hud: BossHealthHUD, stage: String) -> void:
	var maximum := enemy.get_runtime_max_health()
	var expected_visible := not enemy.is_dead and enemy.current_health > 0 and enemy.current_health < maximum
	_expect(bar.visible == expected_visible, "%s: world bar visibility" % stage)
	_expect(is_equal_approx(bar.max_value, float(maximum)), "%s: world bar maximum" % stage)
	if not expected_visible:
		_expect_no_frame_tracking(enemy, bar, stage)
	if not enemy.is_dead:
		_expect(is_equal_approx(bar.value, float(enemy.current_health)), "%s: immediate world bar value" % stage)
	if hud != null:
		_expect(hud.health_bar.visible == expected_visible, "%s: boss HUD visibility" % stage)
		_expect(is_equal_approx(hud.health_bar.max_value, float(maximum)), "%s: boss HUD maximum" % stage)
		if not enemy.is_dead:
			_expect(is_equal_approx(hud.health_bar.value, float(enemy.current_health)), "%s: boss HUD value" % stage)


func _expect_no_frame_tracking(enemy: Enemy, bar: ProgressBar, stage: String) -> void:
	for signal_name: StringName in [&"frame_changed", &"animation_changed"]:
		var has_bar_callback := false
		for connection: Dictionary in enemy.animated_sprite.get_signal_connection_list(signal_name):
			var callback: Callable = connection["callable"]
			if callback.get_object() == bar:
				has_bar_callback = true
		_expect(not has_bar_callback, "%s: hidden bar has no %s callback" % [stage, signal_name])


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if condition:
		return
	failures += 1
	push_error("ENEMY_HEALTH_BARS: %s: %s" % [current_case, description])
