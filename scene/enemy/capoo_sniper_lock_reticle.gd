extends Node2D
class_name CapooSniperLockReticle

@onready var visual: AnimatedSprite2D = $Visual

var duration: float = 3.0
var elapsed: float = 0.0
var auto_progress: bool = false


func _ready() -> void:
	set_process(false)
	set_progress(0.0)


func start(new_duration: float) -> void:
	duration = maxf(new_duration, 0.01)
	elapsed = 0.0
	auto_progress = true
	visible = true
	set_process(true)
	set_progress(0.0)


func stop() -> void:
	auto_progress = false
	set_process(false)
	queue_free()


func set_progress(progress: float) -> void:
	var frames := visual.sprite_frames
	if frames == null or not frames.has_animation(&"lock"):
		return
	var frame_count := frames.get_frame_count(&"lock")
	if frame_count <= 0:
		return
	visual.animation = &"lock"
	visual.frame = clampi(floori(clampf(progress, 0.0, 1.0) * float(frame_count - 1)), 0, frame_count - 1)
	visual.frame_progress = 0.0


func _process(delta: float) -> void:
	if not auto_progress:
		return
	elapsed = minf(elapsed + delta, duration)
	set_progress(elapsed / duration)
