extends CanvasLayer
class_name DayPhaseAnnouncement

signal announcement_started(display_text: String)
signal announcement_finished(display_text: String)

const PRESENTATION_DURATION_SECONDS := 3.5
const BASELINE_VIEWPORT_HEIGHT := 648.0
const BASELINE_FONT_SIZE := 100.0
const MINIMUM_FONT_SIZE := 56
const MAXIMUM_FONT_SIZE := 100
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
@onready var animation_player: AnimationPlayer = $AnimationPlayer

var current_text := ""
var presentation_count := 0


func _ready() -> void:
	presentation_root.hide()
	_update_font_size()
	var viewport := get_viewport()
	if viewport != null and not viewport.size_changed.is_connected(_update_font_size):
		viewport.size_changed.connect(_update_font_size)
	if not animation_player.animation_finished.is_connected(_on_animation_finished):
		animation_player.animation_finished.connect(_on_animation_finished)


func show_day_phase(day_number: int, is_night: bool) -> void:
	show_announcement(format_day_phase_text(day_number, is_night))


func show_announcement(display_text: String) -> void:
	var normalized_text := display_text.strip_edges()
	if normalized_text.is_empty():
		return
	current_text = normalized_text
	title_label.text = current_text
	presentation_count += 1
	animation_player.stop()
	animation_player.play(&"show")
	# Apply time-zero visibility and opacity in the same frame as the audio cue.
	animation_player.advance(0.0)
	announcement_audio.stop()
	announcement_audio.play()
	announcement_started.emit(current_text)


func hide_announcement() -> void:
	animation_player.stop()
	announcement_audio.stop()
	presentation_root.hide()


func is_presenting() -> bool:
	return presentation_root.visible and animation_player.is_playing()


static func format_day_phase_text(day_number: int, is_night: bool) -> String:
	return "第%s日　%s" % [
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
	var viewport_height := BASELINE_VIEWPORT_HEIGHT
	var viewport := get_viewport()
	if viewport != null:
		viewport_height = maxf(viewport.get_visible_rect().size.y, 1.0)
	var responsive_size := roundi(
		BASELINE_FONT_SIZE * viewport_height / BASELINE_VIEWPORT_HEIGHT
	)
	title_label.label_settings.font_size = clampi(
		responsive_size,
		MINIMUM_FONT_SIZE,
		MAXIMUM_FONT_SIZE
	)


func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name != &"show":
		return
	presentation_root.hide()
	announcement_finished.emit(current_text)
