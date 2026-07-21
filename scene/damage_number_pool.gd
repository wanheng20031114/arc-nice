extends Node2D
class_name DamageNumberPool

enum DisplayPriority {
	NORMAL,
	IMPORTANT,
}

enum CombatNumberKind {
	DAMAGE,
	HEALING,
}

const DAMAGE_FONT := preload("res://resources/font/ResourceHanRoundedCN-Medium.ttf")
const WORLD_EFFECT_VISIBILITY := preload("res://scene/world_effect_visibility.gd")
const BASE_SIZE := Vector2(38.0, 20.0)
const LIFETIME := 0.72
const FONT_SIZE := 9
const FONT_COLOR := Color(1.0, 0.12, 0.09, 1.0)
const OUTLINE_COLOR := Color(0.28, 0.02, 0.02, 0.98)
const MAGIC_FONT_COLOR := Color(0.74, 0.34, 1.0, 1.0)
const MAGIC_OUTLINE_COLOR := Color(0.16, 0.04, 0.30, 0.98)
const HEALING_FONT_COLOR := Color("#AFDD22")
const HEALING_OUTLINE_COLOR := Color(0.08, 0.20, 0.015, 0.98)
const OUTLINE_SIZE := 2
# Floating combat text is feedback, not authoritative simulation. Rebuilding up
# to 96 shaped TextLine draw commands every render frame was visible in the
# profiler during burst damage. Keep the CanvasItem render loop smooth while
# advancing and rebuilding this short-lived batch at 30 Hz. The first number
# after an idle period appears immediately; further admissions join the next
# scheduled redraw, at most one 30 Hz interval later.
const VISUAL_UPDATE_INTERVAL := 1.0 / 30.0

@export_range(1, 256, 1, "or_greater") var pool_size: int = 96
@export_range(1, 240, 1, "or_greater") var max_numbers_per_second: int = 120
@export_range(1, 32, 1, "or_greater") var max_numbers_per_frame: int = 16
@export_range(0, 32, 1, "or_greater") var important_frame_reserve: int = 4
@export_range(0, 240, 1, "or_greater") var important_per_second_reserve: int = 24
@export_range(0.0, 512.0, 1.0, "or_greater") var visibility_margin: float = 192.0

# Combat numbers used to be 96 Node2D + Label pairs, each with its own
# _process callback and CanvasItem state. These fixed-capacity arrays keep the
# same visual slots while one node updates and draws the entire batch.
var slot_active := PackedByteArray()
var slot_elapsed := PackedFloat32Array()
var slot_start_positions := PackedVector2Array()
var slot_float_offsets := PackedVector2Array()
var slot_texts: Array[String] = []
var slot_number_kinds := PackedByteArray()
var slot_damage_types := PackedByteArray()
var slot_text_lines: Array[TextLine] = []
var active_count: int = 0
var visual_update_accumulator := 0.0
var redraw_request_count: int = 0

var budget_frame: int = -1
var shown_this_frame: int = 0
var normal_shown_this_frame: int = 0
var budget_second_started_msec: int = 0
var shown_this_second: int = 0
var normal_shown_this_second: int = 0
var offscreen_requests_skipped: int = 0


func _ready() -> void:
	_initialize_slots()
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	set_process(false)


func show_damage_number(
	amount: int,
	spawn_position: Vector2,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	display_priority: DisplayPriority = DisplayPriority.NORMAL
) -> bool:
	return show_combat_number(
		amount,
		spawn_position,
		CombatNumberKind.DAMAGE,
		impact_direction,
		damage_type,
		display_priority
	)


func show_healing_number(
	amount: int,
	spawn_position: Vector2,
	motion_direction: Vector2 = Vector2.ZERO,
	display_priority: DisplayPriority = DisplayPriority.NORMAL
) -> bool:
	return show_combat_number(
		amount,
		spawn_position,
		CombatNumberKind.HEALING,
		motion_direction,
		EnemyConfig.DamageType.PHYSICAL,
		display_priority
	)


## Canonical allocation-free combat feedback entry point. Damage and healing
## share the same fixed slots, visibility check and render-frame/second budgets.
func show_combat_number(
	amount: int,
	spawn_position: Vector2,
	number_kind: CombatNumberKind,
	motion_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	display_priority: DisplayPriority = DisplayPriority.NORMAL
) -> bool:
	if amount <= 0:
		return false
	# Budget saturation is much cheaper to test than resolving a viewport and
	# its transformed visible rect. Recheck at consumption so a future caller
	# cannot accidentally bypass the shared limits.
	if not _has_display_budget(display_priority):
		return false
	# Invisible feedback must not consume the shared display budget and starve
	# nearby combat. The margin keeps numbers that can enter view during their
	# short lifetime.
	if not WORLD_EFFECT_VISIBILITY.is_position_near_viewport(
		self,
		spawn_position,
		visibility_margin
	):
		offscreen_requests_skipped += 1
		return false
	if not _consume_display_budget(display_priority):
		return false

	var slot_index := _find_available_slot()
	if slot_index < 0:
		return false
	var was_active := slot_active[slot_index] != 0
	var was_pool_idle := active_count <= 0
	if was_pool_idle:
		visual_update_accumulator = 0.0
	slot_active[slot_index] = 1
	slot_elapsed[slot_index] = 0.0
	slot_start_positions[slot_index] = (
		spawn_position + Vector2(randf_range(-2.0, 2.0), -9.0)
	)
	var horizontal_sign := 0.0
	if not is_zero_approx(motion_direction.x):
		horizontal_sign = signf(motion_direction.x)
	else:
		horizontal_sign = -1.0 if randf() < 0.5 else 1.0
	slot_float_offsets[slot_index] = Vector2(
		horizontal_sign * randf_range(4.0, 8.0),
		-14.0
	)
	slot_texts[slot_index] = (
		"+%d" % amount
		if number_kind == CombatNumberKind.HEALING
		else str(amount)
	)
	slot_number_kinds[slot_index] = number_kind
	slot_damage_types[slot_index] = damage_type
	_shape_slot_text(slot_index)
	if not was_active:
		active_count += 1
	set_process(true)
	if was_pool_idle:
		_request_visual_redraw()
	return true


func get_active_count() -> int:
	return active_count


func get_slot_capacity() -> int:
	return slot_active.size()


func get_redraw_request_count() -> int:
	return redraw_request_count


func has_active_text(expected_text: String) -> bool:
	for index in range(slot_active.size()):
		if slot_active[index] != 0 and slot_texts[index] == expected_text:
			return true
	return false


func get_first_active_debug_snapshot(
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> Dictionary:
	for index in range(slot_active.size()):
		if (
			slot_active[index] == 0
			or slot_number_kinds[index] != CombatNumberKind.DAMAGE
			or slot_damage_types[index] != damage_type
		):
			continue
		return _get_slot_debug_snapshot(index)
	return {}


func get_first_active_combat_number_debug_snapshot(
	number_kind: CombatNumberKind,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> Dictionary:
	for index in range(slot_active.size()):
		if slot_active[index] == 0 or slot_number_kinds[index] != number_kind:
			continue
		if (
			number_kind == CombatNumberKind.DAMAGE
			and slot_damage_types[index] != damage_type
		):
			continue
		return _get_slot_debug_snapshot(index)
	return {}


func _get_slot_debug_snapshot(index: int) -> Dictionary:
	var number_kind := int(slot_number_kinds[index]) as CombatNumberKind
	var damage_type := int(slot_damage_types[index]) as EnemyConfig.DamageType
	return {
		"text": slot_texts[index],
		"elapsed": slot_elapsed[index],
		"number_kind": number_kind,
		"damage_type": damage_type,
		"font_color": _get_font_color(number_kind, damage_type),
		"outline_color": _get_outline_color(number_kind, damage_type),
		"start_position": slot_start_positions[index],
		"float_offset": slot_float_offsets[index],
	}


func _process(delta: float) -> void:
	if active_count <= 0:
		visual_update_accumulator = 0.0
		set_process(false)
		return
	visual_update_accumulator += maxf(delta, 0.0)
	if visual_update_accumulator < VISUAL_UPDATE_INTERVAL:
		return
	var safe_delta := visual_update_accumulator
	visual_update_accumulator = 0.0
	for index in range(slot_active.size()):
		if slot_active[index] == 0:
			continue
		var next_elapsed := slot_elapsed[index] + safe_delta
		if next_elapsed >= LIFETIME:
			slot_active[index] = 0
			slot_elapsed[index] = 0.0
			slot_texts[index] = ""
			active_count -= 1
			continue
		slot_elapsed[index] = next_elapsed
	_request_visual_redraw()
	if active_count <= 0:
		active_count = 0
		visual_update_accumulator = 0.0
		set_process(false)


func _draw() -> void:
	for index in range(slot_active.size()):
		if slot_active[index] == 0:
			continue
		var elapsed := slot_elapsed[index]
		var progress := clampf(elapsed / LIFETIME, 0.0, 1.0)
		var world_position := (
			slot_start_positions[index]
			+ slot_float_offsets[index] * _ease_out_circ(progress)
		)
		var local_position := to_local(world_position)
		# Label's vertical-centering path truncates the positive spare space to an
		# integer before adding the font ascent. Use the equivalent top-left line
		# origin so the batched glyphs stay on the exact authored pixel row.
		var line_position := local_position + Vector2(
			-BASE_SIZE.x * 0.5,
			-BASE_SIZE.y * 0.5
				+ float(int((BASE_SIZE.y - DAMAGE_FONT.get_height(FONT_SIZE)) * 0.5))
		)
		var brightness := _get_brightness(elapsed)
		var alpha := _get_alpha(elapsed)
		var number_kind := int(slot_number_kinds[index]) as CombatNumberKind
		var damage_type := int(slot_damage_types[index]) as EnemyConfig.DamageType
		var font_color := _scaled_color(
			_get_font_color(number_kind, damage_type),
			brightness,
			alpha
		)
		var outline_color := _scaled_color(
			_get_outline_color(number_kind, damage_type),
			brightness,
			alpha
		)
		var text_line := slot_text_lines[index]
		text_line.draw_outline(
			get_canvas_item(),
			line_position,
			OUTLINE_SIZE,
			outline_color
		)
		text_line.draw(get_canvas_item(), line_position, font_color)


func _initialize_slots() -> void:
	var capacity := maxi(pool_size, 1)
	slot_active.resize(capacity)
	slot_active.fill(0)
	slot_elapsed.resize(capacity)
	slot_elapsed.fill(0.0)
	slot_start_positions.resize(capacity)
	slot_start_positions.fill(Vector2.ZERO)
	slot_float_offsets.resize(capacity)
	slot_float_offsets.fill(Vector2.ZERO)
	slot_number_kinds.resize(capacity)
	slot_number_kinds.fill(CombatNumberKind.DAMAGE)
	slot_damage_types.resize(capacity)
	slot_damage_types.fill(EnemyConfig.DamageType.PHYSICAL)
	slot_texts.resize(capacity)
	slot_texts.fill("")
	slot_text_lines.resize(capacity)
	for index in range(capacity):
		var text_line := TextLine.new()
		text_line.width = BASE_SIZE.x
		text_line.alignment = HORIZONTAL_ALIGNMENT_CENTER
		slot_text_lines[index] = text_line
	active_count = 0
	visual_update_accumulator = 0.0
	redraw_request_count = 0


func _request_visual_redraw() -> void:
	redraw_request_count += 1
	queue_redraw()


func _consume_display_budget(display_priority: DisplayPriority) -> bool:
	if not _has_display_budget(display_priority):
		return false
	shown_this_frame += 1
	shown_this_second += 1
	if display_priority == DisplayPriority.NORMAL:
		normal_shown_this_frame += 1
		normal_shown_this_second += 1
	return true


func _has_display_budget(display_priority: DisplayPriority) -> bool:
	_refresh_display_budget_windows()
	var frame_limit := maxi(max_numbers_per_frame, 1)
	if shown_this_frame >= frame_limit:
		return false
	if display_priority == DisplayPriority.NORMAL:
		var normal_frame_limit := maxi(
			frame_limit - clampi(important_frame_reserve, 0, frame_limit),
			0
		)
		if normal_shown_this_frame >= normal_frame_limit:
			return false

	var second_limit := maxi(max_numbers_per_second, 1)
	if shown_this_second >= second_limit:
		return false
	if display_priority == DisplayPriority.NORMAL:
		var normal_second_limit := maxi(
			second_limit - clampi(important_per_second_reserve, 0, second_limit),
			0
		)
		if normal_shown_this_second >= normal_second_limit:
			return false
	return true


func _refresh_display_budget_windows() -> void:
	# A long visible frame can execute multiple catch-up physics ticks. Render
	# feedback must share one budget across all of them, so key the limiter to the
	# process/render frame instead of allowing max_numbers_per_frame per tick.
	var current_frame := Engine.get_process_frames()
	if current_frame != budget_frame:
		budget_frame = current_frame
		shown_this_frame = 0
		normal_shown_this_frame = 0

	var now := Time.get_ticks_msec()
	if now - budget_second_started_msec >= 1000:
		budget_second_started_msec = now
		shown_this_second = 0
		normal_shown_this_second = 0


func _find_available_slot() -> int:
	for index in range(slot_active.size()):
		if slot_active[index] == 0:
			return index
	var oldest_index := -1
	var oldest_elapsed := -INF
	for index in range(slot_active.size()):
		if slot_elapsed[index] > oldest_elapsed:
			oldest_elapsed = slot_elapsed[index]
			oldest_index = index
	return oldest_index


func _shape_slot_text(slot_index: int) -> void:
	var text_line := slot_text_lines[slot_index]
	text_line.clear()
	text_line.width = BASE_SIZE.x
	text_line.alignment = HORIZONTAL_ALIGNMENT_CENTER
	text_line.add_string(slot_texts[slot_index], DAMAGE_FONT, FONT_SIZE)


func _get_brightness(elapsed: float) -> float:
	if elapsed < 0.12:
		return lerpf(1.0, 1.35, _ease_out_back(clampf(elapsed / 0.12, 0.0, 1.0)))
	if elapsed < 0.34:
		return lerpf(
			1.35,
			1.0,
			_ease_out_sine(clampf((elapsed - 0.12) / 0.22, 0.0, 1.0))
		)
	return 1.0


func _get_alpha(elapsed: float) -> float:
	if elapsed <= 0.5:
		return 1.0
	return 1.0 - _ease_out_sine(clampf((elapsed - 0.5) / 0.22, 0.0, 1.0))


func _get_font_color(
	number_kind: CombatNumberKind,
	damage_type: EnemyConfig.DamageType
) -> Color:
	if number_kind == CombatNumberKind.HEALING:
		return HEALING_FONT_COLOR
	return MAGIC_FONT_COLOR if damage_type == EnemyConfig.DamageType.MAGIC else FONT_COLOR


func _get_outline_color(
	number_kind: CombatNumberKind,
	damage_type: EnemyConfig.DamageType
) -> Color:
	if number_kind == CombatNumberKind.HEALING:
		return HEALING_OUTLINE_COLOR
	return (
		MAGIC_OUTLINE_COLOR
		if damage_type == EnemyConfig.DamageType.MAGIC
		else OUTLINE_COLOR
	)


func _scaled_color(color: Color, brightness: float, alpha: float) -> Color:
	return Color(
		color.r * brightness,
		color.g * brightness,
		color.b * brightness,
		color.a * alpha
	)


func _ease_out_circ(value: float) -> float:
	return sqrt(1.0 - pow(value - 1.0, 2.0))


func _ease_out_sine(value: float) -> float:
	return sin((value * PI) * 0.5)


func _ease_out_back(value: float) -> float:
	const C1 := 1.70158
	const C3 := C1 + 1.0
	return 1.0 + C3 * pow(value - 1.0, 3.0) + C1 * pow(value - 1.0, 2.0)
