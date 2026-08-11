extends SceneTree

const LARGE_SCENE := preload(
	"res://scene/enemy/artificial_creation/cardboard_monster_large.tscn"
)
const LARGE_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster_large.tres"
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
	test_root.name = "CardboardMonsterLargeNetworkSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", 200)
	player.max_health = 200
	player.current_health = 200
	player.health_bar.setup(player.max_health, player.current_health)

	var proxy := LARGE_SCENE.instantiate() as CardboardMonsterLarge
	test_root.add_child(proxy)
	proxy.setup(LARGE_CONFIG, player)
	proxy.configure_multiplayer_proxy()
	await physics_frame

	_expect(proxy is CardboardMonster, "Large proxy must retain CardboardMonster inheritance.")
	_expect(proxy.is_multiplayer_proxy, "Large proxy flag must be enabled.")
	_expect(not proxy.is_physics_processing(), "Large proxy must not run authoritative physics.")
	_expect(proxy.collision_mask == 0, "Large proxy body collision mask must be disabled.")
	_expect(not proxy.touch_damage_area.monitoring, "Large proxy touch monitoring must be disabled.")
	_expect(player.current_health == 200, "Large proxy must never deal touch damage.")
	_expect(proxy.call("_get_slash_damage_source_type") == &"cardboard_monster_large_slash", "Large slash source claim mismatch.")
	var profile := proxy.call("_create_damage_target_profile") as DamageTargetProfile
	_expect(profile != null and is_equal_approx(profile.fixed_damage_per_accepted_hit, 1.0), "Large proxy class must retain the fixed-hit profile contract.")

	var health_before := proxy.current_health
	var proxy_result := proxy.apply_combat_damage(
		DamageRequest.new(999, CombatTypes.DamageType.PHYSICAL)
	)
	_expect(not proxy_result.accepted and proxy_result.applied_damage == 0 and proxy.current_health == health_before, "Large proxy must reject local incoming damage.")

	proxy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(proxy.latest_proxy_action_id == 1, "Large proxy windup action id must advance.")
	_expect(proxy.animated_sprite.animation == &"windup", "Large proxy windup must play windup animation.")
	_expect(not proxy.animated_sprite.flip_h, "Right large proxy windup must face right.")
	_expect(proxy.windup_warning.visible, "Large proxy windup warning must appear.")

	proxy.play_multiplayer_enemy_action(&"windup", Vector2.LEFT, 2)
	await process_frame
	_expect(proxy.latest_proxy_action_id == 2, "Newer large proxy windup must advance.")
	_expect(proxy.animated_sprite.flip_h, "New large proxy action must correct facing left.")
	_expect(is_equal_approx(absf(proxy.windup_warning.rotation), PI), "Left large proxy warning must rotate left.")

	proxy.play_multiplayer_enemy_action(&"slash", Vector2.LEFT, 3)
	await process_frame
	_expect(proxy.latest_proxy_action_id == 3, "Large proxy slash id must advance.")
	_expect(proxy.animated_sprite.animation == &"slash", "Large proxy slash must play slash animation.")
	_expect(proxy.animated_sprite.flip_h, "Large proxy slash must retain the action's locked facing.")
	_expect(not proxy.windup_warning.visible, "Large proxy slash must clear windup warning.")
	_expect(player.current_health == 200, "Large proxy slash presentation must not apply damage.")

	proxy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 2)
	await process_frame
	_expect(proxy.latest_proxy_action_id == 3, "Duplicate/out-of-order large action must be ignored.")
	_expect(proxy.animated_sprite.animation == &"slash" and proxy.animated_sprite.flip_h, "Ignored action must not rewind animation/facing.")

	proxy.play_multiplayer_death_sequence()
	await process_frame
	_expect(not proxy.windup_warning.visible, "Large proxy death must clear warning.")
	var action_id_after_death := proxy.latest_proxy_action_id
	proxy.play_multiplayer_enemy_action(&"slash", Vector2.RIGHT, action_id_after_death)
	await process_frame
	_expect(proxy.latest_proxy_action_id == action_id_after_death, "Death/stale large action ordering must remain monotonic.")
	_expect(player.current_health == 200, "Dead large proxy must remain presentation-only.")

	proxy.queue_free()
	player.queue_free()
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("CARDBOARD_MONSTER_LARGE_NETWORK_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
