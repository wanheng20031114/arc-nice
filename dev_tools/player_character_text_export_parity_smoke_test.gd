extends SceneTree

const CHARACTER_CARD_SCENE := preload(
	"res://scene/character_selection/player_character_card.tscn"
)
const BASE_CONTENT_SIZE := Vector2i(1152, 648)
const EXPECTED_CARD_WIDTH := 252.0
const EXPECTED_DESCRIPTION_WIDTH := 224.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = BASE_CONTENT_SIZE
	root.size = BASE_CONTENT_SIZE

	var wrapped_line_counts := PackedInt32Array()
	for config in PlayerCharacterRegistry.get_all_configs():
		var card := CHARACTER_CARD_SCENE.instantiate() as PlayerCharacterCard
		root.add_child(card)
		card.setup(config)
		await _wait_frames(4)
		_verify_card_text_contract(card)
		wrapped_line_counts.append(card.description_label.get_line_count())
		card.queue_free()
		await _wait_frames(2)

	if failures.is_empty():
		print(
			"PLAYER_CHARACTER_TEXT_EXPORT_PARITY_SMOKE_TEST_OK driver=%s lines=%s"
			% [TextServerManager.get_primary_interface().get_name(), wrapped_line_counts]
		)
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_card_text_contract(card: PlayerCharacterCard) -> void:
	var description := card.description_label
	_expect(
		is_equal_approx(card.size.x, EXPECTED_CARD_WIDTH),
		"Character card width changed unexpectedly: %.2f." % card.size.x
	)
	_expect(
		is_equal_approx(description.size.x, EXPECTED_DESCRIPTION_WIDTH),
		"Character description width changed unexpectedly: %.2f." % description.size.x
	)
	_expect(
		description.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART,
		"Character descriptions must use adaptive word wrapping."
	)
	_expect(
		description.get_line_count() >= 2,
		"CJK character description did not wrap: %s" % card.character_config.character_id
	)
	_expect(
		description.get_content_width() <= ceili(description.size.x),
		"Wrapped description still exceeds its text box: %s"
		% card.character_config.character_id
	)
	_expect(
		description.get_content_height() <= ceili(description.size.y),
		"Wrapped description is vertically clipped: %s"
		% card.character_config.character_id
	)
	for label in [card.title_label, card.name_label, card.stats_label, card.playstyle_label]:
		_expect(
			label.clip_text
			and label.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS,
			"Single-line character-card text must have deterministic overflow handling."
		)


func _wait_frames(frame_count: int) -> void:
	for _frame in frame_count:
		await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
