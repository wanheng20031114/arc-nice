extends RefCounted
class_name EnemyAttackAudioLimiter

const SPATIAL_VOICE_LIMITER := preload("res://scene/spatial_audio_voice_limiter.gd")

const RAPID_FIRE_AUDIO_GROUP := &"limited_enemy_rapid_fire_audio_players"
const HEAVY_ATTACK_AUDIO_GROUP := &"limited_enemy_heavy_attack_audio_players"
const BASE_VOLUME_META := &"base_enemy_attack_volume_db"

const MAX_SIMULTANEOUS_RAPID_FIRE_VOICES := 8
const MAX_SIMULTANEOUS_HEAVY_ATTACK_VOICES := 6
const RAPID_FIRE_STACK_ATTENUATION_DB := 2.0
const RAPID_FIRE_MAX_STACK_ATTENUATION_DB := 12.0
const HEAVY_ATTACK_STACK_ATTENUATION_DB := 3.0
const HEAVY_ATTACK_MAX_STACK_ATTENUATION_DB := 15.0

enum AttackAudioClass {
	RAPID_FIRE,
	HEAVY_ATTACK,
}

## Strict A/B switch. Disabling it restores the former direct play() path.
static var limiting_enabled := true

static var play_request_count := 0
static var play_admitted_count := 0
static var play_rejected_count := 0
static var bypassed_request_count := 0
static var rapid_fire_request_count := 0
static var rapid_fire_admitted_count := 0
static var rapid_fire_rejected_count := 0
static var heavy_attack_request_count := 0
static var heavy_attack_admitted_count := 0
static var heavy_attack_rejected_count := 0
static var rapid_fire_active_voice_count := 0
static var heavy_attack_active_voice_count := 0
static var rapid_fire_peak_active_voice_count := 0
static var heavy_attack_peak_active_voice_count := 0
static var peak_active_voice_count := 0


static func play_rapid_fire(audio_player: AudioStreamPlayer2D) -> bool:
	return _play_limited_audio(audio_player, AttackAudioClass.RAPID_FIRE)


static func play_heavy_attack(audio_player: AudioStreamPlayer2D) -> bool:
	return _play_limited_audio(audio_player, AttackAudioClass.HEAVY_ATTACK)


static func reset_metrics() -> void:
	play_request_count = 0
	play_admitted_count = 0
	play_rejected_count = 0
	bypassed_request_count = 0
	rapid_fire_request_count = 0
	rapid_fire_admitted_count = 0
	rapid_fire_rejected_count = 0
	heavy_attack_request_count = 0
	heavy_attack_admitted_count = 0
	heavy_attack_rejected_count = 0
	rapid_fire_active_voice_count = 0
	heavy_attack_active_voice_count = 0
	rapid_fire_peak_active_voice_count = 0
	heavy_attack_peak_active_voice_count = 0
	peak_active_voice_count = 0


static func get_metrics() -> Dictionary:
	return {
		&"requests": play_request_count,
		&"admitted": play_admitted_count,
		&"rejected": play_rejected_count,
		&"bypassed": bypassed_request_count,
		&"rapid_requests": rapid_fire_request_count,
		&"rapid_admitted": rapid_fire_admitted_count,
		&"rapid_rejected": rapid_fire_rejected_count,
		&"heavy_requests": heavy_attack_request_count,
		&"heavy_admitted": heavy_attack_admitted_count,
		&"heavy_rejected": heavy_attack_rejected_count,
		&"rapid_active": rapid_fire_active_voice_count,
		&"heavy_active": heavy_attack_active_voice_count,
		&"rapid_peak": rapid_fire_peak_active_voice_count,
		&"heavy_peak": heavy_attack_peak_active_voice_count,
		&"peak_active": peak_active_voice_count,
	}


static func get_active_voice_count(
	tree: SceneTree,
	audio_class: AttackAudioClass
) -> int:
	if tree == null:
		return 0
	return _count_active_voices(tree, _get_audio_group(audio_class))


static func _play_limited_audio(
	audio_player: AudioStreamPlayer2D,
	audio_class: AttackAudioClass
) -> bool:
	_record_request(audio_class)
	if audio_player == null:
		_record_rejection(audio_class)
		return false

	if not limiting_enabled:
		bypassed_request_count += 1
		_restore_base_volume(audio_player)
		audio_player.play()
		if audio_player.playing:
			_record_admission(audio_class)
			return true
		_record_rejection(audio_class)
		return false

	if audio_player.stream == null or not audio_player.is_inside_tree():
		_record_rejection(audio_class)
		return false
	var tree := audio_player.get_tree()
	if tree == null:
		_record_rejection(audio_class)
		return false

	var audio_group := _get_audio_group(audio_class)
	var active_count := SPATIAL_VOICE_LIMITER.claim_voice(
		audio_player,
		audio_group,
		_get_voice_cap(audio_class)
	)
	if active_count == SPATIAL_VOICE_LIMITER.REJECTED_ACTIVE_COUNT:
		_record_rejection(audio_class)
		return false

	if not audio_player.is_in_group(audio_group):
		audio_player.add_to_group(audio_group)
	var finished_callback := _on_audio_finished.bind(
		audio_player,
		audio_group,
		audio_class
	)
	if not audio_player.finished.is_connected(finished_callback):
		audio_player.finished.connect(finished_callback)

	var base_volume_db := audio_player.volume_db
	if audio_player.has_meta(BASE_VOLUME_META):
		base_volume_db = float(audio_player.get_meta(BASE_VOLUME_META))
	else:
		audio_player.set_meta(BASE_VOLUME_META, base_volume_db)
	var attenuation_db := minf(
		float(active_count) * _get_stack_attenuation_db(audio_class),
		_get_max_stack_attenuation_db(audio_class)
	)
	audio_player.volume_db = base_volume_db - attenuation_db
	audio_player.play()
	if not audio_player.playing:
		_remove_voice(audio_player, audio_group, audio_class)
		_record_rejection(audio_class)
		return false

	_record_admission(audio_class)
	_update_active_voice_metrics(audio_class, active_count + 1)
	return true


static func _record_request(audio_class: AttackAudioClass) -> void:
	play_request_count += 1
	if audio_class == AttackAudioClass.RAPID_FIRE:
		rapid_fire_request_count += 1
	else:
		heavy_attack_request_count += 1


static func _record_admission(audio_class: AttackAudioClass) -> void:
	play_admitted_count += 1
	if audio_class == AttackAudioClass.RAPID_FIRE:
		rapid_fire_admitted_count += 1
	else:
		heavy_attack_admitted_count += 1


static func _record_rejection(audio_class: AttackAudioClass) -> void:
	play_rejected_count += 1
	if audio_class == AttackAudioClass.RAPID_FIRE:
		rapid_fire_rejected_count += 1
	else:
		heavy_attack_rejected_count += 1


static func _update_active_voice_metrics(
	audio_class: AttackAudioClass,
	active_count: int
) -> void:
	if audio_class == AttackAudioClass.RAPID_FIRE:
		rapid_fire_active_voice_count = active_count
		rapid_fire_peak_active_voice_count = maxi(
			rapid_fire_peak_active_voice_count,
			active_count
		)
	else:
		heavy_attack_active_voice_count = active_count
		heavy_attack_peak_active_voice_count = maxi(
			heavy_attack_peak_active_voice_count,
			active_count
		)
	peak_active_voice_count = maxi(
		peak_active_voice_count,
		rapid_fire_active_voice_count + heavy_attack_active_voice_count
	)


static func _on_audio_finished(
	audio_player: AudioStreamPlayer2D,
	audio_group: StringName,
	audio_class: AttackAudioClass
) -> void:
	# A polyphonic player can report one playback finishing while a replay is
	# still active. Only the final playback releases its shared logical voice.
	if is_instance_valid(audio_player) and audio_player.playing:
		return
	_remove_voice(audio_player, audio_group, audio_class)


static func _remove_voice(
	audio_player: AudioStreamPlayer2D,
	audio_group: StringName,
	audio_class: AttackAudioClass
) -> void:
	var tree: SceneTree = null
	if is_instance_valid(audio_player):
		tree = audio_player.get_tree()
		if audio_player.is_in_group(audio_group):
			audio_player.remove_from_group(audio_group)
	var active_count := _count_active_voices(tree, audio_group) if tree != null else 0
	if audio_class == AttackAudioClass.RAPID_FIRE:
		rapid_fire_active_voice_count = active_count
	else:
		heavy_attack_active_voice_count = active_count


static func _count_active_voices(
	tree: SceneTree,
	audio_group: StringName
) -> int:
	var active_count := 0
	for node in tree.get_nodes_in_group(audio_group):
		var audio_player := node as AudioStreamPlayer2D
		if audio_player == null:
			if is_instance_valid(node):
				node.remove_from_group(audio_group)
			continue
		if not audio_player.playing:
			audio_player.remove_from_group(audio_group)
			continue
		active_count += 1
	return active_count


static func _restore_base_volume(audio_player: AudioStreamPlayer2D) -> void:
	if audio_player.has_meta(BASE_VOLUME_META):
		audio_player.volume_db = float(audio_player.get_meta(BASE_VOLUME_META))


static func _get_audio_group(audio_class: AttackAudioClass) -> StringName:
	return (
		RAPID_FIRE_AUDIO_GROUP
		if audio_class == AttackAudioClass.RAPID_FIRE
		else HEAVY_ATTACK_AUDIO_GROUP
	)


static func _get_voice_cap(audio_class: AttackAudioClass) -> int:
	return (
		MAX_SIMULTANEOUS_RAPID_FIRE_VOICES
		if audio_class == AttackAudioClass.RAPID_FIRE
		else MAX_SIMULTANEOUS_HEAVY_ATTACK_VOICES
	)


static func _get_stack_attenuation_db(audio_class: AttackAudioClass) -> float:
	return (
		RAPID_FIRE_STACK_ATTENUATION_DB
		if audio_class == AttackAudioClass.RAPID_FIRE
		else HEAVY_ATTACK_STACK_ATTENUATION_DB
	)


static func _get_max_stack_attenuation_db(audio_class: AttackAudioClass) -> float:
	return (
		RAPID_FIRE_MAX_STACK_ATTENUATION_DB
		if audio_class == AttackAudioClass.RAPID_FIRE
		else HEAVY_ATTACK_MAX_STACK_ATTENUATION_DB
	)
