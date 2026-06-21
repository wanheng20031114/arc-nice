extends RefCounted
class_name ExplosionAudioLimiter

const EXPLOSION_AUDIO_GROUP := &"limited_explosion_audio_players"
const BASE_VOLUME_META := &"base_explosion_volume_db"
const MAX_SIMULTANEOUS_EXPLOSIONS := 6
const STACK_ATTENUATION_DB := 4.0
const MAX_STACK_ATTENUATION_DB := 18.0


static func play(audio_player: AudioStreamPlayer2D) -> void:
	if audio_player == null:
		return

	var tree := audio_player.get_tree()
	if tree == null:
		audio_player.play()
		return

	var active_count := _count_active_explosion_players(tree)
	if active_count >= MAX_SIMULTANEOUS_EXPLOSIONS:
		return

	if not audio_player.is_in_group(EXPLOSION_AUDIO_GROUP):
		audio_player.add_to_group(EXPLOSION_AUDIO_GROUP)

	var base_volume_db := audio_player.volume_db
	if audio_player.has_meta(BASE_VOLUME_META):
		base_volume_db = float(audio_player.get_meta(BASE_VOLUME_META))
	else:
		audio_player.set_meta(BASE_VOLUME_META, base_volume_db)

	var attenuation_db := minf(
		float(active_count) * STACK_ATTENUATION_DB,
		MAX_STACK_ATTENUATION_DB
	)
	audio_player.volume_db = base_volume_db - attenuation_db
	audio_player.play()


static func _count_active_explosion_players(tree: SceneTree) -> int:
	var active_count := 0
	for node in tree.get_nodes_in_group(EXPLOSION_AUDIO_GROUP):
		var audio_player := node as AudioStreamPlayer2D
		if audio_player == null:
			continue
		if not is_instance_valid(audio_player):
			continue
		if audio_player.playing:
			active_count += 1
	return active_count
