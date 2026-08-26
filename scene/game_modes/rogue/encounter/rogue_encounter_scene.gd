extends Node
class_name RogueEncounterScene

signal intro_ack_requested(occurrence_key: String, expected_revision: int)
signal vote_requested(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
)
signal encounter_revealed(occurrence_key: String, expected_revision: int)
signal result_hold_completed(occurrence_key: String, expected_revision: int)
signal encounter_hidden

## 遭遇是独立的 PackedScene 表现层；权威 Session、经济与 RPC 仍由
## 常驻路线运行时持有。本节点只协调不透明背景、UI 与转场时序。
@onready var presentation: RogueEncounterOverlay = $Presentation
@onready var backdrop_layer: CanvasLayer = $BackdropLayer
@onready var opaque_backdrop: TextureRect = $BackdropLayer/Root/OpaqueBackdrop
@onready var encounter_backdrop: TextureRect = %EncounterBackdrop
@onready var chamber_frame: Panel = $BackdropLayer/Root/ChamberFrame
@onready var top_ambient_band: ColorRect = $BackdropLayer/Root/TopAmbientBand
@onready var bottom_ambient_band: ColorRect = (
	$BackdropLayer/Root/BottomAmbientBand
)

var _transfer_serial := 0
var _backdrop_encounter_id: StringName = &""


func _ready() -> void:
	presentation.intro_ack_requested.connect(_forward_intro_ack_requested)
	presentation.vote_requested.connect(_forward_vote_requested)
	presentation.encounter_revealed.connect(_forward_encounter_revealed)
	presentation.result_hold_completed.connect(
		_forward_result_hold_completed
	)
	presentation.encounter_hidden.connect(_on_presentation_hidden)
	hide_immediately()


func configure_local_context(
	peer_id: int,
	player_names: Dictionary,
	character_ids: Dictionary
) -> void:
	presentation.configure_local_context(
		peer_id,
		player_names,
		character_ids
	)


func apply_state(new_state: Dictionary) -> void:
	_bind_encounter_backdrop(StringName(new_state.get("encounter_id", &"")))
	presentation.apply_state(new_state)


func _bind_encounter_backdrop(encounter_id: StringName) -> void:
	if encounter_id == _backdrop_encounter_id:
		return
	_backdrop_encounter_id = encounter_id
	var config := RogueEncounterRegistry.get_encounter_config(encounter_id)
	var background_path := str(config.get("background_texture_path", ""))
	var background_texture: Texture2D = null
	if (
		not background_path.is_empty()
		and ResourceLoader.exists(background_path, "Texture2D")
	):
		background_texture = load(background_path) as Texture2D
	var uses_encounter_background := background_texture != null
	encounter_backdrop.texture = background_texture
	encounter_backdrop.visible = uses_encounter_background
	opaque_backdrop.visible = not uses_encounter_background
	chamber_frame.visible = not uses_encounter_background
	top_ambient_band.visible = not uses_encounter_background
	bottom_ambient_band.visible = not uses_encounter_background


## 先让着色器在路线画面上完成遮盖，再显示遭遇的独立不透明背景。
## 这样背景不会在转场开始的第一帧突然盖住路线。
func cover_route_for_encounter() -> void:
	_transfer_serial += 1
	var serial := _transfer_serial
	backdrop_layer.visible = false
	await presentation.cover_map_for_encounter()
	if not _transfer_is_current(serial):
		return
	backdrop_layer.visible = true


## 兼容旧的路线调用命名。
func cover_map_for_encounter() -> void:
	await cover_route_for_encounter()


func reveal_encounter() -> void:
	var serial := _transfer_serial
	# 远端全量快照可能直接恢复到活动遭遇；即使没有先播放 cover，
	# 也必须保证路线画面不会透过独立场景。
	backdrop_layer.visible = true
	await presentation.reveal_encounter()
	if not _transfer_is_current(serial):
		return


## 退出第一阶段只遮盖遭遇。外层在 await 返回后恢复路线 World/HUD，
## 全程不销毁也不重定位玩家或 Camera2D。
func cover_encounter_for_route() -> void:
	_transfer_serial += 1
	var serial := _transfer_serial
	await presentation.cover_encounter_for_route()
	if not _transfer_is_current(serial):
		return


## 外层已在全遮盖下恢复路线后，先移除遭遇背景，再揭示原路线。
func reveal_route_after_encounter() -> void:
	_transfer_serial += 1
	var serial := _transfer_serial
	backdrop_layer.visible = false
	await presentation.reveal_route_after_encounter()
	if not _transfer_is_current(serial):
		return


## 兼容原本一次完成退出的 API。独立场景流程应优先分两阶段调用，
## 以便在全遮盖帧内切换 Route/Encounter 两套表现层。
func reveal_map_after_encounter() -> void:
	if not presentation.visible:
		encounter_hidden.emit()
		return
	await cover_encounter_for_route()
	if not presentation.visible:
		return
	await reveal_route_after_encounter()


## 中断、重置或布局回卷时不等待 tween，立即恢复到完全隐藏状态。
## serial 会让任何已挂起的转场协程在恢复后停止继续改动背景。
func hide_immediately() -> void:
	_transfer_serial += 1
	backdrop_layer.visible = false
	presentation.hide_immediately()
	if is_inside_tree():
		get_viewport().gui_release_focus()


func _transfer_is_current(serial: int) -> bool:
	return serial == _transfer_serial and is_inside_tree()


func _forward_intro_ack_requested(
	occurrence_key: String,
	expected_revision: int
) -> void:
	intro_ack_requested.emit(occurrence_key, expected_revision)


func _forward_vote_requested(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> void:
	vote_requested.emit(occurrence_key, expected_revision, option_id)


func _forward_encounter_revealed(
	occurrence_key: String,
	expected_revision: int
) -> void:
	encounter_revealed.emit(occurrence_key, expected_revision)


func _forward_result_hold_completed(
	occurrence_key: String,
	expected_revision: int
) -> void:
	result_hold_completed.emit(occurrence_key, expected_revision)


func _on_presentation_hidden() -> void:
	backdrop_layer.visible = false
	encounter_hidden.emit()
