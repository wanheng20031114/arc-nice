extends SceneTree

const TIYI_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")
const SNIPER_BULLET_SCENE := preload(
	"res://scene/player/tiyi/tiyi_sniper_bullet.tscn"
)
const HIT_EFFECT_SCENE := preload(
	"res://scene/player/tiyi/tiyi_sniper_hit_effect.tscn"
)

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerTiyiPerformanceSmokeRoot"
	root.add_child(test_root)
	current_scene = test_root

	var players: Array[PlayerTiyi] = []
	for player_index in range(4):
		var player := TIYI_SCENE.instantiate() as PlayerTiyi
		test_root.add_child(player)
		player.global_position = Vector2(-10000.0, -10000.0 - player_index * 64.0)
		player.set_physics_process(false)
		_stop_audio_players(player)
		players.append(player)
	await process_frame
	await physics_frame

	var steady_node_count := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var minimum_steady_nodes := steady_node_count
	var maximum_steady_nodes := steady_node_count
	var started_usec := Time.get_ticks_usec()
	# Equivalent workload: four Tiyi at ten shots/second for thirty seconds.
	for _simulated_second in range(30):
		for player in players:
			for _shot in range(10):
				var bullet := SNIPER_BULLET_SCENE.instantiate() as TiyiSniperBullet
				bullet.setup(Vector2.RIGHT, 100, false)
				bullet.setup_collectible_owner(player)
				test_root.add_child(bullet)
				bullet.global_position = player.global_position
				bullet.set_physics_process(false)
				bullet.call("_physics_process", 0.35)
		await process_frame
		await physics_frame
		_expect(
			_count_transient_tiyi_nodes(test_root) == 0,
			"Expired sniper bullets must be released after every simulated second."
		)
		var current_nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		minimum_steady_nodes = mini(minimum_steady_nodes, current_nodes)
		maximum_steady_nodes = maxi(maximum_steady_nodes, current_nodes)

	# One twenty-target finish burst uses the same dedicated hit effect as bullets.
	for effect_index in range(20):
		var effect := HIT_EFFECT_SCENE.instantiate() as TiyiSniperHitEffect
		effect.setup(Vector2.RIGHT.rotated(float(effect_index) / 20.0 * TAU))
		test_root.add_child(effect)
		effect.global_position = Vector2(effect_index * 4.0, 0.0)
	await create_timer(0.5).timeout
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	_expect(
		_count_transient_tiyi_nodes(test_root) == 0,
		"Sniper bullets and twenty-target hit effects must be gone within one second."
	)
	_expect(
		maximum_steady_nodes - minimum_steady_nodes <= 8,
		"Repeated sniper fire must not cause a continuously growing steady node count."
	)
	var lock_line_source := FileAccess.get_file_as_string(
		"res://scene/player/tiyi/tiyi_high_noon_lock_lines.gd"
	)
	_expect(
		lock_line_source.count("draw_multiline(") == 2,
		"High Noon lock rendering must remain exactly two batched draw_multiline calls."
	)

	var elapsed_msec := float(Time.get_ticks_usec() - started_usec) / 1000.0
	print("TIYI_PERFORMANCE_SMOKE_METRIC_MS=%.3f" % elapsed_msec)
	await _finish()


func _count_transient_tiyi_nodes(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		if child is TiyiSniperBullet or child is TiyiSniperHitEffect:
			count += 1
		count += _count_transient_tiyi_nodes(child)
	return count


func _finish() -> void:
	if test_root != null:
		test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("PLAYER_TIYI_PERFORMANCE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _stop_audio_players(node: Node) -> void:
	for child in node.get_children():
		var audio_player := child as AudioStreamPlayer
		if audio_player != null:
			audio_player.stop()
			audio_player.stream = null
		var audio_player_2d := child as AudioStreamPlayer2D
		if audio_player_2d != null:
			audio_player_2d.stop()
			audio_player_2d.stream = null
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
