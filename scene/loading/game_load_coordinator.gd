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
const MULTIPLAYER_STATE_IN_GAME := 5
const CAMPAIGN_RUNTIME_RESOURCES_META := &"_game_load_runtime_resources"

enum LoadState {
	IDLE,
	REQUESTING,
	SWITCHING_SCENE,
	WAITING_FOR_MULTIPLAYER,
	COMPLETING,
	FAILED,
}

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
var _target_scene_path := ""
var _requested_paths: Array[String] = []
var _resource_weights: Dictionary = {}
var _loaded_resources: Dictionary = {}
var _started_paths: Dictionary = {}
var _expanded_campaign_paths: Dictionary = {}
var _runtime_resource_campaign_owners: Dictionary = {}
var _displayed_progress := 0.0
var _target_progress := 0.0
var _load_started_msec := 0
var _scene_switch_frame := 0
var _request_generation := 0
var _net_manager: NetManagerStore = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	overlay.hide()
	retry_button.pressed.connect(_on_retry_pressed)
	back_button.pressed.connect(_on_back_pressed)
	_net_manager = NetManagerStore.get_autoload_instance()
	if _net_manager != null:
		_net_manager.game_load_progress_changed.connect(
			_on_game_load_progress_changed
		)
		_net_manager.connection_state_changed.connect(
			_on_connection_state_changed
		)


func begin_singleplayer(scene_path: String) -> void:
	if _state != LoadState.IDLE and _state != LoadState.FAILED:
		return
	var definition := GameModeCatalog.get_definition_by_singleplayer_entry(scene_path)
	if definition == null:
		_is_multiplayer_load = false
		_show_error("无法识别单人游戏模式：%s" % scene_path)
		return
	if not GameModeCatalog.is_mode_selectable(definition.mode_id):
		_is_multiplayer_load = false
		_show_error("该游戏模式的运行素材尚未发布：%s" % scene_path)
		return
	_begin_load(scene_path, _build_singleplayer_manifest(scene_path), false)


func begin_singleplayer_mode(mode_id: int) -> void:
	var definition := GameModeCatalog.get_definition(mode_id)
	if definition == null:
		if _state == LoadState.IDLE or _state == LoadState.FAILED:
			_is_multiplayer_load = false
			_show_error("无法识别单人游戏模式：%d" % mode_id)
		return
	if not GameModeCatalog.is_mode_selectable(mode_id):
		if _state == LoadState.IDLE or _state == LoadState.FAILED:
			_is_multiplayer_load = false
			_show_error("该游戏模式的运行素材尚未发布：%d" % mode_id)
		return
	begin_singleplayer(definition.singleplayer_entry_scene_path)


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
	if not GameModeCatalog.is_mode_selectable(game_mode):
		_is_multiplayer_load = true
		_show_error("该多人游戏模式的运行素材尚未发布：%d" % game_mode)
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
	_request_generation += 1
	_is_multiplayer_load = multiplayer_load
	_target_scene_path = target_scene_path
	_requested_paths.clear()
	_resource_weights.clear()
	_loaded_resources.clear()
	_started_paths.clear()
	_expanded_campaign_paths.clear()
	_runtime_resource_campaign_owners.clear()
	_displayed_progress = 0.0
	_target_progress = 0.0
	_load_started_msec = Time.get_ticks_msec()
	_scene_switch_frame = 0
	_state = LoadState.REQUESTING
	action_row.hide()
	retry_button.visible = not multiplayer_load
	back_button.text = "返回大厅" if multiplayer_load else "返回主菜单"
	readiness_label.text = ""
	stage_label.text = "正在部署战场"
	detail_label.text = "整理作战资源与地形数据…"
	progress_bar.value = 0.0
	percentage_label.text = "0%"
	overlay.show()
	loading_started.emit(multiplayer_load)

	for path in manifest:
		if path.is_empty() or _requested_paths.has(path):
			continue
		if not ResourceLoader.exists(path):
			_show_error("加载清单中的资源不存在：%s" % path)
			return
		_requested_paths.append(path)
		_resource_weights[path] = _get_resource_weight(path)
	_start_next_resource_request()


func _process(delta: float) -> void:
	if _state == LoadState.IDLE:
		return
	if (
		_state != LoadState.COMPLETING
		and _state != LoadState.FAILED
		and Time.get_ticks_msec() - _load_started_msec > int(LOAD_TIMEOUT_SECONDS * 1000.0)
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
	var weighted_progress := 0.0
	var total_weight := 0.0
	var all_loaded := true
	var loaded_campaigns_to_expand: Array[Dictionary] = []
	for path in _requested_paths:
		var weight := float(_resource_weights.get(path, 1.0))
		total_weight += weight
		if _loaded_resources.has(path):
			weighted_progress += weight
			continue
		if not _started_paths.has(path):
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
				_loaded_resources[path] = resource
				_retain_campaign_runtime_resource(path, resource)
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
	_scene_switch_frame = Engine.get_process_frames()
	call_deferred("_commit_scene_change", _request_generation)


func _start_next_resource_request() -> void:
	if _state != LoadState.REQUESTING:
		return
	# Keep only one threaded request active at a time. Scenes and campaign
	# resources can share dependency trees; serial requests avoid asking the
	# loader to resolve the same dependency concurrently while still keeping the
	# main thread responsive.
	for started_path_variant in _started_paths:
		var started_path := str(started_path_variant)
		if not _loaded_resources.has(started_path):
			return
	for path in _requested_paths:
		if _loaded_resources.has(path) or _started_paths.has(path):
			continue
		var existing_status := ResourceLoader.load_threaded_get_status(path)
		if (
			existing_status == ResourceLoader.THREAD_LOAD_IN_PROGRESS
			or existing_status == ResourceLoader.THREAD_LOAD_LOADED
		):
			_started_paths[path] = true
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
		_started_paths[path] = true
		return


func _commit_scene_change(generation: int) -> void:
	if generation != _request_generation or _state != LoadState.SWITCHING_SCENE:
		return
	var target_scene := _loaded_resources.get(_target_scene_path) as PackedScene
	if target_scene == null:
		_show_error("目标场景没有作为 PackedScene 加载：%s" % _target_scene_path)
		return
	var error := get_tree().change_scene_to_packed(target_scene)
	if error != OK:
		_show_error("切换场景失败：%s" % error_string(error))


func _poll_scene_switch() -> void:
	if Engine.get_process_frames() <= _scene_switch_frame:
		return
	var current_scene := get_tree().current_scene
	if current_scene == null or current_scene.scene_file_path != _target_scene_path:
		return
	if (
		current_scene.has_method("is_runtime_preparation_complete")
		and not bool(current_scene.call("is_runtime_preparation_complete"))
	):
		if current_scene.has_method("get_runtime_preparation_progress"):
			var preparation := current_scene.call("get_runtime_preparation_progress") as Dictionary
			var completed := int(preparation.get("completed", 0))
			var total := maxi(int(preparation.get("total", 1)), 1)
			stage_label.text = "正在预热战场"
			detail_label.text = str(preparation.get("stage", "准备运行时缓存…"))
			_target_progress = maxf(
				_target_progress,
				lerpf(0.88, SCENE_READY_PROGRESS, float(completed) / float(total))
			)
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
		if current_scene.has_method("activate_runtime"):
			current_scene.call("activate_runtime")
		_complete_loading()


func _update_progress_visual(delta: float) -> void:
	var speed := 1.8 if _state != LoadState.COMPLETING else 4.0
	_displayed_progress = move_toward(_displayed_progress, _target_progress, delta * speed)
	progress_bar.value = _displayed_progress * 100.0
	percentage_label.text = "%d%%" % clampi(roundi(_displayed_progress * 100.0), 0, 100)
	var pulse := 0.72 + sin(Time.get_ticks_msec() * 0.006) * 0.18
	route_glow.modulate.a = clampf(pulse, 0.45, 0.9)


func _update_background_motion() -> void:
	# Integer-only drift keeps the background calm without introducing fractional text transforms.
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
	if _state == LoadState.COMPLETING or _state == LoadState.IDLE:
		return
	_state = LoadState.COMPLETING
	action_row.hide()
	stage_label.text = "部署完成"
	detail_label.text = "作战路线已确认。"
	_target_progress = 1.0
	call_deferred("_finish_after_minimum_duration", _request_generation)


func _finish_after_minimum_duration(generation: int) -> void:
	var elapsed := (Time.get_ticks_msec() - _load_started_msec) / 1000.0
	var wait_seconds := maxf(MINIMUM_VISIBLE_SECONDS - elapsed, 0.16)
	await get_tree().create_timer(wait_seconds, true, false, true).timeout
	if generation != _request_generation or _state != LoadState.COMPLETING:
		return
	_displayed_progress = 1.0
	_target_progress = 1.0
	progress_bar.value = 100.0
	percentage_label.text = "100%"
	overlay.hide()
	_loaded_resources.clear()
	_requested_paths.clear()
	_started_paths.clear()
	_expanded_campaign_paths.clear()
	_runtime_resource_campaign_owners.clear()
	_state = LoadState.IDLE
	loading_finished.emit(_is_multiplayer_load)


func _show_error(message: String) -> void:
	_state = LoadState.FAILED
	stage_label.text = "部署未完成"
	detail_label.text = message
	readiness_label.text = ""
	action_row.show()
	overlay.show()
	loading_failed.emit(message)


func _on_retry_pressed() -> void:
	if _is_multiplayer_load:
		begin_multiplayer()
	else:
		begin_singleplayer(_target_scene_path)


func _on_back_pressed() -> void:
	_request_generation += 1
	_loaded_resources.clear()
	_requested_paths.clear()
	_started_paths.clear()
	_expanded_campaign_paths.clear()
	_runtime_resource_campaign_owners.clear()
	_state = LoadState.IDLE
	overlay.hide()
	if _is_multiplayer_load:
		if _net_manager != null:
			_net_manager.disconnect_from_game()
		get_tree().change_scene_to_file(MULTIPLAYER_LOBBY_SCENE_PATH)
	elif get_tree().current_scene == null or get_tree().current_scene.scene_file_path != MAIN_MENU_SCENE_PATH:
		get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)


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
		for character_config in PlayerCharacterRegistry.get_all_configs():
			if character_config != null:
				_append_existing_resource_path(manifest, character_config.player_scene)


func _append_inventory_runtime_resources(
	manifest: Array[String],
	run_state: RunStateStore
) -> void:
	if run_state == null:
		return
	_append_inventory_snapshot_resources(manifest, run_state.export_inventory_snapshot())
	for peer_id_variant in run_state.multiplayer_inventories.keys():
		var peer_id := int(peer_id_variant)
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
	if campaign_path.is_empty() or _expanded_campaign_paths.has(campaign_path):
		return 0.0
	_expanded_campaign_paths[campaign_path] = true
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
					added_weight += _append_campaign_runtime_resource(
						campaign,
						str(runtime_path)
					)
		var boss_config := flow_step as BossConfig
		if boss_config == null:
			continue
		for runtime_path in [
			boss_config.enemy_config_path,
			boss_config.intro_vfx_scene_path,
			boss_config.boss_hud_scene_path,
		]:
			added_weight += _append_campaign_runtime_resource(campaign, str(runtime_path))
	return added_weight


func _append_campaign_runtime_resource(
	campaign: WaveCampaignConfig,
	path: String
) -> float:
	if path.is_empty() or _requested_paths.has(path):
		return 0.0
	if not ResourceLoader.exists(path):
		_show_error("战役加载清单中的资源不存在：%s" % path)
		return 0.0
	_requested_paths.append(path)
	_runtime_resource_campaign_owners[path] = campaign
	var weight := _get_resource_weight(path)
	_resource_weights[path] = weight
	return weight


func _retain_campaign_runtime_resource(path: String, resource: Resource) -> void:
	var campaign := _runtime_resource_campaign_owners.get(path) as WaveCampaignConfig
	if campaign == null or resource == null:
		return
	var retained := campaign.get_meta(CAMPAIGN_RUNTIME_RESOURCES_META, {}) as Dictionary
	retained[path] = resource
	campaign.set_meta(CAMPAIGN_RUNTIME_RESOURCES_META, retained)


func _get_resource_weight(path: String) -> float:
	# Calibrated against cold threaded-load timings. Runtime scenes and the
	# multiplayer wrapper own most script/texture dependencies; Campaign and
	# selected-character resources become comparatively cheap after that shared
	# closure is cached.
	return GameModeCatalog.get_scene_load_weight(path)
