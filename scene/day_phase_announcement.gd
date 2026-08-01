extends CanvasLayer
class_name DayPhaseAnnouncement

signal announcement_started(display_text: String)
signal announcement_finished(display_text: String)

const PRESENTATION_DURATION_SECONDS := 3.0
const MAIN_TEXT_HEIGHT_RATIO := 0.21605
const MAIN_TEXT_BASE_SPACING_RATIO := 0.021875
const MAIN_TEXT_MINIMUM_SPACING_RATIO := 0.002
const MAIN_TEXT_SPACING_DECAY_RATE := 1.0
const MINIMUM_FONT_SIZE := 24
const MINIMUM_HORIZONTAL_PADDING := 24.0
const CHINESE_DIGITS: PackedStringArray = [
	"零",
	"一",
	"二",
	"三",
	"四",
	"五",
	"六",
	"七",
	"八",
	"九",
]

@onready var presentation_root: Control = $PresentationRoot
@onready var title_label: Label = $PresentationRoot/Title
@onready var announcement_audio: AudioStreamPlayer = $AnnouncementAudio
@onready var presentation_timer: Timer = $PresentationTimer

var current_text := ""
var presentation_count := 0


func _ready() -> void:
	presentation_root.hide()
	_update_font_size()
	var viewport := get_viewport()
	if viewport != null and not viewport.size_changed.is_connected(_update_font_size):
		viewport.size_changed.connect(_update_font_size)


func show_day_phase(day_number: int, is_night: bool) -> void:
	show_announcement(format_day_phase_text(day_number, is_night))


func show_announcement(display_text: String) -> void:
	var normalized_text := display_text.strip_edges()
	if normalized_text.is_empty():
		return
	current_text = normalized_text
	title_label.text = current_text
	_update_font_size()
	presentation_count += 1
	presentation_timer.stop()
	presentation_root.show()
	presentation_timer.start(PRESENTATION_DURATION_SECONDS)
	announcement_audio.stop()
	announcement_audio.play()
	announcement_started.emit(current_text)


func hide_announcement() -> void:
	presentation_timer.stop()
	announcement_audio.stop()
	presentation_root.hide()


func is_presenting() -> bool:
	return presentation_root.visible and not presentation_timer.is_stopped()


static func format_day_phase_text(day_number: int, is_night: bool) -> String:
	return "第%s日 %s" % [
		_format_chinese_number(maxi(day_number, 1)),
		"黑夜" if is_night else "白昼",
	]


static func _format_chinese_number(value: int) -> String:
	if value < 10:
		return CHINESE_DIGITS[value]
	if value > 99:
		return str(value)
	var tens := value / 10
	var units := value % 10
	var result := "十" if tens == 1 else CHINESE_DIGITS[tens] + "十"
	if units > 0:
		result += CHINESE_DIGITS[units]
	return result


func _update_font_size() -> void:
	if title_label == null or title_label.label_settings == null:
		return
	var viewport_size := Vector2(1152.0, 648.0)
	var viewport := get_viewport()
	if viewport != null:
		viewport_size = viewport.get_visible_rect().size
	viewport_size.x = maxf(viewport_size.x, 1.0)
	viewport_size.y = maxf(viewport_size.y, 1.0)

	var character_count := maxi(title_label.text.length(), 1)
	var spacing_ratio := MAIN_TEXT_MINIMUM_SPACING_RATIO + (
		MAIN_TEXT_BASE_SPACING_RATIO - MAIN_TEXT_MINIMUM_SPACING_RATIO
	) * exp(-MAIN_TEXT_SPACING_DECAY_RATE * float(character_count - 1))
	var font_variation := title_label.label_settings.font as FontVariation
	if font_variation != null:
		font_variation.spacing_glyph = maxi(1, roundi(viewport_size.x * spacing_ratio))

	var responsive_size := maxi(
		MINIMUM_FONT_SIZE,
		roundi(viewport_size.y * MAIN_TEXT_HEIGHT_RATIO)
	)
	var available_width := maxf(
		viewport_size.x - MINIMUM_HORIZONTAL_PADDING * 2.0,
		1.0
	)
	var title_font := title_label.label_settings.font
	if title_font != null and not title_label.text.is_empty():
		var measured_width := title_font.get_string_size(
			title_label.text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			responsive_size
		).x
		if measured_width > available_width:
			responsive_size = maxi(
				MINIMUM_FONT_SIZE,
				floori(float(responsive_size) * available_width / measured_width)
			)
	title_label.label_settings.font_size = responsive_size


func _on_presentation_timer_timeout() -> void:
	presentation_timer.stop()
	presentation_root.hide()
	announcement_finished.emit(current_text)
