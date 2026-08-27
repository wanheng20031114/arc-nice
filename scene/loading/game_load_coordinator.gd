extends CanvasLayer

signal loading_started(multiplayer_load: bool)
signal loading_finished(multiplayer_load: bool)
signal loading_failed(message: String)

const MAIN_MENU_SCENE_PATH := "res://scene/main_menu.tscn"
const MULTIPLAYER_LOBBY_SCENE_PATH := "res://scene/multiplayer/multiplayer_lobby.tscn"
const RESOURCE_PROGRESS_END := 0.82
const SCENE_READY_PROGRESS := 0.92
const MULTIPLAYER_READY_PROGRESS_END := 0.99
const MINIMUM_VISIBLE_SECONDS := 0.35
const LOAD_TIMEOUT_SECONDS := 120.0
const MULTIPLAYER_STATE_DISCONNECTED := 0
const MULTIPLAYER_STATE_IN_GAME := 6

enum LoadState {
	IDLE,
	REQUESTING,
	SWITCHING_SCENE,
	WAITING_FOR_MULTIPLAYER,
	COMPLETING,
	FAILED,
}


class LoadRequest extends RefCounted:
	## 重试只复制本次尝试的输入，不再读取协调器上的历史目标。
	var target_scene_path: String
	var manifest: Array[String]
	var multiplayer_load: bool
	var released := false

	func _init(
		p_target_scene_path: String,
		p_manifest: Array[String],
		p_multiplayer_load: bool
	) -> void:
		target_scene_path = p_target_scene_path
		manifest = p_manifest.duplicate()
		multiplayer_load = p_multiplayer_load

	func duplicate_request() -> LoadRequest:
		return LoadRequest.new(target_scene_path, manifest, multiplayer_load)

	func release() -> void:
		if released:
			return
		target_scene_path = ""
		manifest.clear()
		released = true


class LoadAttempt extends RefCounted:
	var generation: int
	var request: LoadRequest
	var requested_paths: Array[String] = []
	var resource_weights: Dictionary = {}
	var loaded_resources: Dictionary = {}
	var started_paths: Dictionary = {}
	var expanded_campaign_paths: Dictionary = {}
	var load_started_msec: int
	var scene_switch_frame := 0
	var released := false
	var release_reason: StringName = &""

	func _init(p_generation: int, p_request: LoadRequest) -> void:
		generation = p_generation
		request = p_request
		load_started_msec = Time.get_ticks_msec()

	## 一个尝试独占全部加载期强引用；释放后，迟到线程结果没有可回写的 owner。
	func release(p_reason: StringName) -> void:
		if released:
			return
		released = true
		release_reason = p_reason
		requested_paths.clear()
		resource_weights.clear()
		loaded_resources.clear()
		started_paths.clear()
		expanded_campaign_paths.clear()
		if request != null:
			request.release()
			request = null

@onready var overlay: Control = $Overlay
@onready var garden_background: TextureRect = $Overlay/GardenBackground
@onready var stage_label: Label = $Overlay/Layout/Stack/Content/Stage
@onready var detail_label: Label = $Overlay/Layout/Stack/Content/Detail
@onready var progress_bar: ProgressBar = $Overlay/Layout/Stack/Content/RouteProgress
@onready var percentage_label: Label = $Overlay/Layout/Stack/Content/ProgressRow/Percentage
@onready var readiness_label: Label = $Overlay/Layout/Stack/Content/ProgressRow/Readiness
@onready var action_row: HBoxContainer = $Overlay/Layout/Stack/Content/ActionRow
@onready var retry_button: Button = $Overlay/Layout/Stack/Content/ActionRow/Retry
@onready var back_button: Button = $Overlay/Layout/Stack/Content/ActionRow/Back
@onready var route_glow: ColorRect = $Overlay/Layout/Stack/Content/RouteGlow

var _state := LoadState.IDLE
var _is_multiplayer_load := false
## 资源、清单、线程状态只能属于当前尝试；失败界面只保存一份不可变重试请求。
var _active_attempt: LoadAttempt = null
var _failed_retry_request: LoadRequest = null
var _displayed_progress := 0.0
var _target_progress := 0.0
var _request_generation := 0
var _net_manager: NetManagerStore = null
var _public_room_lease: PublicRoomLeaseStore = null
var _multiplayer_failure_release_in_progress := false
var _multiplayer_failure_release_token := 0
var _back_navigation_in_progress := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	overlay.hide()
	retry_button.pressed.connect(_on_retry_pressed)
	back_button.pressed.connect(_on_back_pressed)
	_net_manager = NetManagerStore.get_autoload_instance()
	_public_room_lease = PublicRoomLeaseStore.get_autoload_instance()
	if _net_manager != null:
		_net_manager.game_load_progress_changed.connect(
			_on_game_load_progress_changed
		)
		_net_manager.connection_state_changed.connect(
			_on_connection_state_changed
		)


func _exit_tree() -> void:
	# 自动加载退出同样终结租约，避免测试退出或项目关闭时留下加载期引用。
	_invalidate_and_release_active_attempt(&"shutdown")
	_clear_failed_retry_request()


func begin_singleplayer(
	scene_path: String,
	audience: GameModeDefinition.SelectionAudience = (
		GameModeDefinition.SelectionAudience.RELEASE
	)
) -> void:
	if _state != LoadState.IDLE and _state != LoadState.FAILED:
		return
	_clear_failed_retry_request()
	var definition := GameModeCatalog.get_definition_by_singleplayer_entry(scene_path)
	if definition == null:
		_is_multiplayer_load = false
		_show_error("无法识别单人游戏模式：%s" % scene_path)
		return
	if (
		not _is_singleplayer_audience_enabled(audience)
		or not GameModeCatalog.is_selectable_for_audience(
			definition.mode_id,
			audience
		)
	):
		_is_multiplayer_load = false
		_show_error("当前构建未获准运行该单人模式：%s" % scene_path)
		return
	_begin_load(scene_path, _build_singleplayer_manifest(scene_path), false)


func begin_singleplayer_mode(
	mode_id: int,
	audience: GameModeDefinition.SelectionAudience = (
		GameModeDefinition.SelectionAudience.RELEASE
	)
) -> void:
	if _state != LoadState.IDLE and _state != LoadState.FAILED:
		return
	_clear_failed_retry_request()
	var definition := GameModeCatalog.get_definition(mode_id)
	if definition == null:
		if _state == LoadState.IDLE or _state == LoadState.FAILED:
			_is_multiplayer_load = false
			_show_error("无法识别单人游戏模式：%d" % mode_id)
		return
	if (
		not _is_singleplayer_audience_enabled(audience)
		or not GameModeCatalog.is_selectable_for_audience(mode_id, audience)
	):
		if _state == LoadState.IDLE or _state == LoadState.FAILED:
			_is_multiplayer_load = false
			_show_error("当前构建未获准运行该单人模式：%d" % mode_id)
		return
	begin_singleplayer(definition.singleplayer_entry_scene_path, audience)


func _is_singleplayer_audience_enabled(
	audience: GameModeDefinition.SelectionAudience
) -> bool:
	match audience:
		GameModeDefinition.SelectionAudience.RELEASE:
			return true
		GameModeDefinition.SelectionAudience.DEVELOPMENT:
			return OS.is_debug_build()
		_:
			return false


func _build_singleplayer_manifest(scene_path: String) -> Array[String]:
	var manifest: Array[String] = [scene_path]
	var definition := GameModeCatalog.get_definition_by_singleplayer_entry(scene_path)
	if definition == null:
		return manifest
	if definition.uses_wave_campaign:
		_append_existing_resource_path(manifest, definition.singleplayer_campaign_path)
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state != null:
		_append_character_scene(manifest, run_state.get_selected_character_id())
		if definition.include_starting_inventory:
			_append_inventory_runtime_resources(manifest, run_state)
	if not GameModeCatalog.get_preload_resource_paths(definition).is_empty():
		_append_mode_preload_resources(manifest, definition, false)
	return manifest


func _get_singleplayer_campaign_path(scene_path: String) -> String:
	var definition := GameModeCatalog.get_definition_by_singleplayer_entry(scene_path)
	return definition.singleplayer_campaign_path if definition != null else ""


func _uses_tower_defense_runtime(scene_path: String) -> bool:
	var definition := _get_definition_for_runtime_or_entry(scene_path)
	return not GameModeCatalog.get_preload_resource_paths(definition).is_empty()


func _get_definition_for_runtime_or_entry(scene_path: String) -> GameModeDefinition:
	var definition := GameModeCatalog.get_definition_by_singleplayer_entry(scene_path)
	if definition != null:
		return definition
	var catalog := GameModeCatalog.get_shared()
	if catalog == null:
		return null
	for candidate in catalog.definitions:
		if candidate != null and candidate.multiplayer_runtime_scene_path == scene_path:
			return candidate
	return null


func begin_multiplayer() -> void:
	if _state != LoadState.IDLE and _state != LoadState.FAILED:
		return
	_clear_failed_retry_request()
	if _net_manager == null:
		_is_multiplayer_load = true
		_show_error("无法读取多人会话。")
		return
	var game_mode := int(_net_manager.get_current_game_mode())
	var definition := GameModeCatalog.get_definition(game_mode)
	if definition == null:
		_is_multiplayer_load = true
		_show_error("无法识别多人游戏模式：%d" % game_mode)
		return
	if not _net_manager.is_runtime_game_mode_admitted(game_mode):
		_is_multiplayer_load = true
		_show_error("当前构建未获准运行该多人模式：%d" % game_mode)
		return
	var entry_path := definition.multiplayer_entry_scene_path
	var manifest := _build_multiplayer_manifest(game_mode, _net_manager)
	_begin_load(entry_path, manifest, true)


func _build_multiplayer_manifest(
	game_mode: int,
	net_manager: NetManagerStore
) -> Array[String]:
	var definition := GameModeCatalog.get_definition(game_mode)
	if definition == null:
		return []
	var runtime_path := definition.multiplayer_runtime_scene_path
	var entry_path := definition.multiplayer_entry_scene_path
	var manifest: Array[String] = [entry_path]
	if runtime_path != entry_path:
		manifest.append(runtime_path)
	var character_map := net_manager.get_player_character_map()
	for character_id_variant in character_map.values():
		_append_character_scene(manifest, StringName(character_id_variant))
	if definition.uses_wave_campaign:
		_append_existing_resource_path(manifest, definition.multiplayer_campaign_path)
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state != null and definition.include_starting_inventory:
		_append_inventory_runtime_resources(manifest, run_state)
	if not GameModeCatalog.get_preload_resource_paths(definition).is_empty():
		_append_mode_preload_resources(manifest, definition, true)
	return manifest


func _get_multiplayer_entry_path(game_mode: int) -> String:
	var definition := GameModeCatalog.get_definition(game_mode)
	return definition.multiplayer_entry_scene_path if definition != null else ""


func _get_multiplayer_runtime_path(game_mode: int) -> String:
	var definition := GameModeCatalog.get_definition(game_mode)
	return definition.multiplayer_runtime_scene_path if definition != null else ""


func _get_multiplayer_campaign_path(game_mode: int) -> String:
	var definition := GameModeCatalog.get_definition(game_mode)
	return definition.multiplayer_campaign_path if definition != null else ""


func is_loading() -> bool:
	return _state != LoadState.IDLE and _state != LoadState.FAILED


func _begin_load(target_scene_path: String, manifest: Array[String], multiplayer_load: bool) -> void:
	if _back_navigation_in_progress:
		return
	_release_active_attempt(&"replaced")
	_clear_failed_retry_request()
	_request_generation += 1
	var request := LoadRequest.new(target_scene_path, manifest, multiplayer_load)
	var attempt := LoadAttempt.new(_request_generation, request)
	_active_attempt = attempt
	_is_multiplayer_load = multiplayer_load
	_displayed_progress = 0.0
	_target_progress = 0.0
	_state = LoadState.REQUESTING
	action_row.hide()
	back_button.disabled = false
	retry_button.disabled = false
	retry_button.visible = not multiplayer_load
	back_button.text = "返回大厅" if multiplayer_load else "返回主菜单"
	readiness_label.text = ""
	stage_label.text = "正在部署战场"
	detail_label.text = "整理作战资源与地形数据…"
	progress_bar.value = 0.0
	percentage_label.text = "0%"
	overlay.show()
	loading_started.emit(multiplayer_load)

	for path in request.manifest:
		if path.is_empty() or attempt.requested_paths.has(path):
			continue
		if not ResourceLoader.exists(path):
			_show_error("加载清单中的资源不存在：%s" % path)
			return
		attempt.requested_paths.append(path)
		attempt.resource_weights[path] = _get_resource_weight(path)
	_start_next_resource_request()


func _release_active_attempt(reason: StringName) -> void:
	if _active_attempt == null:
		return
	_active_attempt.release(reason)
	_active_attempt = null


func _clear_failed_retry_request() -> void:
	if _failed_retry_request != null:
		_failed_retry_request.release()
	_failed_retry_request = null


func _invalidate_and_release_active_attempt(reason: StringName) -> void:
	_request_generation += 1
	_release_active_attempt(reason)


func _is_active_generation(generation: int) -> bool:
	return (
		_active_attempt != null
		and not _active_attempt.released
		and _active_attempt.generation == generation
	)


func _process(delta: float) -> void:
	if _state == LoadState.IDLE:
		return
	if (
		_state != LoadState.COMPLETING
		and _state != LoadState.FAILED
		and _active_attempt != null
		and Time.get_ticks_msec() - _active_attempt.load_started_msec
		> int(LOAD_TIMEOUT_SECONDS * 1000.0)
	):
		_show_error("战场准备超时，请重试或返回。")
		return
	_update_background_motion()
	_update_progress_visual(delta)
	match _state:
		LoadState.REQUESTING:
			_poll_resource_requests()
		LoadState.SWITCHING_SCENE:
			_poll_scene_switch()
		_:
			pass


func _poll_resource_requests() -> void:
	var attempt := _active_attempt
	if attempt == null or attempt.released:
		return
	var weighted_progress := 0.0
	var total_weight := 0.0
	var all_loaded := true
	var loaded_campaigns_to_expand: Array[Dictionary] = []
	# 失败会立即清空租约；遍历快照可避免在错误分支中修改正在迭代的集合。
	for path in attempt.requested_paths.duplicate():
		var weight := float(attempt.resource_weights.get(path, 1.0))
		total_weight += weight
		if attempt.loaded_resources.has(path):
			weighted_progress += weight
			continue
		if not attempt.started_paths.has(path):
			all_loaded = false
			continue
		var progress: Array = []
		var status := ResourceLoader.load_threaded_get_status(path, progress)
		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				var resource := ResourceLoader.load_threaded_get(path)
				if resource == null:
					_show_error("资源加载完成但无法取得实例：%s" % path)
					return
				attempt.loaded_resources[path] = resource
				weighted_progress += weight
				if path.ends_with("campaign.tres"):
					loaded_campaigns_to_expand.append({
						"path": path,
						"resource": resource,
					})
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				all_loaded = false
				var path_progress := float(progress[0]) if not progress.is_empty() else 0.0
				weighted_progress += clampf(path_progress, 0.0, 1.0) * weight
			ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				_show_error("资源加载失败：%s" % path)
				return
			_:
				all_loaded = false
	for campaign_entry in loaded_campaigns_to_expand:
		var added_weight := _expand_campaign_runtime_manifest(
			str(campaign_entry.get("path", "")),
			campaign_entry.get("resource") as WaveCampaignConfig
		)
		if _state == LoadState.FAILED:
			return
		if added_weight > 0.0:
			total_weight += added_weight
			all_loaded = false
	if total_weight > 0.0:
		_target_progress = maxf(
			_target_progress,
			(weighted_progress / total_weight) * RESOURCE_PROGRESS_END
		)
	if not all_loaded:
		_start_next_resource_request()
		return
	stage_label.text = "正在构建战场"
	detail_label.text = "初始化瓦片、寻路缓存与战斗界面…"
	_target_progress = SCENE_READY_PROGRESS - 0.02
	_state = LoadState.SWITCHING_SCENE
	attempt.scene_switch_frame = Engine.get_process_frames()
	call_deferred("_commit_scene_change", attempt.generation)


func _start_next_resource_request() -> void:
	var attempt := _active_attempt
	if _state != LoadState.REQUESTING or attempt == null or attempt.released:
		return
	# 场景与战役可能共享依赖树；单路线程请求避免并发解析同一依赖，同时不阻塞主线程。
	for started_path_variant in attempt.started_paths.duplicate():
		var started_path := str(started_path_variant)
		if not attempt.loaded_resources.has(started_path):
			return
	for path in attempt.requested_paths.duplicate():
		if attempt.loaded_resources.has(path) or attempt.started_paths.has(path):
			continue
		var existing_status := ResourceLoader.load_threaded_get_status(path)
		if (
			existing_status == ResourceLoader.THREAD_LOAD_IN_PROGRESS
			or existing_status == ResourceLoader.THREAD_LOAD_LOADED
		):
			attempt.started_paths[path] = true
			return
		var error := ResourceLoader.load_threaded_request(
			path,
			"",
			true,
			ResourceLoader.CACHE_MODE_REUSE
		)
		if error != OK:
			_show_error("无法开始加载资源：%s（%s）" % [path, error_string(error)])
			return
		attempt.started_paths[path] = true
		return


func _commit_scene_change(generation: int) -> void:
	if not _is_active_generation(generation) or _state != LoadState.SWITCHING_SCENE:
		return
	var attempt := _active_attempt
	var target_scene_path := attempt.request.target_scene_path
	var target_scene := attempt.loaded_resources.get(target_scene_path) as PackedScene
	if target_scene == null:
		_show_error("目标场景没有作为 PackedScene 加载：%s" % target_scene_path)
		return
	var error := get_tree().change_scene_to_packed(target_scene)
	if error != OK:
		_show_error("切换场景失败：%s" % error_string(error))


func _poll_scene_switch() -> void:
	var attempt := _active_attempt
	if attempt == null or attempt.released:
		return
	if Engine.get_process_frames() <= attempt.scene_switch_frame:
		return
	var expected_scene_path := attempt.request.target_scene_path
	var current_scene := get_tree().current_scene
	if current_scene == null or current_scene.scene_file_path != expected_scene_path:
		return
	if not _poll_runtime_preparation_capability(
		current_scene,
		expected_scene_path
	):
		return
	_target_progress = SCENE_READY_PROGRESS
	if _is_multiplayer_load:
		_state = LoadState.WAITING_FOR_MULTIPLAYER
		stage_label.text = "等待队伍就绪"
		detail_label.text = "本地战场已准备，正在同步所有玩家…"
		retry_button.hide()
		back_button.text = "取消并返回大厅"
		action_row.show()
		_update_multiplayer_readiness_from_manager()
		if (
			_net_manager != null
			and int(_net_manager.connection_state) == MULTIPLAYER_STATE_IN_GAME
		):
			_complete_loading()
	else:
		(current_scene as RuntimePreparationProvider).activate_runtime()
		_complete_loading()


func _poll_runtime_preparation_capability(
	current_scene: Node,
	expected_scene_path: String
) -> bool:
	var provider := current_scene as RuntimePreparationProvider
	if provider == null:
		_freeze_failed_runtime_scene(current_scene)
		_show_error(
			"目标场景缺少强类型运行时准备能力：%s" % expected_scene_path
		)
		return false
	var preparation := provider.get_runtime_preparation_snapshot()
	if preparation.generation <= 0:
		_freeze_failed_runtime_scene(current_scene)
		_show_error(
			"目标场景返回无效运行时准备 generation：%s" % expected_scene_path
		)
		return false
	match preparation.state:
		RuntimePreparationProvider.PreparationState.PREPARING:
			var total := maxi(preparation.total, 1)
			stage_label.text = "正在预热战场"
			detail_label.text = preparation.stage
			_target_progress = maxf(
				_target_progress,
				lerpf(
					0.88,
					SCENE_READY_PROGRESS,
					float(preparation.completed) / float(total)
				)
			)
			return false
		RuntimePreparationProvider.PreparationState.READY:
			return true
		RuntimePreparationProvider.PreparationState.FAILED:
			_freeze_failed_runtime_scene(current_scene)
			_show_error(preparation.failure_reason)
			return false
		_:
			_freeze_failed_runtime_scene(current_scene)
			_show_error(
				"目标场景返回未知运行时准备状态：%s" % expected_scene_path
			)
			return false


func _freeze_failed_runtime_scene(current_scene: Node) -> void:
	if current_scene == null or not is_instance_valid(current_scene):
		return
	# 未实现 Provider 的未知场景不会自行冻结；错误遮罩出现前同步停掉根节点与物理回调。
	current_scene.process_mode = Node.PROCESS_MODE_DISABLED
	current_scene.set_process(false)
	current_scene.set_physics_process(false)


func _update_progress_visual(delta: float) -> void:
	var speed := 1.8 if _state != LoadState.COMPLETING else 4.0
	_displayed_progress = move_toward(_displayed_progress, _target_progress, delta * speed)
	progress_bar.value = _displayed_progress * 100.0
	percentage_label.text = "%d%%" % clampi(roundi(_displayed_progress * 100.0), 0, 100)
	var pulse := 0.72 + sin(Time.get_ticks_msec() * 0.006) * 0.18
	route_glow.modulate.a = clampf(pulse, 0.45, 0.9)


func _update_background_motion() -> void:
	# 只做整数像素漂移，避免文字层受到亚像素变换影响。
	var drift := int(Time.get_ticks_msec() / 90) % 24
	garden_background.offset_left = -drift
	garden_background.offset_top = 0
	garden_background.offset_right = 24 - drift
	garden_background.offset_bottom = 0


func _on_game_load_progress_changed(ready_count: int, total_count: int) -> void:
	if (
		not _is_multiplayer_load
		or (_state != LoadState.SWITCHING_SCENE and _state != LoadState.WAITING_FOR_MULTIPLAYER)
	):
		return
	var safe_total := maxi(total_count, 1)
	var ratio := clampf(float(ready_count) / float(safe_total), 0.0, 1.0)
	_target_progress = maxf(
		_target_progress,
		lerpf(SCENE_READY_PROGRESS, MULTIPLAYER_READY_PROGRESS_END, ratio)
	)
	readiness_label.text = "%d / %d 名玩家就绪" % [ready_count, total_count]


func _update_multiplayer_readiness_from_manager() -> void:
	if _net_manager == null:
		return
	var progress := _net_manager.get_game_load_progress()
	_on_game_load_progress_changed(
		int(progress.get("ready", 0)),
		int(progress.get("total", 0))
	)


func _on_connection_state_changed(new_state: int) -> void:
	if not _is_multiplayer_load:
		return
	if new_state == MULTIPLAYER_STATE_IN_GAME and _state == LoadState.WAITING_FOR_MULTIPLAYER:
		_complete_loading()
	elif (
		new_state == MULTIPLAYER_STATE_DISCONNECTED
		and _state != LoadState.IDLE
		and _state != LoadState.FAILED
	):
		_show_error("多人连接已中断。")


func _complete_loading() -> void:
	if (
		_state == LoadState.COMPLETING
		or _state == LoadState.IDLE
		or _active_attempt == null
	):
		return
	_state = LoadState.COMPLETING
	action_row.hide()
	stage_label.text = "部署完成"
	detail_label.text = "作战路线已确认。"
	_target_progress = 1.0
	call_deferred(
		"_finish_after_minimum_duration",
		_active_attempt.generation
	)


func _finish_after_minimum_duration(generation: int) -> void:
	if not _is_active_generation(generation):
		return
	var elapsed := (
		Time.get_ticks_msec() - _active_attempt.load_started_msec
	) / 1000.0
	var wait_seconds := maxf(MINIMUM_VISIBLE_SECONDS - elapsed, 0.16)
	await get_tree().create_timer(wait_seconds, true, false, true).timeout
	if not _is_active_generation(generation) or _state != LoadState.COMPLETING:
		return
	var completed_multiplayer_load := _active_attempt.request.multiplayer_load
	_displayed_progress = 1.0
	_target_progress = 1.0
	progress_bar.value = 100.0
	percentage_label.text = "100%"
	overlay.hide()
	_invalidate_and_release_active_attempt(&"completed")
	_clear_failed_retry_request()
	_state = LoadState.IDLE
	loading_finished.emit(completed_multiplayer_load)


func _show_error(message: String) -> void:
	var retry_request: LoadRequest = null
	var failed_attempt_generation := _request_generation
	if _active_attempt != null:
		failed_attempt_generation = _active_attempt.generation
		_is_multiplayer_load = _active_attempt.request.multiplayer_load
		if not _active_attempt.request.multiplayer_load:
			retry_request = _active_attempt.request.duplicate_request()
	var failed_session_incarnation := 0
	if _is_multiplayer_load and _net_manager != null:
		failed_session_incarnation = _net_manager.get_game_session_incarnation()
	_invalidate_and_release_active_attempt(&"failed")
	var failed_release_fence_generation := _request_generation
	_clear_failed_retry_request()
	_failed_retry_request = retry_request
	_state = LoadState.FAILED
	stage_label.text = "部署未完成"
	detail_label.text = message
	readiness_label.text = ""
	retry_button.visible = _failed_retry_request != null
	action_row.show()
	overlay.show()
	loading_failed.emit(message)
	if _is_multiplayer_load:
		_multiplayer_failure_release_token += 1
		var release_token := _multiplayer_failure_release_token
		_multiplayer_failure_release_in_progress = true
		call_deferred(
			"_release_failed_multiplayer_load",
			release_token,
			failed_attempt_generation,
			failed_release_fence_generation,
			failed_session_incarnation
		)


func _release_failed_multiplayer_load(
	release_token: int,
	failed_attempt_generation: int,
	failed_release_fence_generation: int,
	failed_session_incarnation: int
) -> void:
	# 旧失败清理可能跨越 HTTP await；加载 generation 与会话 incarnation 必须同时匹配。
	if not _is_current_failed_multiplayer_release(
		release_token,
		failed_attempt_generation,
		failed_release_fence_generation,
		failed_session_incarnation
	):
		_finish_failed_multiplayer_release(release_token)
		return
	if _public_room_lease != null:
		await _public_room_lease.release_current_and_wait(&"multiplayer_load_failed")
	if not _is_current_failed_multiplayer_release(
		release_token,
		failed_attempt_generation,
		failed_release_fence_generation,
		failed_session_incarnation
	):
		_finish_failed_multiplayer_release(release_token)
		return
	if _net_manager != null and _net_manager.is_multiplayer_active():
		_net_manager.disconnect_from_game()
	_finish_failed_multiplayer_release(release_token)


func _is_current_failed_multiplayer_release(
	release_token: int,
	failed_attempt_generation: int,
	failed_release_fence_generation: int,
	failed_session_incarnation: int
) -> bool:
	return (
		is_inside_tree()
		and release_token > 0
		and release_token == _multiplayer_failure_release_token
		and _state == LoadState.FAILED
		and failed_release_fence_generation > failed_attempt_generation
		and _request_generation == failed_release_fence_generation
		and _net_manager != null
		and _net_manager.get_game_session_incarnation()
		== failed_session_incarnation
	)


func _finish_failed_multiplayer_release(release_token: int) -> void:
	if release_token != _multiplayer_failure_release_token:
		return
	_multiplayer_failure_release_in_progress = false


func _on_retry_pressed() -> void:
	if _state != LoadState.FAILED or _failed_retry_request == null:
		return
	var retry_request := _failed_retry_request.duplicate_request()
	_clear_failed_retry_request()
	_begin_load(
		retry_request.target_scene_path,
		retry_request.manifest,
		retry_request.multiplayer_load
	)


func _on_back_pressed() -> void:
	if _back_navigation_in_progress:
		return
	_back_navigation_in_progress = true
	back_button.disabled = true
	retry_button.disabled = true
	_invalidate_and_release_active_attempt(&"returned")
	_clear_failed_retry_request()
	_state = LoadState.IDLE
	overlay.hide()
	if _is_multiplayer_load:
		if _public_room_lease != null:
			await _public_room_lease.release_current_and_wait(
				&"multiplayer_load_back"
			)
		if _net_manager != null:
			_net_manager.disconnect_from_game()
		await _finish_back_navigation(MULTIPLAYER_LOBBY_SCENE_PATH)
	elif get_tree().current_scene == null or get_tree().current_scene.scene_file_path != MAIN_MENU_SCENE_PATH:
		await _finish_back_navigation(MAIN_MENU_SCENE_PATH)
	else:
		_back_navigation_in_progress = false
		back_button.disabled = false
		retry_button.disabled = false


func _finish_back_navigation(target_scene_path: String) -> void:
	var tree := get_tree()
	if tree == null:
		_back_navigation_in_progress = false
		return
	var error := tree.change_scene_to_file(target_scene_path)
	if error == OK:
		await tree.scene_changed
	_back_navigation_in_progress = false
	back_button.disabled = false
	retry_button.disabled = false


func _append_character_scene(manifest: Array[String], character_id: StringName) -> void:
	var config := PlayerCharacterRegistry.get_config(character_id)
	if config == null or config.player_scene.is_empty() or manifest.has(config.player_scene):
		return
	manifest.append(config.player_scene)


func _append_mode_preload_resources(
	manifest: Array[String],
	definition: GameModeDefinition,
	include_all_characters: bool
) -> void:
	for path in GameModeCatalog.get_preload_resource_paths(definition):
		_append_existing_resource_path(manifest, path)
	if include_all_characters:
		for character_config in PlayerCharacterRegistry.get_multiplayer_configs():
			if character_config != null:
				_append_existing_resource_path(manifest, character_config.player_scene)


func _append_inventory_runtime_resources(
	manifest: Array[String],
	run_state: RunStateStore
) -> void:
	if run_state == null:
		return
	_append_inventory_snapshot_resources(manifest, run_state.export_inventory_snapshot())
	for peer_id in run_state.get_registered_inventory_peer_ids():
		if peer_id > 0 and run_state.has_multiplayer_peer_state(peer_id):
			_append_inventory_snapshot_resources(
				manifest,
				run_state.export_inventory_snapshot_for_peer(peer_id)
			)


func _append_inventory_snapshot_resources(
	manifest: Array[String],
	snapshot: Dictionary
) -> void:
	for slot_variant in snapshot.get("slots", []) as Array:
		var slot := slot_variant as Dictionary
		_append_existing_resource_path(manifest, str(slot.get("config_path", "")))


func _append_existing_resource_path(manifest: Array[String], path: String) -> void:
	if path.is_empty() or manifest.has(path) or not ResourceLoader.exists(path):
		return
	manifest.append(path)


func _expand_campaign_runtime_manifest(
	campaign_path: String,
	campaign: WaveCampaignConfig
) -> float:
	var attempt := _active_attempt
	if attempt == null or attempt.released:
		return 0.0
	if campaign_path.is_empty() or attempt.expanded_campaign_paths.has(campaign_path):
		return 0.0
	attempt.expanded_campaign_paths[campaign_path] = true
	if campaign == null or campaign.flow_graph == null:
		return 0.0

	var added_weight := 0.0
	for flow_step in campaign.flow_graph.steps:
		var wave_config := flow_step as WaveConfig
		if wave_config != null:
			for entry in wave_config.enemy_entries:
				if entry == null or entry.enemy_config == null:
					continue
				for runtime_path in [
					entry.enemy_config.resource_path,
					entry.enemy_config.enemy_scene.resource_path
					if entry.enemy_config.enemy_scene != null
					else "",
				]:
					added_weight += _append_campaign_runtime_resource(str(runtime_path))
		var boss_config := flow_step as BossConfig
		if boss_config == null:
			continue
		for runtime_path in [
			boss_config.enemy_config_path,
			boss_config.intro_vfx_scene_path,
			boss_config.boss_hud_scene_path,
		]:
			added_weight += _append_campaign_runtime_resource(str(runtime_path))
	return added_weight


func _append_campaign_runtime_resource(path: String) -> float:
	var attempt := _active_attempt
	if attempt == null or attempt.released:
		return 0.0
	if path.is_empty() or attempt.requested_paths.has(path):
		return 0.0
	if not ResourceLoader.exists(path):
		_show_error("战役加载清单中的资源不存在：%s" % path)
		return 0.0
	attempt.requested_paths.append(path)
	var weight := _get_resource_weight(path)
	attempt.resource_weights[path] = weight
	return weight


func _get_resource_weight(path: String) -> float:
	# 权重按冷启动线程加载耗时校准；共享依赖缓存后，战役与角色资源相对更轻。
	return GameModeCatalog.get_scene_load_weight(path)
