extends RefCounted
class_name ExplosionAudioLimiter

const SPATIAL_VOICE_LIMITER := preload("res://scene/spatial_audio_voice_limiter.gd")
const EXPLOSION_AUDIO_GROUP := &"limited_explosion_audio_players"
const ENEMY_HIT_AUDIO_GROUP := &"limited_enemy_hit_audio_players"
const ENEMY_DEATH_AUDIO_GROUP := &"limited_enemy_death_audio_players"
const BASE_VOLUME_META := &"base_explosion_volume_db"
const MAX_SIMULTANEOUS_EXPLOSIONS := 6
const STACK_ATTENUATION_DB := 4.0
const MAX_STACK_ATTENUATION_DB := 18.0
const MAX_SIMULTANEOUS_ENEMY_HITS := 5
const ENEMY_HIT_STACK_ATTENUATION_DB := 5.0
const ENEMY_HIT_MAX_STACK_ATTENUATION_DB := 20.0
const MAX_SIMULTANEOUS_ENEMY_DEATHS := 4
const ENEMY_DEATH_STACK_ATTENUATION_DB := 4.0
const ENEMY_DEATH_MAX_STACK_ATTENUATION_DB := 16.0


static func play(audio_player: AudioStreamPlayer2D) -> void:
	_play_limited_audio(
		audio_player,
		EXPLOSION_AUDIO_GROUP,
		MAX_SIMULTANEOUS_EXPLOSIONS,
		STACK_ATTENUATION_DB,
		MAX_STACK_ATTENUATION_DB
	)


static func play_enemy_hit(audio_player: AudioStreamPlayer2D) -> void:
	_play_limited_audio(
		audio_player,
		ENEMY_HIT_AUDIO_GROUP,
		MAX_SIMULTANEOUS_ENEMY_HITS,
		ENEMY_HIT_STACK_ATTENUATION_DB,
		ENEMY_HIT_MAX_STACK_ATTENUATION_DB
	)


static func play_enemy_death(audio_player: AudioStreamPlayer2D) -> void:
	_play_limited_audio(
		audio_player,
		ENEMY_DEATH_AUDIO_GROUP,
		MAX_SIMULTANEOUS_ENEMY_DEATHS,
		ENEMY_DEATH_STACK_ATTENUATION_DB,
		ENEMY_DEATH_MAX_STACK_ATTENUATION_DB
	)


static func _play_limited_audio(
	audio_player: AudioStreamPlayer2D,
	audio_group: StringName,
	max_simultaneous_count: int,
	stack_attenuation_db: float,
	max_stack_attenuation_db: float
) -> void:
	if audio_player == null:
		return

	var tree := audio_player.get_tree()
	if tree == null:
		audio_player.play()
		return

	var active_count := SPATIAL_VOICE_LIMITER.claim_voice(
		audio_player,
		audio_group,
		max_simultaneous_count
	)
	if active_count == SPATIAL_VOICE_LIMITER.REJECTED_ACTIVE_COUNT:
		return

	if not audio_player.is_in_group(audio_group):
		audio_player.add_to_group(audio_group)
	var finished_callback := _on_limited_audio_finished.bind(audio_player, audio_group)
	if not audio_player.finished.is_connected(finished_callback):
		audio_player.finished.connect(finished_callback)

	var base_volume_db := audio_player.volume_db
	if audio_player.has_meta(BASE_VOLUME_META):
		base_volume_db = float(audio_player.get_meta(BASE_VOLUME_META))
	else:
		audio_player.set_meta(BASE_VOLUME_META, base_volume_db)

	var attenuation_db := minf(
		float(active_count) * stack_attenuation_db,
		max_stack_attenuation_db
	)
	audio_player.volume_db = base_volume_db - attenuation_db
	audio_player.play()
	if not audio_player.playing:
		_remove_audio_player_from_group(audio_player, audio_group)


static func _count_active_explosion_players(tree: SceneTree) -> int:
	return _count_active_audio_players(tree, EXPLOSION_AUDIO_GROUP)


static func _count_active_audio_players(tree: SceneTree, audio_group: StringName) -> int:
	var active_count := 0
	for node in tree.get_nodes_in_group(audio_group):
		var audio_player := node as AudioStreamPlayer2D
		if audio_player == null:
			node.remove_from_group(audio_group)
			continue
		if not is_instance_valid(audio_player):
			continue
		if not audio_player.playing:
			_remove_audio_player_from_group(audio_player, audio_group)
			continue
		active_count += 1
	return active_count


static func _on_limited_audio_finished(
	audio_player: AudioStreamPlayer2D,
	audio_group: StringName
) -> void:
	# AudioStreamPlayer2D emits finished whenever any one of its playback
	# streams ends. Keep the logical voice while a replay/overlapping stream is
	# still active; the persistent connection releases it after the final one.
	if is_instance_valid(audio_player) and audio_player.playing:
		return
	_remove_audio_player_from_group(audio_player, audio_group)


static func _remove_audio_player_from_group(
	audio_player: AudioStreamPlayer2D,
	audio_group: StringName
) -> void:
	if not is_instance_valid(audio_player):
		return
	if audio_player.is_in_group(audio_group):
		audio_player.remove_from_group(audio_group)
