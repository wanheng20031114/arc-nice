extends SceneTree

const PLAYER_SCENES: Array[PackedScene] = [
	preload("res://scene/player/weishidaier/player_weishidaier.tscn"),
	preload("res://scene/player/tiyi/player_tiyi.tscn"),
	preload("res://scene/player/hoe_cat/player_hoe_cat.tscn"),
	preload("res://scene/player/tango/player_tango.tscn"),
]
const TOWER_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)


class TestGrassTerrain extends DualGridTilemap:
	func is_world_position_plantable(world_position: Vector2) -> bool:
		return world_position.x < 0.0


var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_authored_tower_scene_contract()
	await _test_all_player_particle_contracts()
	await _test_grass_healing_contracts()
	_finish()


func _test_authored_tower_scene_contract() -> void:
	var file := FileAccess.open(TOWER_SCENE_PATH, FileAccess.READ)
	_expect(file != null, "必须能够读取正式塔防场景。")
	if file == null:
		return
	var source := file.get_as_text()
	_expect(
		source.contains(
			"path=\"res://scene/game_modes/tower_defense/player/"
			+ "grass_healing_coordinator.gd\""
		)
		and source.contains(
			"[node name=\"GrassHealingCoordinator\" type=\"Node\" parent=\".\""
		)
		and source.contains("terrain_map = NodePath(\"../DualGridTerrain\")")
		and source.contains(
			"player_roster_coordinator = NodePath("
			+ "\"../PlayerRosterCoordinator\")"
		),
		"塔防场景必须静态预置并完整绑定草地回血协调器。"
	)


func _test_all_player_particle_contracts() -> void:
	for scene_index in PLAYER_SCENES.size():
		var player := PLAYER_SCENES[scene_index].instantiate() as Player
		_expect(player != null, "第%d个角色场景必须能够实例化。" % (scene_index + 1))
		if player == null:
			continue
		player.name = "GrassParticlePlayer%d" % scene_index
		root.add_child(player)
		await process_frame
		var particles := player.get_node_or_null(
			"BodySprite/GrassHealingParticles"
		) as GPUParticles2D
		var material := (
			particles.process_material as ParticleProcessMaterial
			if particles != null
			else null
		)
		_expect(
			particles != null
			and particles.get_parent() == player.body_sprite
			and not particles.visible
			and not particles.emitting
			and particles.amount == 16
			and is_equal_approx(particles.lifetime, 0.8)
			and is_equal_approx(particles.speed_scale, 0.5)
			and particles.visibility_rect
			== Rect2(-5.5, -2.5, 11.0, 3.5)
			and material != null
			and material.emission_shape
			== ParticleProcessMaterial.EMISSION_SHAPE_BOX
			and material.emission_box_extents
			== Vector3(4.75, 0.5, 1.0)
			and material.direction == Vector3(0.0, -1.0, 0.0)
			and material.color.is_equal_approx(
				Color(0.741, 1.0, 0.278, 0.9)
			),
			"四个角色都必须在BodySprite下静态复用植被桩同款绿色上浮粒子。"
		)
		_stop_audio_players(player)
		player.queue_free()
		await process_frame


func _test_grass_healing_contracts() -> void:
	var player := PLAYER_SCENES[0].instantiate() as Player
	var terrain := TestGrassTerrain.new()
	var roster := TowerDefensePlayerRosterCoordinator.new()
	var coordinator := GrassHealingCoordinator.new()
	_expect(player != null, "测试角色必须能够实例化。")
	if player == null:
		return
	player.name = "GrassHealingPlayer"
	roster.local_player = player
	coordinator.terrain_map = terrain
	coordinator.player_roster_coordinator = roster
	root.add_child(terrain)
	root.add_child(roster)
	root.add_child(player)
	root.add_child(coordinator)
	await process_frame
	coordinator.set_physics_process(false)

	player.global_position = Vector2(-10.0, 0.0)
	player.max_health = 101
	player.current_health = 1
	player.health_bar.set_health(1, 101)
	coordinator.advance_grass_healing(0.5)
	_expect(
		player.current_health == 1
		and player.grass_healing_particles.visible
		and player.grass_healing_particles.emitting,
		"站上草块不足一秒时不能提前回血，但必须立即显示植被桩同款粒子。"
	)
	coordinator.advance_grass_healing(0.5)
	_expect(
		player.current_health == 22,
		"101点生命上限在草块站满一秒必须向上取整恢复21点（20%）。"
	)

	player.global_position = Vector2(10.0, 0.0)
	coordinator.advance_grass_healing(0.75)
	_expect(
		player.current_health == 22
		and not player.grass_healing_particles.visible
		and not player.grass_healing_particles.emitting,
		"离开草块必须立即停用粒子、停止回血并清空本轮站立计时。"
	)
	player.global_position = Vector2(-10.0, 0.0)
	coordinator.advance_grass_healing(0.25)
	_expect(player.current_health == 22, "重新踏上草块必须重新累计完整一秒。")

	roster.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	player.current_health = 1
	coordinator.advance_grass_healing(1.0)
	_expect(
		player.current_health == 1
		and player.grass_healing_particles.emitting,
		"客户端视图只可显示草地粒子，不得自行修改玩家生命。"
	)
	roster.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER

	player.is_dead = true
	coordinator.advance_grass_healing(1.0)
	_expect(
		player.current_health == 1
		and not player.grass_healing_particles.emitting,
		"死亡玩家即使位于草块也不能回血或继续发射粒子。"
	)

	_stop_audio_players(player)
	coordinator.queue_free()
	player.queue_free()
	roster.queue_free()
	terrain.queue_free()
	await process_frame
	await process_frame


func _stop_audio_players(node: Node) -> void:
	for audio in node.find_children("*", "AudioStreamPlayer", true, false):
		(audio as AudioStreamPlayer).stop()
	for audio in node.find_children("*", "AudioStreamPlayer2D", true, false):
		(audio as AudioStreamPlayer2D).stop()
	for audio in node.find_children("*", "AudioStreamPlayer3D", true, false):
		(audio as AudioStreamPlayer3D).stop()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("GRASS_HEALING_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
