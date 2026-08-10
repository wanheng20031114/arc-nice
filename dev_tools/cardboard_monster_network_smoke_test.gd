extends SceneTree

const CARDBOARD_SCENE := preload(
	"res://scene/enemy/artificial_creation/cardboard_monster.tscn"
)
const CARDBOARD_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CardboardMonsterNetworkSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", 100)
	player.max_health = 100
	player.current_health = 100
	player.health_bar.setup(player.max_health, player.current_health)

	var proxy := CARDBOARD_SCENE.instantiate() as CardboardMonster
	test_root.add_child(proxy)
	proxy.setup(CARDBOARD_CONFIG, player)
	proxy.configure_multiplayer_proxy()
	await physics_frame

	_expect(proxy.is_multiplayer_proxy, "Cardboard proxy flag must be enabled.")
	_expect(not proxy.is_physics_processing(), "Proxy must not run authoritative physics.")
	_expect(proxy.collision_mask == 0, "Proxy body collision mask must be disabled.")
	_expect(not proxy.touch_damage_area.monitoring, "Proxy touch area monitoring must be disabled.")
	_expect(player.current_health == 100, "Proxy must never deal touch damage.")

	var health_before := proxy.current_health
	var proxy_result := proxy.apply_combat_damage(
		DamageRequest.new(100, int(EnemyConfig.DamageType.PHYSICAL))
	)
	_expect(not proxy_result.accepted and proxy.current_health == health_before, "Proxy must reject local incoming damage.")

	proxy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(proxy.latest_proxy_action_id == 1, "Proxy windup action id must advance.")
	_expect(proxy.animated_sprite.animation == &"windup", "Proxy windup must play the configured animation.")
	_expect(not proxy.animated_sprite.flip_h, "Right proxy windup must face right.")
	_expect(proxy.windup_warning.visible, "Proxy windup warning must appear.")

	proxy.play_multiplayer_enemy_action(&"windup", Vector2.LEFT, 2)
	await process_frame
	_expect(proxy.latest_proxy_action_id == 2, "Newer proxy windup action must advance.")
	_expect(proxy.animated_sprite.flip_h, "Left proxy windup must mirror the right-authored sprite.")
	_expect(is_equal_approx(absf(proxy.windup_warning.rotation), PI), "Left proxy warning must rotate left.")

	proxy.play_multiplayer_enemy_action(&"slash", Vector2.LEFT, 3)
	await process_frame
	_expect(proxy.latest_proxy_action_id == 3, "Proxy slash action id must advance.")
	_expect(proxy.animated_sprite.animation == &"slash", "Proxy slash must play the configured animation.")
	_expect(proxy.animated_sprite.flip_h, "Left proxy slash must retain locked facing.")
	_expect(not proxy.windup_warning.visible, "Proxy slash must clear the windup warning.")
	_expect(player.current_health == 100, "Proxy slash presentation must not apply damage.")

	proxy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 2)
	await process_frame
	_expect(proxy.latest_proxy_action_id == 3, "Duplicate/out-of-order action must be ignored.")
	_expect(proxy.animated_sprite.animation == &"slash" and proxy.animated_sprite.flip_h, "Ignored action must not rewind animation or facing.")

	proxy.play_multiplayer_death_sequence()
	await process_frame
	_expect(not proxy.windup_warning.visible, "Proxy death must clear the warning.")
	var action_id_after_death := proxy.latest_proxy_action_id
	proxy.play_multiplayer_enemy_action(&"slash", Vector2.RIGHT, action_id_after_death)
	await process_frame
	_expect(proxy.latest_proxy_action_id == action_id_after_death, "Death/stale action ordering must remain monotonic.")
	_expect(player.current_health == 100, "Dead proxy must remain presentation-only.")

	proxy.queue_free()
	player.queue_free()
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("CARDBOARD_MONSTER_NETWORK_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
