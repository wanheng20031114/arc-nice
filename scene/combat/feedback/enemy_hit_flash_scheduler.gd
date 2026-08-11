extends Node

## Active-only presentation scheduler for the shared enemy direct-hit flash.
## One weak state is retained per currently flashing enemy; idle sessions have
## no process callback, per-enemy Timer/Tween or duplicated ShaderMaterial.
const FLASH_DURATION_SECONDS := 0.07
const FLASH_HOLD_SECONDS := 0.025
const FLASH_FADE_SECONDS := FLASH_DURATION_SECONDS - FLASH_HOLD_SECONDS
const FLASH_PEAK_STRENGTH := 0.84


class FlashState:
	var target_id := 0
	var target_ref: WeakRef = null
	var elapsed_seconds := 0.0
	var trigger_process_frame := 0


var _states_by_target_id: Dictionary[int, FlashState] = {}


func _ready() -> void:
	set_process(false)


func trigger(target: Enemy) -> bool:
	if (
		target == null
		or not is_instance_valid(target)
		or target.is_queued_for_deletion()
	):
		return false
	var target_id := int(target.get_instance_id())
	var state := _states_by_target_id.get(target_id) as FlashState
	if state != null and state.target_ref.get_ref() != target:
		_states_by_target_id.erase(target_id)
		state = null
	if state == null:
		state = FlashState.new()
		state.target_id = target_id
		state.target_ref = weakref(target)
		_states_by_target_id[target_id] = state
	state.elapsed_seconds = 0.0
	state.trigger_process_frame = Engine.get_process_frames()
	target.call("_set_direct_hit_flash_strength", FLASH_PEAK_STRENGTH)
	set_process(true)
	return true


func clear_target(target: Enemy, clear_visual: bool = true) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var target_id := int(target.get_instance_id())
	var state := _states_by_target_id.get(target_id) as FlashState
	if state == null or state.target_ref.get_ref() != target:
		return false
	_states_by_target_id.erase(target_id)
	if clear_visual and not target.is_queued_for_deletion():
		target.call("_set_direct_hit_flash_strength", 0.0)
	if _states_by_target_id.is_empty():
		set_process(false)
	return true


func clear_all() -> void:
	for state in _states_by_target_id.values():
		var target := state.target_ref.get_ref() as Enemy
		if (
			target != null
			and is_instance_valid(target)
			and not target.is_queued_for_deletion()
		):
			target.call("_set_direct_hit_flash_strength", 0.0)
	_states_by_target_id.clear()
	set_process(false)


func get_active_target_count() -> int:
	return _states_by_target_id.size()


func advance_for_test(delta: float) -> void:
	_advance(maxf(delta, 0.0), true)


func _process(delta: float) -> void:
	_advance(maxf(delta, 0.0), false)


func _advance(delta: float, force_render_frame_advanced: bool) -> void:
	if _states_by_target_id.is_empty():
		set_process(false)
		return
	var completed_target_ids: Array[int] = []
	var current_process_frame := Engine.get_process_frames()
	for target_id in _states_by_target_id:
		var state := _states_by_target_id[target_id] as FlashState
		var target := state.target_ref.get_ref() as Enemy
		if (
			target == null
			or not is_instance_valid(target)
			or target.is_queued_for_deletion()
		):
			completed_target_ids.append(target_id)
			continue
		# A hit can be triggered from physics immediately before this process pass.
		# Keep the peak through at least one render opportunity even after a hitch.
		if (
			not force_render_frame_advanced
			and current_process_frame <= state.trigger_process_frame
		):
			target.call("_set_direct_hit_flash_strength", FLASH_PEAK_STRENGTH)
			continue
		state.elapsed_seconds += delta
		if state.elapsed_seconds >= FLASH_DURATION_SECONDS:
			target.call("_set_direct_hit_flash_strength", 0.0)
			completed_target_ids.append(target_id)
			continue
		var strength := FLASH_PEAK_STRENGTH
		if state.elapsed_seconds > FLASH_HOLD_SECONDS:
			var fade_progress := clampf(
				(state.elapsed_seconds - FLASH_HOLD_SECONDS)
				/ FLASH_FADE_SECONDS,
				0.0,
				1.0
			)
			strength *= 1.0 - smoothstep(0.0, 1.0, fade_progress)
		target.call("_set_direct_hit_flash_strength", strength)
	for target_id in completed_target_ids:
		_states_by_target_id.erase(target_id)
	if _states_by_target_id.is_empty():
		set_process(false)
