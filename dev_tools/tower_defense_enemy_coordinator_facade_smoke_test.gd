extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	game.pending_enemy_config_index = 7
	game.next_multiplayer_enemy_net_id = 43
	game.enemy_retarget_time_left = 0.37
	game.enemy_retarget_sweep_remaining = 19
	game.enemy_retarget_cursor = 5
	game.active_wave_enemy_ids[101] = true
	game.hud_alive_enemy_ids[102] = true
	game.pending_multiplayer_enemy_escape_ids[103] = true

	root.add_child(game)
	current_scene = game
	_expect(game.enemy_coordinator.pending_enemy_config_index == 7, "ready 前 queue cursor 被吞掉。")
	_expect(game.enemy_coordinator.next_multiplayer_enemy_net_id == 43, "ready 前 net id 被吞掉。")
	_expect(is_equal_approx(game.enemy_coordinator.enemy_retarget_time_left, 0.37), "ready 前 retarget timer 被吞掉。")
	_expect(game.enemy_coordinator.enemy_retarget_sweep_remaining == 19, "ready 前 retarget sweep 被吞掉。")
	_expect(game.enemy_coordinator.enemy_retarget_cursor == 5, "ready 前 retarget cursor 被吞掉。")
	_expect(game.enemy_coordinator.has_active_enemy(101), "active id façade 没有共享同一 Dictionary。")
	_expect(game.enemy_coordinator.hud_enemy_count() == 1, "HUD id façade 没有共享同一 Dictionary。")
	_expect(game.enemy_coordinator.consume_pending_escape(103), "escape id façade 没有共享同一 Dictionary。")
	await process_frame

	game.pending_enemy_config_index = 11
	game.next_multiplayer_enemy_net_id = 47
	game.enemy_retarget_cursor = 9
	_expect(game.enemy_coordinator.pending_enemy_config_index == 11, "ready 后 queue cursor setter 未转发。")
	_expect(game.enemy_coordinator.next_multiplayer_enemy_net_id == 47, "ready 后 net id setter 未转发。")
	_expect(game.enemy_coordinator.enemy_retarget_cursor == 9, "ready 后 retarget setter 未转发。")

	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_ENEMY_COORDINATOR_FACADE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
