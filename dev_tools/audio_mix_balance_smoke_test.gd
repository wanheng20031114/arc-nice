extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const ENEMY_BASE_SCENE := preload("res://scene/enemy/enemy.tscn")
const YUANSHI_BOMBER_SCENE := preload("res://scene/enemy/yuanshi_insect_bomber.tscn")
const YUANSHI_PURPLE_BOMBER_SCENE := preload("res://scene/enemy/yuanshi_insect_purple_bomber.tscn")
const YUANSHI_FIRE_RANGED_SCENE := preload("res://scene/enemy/yuanshi_insect_fire_ranged.tscn")
const RPG_EXPLOSION_SCENE := preload("res://scene/enemy/capoo_rpg_explosion.tscn")
const SKILL1_EXPLOSION_SCENE := preload("res://scene/weishidaier_skill1_explosion.tscn")
const MERCHANT_BUBBLE_SCENE := preload("res://scene/merchant_dialogue_bubble.tscn")
const MULTIPLAYER_LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")

const AK_CONFIG := preload("res://resources/config/enemies/capoo_ak47.tres")
const RPG_CONFIG := preload("res://resources/config/enemies/capoo_rpg.tres")
const SMG_CONFIG := preload("res://resources/config/enemies/capoo_smg.tres")
const KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight.tres")
const ELITE_KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight_elite.tres")
const SWORDSMAN_CONFIG := preload("res://resources/config/enemies/capoo_swordsman.tres")
const FIRE_RANGED_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres")
const AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")
const ENEMY_HIT_STREAM := preload("res://resources/audio/cowboy_monsterhit.wav")
const ENEMY_DEATH_STREAM := preload("res://resources/audio/cowboy_monsterdie.wav")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_game_mix()
	await _test_player_mix()
	await _test_enemy_mix()
	await _test_combat_audio_limiter()
	await _test_ui_mix()
	await _test_ui_click_audio()
	_test_attack_stream_contracts()
	await _drain_cleanup_frames()

	if failures.is_empty():
		print("AUDIO_MIX_BALANCE_SMOKE_TEST_OK")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_game_mix() -> void:
	var game := GAME_SCENE.instantiate()
	_expect(game != null, "Game scene must instantiate for audio mix test.")
	if game == null:
		return
	game.set("auto_start_waves", false)
	root.add_child(game)
	await process_frame

	_expect_volume(game, "MusicPlayer", -6.0, "Music bed must sit above the old under-mixed level.")
	_expect(game.get_node_or_null("EnemySpawnAudio") == null, "Enemy spawn audio cue must stay removed.")
	_expect_volume(game, "CountdownAudio", -13.0, "Countdown tick must not overpower combat SFX.")
	_expect_volume(game, "WaveStartAudio", -12.0, "Wave start cue must sit below explosion peaks.")

	_stop_audio_players(game)
	game.queue_free()
	await _drain_cleanup_frames()


func _test_player_mix() -> void:
	var player := PLAYER_SCENE.instantiate()
	_expect(player != null, "Player scene must instantiate for audio mix test.")
	if player == null:
		return
	root.add_child(player)
	await process_frame

	_expect_volume(player, "GunshotAudio", -2.0, "Primary gunshot mix must stay clear for repeated fire.")
	_expect_volume(player, "GunloadAudio", -8.0, "Gunload cue must sit behind gunfire.")
	_expect_volume(player, "FootstepAudio", 6.0, "Footsteps need gain because the source file is very quiet.")
	_expect_volume(player, "DeathAudio", -4.0, "Player death cue must remain prominent but not spike.")
	_expect_volume(player, "PowerupAudio", 6.0, "Powerup cue needs gain because the source file is very quiet.")
	_expect_volume(player, "SecretAudio", -1.0, "Secret cue must remain the loudest reward cue.")
	_expect_volume(player, "XirangPickupAudio", -4.0, "Frequent xirang pickup cue must be audible but restrained.")

	_stop_audio_players(player)
	player.queue_free()
	await _drain_cleanup_frames()


func _test_enemy_mix() -> void:
	var base_enemy := ENEMY_BASE_SCENE.instantiate()
	_expect(base_enemy != null, "Base enemy scene must instantiate for audio mix test.")
	if base_enemy != null:
		_expect_volume(base_enemy, "HitAudio", -6.0, "Enemy hit cue must stay present.")
		_expect_volume(base_enemy, "DeathAudio", -5.0, "Enemy death cue must stay below player death.")
		_stop_audio_players(base_enemy)
		base_enemy.queue_free()
		await _drain_cleanup_frames()

	await _expect_scene_audio_volume(YUANSHI_BOMBER_SCENE, "ExplosionAudio", -9.0, "Yuanshi bomber explosion mix mismatch.")
	await _expect_scene_audio_volume(YUANSHI_PURPLE_BOMBER_SCENE, "ExplosionAudio", -9.0, "Purple bomber explosion mix mismatch.")
	await _expect_scene_audio_volume(RPG_EXPLOSION_SCENE, "ExplosionAudio", -9.0, "RPG explosion mix mismatch.")
	await _expect_scene_audio_volume(SKILL1_EXPLOSION_SCENE, "ExplosionAudio", -9.0, "Skill1 explosion mix mismatch.")
	await _expect_scene_audio_volume(YUANSHI_FIRE_RANGED_SCENE, "AttackAudio", -10.0, "Yuanshi fire attack cue mix mismatch.")


func _test_combat_audio_limiter() -> void:
	var audio_root := Node2D.new()
	root.add_child(audio_root)
	await process_frame

	var hit_players: Array[AudioStreamPlayer2D] = []
	for index in range(7):
		var audio_player := AudioStreamPlayer2D.new()
		audio_player.stream = ENEMY_HIT_STREAM
		audio_player.volume_db = -6.0
		audio_root.add_child(audio_player)
		hit_players.append(audio_player)
		AUDIO_LIMITER.play_enemy_hit(audio_player)
	var active_hits := _count_playing(hit_players)
	_expect(active_hits == 5, "Enemy hit audio limiter must drop excessive simultaneous hit sounds.")
	_expect(
		_float_close(hit_players[1].volume_db, hit_players[0].volume_db - 5.0),
		"Enemy hit audio limiter must attenuate stacked hit sounds."
	)

	for player in hit_players:
		player.stop()
	await _drain_cleanup_frames()

	var death_players: Array[AudioStreamPlayer2D] = []
	for index in range(6):
		var audio_player := AudioStreamPlayer2D.new()
		audio_player.stream = ENEMY_DEATH_STREAM
		audio_player.volume_db = -5.0
		audio_root.add_child(audio_player)
		death_players.append(audio_player)
		AUDIO_LIMITER.play_enemy_death(audio_player)
	_expect(
		_count_playing(death_players) == 4,
		"Enemy death audio limiter must drop excessive simultaneous death sounds."
	)
	_expect(
		_float_close(death_players[1].volume_db, death_players[0].volume_db - 4.0),
		"Enemy death audio limiter must attenuate stacked death sounds."
	)

	_stop_audio_players(audio_root)
	audio_root.queue_free()
	await _drain_cleanup_frames()


func _test_ui_mix() -> void:
	await _expect_scene_audio_volume(MERCHANT_BUBBLE_SCENE, "BlipAudio", 4.0, "Dialogue blip must compensate for the quiet source file.")

	var lobby := MULTIPLAYER_LOBBY_SCENE.instantiate()
	_expect(lobby != null, "Multiplayer lobby must instantiate for typing audio mix test.")
	if lobby == null:
		return
	root.add_child(lobby)
	await process_frame
	var typing_audio := lobby.get_node_or_null("LobbyCenter/UsernamePanel/TypingBlipAudio") as AudioStreamPlayer
	_expect(typing_audio != null, "TypingBlipAudio must exist.")
	if typing_audio != null:
		_expect(_float_close(typing_audio.volume_db, 6.0), "Typing blip must compensate for the quiet source file.")
		_expect(typing_audio.stream is AudioStreamRandomizer, "Typing blip must keep randomized pitch/volume.")
		_expect(typing_audio.max_polyphony == 4, "Typing blip must allow quick overlapping input sounds.")
		_expect(typing_audio.bus == "SFX", "Typing blip must route to the SFX bus.")
		typing_audio.stop()
		typing_audio.stream = null
	_stop_audio_players(lobby)
	lobby.queue_free()
	await _drain_cleanup_frames()


func _test_ui_click_audio() -> void:
	var ui_audio := root.get_node_or_null("UIAudio")
	_expect(ui_audio != null, "UIAudio autoload must exist for global button clicks.")
	if ui_audio == null:
		return
	var click_audio := ui_audio.get_node_or_null("ClickAudio") as AudioStreamPlayer
	_expect(click_audio != null, "UIAudio must own one ClickAudio player.")
	if click_audio == null:
		return
	_expect(_resource_path(click_audio.stream).ends_with("resources/audio/ui/ui_click.wav"), "UI click stream mismatch.")
	_expect(_float_close(click_audio.volume_db, -8.0), "UI click must stay below main interaction SFX.")
	_expect(click_audio.max_polyphony == 6, "UI click must allow quick repeated button presses.")
	_expect(click_audio.bus == "SFX", "UI click must route to the SFX bus.")

	var button := Button.new()
	root.add_child(button)
	await process_frame
	button.pressed.emit()
	await process_frame
	_expect(click_audio.playing, "Button press did not trigger UI click audio.")
	click_audio.stop()
	button.queue_free()
	await _drain_cleanup_frames()


func _test_attack_stream_contracts() -> void:
	_expect(AK_CONFIG.attack_audio_stream != null, "AK attack stream must remain configured.")
	_expect(_resource_path(AK_CONFIG.attack_audio_stream).ends_with("capoo_ak47_fire.wav"), "AK must keep its established fire cue.")
	_expect(_resource_path(RPG_CONFIG.attack_audio_stream).ends_with("capoo_rpg_launch.wav"), "RPG must use a dedicated launch cue instead of reusing AK fire.")
	_expect(_resource_path(SMG_CONFIG.attack_audio_stream).ends_with("capoo_smg_fire.wav"), "SMG must use a short dedicated fire cue instead of reusing AK fire.")
	_expect(_resource_path(KNIGHT_CONFIG.attack_audio_stream).ends_with("capoo_sword_slash_heavy.wav"), "Knight must use a heavy slash cue.")
	_expect(_resource_path(ELITE_KNIGHT_CONFIG.attack_audio_stream).ends_with("capoo_sword_slash_heavy.wav"), "Elite knight must use the heavy slash cue.")
	_expect(_resource_path(SWORDSMAN_CONFIG.attack_audio_stream).ends_with("capoo_sword_slash_light.wav"), "Swordsman must use a light slash cue.")
	_expect(FIRE_RANGED_CONFIG.attack_audio_stream != null, "Yuanshi fire attack stream must remain configured.")


func _expect_scene_audio_volume(scene: PackedScene, node_path: NodePath, expected_volume: float, message: String) -> void:
	var instance := scene.instantiate()
	_expect(instance != null, "%s must instantiate for audio mix test." % scene.resource_path)
	if instance == null:
		return
	root.add_child(instance)
	await process_frame
	_expect_volume(instance, node_path, expected_volume, message)
	_stop_audio_players(instance)
	instance.queue_free()
	await _drain_cleanup_frames()


func _expect_volume(root_node: Node, node_path: NodePath, expected_volume: float, message: String) -> void:
	var audio_player := root_node.get_node_or_null(node_path) as AudioStreamPlayer
	var audio_player_2d := root_node.get_node_or_null(node_path) as AudioStreamPlayer2D
	if audio_player == null and audio_player_2d == null:
		_expect(false, "%s is missing." % node_path)
		return
	var actual := audio_player.volume_db if audio_player != null else audio_player_2d.volume_db
	_expect(_float_close(actual, expected_volume), message)


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


func _drain_cleanup_frames() -> void:
	for _frame_index in range(4):
		await process_frame


func _count_playing(players: Array[AudioStreamPlayer2D]) -> int:
	var playing_count := 0
	for player in players:
		if player.playing:
			playing_count += 1
	return playing_count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _float_close(a: float, b: float) -> bool:
	return absf(a - b) <= 0.001


func _resource_path(resource: Resource) -> String:
	return resource.resource_path if resource != null else ""
