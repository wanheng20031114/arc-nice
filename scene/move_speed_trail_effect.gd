extends Node2D

const MIN_DIRECTION_LENGTH_SQUARED := 0.001

@export var emitter_back_offset: float = 8.0

@onready var trail_particles: Array[GPUParticles2D] = [
	$TrailParticles,
	$TrailParticlesUpper,
	$TrailParticlesLower,
	$TrailParticlesFar,
]

var motion_direction := Vector2.RIGHT


func _ready() -> void:
	visible = false
	for emitter in trail_particles:
		emitter.emitting = false
	_apply_motion_direction()
	process_mode = Node.PROCESS_MODE_DISABLED


func set_effect_active(enabled: bool) -> void:
	var expected_process_mode := (
		Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
	)
	if (
		visible == enabled
		and _are_emitters_active(enabled)
		and process_mode == expected_process_mode
	):
		return

	if enabled:
		process_mode = Node.PROCESS_MODE_INHERIT
	visible = enabled
	for emitter in trail_particles:
		emitter.emitting = enabled
	if enabled:
		_apply_motion_direction()
		for emitter in trail_particles:
			emitter.restart()
	else:
		process_mode = Node.PROCESS_MODE_DISABLED


func set_motion_direction(direction: Vector2) -> void:
	if direction.length_squared() >= MIN_DIRECTION_LENGTH_SQUARED:
		motion_direction = direction.normalized()
	if visible:
		_apply_motion_direction()


func _apply_motion_direction() -> void:
	var back_direction := -motion_direction
	var side_direction := Vector2(-motion_direction.y, motion_direction.x)
	var back_offsets: Array[float] = [
		emitter_back_offset,
		emitter_back_offset + 4.0,
		emitter_back_offset + 7.0,
		emitter_back_offset + 12.0,
	]
	var side_offsets: Array[float] = [-5.0, 0.0, 5.0, -1.5]
	for index in range(trail_particles.size()):
		var emitter := trail_particles[index]
		emitter.position = back_direction * back_offsets[index] + side_direction * side_offsets[index]
		emitter.rotation = back_direction.angle()


func _are_emitters_active(enabled: bool) -> bool:
	for emitter in trail_particles:
		if emitter.emitting != enabled:
			return false
	return true
