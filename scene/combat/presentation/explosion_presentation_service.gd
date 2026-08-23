extends Node2D
class_name ExplosionPresentationService

const WORLD_EFFECT_VISIBILITY := preload(
	"res://scene/combat/feedback/world_effect_visibility.gd"
)
const EXPLOSION_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/explosion_audio_limiter.gd"
)
const NIGHT_VFX_FLASH_POOL := preload(
	"res://scene/lighting/night_vfx_flash_pool.gd"
)

enum Profile {
	INVALID,
	CAPOO_RPG,
	CAPOO_MAGE,
}

const VISUAL_CAPACITY := 96
const TOTAL_VISUAL_SLOT_CAPACITY := VISUAL_CAPACITY * 2
const PENDING_CAPACITY := 2048
const AUDIO_VOICE_CAPACITY := 6
const EXPLOSION_FRAME_COUNT := 8
const EXPLOSION_FPS := 14.0
const EXPLOSION_DURATION_SECONDS := float(EXPLOSION_FRAME_COUNT) / EXPLOSION_FPS
const MAGE_IMPACT_FRAME_COUNT := 6
const MAGE_IMPACT_FPS := 32.0
const MAGE_IMPACT_DURATION_SECONDS := (
	float(MAGE_IMPACT_FRAME_COUNT) / MAGE_IMPACT_FPS
)
const VISIBILITY_MARGIN := 64.0
const BASE_AUDIO_VOLUME_DB := -9.0
const MAGE_AUDIO_VOLUME_DB := -7.0

@onready var base_instances: MultiMeshInstance2D = $ExplosionBase
@onready var emission_instances: MultiMeshInstance2D = $ExplosionEmission
@onready var _audio_voices_root: Node2D = $AudioVoices
@onready var mage_base_instances: MultiMeshInstance2D = $MageImpactBase
@onready var mage_emission_instances: MultiMeshInstance2D = $MageImpactEmission
@onready var _mage_audio_voices_root: Node2D = $MageAudioVoices

var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _rpg_audio_voices: Array[AudioStreamPlayer2D] = []
var _mage_audio_voices: Array[AudioStreamPlayer2D] = []
var _slot_active := PackedByteArray()
var _slot_profiles := PackedInt32Array()
var _slot_positions := PackedVector2Array()
var _slot_ages := PackedFloat32Array()
var _active_profile_counts := PackedInt32Array()
var _pending_profiles := PackedInt32Array()
var _pending_positions := PackedVector2Array()
var _pending_elapsed_seconds := PackedFloat32Array()
var _pending_count := 0
var _headless_disabled := false
var _teardown_prepared := false
var _last_visible_count := 0
var _last_rpg_visible_count := 0
var _last_mage_visible_count := 0
var _last_offscreen_omissions := 0
var _metric_queue_requests := 0
var _metric_queue_rejections := 0
var _metric_pending_capacity_drops := 0
var _metric_flushes := 0
var _metric_visual_starts := 0
var _metric_visual_completions := 0
var _metric_visual_capacity_drops := 0
var _metric_offscreen_omissions := 0
var _metric_expired_omissions := 0
var _metric_headless_omissions := 0
var _metric_visual_writes := 0
var _metric_peak_active_visuals := 0
var _metric_audio_attempts := 0
var _metric_audio_starts := 0
var _metric_audio_capacity_drops := 0
var _metric_light_requests := 0
var _metric_light_accepts := 0
var _metric_teardown_count := 0


func _init() -> void:
	_headless_disabled = DisplayServer.get_name() == "headless"
	_slot_active.resize(TOTAL_VISUAL_SLOT_CAPACITY)
	_slot_profiles.resize(TOTAL_VISUAL_SLOT_CAPACITY)
	_slot_positions.resize(TOTAL_VISUAL_SLOT_CAPACITY)
	_slot_ages.resize(TOTAL_VISUAL_SLOT_CAPACITY)
	_active_profile_counts.resize(Profile.CAPOO_MAGE + 1)
	_pending_profiles.resize(PENDING_CAPACITY)
	_pending_positions.resize(PENDING_CAPACITY)
	_pending_elapsed_seconds.resize(PENDING_CAPACITY)
	set_process(false)
	set_physics_process(false)


func _ready() -> void:
	_collect_authored_audio()
	_stop_all_audio()
	if _headless_disabled or _teardown_prepared:
		_disable_visual_storage()
		return
	for multimesh in _get_multimeshes():
		if not _is_valid_authored_multimesh(multimesh):
			push_error("ExplosionPresentationService authored MultiMesh contract is invalid.")
			_disable_visual_storage()
			return
		multimesh.instance_count = VISUAL_CAPACITY
		multimesh.visible_instance_count = 0


func bind_context(
	combat_runtime: CombatRuntimeBase,
	enemy_simulation_coordinator: EnemySimulationCoordinator
) -> bool:
	if (
		_teardown_prepared
		or combat_runtime == null
		or enemy_simulation_coordinator == null
		or not is_instance_valid(combat_runtime)
		or not is_instance_valid(enemy_simulation_coordinator)
	):
		return false
	_combat_runtime = combat_runtime
	_enemy_simulation_coordinator = enemy_simulation_coordinator
	return true


func is_bound() -> bool:
	return (
		_combat_runtime != null
		and _enemy_simulation_coordinator != null
		and is_instance_valid(_combat_runtime)
		and is_instance_valid(_enemy_simulation_coordinator)
	)


func queue_explosion(
	profile: int,
	world_position: Vector2,
	elapsed_seconds: float = 0.0
) -> bool:
	_metric_queue_requests += 1
	if (
		_teardown_prepared
		or (profile != Profile.CAPOO_RPG and profile != Profile.CAPOO_MAGE)
		or not world_position.is_finite()
		or not is_finite(elapsed_seconds)
	):
		_metric_queue_rejections += 1
		return false
	if _pending_count >= PENDING_CAPACITY:
		_metric_pending_capacity_drops += 1
		return true
	_pending_profiles[_pending_count] = profile
	_pending_positions[_pending_count] = world_position
	_pending_elapsed_seconds[_pending_count] = maxf(elapsed_seconds, 0.0)
	_pending_count += 1
	return true


func flush_presenter(delta: float = 0.0) -> int:
	_metric_flushes += 1
	if _headless_disabled:
		_metric_headless_omissions += _pending_count
		_pending_count = 0
		return 0
	if _teardown_prepared:
		_clear_visible_prefixes()
		_pending_count = 0
		return 0
	var safe_delta := maxf(delta, 0.0) if is_finite(delta) else 0.0
	_advance_visual_slots(safe_delta)
	_consume_pending_requests()
	_pending_count = 0
	_rebuild_multimeshes()
	return _last_visible_count


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_metric_teardown_count += 1
	_pending_count = 0
	_slot_active.fill(0)
	_active_profile_counts.fill(0)
	_stop_all_audio()
	_combat_runtime = null
	_enemy_simulation_coordinator = null
	set_process(false)
	_disable_visual_storage()


func get_metrics() -> Dictionary:
	return {
		"queue_requests": _metric_queue_requests,
		"queue_rejections": _metric_queue_rejections,
		"pending_requests": _pending_count,
		"pending_capacity": PENDING_CAPACITY,
		"pending_capacity_drops": _metric_pending_capacity_drops,
		"flushes": _metric_flushes,
		"draw_family_count": 4,
		"visual_capacity": VISUAL_CAPACITY,
		"total_visual_slot_capacity": TOTAL_VISUAL_SLOT_CAPACITY,
		"effective_visual_capacity": 0 if _headless_disabled else VISUAL_CAPACITY,
		"authored_audio_voice_capacity": (
			_rpg_audio_voices.size() + _mage_audio_voices.size()
		),
		"authored_rpg_audio_voice_capacity": _rpg_audio_voices.size(),
		"authored_mage_audio_voice_capacity": _mage_audio_voices.size(),
		"effective_audio_voice_capacity": (
			0
			if _headless_disabled
			else _rpg_audio_voices.size() + _mage_audio_voices.size()
		),
		"active_visuals": _count_active_visuals(),
		"visible_visuals": _last_visible_count,
		"visible_rpg_visuals": _last_rpg_visible_count,
		"visible_mage_visuals": _last_mage_visible_count,
		"last_offscreen_omissions": _last_offscreen_omissions,
		"peak_active_visuals": _metric_peak_active_visuals,
		"active_audio_voices": _count_active_audio_voices(),
		"visual_starts": _metric_visual_starts,
		"visual_completions": _metric_visual_completions,
		"visual_capacity_drops": _metric_visual_capacity_drops,
		"offscreen_omissions": _metric_offscreen_omissions,
		"expired_omissions": _metric_expired_omissions,
		"headless_omissions": _metric_headless_omissions,
		"visual_writes": _metric_visual_writes,
		"audio_attempts": _metric_audio_attempts,
		"audio_starts": _metric_audio_starts,
		"audio_capacity_drops": _metric_audio_capacity_drops,
		"light_requests": _metric_light_requests,
		"light_accepts": _metric_light_accepts,
		"allocated_base_instances": _instance_count(_get_base_multimesh()),
		"allocated_emission_instances": _instance_count(_get_emission_multimesh()),
		"allocated_mage_base_instances": _instance_count(
			_get_mage_base_multimesh()
		),
		"allocated_mage_emission_instances": _instance_count(
			_get_mage_emission_multimesh()
		),
		"headless_disabled": _headless_disabled,
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _metric_teardown_count,
	}


func _advance_visual_slots(delta: float) -> void:
	if delta <= 0.0:
		return
	for slot in range(TOTAL_VISUAL_SLOT_CAPACITY):
		if _slot_active[slot] == 0:
			continue
		_slot_ages[slot] += delta
		if _slot_ages[slot] >= _get_profile_duration(_slot_profiles[slot]):
			var profile := int(_slot_profiles[slot])
			_slot_active[slot] = 0
			_active_profile_counts[profile] = maxi(
				int(_active_profile_counts[profile]) - 1,
				0
			)
			_metric_visual_completions += 1


func _consume_pending_requests() -> void:
	for request_index in range(_pending_count):
		var elapsed := float(_pending_elapsed_seconds[request_index])
		if elapsed >= _get_profile_duration(_pending_profiles[request_index]):
			_metric_expired_omissions += 1
			continue
		var position := _pending_positions[request_index]
		if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
			self, position, VISIBILITY_MARGIN
		):
			_metric_offscreen_omissions += 1
			continue
		var slot := _find_free_slot(_pending_profiles[request_index])
		if slot < 0:
			_metric_visual_capacity_drops += 1
			continue
		_slot_active[slot] = 1
		_slot_profiles[slot] = _pending_profiles[request_index]
		_active_profile_counts[_pending_profiles[request_index]] += 1
		_slot_positions[slot] = position
		_slot_ages[slot] = elapsed
		_metric_visual_starts += 1
		_start_audio_voice(_pending_profiles[request_index], position, elapsed)
		_request_night_flash(_pending_profiles[request_index], position, elapsed)
	_metric_peak_active_visuals = maxi(
		_metric_peak_active_visuals, _count_active_visuals()
	)


func _rebuild_multimeshes() -> void:
	var base := _get_base_multimesh()
	var emission := _get_emission_multimesh()
	var mage_base := _get_mage_base_multimesh()
	var mage_emission := _get_mage_emission_multimesh()
	if (
		base == null
		or emission == null
		or mage_base == null
		or mage_emission == null
	):
		_clear_visible_prefixes()
		return
	_last_visible_count = 0
	_last_rpg_visible_count = 0
	_last_mage_visible_count = 0
	_last_offscreen_omissions = 0
	for slot in range(TOTAL_VISUAL_SLOT_CAPACITY):
		if _slot_active[slot] == 0:
			continue
		var position := _slot_positions[slot]
		if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
			self, position, VISIBILITY_MARGIN
		):
			_last_offscreen_omissions += 1
			continue
		var profile := int(_slot_profiles[slot]) as Profile
		var draw_slot := (
			_last_mage_visible_count
			if profile == Profile.CAPOO_MAGE
			else _last_rpg_visible_count
		)
		var transform := Transform2D(0.0, to_local(position))
		var frame_count := _get_profile_frame_count(profile)
		var frame := clampi(
			floori(float(_slot_ages[slot]) * _get_profile_fps(profile)),
			0,
			frame_count - 1
		)
		var custom := Color(
			(float(frame) + 0.5) / float(frame_count),
			0.0, 0.0, 1.0
		)
		if profile == Profile.CAPOO_MAGE:
			mage_base.set_instance_transform_2d(draw_slot, transform)
			mage_emission.set_instance_transform_2d(draw_slot, transform)
			mage_base.set_instance_custom_data(draw_slot, custom)
			mage_emission.set_instance_custom_data(draw_slot, custom)
			_last_mage_visible_count += 1
		else:
			base.set_instance_transform_2d(draw_slot, transform)
			emission.set_instance_transform_2d(draw_slot, transform)
			base.set_instance_custom_data(draw_slot, custom)
			emission.set_instance_custom_data(draw_slot, custom)
			_last_rpg_visible_count += 1
		_last_visible_count += 1
	base.visible_instance_count = _last_rpg_visible_count
	emission.visible_instance_count = _last_rpg_visible_count
	mage_base.visible_instance_count = _last_mage_visible_count
	mage_emission.visible_instance_count = _last_mage_visible_count
	_metric_visual_writes += _last_visible_count * 2


func _find_free_slot(profile: int) -> int:
	if int(_active_profile_counts[profile]) >= VISUAL_CAPACITY:
		return -1
	for slot in range(TOTAL_VISUAL_SLOT_CAPACITY):
		if _slot_active[slot] == 0:
			return slot
	return -1


func _collect_authored_audio() -> void:
	_rpg_audio_voices.clear()
	for child in _audio_voices_root.get_children():
		var voice := child as AudioStreamPlayer2D
		if voice != null:
			_rpg_audio_voices.append(voice)
	_mage_audio_voices.clear()
	for child in _mage_audio_voices_root.get_children():
		var voice := child as AudioStreamPlayer2D
		if voice != null:
			_mage_audio_voices.append(voice)


func _start_audio_voice(profile: int, position: Vector2, elapsed: float) -> void:
	_metric_audio_attempts += 1
	var voices := (
		_mage_audio_voices
		if profile == Profile.CAPOO_MAGE
		else _rpg_audio_voices
	)
	var volume_db := (
		MAGE_AUDIO_VOLUME_DB
		if profile == Profile.CAPOO_MAGE
		else BASE_AUDIO_VOLUME_DB
	)
	for voice in voices:
		if voice.playing:
			continue
		if voice.stream == null or elapsed >= voice.stream.get_length():
			return
		voice.global_position = position
		voice.volume_db = volume_db
		EXPLOSION_AUDIO_LIMITER.play(voice, self)
		if voice.playing:
			if elapsed > 0.0:
				voice.seek(elapsed)
			_metric_audio_starts += 1
		return
	_metric_audio_capacity_drops += 1


func _request_night_flash(
	profile: int,
	position: Vector2,
	elapsed: float
) -> void:
	_metric_light_requests += 1
	var accepted := false
	if profile == Profile.CAPOO_MAGE:
		accepted = NIGHT_VFX_FLASH_POOL.request_from(
			self, position, Color(1.0, 0.56, 0.24, 1.0),
			0.78, 0.34, 0.025, 0.035, 0.18, 1, elapsed
		)
	else:
		accepted = NIGHT_VFX_FLASH_POOL.request_from(
			self, position, Color(1.0, 0.56, 0.22, 1.0),
			1.08, 0.82, 0.04, 0.06, 0.30, 2, elapsed
		)
	if accepted:
		_metric_light_accepts += 1


func _stop_all_audio() -> void:
	for voice in _rpg_audio_voices:
		EXPLOSION_AUDIO_LIMITER.stop(voice)
		voice.volume_db = BASE_AUDIO_VOLUME_DB
	for voice in _mage_audio_voices:
		EXPLOSION_AUDIO_LIMITER.stop(voice)
		voice.volume_db = MAGE_AUDIO_VOLUME_DB


func _count_active_visuals() -> int:
	var count := 0
	for active in _slot_active:
		if active != 0:
			count += 1
	return count


func _count_active_audio_voices() -> int:
	var count := 0
	for voice in _rpg_audio_voices:
		if voice.playing:
			count += 1
	for voice in _mage_audio_voices:
		if voice.playing:
			count += 1
	return count


func _clear_visible_prefixes() -> void:
	for multimesh in _get_multimeshes():
		if multimesh != null:
			multimesh.visible_instance_count = 0
	_last_visible_count = 0
	_last_rpg_visible_count = 0
	_last_mage_visible_count = 0


func _disable_visual_storage() -> void:
	for multimesh in _get_multimeshes():
		if multimesh != null:
			multimesh.visible_instance_count = 0
			multimesh.instance_count = 0
	_last_visible_count = 0
	_last_rpg_visible_count = 0
	_last_mage_visible_count = 0


func _get_multimeshes() -> Array[MultiMesh]:
	return [
		_get_base_multimesh(),
		_get_emission_multimesh(),
		_get_mage_base_multimesh(),
		_get_mage_emission_multimesh(),
	]


func _get_base_multimesh() -> MultiMesh:
	var node := get_node_or_null("ExplosionBase") as MultiMeshInstance2D
	return node.multimesh if node != null else null


func _get_emission_multimesh() -> MultiMesh:
	var node := get_node_or_null("ExplosionEmission") as MultiMeshInstance2D
	return node.multimesh if node != null else null


func _get_mage_base_multimesh() -> MultiMesh:
	var node := get_node_or_null("MageImpactBase") as MultiMeshInstance2D
	return node.multimesh if node != null else null


func _get_mage_emission_multimesh() -> MultiMesh:
	var node := get_node_or_null("MageImpactEmission") as MultiMeshInstance2D
	return node.multimesh if node != null else null


static func _get_profile_duration(profile: int) -> float:
	return (
		MAGE_IMPACT_DURATION_SECONDS
		if profile == Profile.CAPOO_MAGE
		else EXPLOSION_DURATION_SECONDS
	)


static func _get_profile_frame_count(profile: int) -> int:
	return (
		MAGE_IMPACT_FRAME_COUNT
		if profile == Profile.CAPOO_MAGE
		else EXPLOSION_FRAME_COUNT
	)


static func _get_profile_fps(profile: int) -> float:
	return MAGE_IMPACT_FPS if profile == Profile.CAPOO_MAGE else EXPLOSION_FPS


static func _is_valid_authored_multimesh(multimesh: MultiMesh) -> bool:
	return (
		multimesh != null
		and multimesh.transform_format == MultiMesh.TRANSFORM_2D
		and multimesh.use_custom_data
		and multimesh.mesh != null
	)


static func _instance_count(multimesh: MultiMesh) -> int:
	return multimesh.instance_count if multimesh != null else 0


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
