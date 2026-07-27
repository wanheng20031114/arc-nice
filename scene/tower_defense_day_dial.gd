extends Control
class_name TowerDefenseDayDial

const DAY_SEGMENT_COLOR := Color(0.94, 0.82, 0.42, 1.0)
const NIGHT_SEGMENT_COLOR := Color(0.42, 0.68, 0.96, 1.0)
const INACTIVE_SEGMENT_COLOR := Color(0.22, 0.31, 0.28, 0.72)
const INNER_TRACK_COLOR := Color(0.07, 0.12, 0.105, 0.95)
const GAP_RADIANS := 0.13
const PHASE_COUNT := 4
const PROGRESS_TWEEN_SECONDS := 0.22

var phase_index := 0
var wave_progress := 0.0:
	set(value):
		wave_progress = clampf(value, 0.0, 1.0)
		queue_redraw()
var target_wave_progress := 0.0
var progress_tween: Tween = null


func set_day_progress(new_phase_index: int, resolved: int, total: int) -> void:
	var next_phase_index := clampi(new_phase_index, 0, PHASE_COUNT - 1)
	var next_progress := (
		clampf(float(resolved) / float(total), 0.0, 1.0)
		if total > 0
		else 0.0
	)
	if next_phase_index == phase_index and is_equal_approx(next_progress, target_wave_progress):
		return

	var phase_changed := next_phase_index != phase_index
	phase_index = next_phase_index
	target_wave_progress = next_progress
	if progress_tween != null:
		progress_tween.kill()
		progress_tween = null
	if phase_changed:
		wave_progress = 0.0
	if is_equal_approx(wave_progress, target_wave_progress):
		queue_redraw()
		return

	progress_tween = create_tween()
	progress_tween.tween_property(
		self,
		"wave_progress",
		target_wave_progress,
		PROGRESS_TWEEN_SECONDS
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var outer_radius := maxf(minf(size.x, size.y) * 0.5 - 3.0, 2.0)
	var quarter := TAU / 4.0
	for segment_index in range(PHASE_COUNT):
		var start_angle := -PI * 0.5 + float(segment_index) * quarter + GAP_RADIANS
		var end_angle := start_angle + quarter - GAP_RADIANS * 2.0
		var color := INACTIVE_SEGMENT_COLOR
		if segment_index <= phase_index:
			color = DAY_SEGMENT_COLOR if segment_index < 2 else NIGHT_SEGMENT_COLOR
		draw_arc(center, outer_radius, start_angle, end_angle, 12, color, 3.0, true)

	var inner_radius := maxf(outer_radius - 6.0, 1.0)
	draw_arc(center, inner_radius, -PI * 0.5, PI * 1.5, 28, INNER_TRACK_COLOR, 2.0, true)
	if wave_progress > 0.0:
		var active_color := DAY_SEGMENT_COLOR if phase_index < 2 else NIGHT_SEGMENT_COLOR
		draw_arc(
			center,
			inner_radius,
			-PI * 0.5,
			-PI * 0.5 + TAU * wave_progress,
			maxi(4, ceili(28.0 * wave_progress)),
			active_color,
			2.0,
			true
		)
	draw_circle(center, 2.0, Color(0.85, 0.93, 0.83, 0.92))
