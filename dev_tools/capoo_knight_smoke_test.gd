extends SceneTree

const KNIGHT_SCENE := preload("res://scene/capoo_knight.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight.tres")
const WAVES := [
	preload("res://resources/config/waves/wave_05.tres"),
	preload("res://resources/config/waves/wave_06.tres"),
	preload("res://resources/config/waves/wave_07.tres"),
	preload("res://resources/config/waves/wave_08.tres"),
	preload("res://resources/config/waves/wave_09.tres"),
	preload("res://resources/config/waves/wave_10.tres"),
]
const EXPECTED_KNIGHT_COUNTS := [4, 6, 8, 10, 12, 14]
const EXPECTED_WAVE_TOTALS := [140, 150, 160, 180, 195, 210]
var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CapooKnightSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_contract()
	await _test_slash_geometry()
	await _test_windup_delays_damage()
	await _test_death_interrupts_attack()
	await _test_proxy_action_visuals()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("CAPOO_KNIGHT_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(KNIGHT_CONFIG is CapooKnightConfig, "Knight config must use CapooKnightConfig.")
	_expect(KNIGHT_CONFIG.display_name == "骑士猫猫虫", "Display name mismatch.")
	_expect(KNIGHT_CONFIG.enemy_scene_override == KNIGHT_SCENE, "Knight must use its own scene.")
	_expect(KNIGHT_CONFIG.max_health == 200, "Knight health mismatch.")
	_expect(KNIGHT_CONFIG.attack_damage == 28, "Knight slash damage mismatch.")
	_expect(KNIGHT_CONFIG.physical_defense == 20, "Knight physical defense mismatch.")
	_expect(KNIGHT_CONFIG.magic_defense == 0, "Knight magic defense mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.move_speed, 34.0), "Knight move speed mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.collision_radius, 6.5), "Knight collision radius mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.attack_interval, 4.0), "Knight attack interval mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.attack_windup, 0.35), "Knight windup mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.slash_outer_radius, 48.0), "Knight slash outer radius mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.slash_inner_radius, 6.5), "Knight slash inner radius mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.slash_angle_degrees, 60.0), "Knight slash angle mismatch.")
	_expect(KNIGHT_CONFIG.slash_effect_scene != null, "Knight slash effect scene is missing.")

	var texture := load("res://resources/texture/capoo_knight.png") as Texture2D
	var slash_texture := load("res://resources/texture/capoo_knight_slash.png") as Texture2D
	_expect(texture != null and texture.get_size() == Vector2(384, 384), "Knight sprite sheet size is incorrect.")
	_expect(slash_texture != null and slash_texture.get_size() == Vector2(384, 96), "Knight slash sheet size is incorrect.")

	for index in range(WAVES.size()):
		_expect(_count_wave_entries(WAVES[index]) == EXPECTED_KNIGHT_COUNTS[index], "Knight wave count mismatch.")
		_expect(_count_total_wave_entries(WAVES[index]) == EXPECTED_WAVE_TOTALS[index], "Wave total changed unexpectedly.")


func _test_slash_geometry() -> void:
	await _expect_slash_result(Vector2(42.0, 0.0), true, "Knight slash did not hit a target in front.")
	await _expect_slash_result(Vector2(5.0, 0.0), false, "Knight slash hit inside its inner dead zone.")
	await _expect_slash_result(Vector2(52.0, 0.0), false, "Knight slash hit outside its outer radius.")
	await _expect_slash_result(Vector2(36.0, 36.0), false, "Knight slash hit outside its 60-degree arc.")
	await _expect_slash_result(Vector2(-32.0, 0.0), false, "Knight slash hit behind itself.")


func _test_windup_delays_damage() -> void:
	var player := _spawn_player(Vector2(42.0, 0.0))
	var enemy := _spawn_knight(Vector2.ZERO, player)
	await _wait_physics_frames(3)
	_expect(enemy.combat_state == CapooKnight.CombatState.WINDUP, "Knight did not enter windup at melee range.")
	await _wait_physics_frames(10)
	_expect(player.current_health == 100, "Knight dealt damage during early windup.")
	var guard_frames := 0
	while enemy.combat_state == CapooKnight.CombatState.WINDUP:
		await physics_frame
		guard_frames += 1
		if guard_frames > 90:
			_expect(false, "Knight windup did not finish in time.")
			break
	guard_frames = 0
	while enemy.combat_state == CapooKnight.CombatState.SLASH and player.current_health == 100:
		await physics_frame
		guard_frames += 1
		if guard_frames > 90:
			_expect(false, "Knight slash damage did not resolve in time.")
			break
	_expect(player.current_health == 72, "Knight did not deal delayed slash damage.")
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_death_interrupts_attack() -> void:
	var player := _spawn_player(Vector2(42.0, 0.0))
	var enemy := _spawn_knight(Vector2.ZERO, player)
	await _wait_physics_frames(3)
	_expect(enemy.combat_state == CapooKnight.CombatState.WINDUP, "Death test knight did not enter windup.")
	enemy.apply_damage(KNIGHT_CONFIG.max_health + KNIGHT_CONFIG.physical_defense)
	await _wait_physics_frames(45)
	_expect(player.current_health == 100, "Dead knight dealt slash damage after attack interruption.")
	if is_instance_valid(enemy):
		enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_proxy_action_visuals() -> void:
	var player := _spawn_player(Vector2(120.0, 0.0))
	var enemy := _spawn_knight(Vector2.ZERO, player)
	enemy.configure_multiplayer_proxy()
	enemy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(enemy.windup_warning.visible, "Proxy windup warning did not appear.")
	enemy.play_multiplayer_enemy_action(&"slash", Vector2.RIGHT, 2)
	await process_frame
	_expect(_count_slash_effects() > 0, "Proxy slash effect did not spawn.")
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _expect_slash_result(player_position: Vector2, should_hit: bool, message: String) -> void:
	var player := _spawn_player(player_position)
	var enemy := _spawn_knight(Vector2.ZERO, player)
	await _wait_physics_frames(2)
	enemy.slash_direction = Vector2.RIGHT
	enemy.action_sequence = 1
	enemy.call("_apply_slash_damage")
	await physics_frame
	var was_hit := player.current_health == 72
	_expect(was_hit == should_hit, message)
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.current_health = 100
	player.max_health = 100
	return player


func _spawn_knight(position: Vector2, player: Player) -> CapooKnight:
	var enemy := KNIGHT_SCENE.instantiate() as CapooKnight
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(KNIGHT_CONFIG, player)
	return enemy


func _count_wave_entries(wave_config: WaveConfig) -> int:
	var total := 0
	for entry in wave_config.enemy_entries:
		if entry != null and entry.enemy_config == KNIGHT_CONFIG:
			total += entry.count
	return total


func _count_total_wave_entries(wave_config: WaveConfig) -> int:
	var total := 0
	for entry in wave_config.enemy_entries:
		if entry != null:
			total += entry.count
	return total


func _count_slash_effects() -> int:
	var total := 0
	for child in test_root.get_children():
		if child is CapooKnightSlashEffect:
			total += 1
	return total


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)




