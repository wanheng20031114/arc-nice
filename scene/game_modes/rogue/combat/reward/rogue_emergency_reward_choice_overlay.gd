extends CanvasLayer
class_name RogueEmergencyRewardChoiceOverlay

const DEFAULT_ROUND_COUNT := 2
const DEFAULT_ROUND_SECONDS := 30.0
const INVALID_OFFER_INDEX := -1

signal choice_selected(round_number: int, offer_index: int)
signal inventory_requested()

@onready var root: Control = $Root
@onready var round_label: Label = $Root/Center/Frame/Margin/Rows/Header/Info/Round
@onready var countdown_label: Label = (
	$Root/Center/Frame/Margin/Rows/Header/Info/Countdown
)
@onready var choice_panel: RogueSupplyCollectibleChoicePanel = (
	$Root/Center/Frame/Margin/Rows/ChoicePanel
)
@onready var retry_button: Button = $Root/Center/Frame/Margin/Rows/RetryButton
@onready var countdown_timer: Timer = $CountdownTimer

var active_round_number := 0
var total_round_count := DEFAULT_ROUND_COUNT
var active_offer_paths: Array[String] = []
var pending_offer_index := INVALID_OFFER_INDEX
var _displayed_remaining_seconds := 0.0
var _countdown_expired := false


func _ready() -> void:
	choice_panel.choice_selected.connect(_on_choice_selected)
	choice_panel.inventory_requested.connect(_on_inventory_requested)
	retry_button.pressed.connect(_on_retry_pressed)
	countdown_timer.timeout.connect(_on_countdown_timeout)
	hide_and_reset()


func _process(_delta: float) -> void:
	if not visible:
		return
	if not countdown_timer.is_stopped():
		_displayed_remaining_seconds = countdown_timer.time_left
	_update_countdown_label()


func show_round(
	offer_paths: Array,
	round_number: int,
	round_count: int = DEFAULT_ROUND_COUNT,
	remaining_seconds: float = DEFAULT_ROUND_SECONDS,
	status_text: String = "请选择其中一件收藏品",
	interaction_enabled: bool = true,
	inventory_enabled: bool = true
) -> void:
	var normalized_paths := _normalize_offer_paths(offer_paths)
	var normalized_round_count := maxi(round_count, 1)
	var normalized_round_number := clampi(
		round_number,
		1,
		normalized_round_count
	)
	var is_new_round := (
		active_round_number != normalized_round_number
		or total_round_count != normalized_round_count
		or active_offer_paths != normalized_paths
	)
	active_round_number = normalized_round_number
	total_round_count = normalized_round_count
	active_offer_paths = normalized_paths
	if is_new_round:
		pending_offer_index = INVALID_OFFER_INDEX
		retry_button.visible = false
		retry_button.disabled = true
	_countdown_expired = false
	visible = true
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	round_label.text = "第 %d / %d 轮" % [
		active_round_number,
		total_round_count,
	]
	var offers_valid := active_offer_paths.size() == 2
	var effective_status := status_text
	if not offers_valid:
		effective_status = "候选同步异常 · 正在等待重新同步"
	choice_panel.show_choices(
		active_offer_paths,
		effective_status,
		interaction_enabled and offers_valid,
		inventory_enabled and offers_valid,
		inventory_enabled and offers_valid
	)
	set_remaining_seconds(remaining_seconds)
	if interaction_enabled and offers_valid:
		choice_panel.focus_first_available()


func set_remaining_seconds(remaining_seconds: float) -> void:
	_displayed_remaining_seconds = maxf(remaining_seconds, 0.0)
	_countdown_expired = _displayed_remaining_seconds <= 0.0
	countdown_timer.stop()
	if not _countdown_expired:
		countdown_timer.start(_displayed_remaining_seconds)
	_update_countdown_label()
	if _countdown_expired and visible:
		_on_countdown_timeout()


func set_choice_pending(
	offer_index: int,
	status_text: String = "正在确认收藏品……"
) -> void:
	if not _is_valid_offer_index(offer_index):
		return
	pending_offer_index = offer_index
	retry_button.visible = false
	retry_button.disabled = true
	choice_panel.set_pending(true, status_text)


func show_inventory_full_error(
	status_text: String = "背包空间不足 · 当前选择已保留，请整理背包后重试"
) -> void:
	if not _is_valid_offer_index(pending_offer_index):
		return
	choice_panel.show_choices(
		active_offer_paths,
		status_text,
		false,
		true,
		true
	)
	retry_button.visible = true
	retry_button.disabled = false
	retry_button.grab_focus()


func set_waiting(
	status_text: String = "本轮选择已完成 · 等待其他在线玩家"
) -> void:
	retry_button.visible = false
	retry_button.disabled = true
	choice_panel.show_choices(
		active_offer_paths,
		status_text,
		false,
		false,
		false
	)


func hide_and_reset() -> void:
	countdown_timer.stop()
	set_process(false)
	visible = false
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	choice_panel.hide_panel()
	retry_button.visible = false
	retry_button.disabled = true
	active_round_number = 0
	total_round_count = DEFAULT_ROUND_COUNT
	active_offer_paths.clear()
	pending_offer_index = INVALID_OFFER_INDEX
	_displayed_remaining_seconds = 0.0
	_countdown_expired = false
	round_label.text = "第 1 / 2 轮"
	countdown_label.text = "剩余 30 秒"


func _on_choice_selected(offer_index: int) -> void:
	if _countdown_expired or not _is_valid_offer_index(offer_index):
		return
	set_choice_pending(offer_index)
	choice_selected.emit(active_round_number, offer_index)


func _on_retry_pressed() -> void:
	# 超时自动项也可能因背包已满而锁定；整理后必须仍能重试同一项。
	if not _is_valid_offer_index(pending_offer_index):
		return
	var retry_offer_index := pending_offer_index
	set_choice_pending(retry_offer_index, "正在重新确认已选收藏品……")
	choice_selected.emit(active_round_number, retry_offer_index)


func _on_inventory_requested() -> void:
	if not active_offer_paths.is_empty():
		inventory_requested.emit()


func _on_countdown_timeout() -> void:
	countdown_timer.stop()
	_displayed_remaining_seconds = 0.0
	_countdown_expired = true
	_update_countdown_label()
	retry_button.visible = false
	retry_button.disabled = true
	choice_panel.show_choices(
		active_offer_paths,
		"选择时间已结束 · 正在等待自动分配",
		false,
		false,
		false
	)


func _update_countdown_label() -> void:
	countdown_label.text = "剩余 %02d 秒" % maxi(
		ceili(_displayed_remaining_seconds),
		0
	)


func _is_valid_offer_index(offer_index: int) -> bool:
	return offer_index >= 0 and offer_index < active_offer_paths.size()


func _normalize_offer_paths(offer_paths: Array) -> Array[String]:
	var normalized: Array[String] = []
	for raw_path in offer_paths:
		normalized.append(str(raw_path))
	return normalized
