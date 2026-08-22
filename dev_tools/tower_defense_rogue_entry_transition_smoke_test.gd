extends SceneTree

const TRANSITION_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_scene_transition.tscn"
)
const EXPLORATION_COORDINATOR_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/rogue/"
	+ "tower_defense_rogue_exploration_coordinator.tscn"
)

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var fixture := Node.new()
	fixture.name = "TowerDefenseRogueEntryTransitionSmokeTest"
	root.add_child(fixture)
	var transition := TRANSITION_SCENE.instantiate() as RogueSceneTransition
	fixture.add_child(transition)
	await process_frame

	_expect(
		not transition.visible
		and not transition.is_covered()
		and not transition.is_transitioning()
		and transition.cover_rect.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"通用转场初始化后必须隐藏、释放输入且没有运行中的动画。"
	)

	transition.cover()
	await process_frame
	_expect(
		transition.visible
		and transition.is_transitioning()
		and transition.cover_rect.mouse_filter == Control.MOUSE_FILTER_STOP,
		"渐进遮盖必须立即显示输入拦截层并报告转场中。"
	)
	transition.cover_immediately()
	_expect(
		transition.is_covered()
		and not transition.is_transitioning()
		and is_equal_approx(transition.progress, 1.0)
		and transition.cover_rect.mouse_filter == Control.MOUSE_FILTER_STOP,
		"立即遮盖必须取消旧动画、同步全黑并保持输入拦截。"
	)
	var covered_serial := int(transition.get("_transition_serial"))
	transition.cover_immediately()
	_expect(
		transition.is_covered()
		and not transition.is_transitioning()
		and int(transition.get("_transition_serial")) == covered_serial,
		"已全黑时重复立即遮盖必须幂等，不能制造新的转场代次。"
	)
	await create_timer(
		RogueSceneTransition.COVER_DURATION_SECONDS + 0.05,
		true
	).timeout
	_expect(
		transition.is_covered() and not transition.is_transitioning(),
		"被取消的旧遮盖协程不能在延迟结束后改变立即全黑状态。"
	)
	transition.reveal()
	await process_frame
	_expect(
		transition.visible and transition.is_transitioning(),
		"揭幕动画执行期间必须报告转场中。"
	)
	transition.cover_immediately()
	await create_timer(
		RogueSceneTransition.REVEAL_DURATION_SECONDS + 0.05,
		true
	).timeout
	_expect(
		transition.is_covered()
		and transition.visible
		and not transition.is_transitioning()
		and transition.cover_rect.mouse_filter == Control.MOUSE_FILTER_STOP,
		"立即遮盖必须废弃旧揭幕协程，迟到完成不能隐藏输入拦截层。"
	)

	transition.hide_immediately()
	_expect(
		not transition.visible
		and not transition.is_covered()
		and not transition.is_transitioning()
		and transition.cover_rect.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"立即隐藏必须完整清理画面、动画和输入拦截。"
	)

	var coordinator_scene_source := FileAccess.get_file_as_string(
		EXPLORATION_COORDINATOR_SCENE_PATH
	)
	_expect(
		coordinator_scene_source.count(
			"[node name=\"EntrySceneTransition\" parent=\".\" "
			+ "instance=ExtResource(\"4_scene_transition\")]"
		) == 1
		and coordinator_scene_source.contains(
			"[ext_resource type=\"PackedScene\" "
			+ "path=\"res://scene/game_modes/rogue/route/"
			+ "rogue_scene_transition.tscn\" id=\"4_scene_transition\"]"
		),
		"塔防 Rogue 探索协调场景必须原生挂载唯一的 EntrySceneTransition。"
	)
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/rogue/"
		+ "tower_defense_rogue_exploration_coordinator.gd"
	)
	_expect(
		not coordinator_source.contains("RogueSceneTransition.new(")
		and not coordinator_source.contains(
			"rogue_scene_transition.tscn\").instantiate("
		),
		"正式协调器不得在脚本中动态创建入口转场节点。"
	)

	fixture.queue_free()
	await process_frame
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("TOWER_DEFENSE_ROGUE_ENTRY_TRANSITION_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
