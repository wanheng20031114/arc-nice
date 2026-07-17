extends RefCounted
class_name SpatialAudioVoiceLimiter

const REJECTED_ACTIVE_COUNT := -1
const VOICE_PREEMPTED_CALLBACK_META := &"spatial_audio_voice_preempted_callback"


## Reserves one logical AudioStreamPlayer2D voice and returns the number of
## other active voices, which callers can use for stack attenuation. When a
## camera is available, inaudible requests are rejected and a nearer request
## may replace the farthest active voice. Without a camera the original
## first-come behaviour is preserved.
static func claim_voice(
	audio_player: AudioStreamPlayer2D,
	audio_group: StringName,
	max_simultaneous_count: int
) -> int:
	if audio_player == null or max_simultaneous_count <= 0:
		return REJECTED_ACTIVE_COUNT

	var tree := audio_player.get_tree()
	if tree == null:
		return 0

	var viewport := audio_player.get_viewport()
	var camera := viewport.get_camera_2d() if viewport != null else null
	var listener_position := (
		camera.get_screen_center_position()
		if camera != null
		else Vector2.ZERO
	)
	var requested_distance_squared := 0.0
	if camera != null:
		requested_distance_squared = audio_player.global_position.distance_squared_to(
			listener_position
		)
		var audible_distance := maxf(audio_player.max_distance, 0.0)
		if (
			audible_distance > 0.0
			and requested_distance_squared > audible_distance * audible_distance
		):
			return REJECTED_ACTIVE_COUNT

	var active_count := 0
	var farthest_player: AudioStreamPlayer2D = null
	var farthest_distance_squared := -1.0
	for node in tree.get_nodes_in_group(audio_group):
		var active_player := node as AudioStreamPlayer2D
		if active_player == null:
			if is_instance_valid(node):
				node.remove_from_group(audio_group)
			continue
		if not active_player.playing:
			active_player.remove_from_group(audio_group)
			continue
		# Replaying a one-voice player keeps its existing slot instead of
		# consuming another logical voice.
		if active_player == audio_player:
			continue

		active_count += 1
		if camera == null:
			continue
		var active_distance_squared := active_player.global_position.distance_squared_to(
			listener_position
		)
		if active_distance_squared > farthest_distance_squared:
			farthest_distance_squared = active_distance_squared
			farthest_player = active_player

	if active_count < max_simultaneous_count:
		return active_count
	if (
		camera == null
		or farthest_player == null
		or requested_distance_squared >= farthest_distance_squared
	):
		return REJECTED_ACTIVE_COUNT

	# stop() does not emit finished, so release the logical slot explicitly.
	farthest_player.stop()
	farthest_player.remove_from_group(audio_group)
	var preempted_callback: Variant = farthest_player.get_meta(
		VOICE_PREEMPTED_CALLBACK_META,
		Callable()
	)
	if (
		preempted_callback is Callable
		and (preempted_callback as Callable).is_valid()
	):
		(preempted_callback as Callable).call()
	return active_count - 1
