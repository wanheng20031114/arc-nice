extends SceneTree

const PLAYER_SCENES: Array[PackedScene] = [
	preload("res://scene/player/weishidaier/player_weishidaier.tscn"),
	preload("res://scene/player/tiyi/player_tiyi.tscn"),
	preload("res://scene/player/hoe_cat/player_hoe_cat.tscn"),
	preload("res://scene/player/tango/player_tango.tscn"),
]
const CHARACTER_NAMES: Array[String] = ["Weishidaier", "Tiyi", "HoeCat", "Tango"]

var failures: Array[String] = []
var test_root: Node2D = null
var players: Array[Player] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerDeathAnimationSmokeRoot"
	root.add_child(test_root)
	current_scene = test_root

	for index in PLAYER_SCENES.size():
		var player := PLAYER_SCENES[index].instantiate() as Player
		_expect(player != null, "%s scene must instantiate as Player." % CHARACTER_NAMES[index])
		if player == null:
			continue
		test_root.add_child(player)
		players.append(player)

	await process_frame
	await physics_frame
	for index in players.size():
		var player := players[index]
		player.set_physics_process(false)
		_stop_audio_players(player)
		player.death_audio.stream = null
		player.configure_multiplayer_control(index + 1, false, CHARACTER_NAMES[index])

	await _test_plain_multiplayer_death()
	await _test_tower_defense_death_presentation()
	await _test_revive_before_death_animation_finishes()
	await _finish()


func _test_plain_multiplayer_death() -> void:
	for index in players.size():
		var player := players[index]
		var body := player.body_sprite
		var label := CHARACTER_NAMES[index]
		_expect(player.plays_multiplayer_death_animation(), "%s must opt into its authored death animation." % label)
		player.apply_multiplayer_death_state()
		_expect(player.is_dead and player.controls_locked, "%s must enter a locked dead state." % label)
		_expect(
			body.visible and body.animation == &"death" and body.is_playing(),
			"%s multiplayer death must start the authored non-looping death animation." % label
		)
	await create_timer(0.72).timeout
	for index in players.size():
		var player := players[index]
		var body := player.body_sprite
		_expect(
			body.visible and body.animation == &"death" and not body.is_playing(),
			"%s non-tower death must retain the settled final death pose." % CHARACTER_NAMES[index]
		)
		player.revive_multiplayer(Vector2(index * 8.0, 0.0), player.max_health, 0.0)
	await physics_frame


func _test_tower_defense_death_presentation() -> void:
	for index in players.size():
		var player := players[index]
		var body := player.body_sprite
		var label := CHARACTER_NAMES[index]
		player.apply_multiplayer_death_state()
		player.apply_tower_defense_death_presentation()
		_expect(
			body.visible and body.animation == &"death" and body.is_playing(),
			"%s tower-defense death must remain visible until the animation finishes." % label
		)
		_expect(not player.health_bar.visible, "%s tower-defense death must hide its health bar immediately." % label)

	# A same-frame replay check can pass even when the implementation restarts the
	# animation, because both samples are still frame zero. Let the authored death
	# animations advance before applying the repeated network snapshot.
	await create_timer(0.16).timeout
	for index in players.size():
		var player := players[index]
		var body := player.body_sprite
		var label := CHARACTER_NAMES[index]
		_expect(
			body.frame > 0 or body.frame_progress > 0.01,
			"%s tower-defense death animation must advance before the replay guard is tested." % label
		)
		var frame_before_repeat := body.frame
		var progress_before_repeat := body.frame_progress
		player.apply_multiplayer_death_state()
		_expect(
			body.visible
			and body.animation == &"death"
			and body.frame == frame_before_repeat
			and is_equal_approx(body.frame_progress, progress_before_repeat),
			"%s repeated death snapshots must neither hide nor restart an active death animation." % label
		)
	await physics_frame
	for index in players.size():
		var player := players[index]
		_expect(player.collision_shape.disabled, "%s tower-defense death must disable collision immediately." % CHARACTER_NAMES[index])
	await create_timer(0.72).timeout
	for index in players.size():
		var player := players[index]
		var body := player.body_sprite
		var settled_frame := body.frame
		var settled_progress := body.frame_progress
		_expect(
			not body.visible and not body.is_playing(),
			"%s tower-defense corpse must hide only after death animation completion." % CHARACTER_NAMES[index]
		)
		player.apply_multiplayer_death_state()
		_expect(
			not body.visible
			and not body.is_playing()
			and body.frame == settled_frame
			and is_equal_approx(body.frame_progress, settled_progress),
			"%s repeated snapshots must not replay or reveal an already-settled tower-defense corpse."
			% CHARACTER_NAMES[index]
		)
		player.revive_multiplayer(Vector2(index * 8.0, 8.0), player.max_health, 0.0)
	await physics_frame


func _test_revive_before_death_animation_finishes() -> void:
	for index in players.size():
		var player := players[index]
		player.apply_multiplayer_death_state()
		player.apply_tower_defense_death_presentation()
	await create_timer(0.08).timeout
	for index in players.size():
		var player := players[index]
		player.revive_multiplayer(Vector2(index * 8.0, 16.0), player.max_health, 0.0)
		_expect(
			not player.is_dead
			and not player.tower_defense_death_presentation_active
			and player.body_sprite.visible
			and player.body_sprite.animation != &"death",
			"%s revive must atomically replace an unfinished death presentation." % CHARACTER_NAMES[index]
		)
	await create_timer(0.72).timeout
	for index in players.size():
		var player := players[index]
		_expect(
			not player.is_dead and player.body_sprite.visible and player.body_sprite.animation != &"death",
			"%s must not be hidden by a stale death-animation completion after revive." % CHARACTER_NAMES[index]
		)


func _stop_audio_players(node: Node) -> void:
	for child in node.get_children():
		if child is AudioStreamPlayer or child is AudioStreamPlayer2D:
			child.stop()
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if test_root != null and is_instance_valid(test_root):
		test_root.queue_free()
	await process_frame
	if failures.is_empty():
		print("PLAYER_DEATH_ANIMATION_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
