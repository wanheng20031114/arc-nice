extends GPUParticles2D
class_name PlantPlacementParticles

const SPATIAL_AUDIO_VOICE_LIMITER := preload(
	"res://scene/combat/audio/spatial_audio_voice_limiter.gd"
)
const FULL_EMISSION_DURATION := 0.7
const EMISSION_FADE_DURATION := 0.9
const PARTICLE_TAIL_DURATION := 0.6
const REMOVAL_STARTED_SIGNAL: StringName = &"removal_started"
const PLACEMENT_AUDIO_GROUP := &"limited_plant_placement_audio_players"
const MAX_SIMULTANEOUS_PLACEMENT_VOICES := 4
const PLACEMENT_STACK_ATTENUATION_DB := 2.5
const MAX_PLACEMENT_STACK_ATTENUATION_DB := 7.5

@onready var placement_audio: AudioStreamPlayer2D = $PlacementAudio

var _effect_tween: Tween = null
var _source: PlantDefense = null
var _effect_active := false
var _placement_audio_base_volume_db := 0.0


func _ready() -> void:
	one_shot = false
	emitting = false
	amount_ratio = 0.0
	_placement_audio_base_volume_db = placement_audio.volume_db


func _exit_tree() -> void:
	# A scene teardown can remove the source plant and the pooled effect in the
	# same frame. The removal callback may have just created its tail Tween, so
	# explicitly kill that RefCounted before this node leaves the tree instead of
	# relying on the 0.6 s completion callback that can no longer run.
	_reset_effect_state()


func on_pool_acquired(_generation: int) -> void:
	_reset_effect_state()


func on_pool_released(_generation: int) -> void:
	_reset_effect_state()


func restart_effect(source: PlantDefense, effect_scale: float) -> void:
	_reset_effect_state()
	_effect_active = true
	if source == null:
		push_error("PlantPlacementParticles requires a source plant.")
		_finish_effect()
		return

	_source = source
	scale = Vector2.ONE * maxf(effect_scale, 0.01)
	_connect_source_removal()

	amount_ratio = 1.0
	restart()
	emitting = true
	_play_placement_audio()

	_effect_tween = create_tween()
	_effect_tween.tween_interval(FULL_EMISSION_DURATION)
	_effect_tween.tween_property(
		self,
		^"amount_ratio",
		0.0,
		EMISSION_FADE_DURATION
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_effect_tween.tween_callback(_stop_emitting)
	_effect_tween.tween_interval(PARTICLE_TAIL_DURATION)
	_effect_tween.finished.connect(_finish_effect)


func _connect_source_removal() -> void:
	var callback := Callable(self, "_on_source_removal_started")
	if not _source.is_connected(REMOVAL_STARTED_SIGNAL, callback):
		_source.connect(REMOVAL_STARTED_SIGNAL, callback)


func _disconnect_source_removal() -> void:
	if _source == null or not is_instance_valid(_source):
		_source = null
		return
	var callback := Callable(self, "_on_source_removal_started")
	if _source.is_connected(REMOVAL_STARTED_SIGNAL, callback):
		_source.disconnect(REMOVAL_STARTED_SIGNAL, callback)
	_source = null


func _on_source_removal_started(mode: int) -> void:
	if not _effect_active:
		return
	_disconnect_source_removal()
	_kill_effect_tween()
	_stop_emitting()
	# Silent removal is used for scene teardown, manifest repair and test cleanup;
	# by definition it must not leave a visual tail (or a SceneTreeTween) behind.
	if mode == PlantDefense.RemovalMode.SILENT:
		_finish_effect()
		return
	_effect_tween = create_tween()
	_effect_tween.tween_interval(PARTICLE_TAIL_DURATION)
	_effect_tween.finished.connect(_finish_effect)


func _stop_emitting() -> void:
	amount_ratio = 0.0
	emitting = false


func _reset_effect_state() -> void:
	_kill_effect_tween()
	_disconnect_source_removal()
	_stop_placement_audio()
	_effect_active = false
	emitting = false
	amount_ratio = 0.0
	scale = Vector2.ONE


func _play_placement_audio(explicit_audio_scope: Node = null) -> void:
	_stop_placement_audio()
	var audio_scope := SPATIAL_AUDIO_VOICE_LIMITER.resolve_audio_scope(
		placement_audio,
		explicit_audio_scope
	)
	var active_voice_count := SPATIAL_AUDIO_VOICE_LIMITER.claim_voice(
		placement_audio,
		audio_scope,
		PLACEMENT_AUDIO_GROUP,
		MAX_SIMULTANEOUS_PLACEMENT_VOICES
	)
	if active_voice_count == SPATIAL_AUDIO_VOICE_LIMITER.REJECTED_ACTIVE_COUNT:
		return
	placement_audio.add_to_group(PLACEMENT_AUDIO_GROUP)
	placement_audio.volume_db = (
		_placement_audio_base_volume_db
		- minf(
			active_voice_count * PLACEMENT_STACK_ATTENUATION_DB,
			MAX_PLACEMENT_STACK_ATTENUATION_DB
		)
	)
	placement_audio.play()
	if not placement_audio.playing:
		_remove_placement_audio_voice()


func _stop_placement_audio() -> void:
	placement_audio.stop()
	placement_audio.volume_db = _placement_audio_base_volume_db
	_remove_placement_audio_voice()


func _on_placement_audio_finished() -> void:
	if placement_audio.playing:
		return
	_remove_placement_audio_voice()


func _remove_placement_audio_voice() -> void:
	SPATIAL_AUDIO_VOICE_LIMITER.release_voice(
		placement_audio,
		PLACEMENT_AUDIO_GROUP
	)


func _kill_effect_tween() -> void:
	if _effect_tween != null and _effect_tween.is_valid():
		_effect_tween.kill()
	_effect_tween = null


func _finish_effect() -> void:
	if not _effect_active:
		return
	_effect_tween = null
	_disconnect_source_removal()
	_effect_active = false
	_stop_emitting()
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()
