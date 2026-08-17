extends SceneTree

const PACK_ARGUMENT_PREFIX := "--pack="
const ENCYCLOPEDIA_SCENE_PATH := "res://scene/encyclopedia/encyclopedia_screen.tscn"
const BASE_CONTENT_SIZE := Vector2i(1152, 648)
const EXPORT_WINDOW_SIZE := Vector2i(1920, 1080)
const DETAIL_TRANSITION_WAIT_SECONDS := 0.32

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var pack_path := _get_pack_path()
	_expect(
		not pack_path.is_empty(),
		"Pass a real release PCK with --pack=<path>; source-only layout is not an export test."
	)
	if not pack_path.is_empty():
		_expect(
			ProjectSettings.load_resource_pack(pack_path, true),
			"Exported resource pack must mount successfully: %s" % pack_path
		)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = BASE_CONTENT_SIZE
	root.size = EXPORT_WINDOW_SIZE

	var packed_scene := ResourceLoader.load(
		ENCYCLOPEDIA_SCENE_PATH,
		"PackedScene",
		ResourceLoader.CACHE_MODE_REPLACE
	) as PackedScene
	_expect(packed_scene != null, "Exported encyclopedia scene must remain loadable.")
	if packed_scene != null:
		await _verify_detail_layout(packed_scene)
	await _cleanup_root()

	if failures.is_empty():
		print("ENCYCLOPEDIA_EXPORT_LAYOUT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_detail_layout(packed_scene: PackedScene) -> void:
	var screen := packed_scene.instantiate()
	_expect(screen != null, "Exported encyclopedia scene must instantiate.")
	if screen == null:
		return
	root.add_child(screen)
	current_scene = screen
	await _wait_frames(5)
	await _wait_for_grid_build(screen)

	var collectible_button := screen.get_node(
		"Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Sidebar/SectionNav/Buttons/Collectible"
	) as Button
	collectible_button.pressed.emit()
	await create_timer(0.24).timeout
	await _wait_frames(4)
	await _wait_for_grid_build(screen)

	var entry_grid := screen.get_node(
		"Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/GridArea/GridScroll/GridMargin/EntryGrid"
	) as GridContainer
	_expect(entry_grid.get_child_count() > 0, "Exported collectible grid must contain cards.")
	if entry_grid.get_child_count() == 0:
		return
	var first_card := entry_grid.get_child(0)
	var select_button := first_card.get_node("SelectButton") as Button
	select_button.pressed.emit()
	await create_timer(DETAIL_TRANSITION_WAIT_SECONDS).timeout
	await _wait_frames(5)

	var workspace := screen.get_node(
		"Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace"
	) as Control
	var detail_panel := screen.get_node(
		"Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/DetailPanel"
	) as Control
	var details_scroll := detail_panel.get_node("Margin/Content/DetailsScroll") as ScrollContainer
	var name_label := detail_panel.get_node(
		"Margin/Content/DetailsScroll/Body/Details/Name"
	) as Label
	var description_label := detail_panel.get_node(
		"Margin/Content/DetailsScroll/Body/Details/Description"
	) as RichTextLabel
	_expect(detail_panel.visible, "Exported detail panel must open from a collectible card.")
	_expect(
		absf(detail_panel.size.y - workspace.size.y) <= 2.0,
		(
			"Exported detail panel must fill workspace height; panel=%.2f workspace=%.2f "
			+ "anchors=(L%.2f,T%.2f,R%.2f,B%.2f) offsets=(L%.2f,T%.2f,R%.2f,B%.2f)."
		)
		% [
			detail_panel.size.y,
			workspace.size.y,
			detail_panel.anchor_left,
			detail_panel.anchor_top,
			detail_panel.anchor_right,
			detail_panel.anchor_bottom,
			detail_panel.offset_left,
			detail_panel.offset_top,
			detail_panel.offset_right,
			detail_panel.offset_bottom,
		]
	)
	_expect(
		details_scroll.size.y >= 120.0,
		"Exported detail text viewport must not collapse; got %.2f px." % details_scroll.size.y
	)
	_expect(
		not name_label.text.is_empty() and not description_label.text.is_empty(),
		"Exported detail panel must retain its name and description data."
	)

	current_scene = null
	screen.queue_free()
	await _wait_frames(4)


func _get_pack_path() -> String:
	for argument_variant in OS.get_cmdline_user_args():
		var argument := String(argument_variant)
		if argument.begins_with(PACK_ARGUMENT_PREFIX):
			return argument.trim_prefix(PACK_ARGUMENT_PREFIX)
	return ""


func _wait_for_grid_build(screen: Node) -> void:
	for _frame in 240:
		if bool(screen.call("is_grid_build_complete")):
			return
		await process_frame
	_expect(false, "Exported encyclopedia grid did not finish within 240 frames.")


func _wait_frames(frame_count: int) -> void:
	for _frame in frame_count:
		await process_frame


func _cleanup_root() -> void:
	current_scene = null
	for child in root.get_children():
		child.queue_free()
	await _wait_frames(4)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
