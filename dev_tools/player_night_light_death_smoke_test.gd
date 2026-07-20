extends SceneTree

const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const PLAYER_SCENES: Array[PackedScene] = [
	preload("res://scene/player/weishidaier/player_weishidaier.tscn"),
	preload("res://scene/player/tiyi/player_tiyi.tscn"),
	preload("res://scene/player/hoe_cat/player_hoe_cat.tscn"),
]
const CHARACTER_LABELS: Array[String] = [
	"Weishidaier",
	"Tiyi",
	"HoeCat",
]

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node2D.new()
	test_root.name = "PlayerNightLightDeathSmokeRoot"
	root.add_child(test_root)
	current_scene = test_root

	var day_night_controller := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
	test_root.add_child(day_night_controller)

	var players: Array[Player] = []
	for player_scene in PLAYER_SCENES:
		var player := player_scene.instantiate() as Player
		_expect(player != null, "玩家场景必须能实例化为Player。")
		if player == null:
			continue
		test_root.add_child(player)
		players.append(player)

	await process_frame
	await physics_frame
	day_night_controller.set_night_factor_immediate(1.0)
	await process_frame

	for player_index in range(players.size()):
		var player := players[player_index]
		var label := CHARACTER_LABELS[player_index]
		player.set_physics_process(false)
		_stop_audio_players(player)
		player.death_audio.stream = null

		_expect_light_on(player, "%s 初始夜间状态" % label)

		player.call("_die")
		_expect(
			player.is_dead,
			"%s 单机死亡路径必须进入死亡状态。" % label
		)
		_expect_light_off(player, "%s 单机死亡路径" % label)
		player.apply_tower_defense_death_presentation()
		_expect_light_off(player, "%s 塔防尸体隐藏路径" % label)

		player.revive_multiplayer(
			Vector2(player_index * 8.0, 8.0),
			player.max_health,
			0.0
		)
		_expect(not player.is_dead, "%s 单机复活必须恢复存活状态。" % label)
		_expect_light_on(player, "%s 单机复活路径" % label)

		player.configure_multiplayer_control(
			player_index + 1,
			false,
			label
		)
		player.apply_multiplayer_death_state()
		_expect(
			player.is_dead,
			"%s 多人副本死亡路径必须进入死亡状态。" % label
		)
		_expect_light_off(player, "%s 多人副本死亡路径" % label)

		player.apply_multiplayer_death_state()
		_expect_light_off(player, "%s 重复死亡快照路径" % label)

		player.revive_multiplayer(
			Vector2(player_index * 8.0, 16.0),
			player.max_health,
			0.0
		)
		_expect(not player.is_dead, "%s 多人复活必须恢复存活状态。" % label)
		_expect_light_on(player, "%s 多人复活路径" % label)

	test_root.queue_free()
	await process_frame
	current_scene = null
	if failures.is_empty():
		print("PLAYER_NIGHT_LIGHT_DEATH_SMOKE_TEST_PASSED")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect_light_on(player: Player, context: String) -> void:
	var light := player.night_light
	_expect(
		light != null
		and light.is_emission_allowed()
		and light.enabled
		and is_equal_approx(light.energy, light.night_energy),
		"%s：玩家夜灯必须在满夜正常发光。" % context
	)


func _expect_light_off(player: Player, context: String) -> void:
	var light := player.night_light
	_expect(
		light != null
		and not light.is_emission_allowed()
		and not light.enabled
		and is_zero_approx(light.energy),
		"%s：玩家夜灯必须立即关闭且能量归零。" % context
	)


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
