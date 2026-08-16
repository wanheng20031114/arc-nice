extends RuntimePreparationProvider
class_name RogueRouteGame

const ROUTE_INPUT_CONTROL_LOCK_OWNER := &"rogue_route_input"

signal host_layout_committed(
	layout_snapshot: Dictionary,
	state_snapshot: Dictionary
)
signal host_move_committed(delta: Dictionary)
signal host_briefing_state_committed(briefing_snapshot: Dictionary)
signal briefing_cover_completed(
	occurrence_key: String,
	briefing_revision: int,
	expected_route_revision: int
)
signal host_encounter_snapshot_committed(
	encounter_snapshot: Dictionary,
	economy_snapshot: Dictionary
)
signal encounter_intro_ack_requested(
	occurrence_key: String,
	expected_revision: int
)
signal encounter_vote_requested(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
)
signal encounter_result_ack_requested(
	occurrence_key: String,
	result_sequence: int
)
signal host_shop_snapshot_committed(
	target_peer_id: int,
	shop_snapshot: Dictionary
)
signal shop_purchase_requested(
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_session_revision: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
)
signal shop_sell_requested(
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_session_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
)
signal shop_exit_ack_requested(
	occurrence_key: String,
	expected_session_revision: int
)
signal combat_requested(
	node_id: int,
	content_seed: int,
	occurrence_key: String,
	combat_config_id: StringName
)
## 仅保留给既有测试和只读观察者的普通作战兼容信号；正式协调器统一订阅
## combat_requested，特殊作战绝不会通过此信号分发。
signal normal_combat_requested(
	node_id: int,
	content_seed: int,
	occurrence_key: String
)
signal normal_combat_stage_reset(occurrence_key: String)
signal combat_result_dismissed
signal return_requested

const MAIN_MENU_SCENE_PATH := "res://scene/main_menu.tscn"
const INVALID_NODE_ID := -1
const AUTO_SEED := 0
const ROUTE_CONTRACT_FIELD := "runtime_contract_hash"
const SINGLEPLAYER_PEER_ID := 0
const BRIEFING_STATE_FIELD := "briefing_state"
const BRIEFING_SCHEMA_VERSION := 3
const NORMAL_COMBAT_BRIEFING_ADAPTER_SCRIPT := preload(
	"res://scene/game_modes/rogue/route/rogue_normal_combat_briefing_adapter.gd"
)
const EMERGENCY_COMBAT_BRIEFING_ADAPTER_SCRIPT := preload(
	"res://scene/game_modes/rogue/route/rogue_emergency_combat_briefing_adapter.gd"
)
const SPECIAL_COMBAT_BRIEFING_ADAPTER_SCRIPT := preload(
	"res://scene/game_modes/rogue/route/rogue_special_combat_briefing_adapter.gd"
)
const SUITCASE_FOLLOWUP_COMBAT_ID := &"suitcase_battle"
const SUITCASE_FOLLOWUP_RESULT_CODE := &"suitcase_robots_alerted"
const SUITCASE_FOLLOWUP_PRESENTATION := &"pages"
const SUPPLY_COLLECTIBLE_CHOICE_WIRE_PREFIX := "supply_collectible_choice:"
const SUPPLY_INVENTORY_DISCARD_WIRE_PREFIX := "supply_inventory_discard|"
const FLOOR_DEFINITION_SCRIPT := preload(
	"res://resources/config/rogue_route/rogue_route_floor_definition.gd"
)
const AVATAR_SPAWN_OFFSETS := [
	Vector2.ZERO,
	Vector2(12.0, 0.0),
	Vector2(-12.0, 0.0),
	Vector2(0.0, 12.0),
	Vector2(0.0, -12.0),
	Vector2(12.0, 12.0),
	Vector2(-12.0, 12.0),
	Vector2(12.0, -12.0),
]

enum BriefingPhase {
	NONE,
	PRESENTED,
	ENTERING,
}

## 会独占路线世界表现的三个生命周期 owner。位掩码允许完整快照、重连
## 与连续节点转场在短时间内交叠；每个子系统只能释放自己持有的 lease。
enum RoutePresentationLease {
	COMBAT = 1,
	MAGICAL_ENCOUNTER = 2,
	UNDERGROUND_SHOP = 4,
}

## 路线 Player 的 old->new 身份投影结果。READY 只来自纯预检；MIGRATED
## 表示所有路线身份字段已作为一个提交换键，ALREADY_CURRENT 用于可靠重放。
enum ReconnectedPlayerIdentityProjectionResult {
	INVALID,
	READY,
	MIGRATED,
	ALREADY_CURRENT,
	CONFLICT,
}

const ROUTE_PRESENTATION_FULL_HIDE_MASK := (
	RoutePresentationLease.COMBAT
	| RoutePresentationLease.MAGICAL_ENCOUNTER
)

@export var floor_definition: FLOOR_DEFINITION_SCRIPT
@export var auto_initialize := true
@export var manage_return_locally := true
## 嵌入其他正式流程时仍使用完整 Rogue 运行时，但返回权由外层协调器持有。
@export var embedded_session := false
## 0 表示每次进入时生成新 seed；非零值便于复现指定地图。
@export var initial_generation_seed := AUTO_SEED

@onready var world: RogueRouteWorld = $World
@onready var route_music_player: AudioStreamPlayer = $RouteMusicPlayer
@onready var route_board: RogueRouteBoard = $World/RouteBoard
@onready var player_container: Node2D = $World/Players
@onready var map_camera: Camera2D = $World/Camera2D
@onready var top_bar: RogueRouteTopBar = $HUD/Root/TopBar
@onready var content_overline: Label = %ContentOverline
@onready var content_title: Label = %ContentTitle
@onready var content_body: Label = %ContentBody
@onready var content_meta: Label = %ContentMeta
@onready var regenerate_button: Button = %RegenerateButton
@onready var hint_label: Label = %Hint
@onready var status_message: Label = %StatusMessage
@onready var route_hud: CanvasLayer = $HUD
@onready var route_inventory_strip: RogueRouteInventoryStrip = (
	$HUD/Root/BottomBar/RogueRouteInventoryStrip
)
@onready var player_profile_panel: RoguePlayerProfilePanel = (
	$RoguePlayerProfilePanel
)
@onready var move_confirmation: RogueRouteMoveConfirmation = $MoveConfirmation
@onready var node_briefing: RogueRouteNodeBriefing = $NodeBriefing
@onready var encounter_scene: RogueEncounterScene = $EncounterScene
@onready var encounter_economy: RogueEncounterEconomyCoordinator = (
	$EncounterEconomy
)
@onready var encounter_session: RogueEncounterSession = $EncounterSession
@onready var supply_economy: RogueSupplyEconomyCoordinator = $SupplyEconomy
@onready var supply_session: RogueSupplySession = $SupplySession
@onready var supply_overlay: RogueSupplyOverlay = $SupplyOverlay
@onready var rare_chest_economy: RogueRareChestEconomyCoordinator = (
	$RareChestEconomy
)
@onready var rare_chest_session: RogueRareChestSession = $RareChestSession
@onready var rare_chest_overlay: RogueRareChestOverlay = $RareChestOverlay
@onready var underground_shop_controller: RogueUndergroundShopController = (
	$UndergroundShopController
)
@onready var combat_result_overlay: RogueCombatResultOverlay = (
	$CombatResultOverlay
)
@onready var combat_victory_presentation: RogueCombatVictoryPresentation = (
	$CombatVictoryPresentation
)
@onready var combat_scene_transition: RogueSceneTransition = (
	$CombatSceneTransition
)
@onready var emergency_reward_choice_overlay: RogueEmergencyRewardChoiceOverlay = (
	$EmergencyRewardChoiceOverlay
)
@onready var run_defeat_overlay: RogueRunDefeatOverlay = $RunDefeatOverlay

## 保留战斗协调器与既有测试使用的 Overlay 访问契约；实际表现已由
## 独立 RogueEncounterScene 承载，权威状态仍留在当前路线根节点。
var encounter_overlay: RogueEncounterOverlay:
	get:
		return (
			encounter_scene.presentation
			if encounter_scene != null
			else null
		)

## 兼容既有外部调用者的只读入口；楼层资源是唯一可配置来源。
var generation_config: RogueRouteGenerationConfig:
	get:
		return (
			floor_definition.generation_config
			if floor_definition != null
			else null
		)

var _route_graph: RogueRouteGraph = null
var _runtime_state: RogueRouteRuntimeState = null
var _authority_enabled := true
var _route_ready := false
var _pending_node_id := INVALID_NODE_ID
var _pending_revision := -1
var _briefing_revision := 0
var _briefing_phase := BriefingPhase.NONE
var _briefing_node_id := INVALID_NODE_ID
var _briefing_occurrence_key := ""
var _briefing_expected_route_revision := -1
var _briefing_source_kind: StringName = &""
var _briefing_combat_config_id: StringName = &""
var _briefing_source_encounter_occurrence_key := ""
var _normal_combat_briefing_adapters: Dictionary = {}
var _emergency_combat_briefing_adapters: Dictionary = {}
var _special_combat_briefing_adapters: Dictionary = {}
var player: Player = null
var peer_players: Dictionary[int, Player] = {}
var _local_peer_id := 0
var _multiplayer_avatar_mode := false
var _camera_drag_active := false
var _encounter_input_locked := false
var _route_reveal_input_locked := false
var _runtime_activated := false
var _encounter_presented_active := false
var _encounter_presentation_serial := 0
var _local_result_hold_completed_occurrence_key := ""
var _last_supply_ap_broadcast_occurrence_key := ""
var _local_supply_modal_owner_active := false
var _rare_chest_presented_active := false
var _rare_chest_presentation_dismiss_pending := false
var _rare_chest_presentation_serial := 0
var _rare_chest_local_offer_seen_occurrences: Dictionary = {}
var _rare_chest_local_heal_applied_occurrences: Dictionary = {}
var _normal_combat_active := false
var _normal_combat_node_id := INVALID_NODE_ID
var _normal_combat_content_seed := 0
var _normal_combat_visit_count := 0
var _normal_combat_occurrence_key := ""
var _normal_combat_config_id: StringName = &""
var _route_presentation_enabled := true
var _route_presentation_leases := 0
var _player_names: Dictionary = {}
var _player_character_ids: Dictionary = {}
var _player_stable_keys: Dictionary = {SINGLEPLAYER_PEER_ID: "singleplayer:local"}
var _run_state: RunStateStore = null
var _run_failure_presented := false
var _cached_max_health_penalties: Dictionary = {}
var _max_health_transition_by_peer: Dictionary = {}
var _physics_interpolation_lease_token := (
	GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
)
var _floor_definition_applied := false
var _embedded_environment: Environment = null
var _embedded_canvas_layer_visibility: Dictionary = {}


func _enter_tree() -> void:
	_floor_definition_applied = _apply_floor_definition_before_children_ready()
	# 路线与塔防可同时存活；共享物理插值由租约计数，退出次序不影响基线。
	var runtime_policy_lease := (
		GlobalRuntimePolicyLeaseStore.get_autoload_instance()
	)
	if runtime_policy_lease == null:
		push_error("RogueRouteGame: 缺少全局运行策略租约协调器。")
	else:
		_physics_interpolation_lease_token = (
			runtime_policy_lease.acquire_physics_interpolation(self, true)
		)
		if (
			_physics_interpolation_lease_token
			== GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
		):
			push_error("RogueRouteGame: 无法获取物理插值租约。")
	# 嵌入式路线从首帧起就不能与塔防争夺 WorldEnvironment / Camera2D。
	# 父节点 _enter_tree 先于子节点执行，但完整场景树已可按路径访问。
	if embedded_session:
		visible = false
		_set_embedded_canvas_layers_visible(false)
		var route_environment := get_node_or_null(
			"RouteBeaconGlowEnvironment"
		) as WorldEnvironment
		if route_environment != null:
			_embedded_environment = route_environment.environment
			route_environment.environment = null
		var embedded_camera := get_node_or_null("World/Camera2D") as Camera2D
		if embedded_camera != null:
			embedded_camera.enabled = false


func _ready() -> void:
	var preparation_generation := begin_runtime_preparation(
		"正在初始化 Rogue 路线…",
		1
	)
	if not _floor_definition_applied:
		var reason := "路线楼层定义无效，无法初始化路线。"
		_set_status(reason, true)
		mark_runtime_preparation_failed(preparation_generation, reason)
		return
	update_runtime_preparation_progress(
		preparation_generation,
		"正在生成 Rogue 路线图…",
		0,
		1
	)
	_create_normal_combat_briefing_adapters()
	_create_emergency_combat_briefing_adapters()
	_create_special_combat_briefing_adapters()
	top_bar.set_floor_title(floor_definition.display_name)
	_connect_runtime_activation_signal()
	_create_encounter_runtime()
	_create_supply_runtime()
	_create_rare_chest_runtime()
	if not player_profile_panel.opened.is_connected(_on_player_profile_opened):
		player_profile_panel.opened.connect(_on_player_profile_opened)
	if not player_profile_panel.closed.is_connected(_on_player_profile_closed):
		player_profile_panel.closed.connect(_on_player_profile_closed)
	if not player_profile_panel.multiplayer_inventory_item_discard_requested.is_connected(
		_on_supply_profile_inventory_discard_requested
	):
		player_profile_panel.multiplayer_inventory_item_discard_requested.connect(
			_on_supply_profile_inventory_discard_requested
		)
	route_board.show_waiting_for_host()
	if not route_board.entry_reveal_finished.is_connected(
		_on_route_entry_reveal_finished
	):
		route_board.entry_reveal_finished.connect(
			_on_route_entry_reveal_finished
		)
	if manage_return_locally:
		_configure_singleplayer_player()
	_connect_party_status_ledger()
	_create_underground_shop_runtime()
	if run_defeat_overlay != null and not run_defeat_overlay.confirmed.is_connected(
		_on_run_defeat_confirmed
	):
		run_defeat_overlay.confirmed.connect(_on_run_defeat_confirmed)
	_update_authority_ui()
	_update_route_hud()
	_show_node_content(INVALID_NODE_ID, false)
	if auto_initialize:
		call_deferred("_initialize_default_session", preparation_generation)
	else:
		_set_status("等待外部会话初始化。", false)
	call_deferred("_activate_runtime_when_loader_is_idle")


func _exit_tree() -> void:
	var runtime_policy_lease := (
		GlobalRuntimePolicyLeaseStore.get_autoload_instance()
	)
	if (
		runtime_policy_lease != null
		and _physics_interpolation_lease_token
		!= GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
	):
		runtime_policy_lease.release_physics_interpolation(
			_physics_interpolation_lease_token
		)
	_physics_interpolation_lease_token = (
		GlobalRuntimePolicyLeaseStore.INVALID_LEASE_TOKEN
	)


## 父节点先于子节点进入 SceneTree；在这里统一分发楼层依赖，确保
## Board、World 与战斗协调器各自执行 _ready() 时只看到同一份资源。
func _apply_floor_definition_before_children_ready() -> bool:
	var board := get_node_or_null("World/RouteBoard") as RogueRouteBoard
	var background := get_node_or_null(
		"World/Backdrop/RuinsBackground"
	) as Sprite2D
	if board == null or background == null:
		_report_floor_definition_error(
			"RogueRouteGame 的楼层依赖节点结构不完整。"
		)
		return false
	# 先清除表现层依赖，失败路径不得留下隐藏兜底。
	board.world_metrics = null
	background.texture = null
	if floor_definition == null:
		_report_floor_definition_error("RogueRouteGame 缺少 floor_definition。")
		return false
	var definition_errors := floor_definition.validate_definition()
	if not definition_errors.is_empty():
		_report_floor_definition_error(
			"RogueRouteGame 的 floor_definition 无效：%s"
			% [definition_errors]
		)
		return false
	board.world_metrics = floor_definition.world_metrics
	background.texture = floor_definition.background_texture
	return true


func _report_floor_definition_error(message: String) -> void:
	# 离树状态允许工具先做无副作用预检；真实场景生命周期中的失败必须可见。
	if is_inside_tree():
		push_error(message)


func _process(delta: float) -> void:
	if _authority_enabled and encounter_session != null:
		encounter_session.tick(maxf(delta, 0.0))
	if _authority_enabled and supply_session != null:
		supply_session.tick(maxf(delta, 0.0))


func _physics_process(_delta: float) -> void:
	if player != null and is_instance_valid(player):
		_clamp_camera_drag_offset()


func _unhandled_input(event: InputEvent) -> void:
	if _is_route_input_locked() or _pending_node_id != INVALID_NODE_ID:
		_camera_drag_active = false
		return
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
			return
		_camera_drag_active = mouse_button.pressed
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and _camera_drag_active:
		var mouse_motion := event as InputEventMouseMotion
		var drag_mask := MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_MIDDLE
		if (mouse_motion.button_mask & drag_mask) == 0:
			_camera_drag_active = false
			return
		_apply_camera_drag(mouse_motion.relative)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if (
			key_event.pressed
			and not key_event.echo
			and key_event.keycode == KEY_HOME
		):
			_recenter_camera_on_player()
			get_viewport().set_input_as_handled()


func start_authoritative_session(
	generation_seed: int = AUTO_SEED,
	announce_full_snapshot: bool = true,
	initial_action_points_override: int = -1
) -> bool:
	if generation_config == null:
		_set_status("路线生成配置缺失。", true)
		return false
	var config_errors := generation_config.validate_config()
	if not config_errors.is_empty():
		_set_status("路线配置无效：%s" % "；".join(config_errors), true)
		return false

	var resolved_seed := generation_seed
	if resolved_seed == AUTO_SEED:
		resolved_seed = randi_range(1, 2147483646)
	var generated_graph := RogueRouteGenerator.generate(
		generation_config,
		resolved_seed
	)
	if generated_graph == null:
		_set_status("路线图生成失败。", true)
		return false
	var resolved_initial_action_points := (
		generation_config.initial_action_points
		if initial_action_points_override < 0
		else initial_action_points_override
	)
	if resolved_initial_action_points > RogueRouteRuntimeState.MAX_ACTION_POINTS:
		_set_status("路线初始行动力超出运行上限。", true)
		return false
	var generated_state := RogueRouteRuntimeState.new()
	if not generated_state.initialize(
		generated_graph,
		resolved_initial_action_points
	):
		_set_status("路线运行状态初始化失败。", true)
		return false
	_reset_briefing_runtime(true)
	_reset_normal_combat_stage(true)
	_reset_encounter_runtime(true)
	_reset_supply_runtime(true)
	_reset_rare_chest_runtime(true)
	_reset_underground_shop_runtime(true)
	_reset_run_defeat_presentation()

	_set_route_reveal_input_locked(false)
	_clear_pending_move(true)
	set_authority_enabled(true)
	if not route_board.present_graph(
		generated_graph,
		generation_config,
		generated_state.current_node_id,
		generated_state.action_points,
		generated_state.visited_counts,
		true
	):
		_set_status("路线图视觉层初始化失败。", true)
		return false
	_bind_runtime_state(generated_graph, generated_state)
	_route_ready = true
	_reposition_route_players_at_start()
	_configure_camera_world_bounds()
	_recenter_camera_on_player()
	_update_route_hud()
	_show_node_content(_runtime_state.current_node_id, false)
	_set_status("路线世界已生成。可自由探索，点击青色相邻节点即可选择路线。", false)
	if announce_full_snapshot:
		host_layout_committed.emit(
			export_layout_snapshot(),
			export_state_snapshot()
		)
	_try_play_route_entry_reveal()
	return true


## 由嵌入式单人流程显式启用；多人路线不会误创建本地单人角色或单人作战。
func configure_embedded_singleplayer_player() -> bool:
	if not is_node_ready():
		return false
	embedded_session = true
	_configure_singleplayer_player()
	var combat_coordinator := get_node_or_null(
		"SingleplayerCombatCoordinator"
	) as RogueCombatSingleplayerCoordinator
	if player == null or combat_coordinator == null:
		return false
	combat_coordinator.bind_embedded_route(self)
	return combat_coordinator.is_enabled()


## 只有权威路线可追加共享行动力；奖励 revision 会进入既有全量快照。
func grant_authoritative_action_points(amount: int) -> bool:
	return (
		_authority_enabled
		and is_route_ready()
		and _runtime_state.grant_action_points(amount)
	)


func get_action_points() -> int:
	return _runtime_state.action_points if is_route_ready() else -1


## 每次嵌入式探索显现前，从 RunState 刷新永久属性与最大生命惩罚，
## 再把路线角色恢复到当前有效上限。多人各端对同一权威 RunState 快照
## 做绝对值恢复，不产生奖励，也不会改写路线运行 revision。
func restore_embedded_players_to_full_health() -> bool:
	if not embedded_session:
		return false
	if _run_state == null:
		_run_state = get_node_or_null("/root/RunState") as RunStateStore
	if _run_state == null:
		return false
	var restored_any := false
	if _multiplayer_avatar_mode:
		for raw_peer_id in peer_players.keys():
			var peer_id := int(raw_peer_id)
			var peer_player := peer_players.get(peer_id) as Player
			if peer_player == null or not is_instance_valid(peer_player):
				continue
			_restore_embedded_player_to_full_health(peer_player, peer_id)
			restored_any = true
		return restored_any
	if player == null or not is_instance_valid(player):
		return false
	_restore_embedded_player_to_full_health(player, SINGLEPLAYER_PEER_ID)
	return true


func _restore_embedded_player_to_full_health(
	player_instance: Player,
	ledger_peer_id: int
) -> void:
	player_instance.set_run_max_health_penalty(
		_run_state.get_max_health_penalty_for_peer(ledger_peer_id)
	)
	player_instance.configure_run_stat_bonuses(
		_run_state.get_player_stat_bonuses(ledger_peer_id),
		true
	)
	# 即使绝对账本未变化，也要重算收藏品与惩罚的组合上限。
	player_instance.refresh_collectible_stats()
	player_instance.apply_multiplayer_full_health_restore(
		player_instance.global_position,
		maxi(player_instance.max_health, 1)
	)


## 日终自动返回的唯一稳定性判定。每个持久交互 owner 都必须已经释放，
## 避免行动力刚归零时跳过作战、奖励、背包整理或商店离场确认。
func is_exploration_settled_for_return() -> bool:
	if not is_route_ready() or _run_failure_presented:
		return false
	var singleplayer_combat := get_node_or_null(
		"SingleplayerCombatCoordinator"
	) as RogueCombatSingleplayerCoordinator
	return (
		_pending_node_id == INVALID_NODE_ID
		and _briefing_phase == BriefingPhase.NONE
		and not _route_reveal_input_locked
		and _route_presentation_leases == 0
		and not _normal_combat_active
		and (
			singleplayer_combat == null
			or not singleplayer_combat.is_runtime_busy()
		)
		and not _encounter_input_locked
		and not _encounter_presented_active
		and (
			encounter_session == null
			or not encounter_session.is_active()
		)
		and (
			supply_session == null
			or not supply_session.is_active()
		)
		and not _is_local_supply_modal_owner()
		and not _rare_chest_presented_active
		and not _rare_chest_presentation_dismiss_pending
		and (
			rare_chest_session == null
			or not rare_chest_session.is_active()
		)
		and not _is_local_shop_presentation_active()
		and not _is_shop_departure_blocked()
		and (
			combat_result_overlay == null
			or not combat_result_overlay.visible
		)
		and (
			emergency_reward_choice_overlay == null
			or not emergency_reward_choice_overlay.visible
		)
		and (
			player_profile_panel == null
			or not player_profile_panel.is_open()
		)
	)


func has_run_failed() -> bool:
	return _run_failure_presented


## 外层正式流程确认失败已消费后清理本地表现；不回主菜单、不回大厅。
func acknowledge_embedded_run_failure() -> bool:
	if not embedded_session or not _run_failure_presented:
		return false
	_reset_run_defeat_presentation()
	_set_encounter_input_locked(false)
	_refresh_route_input_lock()
	return true


func set_embedded_presentation_active(active: bool) -> void:
	if not embedded_session:
		return
	if not active and world != null:
		# 先撤销路线对共享 viewport canvas transform 的像素相位接管，
		# 再停相机，避免最后一帧吸附残留到塔防相机。
		world.set_route_pixel_snap_enabled(false)
	visible = active
	process_mode = (
		Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	)
	if not is_node_ready():
		return
	_set_embedded_canvas_layers_visible(active)
	var route_environment := get_node_or_null(
		"RouteBeaconGlowEnvironment"
	) as WorldEnvironment
	if route_environment != null:
		if _embedded_environment == null and route_environment.environment != null:
			_embedded_environment = route_environment.environment
		route_environment.environment = _embedded_environment if active else null
	if active:
		# 统一复用 route presentation lease 的原生相机交接、HUD 与像素吸附
		# 协调，确保外部 Tower Camera 后重新 make_current。
		_apply_route_presentation_leases()
	else:
		if route_hud != null:
			route_hud.visible = false
		if map_camera != null:
			map_camera.enabled = false
		if world != null:
			world.set_process(false)
	set_process_unhandled_input(active)
	_reconcile_route_music()


func _set_embedded_canvas_layers_visible(active: bool) -> void:
	for canvas_layer in find_children("*", "CanvasLayer", true, false):
		var typed_layer := canvas_layer as CanvasLayer
		if typed_layer == null:
			continue
		if active:
			typed_layer.visible = bool(
				_embedded_canvas_layer_visibility.get(typed_layer, true)
			)
		else:
			if not _embedded_canvas_layer_visibility.has(typed_layer):
				_embedded_canvas_layer_visibility[typed_layer] = typed_layer.visible
			typed_layer.visible = false
	if active:
		_embedded_canvas_layer_visibility.clear()


func start_client_waiting() -> int:
	var preparation_generation := begin_runtime_preparation(
		"正在等待房主同步路线图…",
		1
	)
	_set_route_reveal_input_locked(false)
	_reset_briefing_runtime(true)
	_clear_pending_move(true)
	_reset_normal_combat_stage(true)
	_reset_encounter_runtime(false)
	_reset_supply_runtime(false)
	_reset_rare_chest_runtime(false)
	_reset_underground_shop_runtime(false)
	_disconnect_runtime_state()
	_route_graph = null
	_runtime_state = null
	_route_ready = false
	set_authority_enabled(false)
	route_board.show_waiting_for_host()
	_update_route_hud()
	_show_node_content(INVALID_NODE_ID, false)
	_set_status("正在等待房主同步路线图…", false)
	return preparation_generation


func apply_full_snapshot(
	layout_snapshot: Dictionary,
	state_snapshot: Dictionary,
	encounter_snapshot: Dictionary = {},
	economy_snapshot: Dictionary = {},
	shop_snapshot: Dictionary = {}
) -> bool:
	var briefing_value: Variant = state_snapshot.get(BRIEFING_STATE_FIELD)
	if typeof(briefing_value) != TYPE_DICTIONARY:
		_set_status("房主路线状态缺少作战简报快照。", true)
		return false
	var briefing_snapshot := (briefing_value as Dictionary).duplicate(true)
	if str(layout_snapshot.get(ROUTE_CONTRACT_FIELD, "")) != (
		_get_runtime_contract_hash()
	):
		_set_status("房主路线版本与本地运行配置不兼容。", true)
		return false
	var imported_graph := RogueRouteGraph.import_layout(
		layout_snapshot,
		generation_config
	)
	if imported_graph == null:
		_set_status("房主路线布局快照无效。", true)
		return false
	var incoming_action_points := int(state_snapshot.get("action_points", -1))
	if incoming_action_points < 0:
		_set_status("房主路线状态快照无效。", true)
		return false
	var imported_state := RogueRouteRuntimeState.new()
	if not imported_state.initialize(imported_graph, incoming_action_points):
		_set_status("无法创建客户端路线状态。", true)
		return false
	if not imported_state.apply_remote_state(state_snapshot):
		_set_status("房主路线状态与布局不匹配。", true)
		return false
	if not _validate_briefing_state_against(
		briefing_snapshot,
		imported_graph,
		imported_state,
		encounter_snapshot
	):
		_set_status("房主作战简报状态与路线不匹配。", true)
		return false
	if (
		not shop_snapshot.is_empty()
		and (
			underground_shop_controller == null
			or not underground_shop_controller.preflight_snapshot(
			shop_snapshot,
			imported_graph,
			imported_state
			)
		)
	):
		_set_status("房主地下商店快照无效或已过期。", true)
		return false
	if (
		not encounter_snapshot.is_empty()
		and _prepare_encounter_snapshot_application(
			encounter_snapshot,
			economy_snapshot,
			true,
			imported_graph
		).is_empty()
	):
		_set_status("房主遭遇或经济快照结构无效。", true)
		return false
	var layout_changed := (
		_route_graph == null
		or _route_graph.compute_layout_hash()
		!= imported_graph.compute_layout_hash()
	)
	var route_rewound := _is_full_snapshot_rewound(
		imported_graph,
		imported_state
	)
	var encounter_rewound := false
	var rare_chest_rewind_occurrence_key := ""
	if encounter_session != null and not encounter_snapshot.is_empty():
		var incoming_encounter_revision := int(
			encounter_snapshot.get("revision", -1)
		)
		var current_encounter_snapshot := encounter_session.export_state()
		var current_encounter_revision := int(
			current_encounter_snapshot.get("revision", -1)
		)
		encounter_rewound = (
			incoming_encounter_revision < current_encounter_revision
			or (
				incoming_encounter_revision == current_encounter_revision
				and not str(current_encounter_snapshot.get(
					"occurrence_key",
					""
				)).is_empty()
				and str(encounter_snapshot.get("occurrence_key", ""))
				!= str(current_encounter_snapshot.get("occurrence_key", ""))
			)
		)
	var incoming_supply_state := encounter_snapshot.get(
		"supply_state",
		{}
	) as Dictionary
	if supply_session != null and not incoming_supply_state.is_empty():
		var current_supply_state := supply_session.export_state()
		var incoming_supply_revision := int(
			incoming_supply_state.get("revision", -1)
		)
		var current_supply_revision := int(
			current_supply_state.get("revision", -1)
		)
		encounter_rewound = encounter_rewound or (
			incoming_supply_revision < current_supply_revision
			or (
				incoming_supply_revision == current_supply_revision
				and not str(current_supply_state.get(
					"occurrence_key",
					""
				)).is_empty()
				and str(incoming_supply_state.get("occurrence_key", ""))
				!= str(current_supply_state.get("occurrence_key", ""))
			)
		)
	var incoming_rare_chest_state := encounter_snapshot.get(
		"rare_chest_state",
		{}
	) as Dictionary
	if rare_chest_session != null and not incoming_rare_chest_state.is_empty():
		var current_rare_chest_state := rare_chest_session.export_state_for_peer(
			_get_local_encounter_peer_id()
		)
		var incoming_rare_revision := int(
			incoming_rare_chest_state.get("revision", -1)
		)
		var current_rare_revision := int(
			current_rare_chest_state.get("revision", -1)
		)
		var incoming_rare_occurrence := str(
			incoming_rare_chest_state.get("occurrence_key", "")
		)
		if (
			not incoming_rare_occurrence.is_empty()
			and incoming_rare_occurrence == str(
				current_rare_chest_state.get("occurrence_key", "")
			)
		):
			rare_chest_rewind_occurrence_key = incoming_rare_occurrence
		encounter_rewound = encounter_rewound or (
			incoming_rare_revision < current_rare_revision
			or (
				incoming_rare_revision == current_rare_revision
				and not str(current_rare_chest_state.get(
					"occurrence_key",
					""
				)).is_empty()
				and str(incoming_rare_chest_state.get("occurrence_key", ""))
				!= str(current_rare_chest_state.get("occurrence_key", ""))
			)
		)
	var presentation_rewound := (
		layout_changed or route_rewound or encounter_rewound
	)
	if (
		not presentation_rewound
		and not encounter_snapshot.is_empty()
		and _prepare_encounter_snapshot_application(
			encounter_snapshot,
			economy_snapshot,
			false,
			imported_graph
		).is_empty()
	):
		_set_status("房主遭遇或经济快照无效或已过期。", true)
		return false
	if not presentation_rewound and is_route_ready():
		var incoming_briefing_revision := int(
			briefing_snapshot["revision"]
		)
		if (
			incoming_briefing_revision < _briefing_revision
			or (
				incoming_briefing_revision == _briefing_revision
				and briefing_snapshot != export_briefing_state_snapshot()
			)
		):
			_set_status("房主作战简报快照已过期或发生冲突。", true)
			return false
	if presentation_rewound:
		_reset_briefing_runtime(true)
		_reset_normal_combat_stage(true)
		_reset_encounter_runtime(false)
		_reset_supply_runtime(false)
		_reset_rare_chest_runtime(
			false,
			rare_chest_rewind_occurrence_key
		)
		_reset_underground_shop_runtime(false)

	_set_route_reveal_input_locked(false)
	if _briefing_phase == BriefingPhase.NONE:
		_clear_pending_move(true)
	elif move_confirmation.visible:
		move_confirmation.dismiss()
	set_authority_enabled(false)
	if not route_board.present_graph(
		imported_graph,
		generation_config,
		imported_state.current_node_id,
		imported_state.action_points,
		imported_state.visited_counts,
		false,
		layout_changed or route_rewound or encounter_rewound
	):
		_set_status("客户端路线视觉层初始化失败。", true)
		return false
	_bind_runtime_state(imported_graph, imported_state)
	_route_ready = true
	if layout_changed:
		_reposition_route_players_at_start()
	if (
		not encounter_snapshot.is_empty()
		and not apply_encounter_snapshot(
			encounter_snapshot,
			economy_snapshot
		)
	):
		_set_status("房主遭遇或经济快照无效。", true)
		return false
	if not apply_briefing_state_snapshot(briefing_snapshot):
		_set_status("房主作战简报状态与路线不匹配。", true)
		return false
	if _briefing_phase != BriefingPhase.NONE:
		route_board.select_node(_briefing_node_id)
	_refresh_route_input_lock()
	if not shop_snapshot.is_empty() and not apply_shop_snapshot(shop_snapshot):
		_set_status("房主地下商店快照无效或已过期。", true)
		return false
	_configure_camera_world_bounds()
	if layout_changed:
		_recenter_camera_on_player()
	_update_route_hud()
	_show_node_content(_runtime_state.current_node_id, false)
	_set_status("已同步房主路线。当前为只读模式。", false)
	_try_play_route_entry_reveal()
	return true


func _is_full_snapshot_rewound(
	imported_graph: RogueRouteGraph,
	imported_state: RogueRouteRuntimeState
) -> bool:
	if (
		_route_graph == null
		or _runtime_state == null
		or imported_graph == null
		or imported_state == null
		or _route_graph.compute_layout_hash()
		!= imported_graph.compute_layout_hash()
	):
		return false
	if (
		imported_state.state_revision < _runtime_state.state_revision
		or imported_state.action_points_revision
		< _runtime_state.action_points_revision
	):
		return true
	return (
		imported_state.state_revision == _runtime_state.state_revision
		and imported_state.action_points_revision
		== _runtime_state.action_points_revision
		and imported_state.export_state() != _runtime_state.export_state()
	)


func apply_move_delta(delta: Dictionary) -> bool:
	if (
		_authority_enabled
		or not is_route_ready()
		or not _runtime_state.apply_remote_move_delta(delta)
	):
		return false
	_set_status(
		"房主已将队伍移动至%s。"
		% _get_node_display_name(_runtime_state.current_node_id),
		false
	)
	return true


func export_layout_snapshot() -> Dictionary:
	if not is_route_ready():
		return {}
	var snapshot := _route_graph.export_layout().duplicate(true)
	snapshot[ROUTE_CONTRACT_FIELD] = _get_runtime_contract_hash()
	return snapshot


func export_state_snapshot() -> Dictionary:
	if not is_route_ready():
		return {}
	var snapshot := _runtime_state.export_state().duplicate(true)
	snapshot[BRIEFING_STATE_FIELD] = export_briefing_state_snapshot()
	return snapshot


func export_briefing_state_snapshot() -> Dictionary:
	if not is_route_ready():
		return {}
	return {
		"schema_version": BRIEFING_SCHEMA_VERSION,
		"layout_hash": _route_graph.compute_layout_hash(),
		"revision": _briefing_revision,
		"phase": _briefing_phase,
		"node_id": _briefing_node_id,
		"occurrence_key": _briefing_occurrence_key,
		"expected_route_revision": _briefing_expected_route_revision,
		"source_kind": String(_briefing_source_kind),
		"combat_config_id": String(_briefing_combat_config_id),
		"source_encounter_occurrence_key": (
			_briefing_source_encounter_occurrence_key
		),
	}


## 客户端只接受可由本地路线完整复算的权威简报状态。旧 revision 会被忽略，
## 同 revision 的不同内容会被拒绝，避免过期包重新打开或重复提交简报。
func apply_briefing_state_snapshot(snapshot: Dictionary) -> bool:
	if (
		_authority_enabled
		or not is_route_ready()
		or not _validate_briefing_state_against(
			snapshot,
			_route_graph,
			_runtime_state,
			encounter_session.export_state() if encounter_session != null else {}
		)
	):
		return false
	var incoming_revision := int(snapshot["revision"])
	if incoming_revision < _briefing_revision:
		return true
	if incoming_revision == _briefing_revision:
		return snapshot == export_briefing_state_snapshot()
	var previous_phase := _briefing_phase
	_assign_briefing_state(snapshot)
	_sync_briefing_presentation(previous_phase)
	return true


## 战场已经在遮盖下完成本地准备后，由协调器调用。入口遮盖不存在时返回
## true，以兼容直接构造战斗阶段的底层 smoke；正式简报路径一定会执行 reveal。
func reveal_normal_combat_entry(occurrence_key: String) -> bool:
	if (
		occurrence_key.is_empty()
		or not _normal_combat_active
		or occurrence_key != _normal_combat_occurrence_key
	):
		return false
	if not combat_scene_transition.visible:
		return true
	var revealed := await combat_scene_transition.reveal()
	return (
		revealed
		and _normal_combat_active
		and occurrence_key == _normal_combat_occurrence_key
	)


## Host 在全员战场准备屏障到齐时结束权威 ENTERING 状态；各端正在进行的
## reveal 不受 NONE 快照影响，仍由本地协调器独立等待完成。
func complete_briefing_entry(occurrence_key: String) -> bool:
	if (
		not _authority_enabled
		or _briefing_phase != BriefingPhase.ENTERING
		or occurrence_key.is_empty()
		or occurrence_key != _briefing_occurrence_key
	):
		return false
	return _commit_host_briefing_state(
		BriefingPhase.NONE,
		INVALID_NODE_ID,
		"",
		-1
	)


## 单机由本地 cover 完成后直接调用；联机仅由 MpRogueRoute 的全员
## cover-ready 屏障调用。tuple 与当前权威状态必须完全一致，且 route revision
## 仍停留在确认前，因而重复 ready 不可能再次扣除行动力。
func host_commit_briefing_entry(
	occurrence_key: String,
	briefing_revision: int,
	expected_route_revision: int
) -> bool:
	if (
		not _authority_enabled
		or not is_route_ready()
		or _briefing_phase != BriefingPhase.ENTERING
		or _briefing_node_id < 0
		or _briefing_node_id >= _runtime_state.visited_counts.size()
		or occurrence_key.is_empty()
		or occurrence_key != _briefing_occurrence_key
		or briefing_revision != _briefing_revision
		or expected_route_revision != _briefing_expected_route_revision
		or _runtime_state.state_revision != expected_route_revision
	):
		return false
	if _briefing_source_kind == RogueRouteNodeBriefingModel.SOURCE_KIND_SPECIAL_COMBAT:
		if (
			_normal_combat_active
			or _briefing_combat_config_id == &""
			or get_signal_connection_list(&"combat_requested").is_empty()
			or not _validate_followup_encounter_snapshot(
				encounter_session.export_state() if encounter_session != null else {},
				_briefing_node_id,
				_briefing_source_encounter_occurrence_key,
				_briefing_combat_config_id
			)
		):
			call_deferred(
				&"_recover_failed_briefing_entry",
				"特殊作战配置或来源遭遇已经失效。"
			)
			return false
		var content_seed := _route_graph.get_node_content_seed(
			_briefing_node_id
		)
		_begin_normal_combat_stage(
			_briefing_node_id,
			content_seed,
			occurrence_key,
			_briefing_combat_config_id
		)
		_set_status("遭遇已转入特殊作战，正在准备战斗。", false)
		combat_requested.emit(
			_briefing_node_id,
			content_seed,
			occurrence_key,
			_briefing_combat_config_id
		)
		return true
	var emergency_source := (
		_briefing_source_kind
		== RogueRouteNodeBriefingModel.SOURCE_KIND_EMERGENCY_COMBAT
	)
	var expected_direct_config := (
		resolve_emergency_combat_config_for_node(_briefing_node_id)
		if emergency_source
		else resolve_normal_combat_config_for_node(_briefing_node_id)
	)
	if (
		expected_direct_config == null
		or _briefing_combat_config_id != expected_direct_config.encounter_id
	):
		call_deferred(
			&"_recover_failed_briefing_entry",
			"紧急作战配置已经失效。" if emergency_source else "普通作战配置已经失效。"
		)
		return false
	# 路线作战仅在首次踏入时允许提交。即便出现被篡改或过时的简报包，
	# 已访问节点也不能再因该包扣行动力、转场或重开战斗。
	if int(_runtime_state.visited_counts[_briefing_node_id]) != 0:
		call_deferred(
			&"_recover_failed_briefing_entry",
			"该紧急作战节点已完成探索。" if emergency_source else "该普通作战节点已完成探索。"
		)
		return false
	var rejection_reason := _runtime_state.get_move_rejection_reason(
		_briefing_node_id,
		generation_config.move_action_cost,
		expected_route_revision
	)
	if not rejection_reason.is_empty():
		call_deferred(
			&"_recover_failed_briefing_entry",
			rejection_reason
		)
		return false
	if not _begin_shop_departure_for_route_move():
		call_deferred(
			&"_recover_failed_briefing_entry",
			"仍有玩家停留在地下商店。"
		)
		return false
	if not _runtime_state.try_move(
		_briefing_node_id,
		generation_config.move_action_cost,
		expected_route_revision
	):
		_cancel_shop_departure_for_failed_move()
		call_deferred(
			&"_recover_failed_briefing_entry",
			"路线状态已变化，本次作战未启动。"
		)
		return false
	return true


## 兼容旧协调器/聚焦测试的入口；通用实现同时处理默认与遭遇跟随作战。
func host_commit_briefed_move(
	occurrence_key: String,
	briefing_revision: int,
	expected_route_revision: int
) -> bool:
	return host_commit_briefing_entry(
		occurrence_key,
		briefing_revision,
		expected_route_revision
	)


func abort_briefing_entry(occurrence_key: String) -> void:
	if (
		_briefing_phase == BriefingPhase.ENTERING
		and not occurrence_key.is_empty()
		and occurrence_key == _briefing_occurrence_key
	):
		if _authority_enabled:
			_commit_host_briefing_state(
				BriefingPhase.NONE,
				INVALID_NODE_ID,
				"",
				-1
			)
		else:
			_reset_briefing_runtime(false)
	combat_scene_transition.hide_immediately()


func hide_combat_entry_transition() -> void:
	combat_scene_transition.hide_immediately()


func export_encounter_snapshot(target_peer_id: int = -1) -> Dictionary:
	if encounter_session == null:
		return {}
	var snapshot := encounter_session.export_state().duplicate(true)
	# 线路协议会把经济账本作为独立字段发送。保留 Session 内部完整快照，
	# 但在线路视图中只留下空占位，避免每次倒计时广播重复携带仓库与背包。
	snapshot["economy_snapshot"] = {}
	if supply_session != null:
		var supply_state := supply_session.export_state().duplicate(true)
		supply_state["economy_snapshot"] = {}
		snapshot["supply_state"] = supply_state
	if rare_chest_session != null:
		snapshot["rare_chest_state"] = (
			rare_chest_session.export_state_for_peer(target_peer_id)
		)
	return snapshot


func export_encounter_economy_snapshot(target_peer_id: int = -1) -> Dictionary:
	if encounter_economy == null:
		return {}
	var encounter_peer_ids := _get_active_encounter_peer_ids()
	if encounter_session != null:
		var session_snapshot := encounter_session.export_state()
		var session_peer_ids := session_snapshot.get(
			"participant_peer_ids",
			[]
		) as Array
		if not session_peer_ids.is_empty():
			encounter_peer_ids.clear()
			for raw_peer_id in session_peer_ids:
				encounter_peer_ids.append(int(raw_peer_id))
	if rare_chest_session != null:
		for peer_id in rare_chest_session.get_economy_peer_ids():
			if not encounter_peer_ids.has(peer_id):
				encounter_peer_ids.append(peer_id)
	encounter_peer_ids.sort()
	var snapshot := encounter_economy.export_snapshot(
		encounter_peer_ids
	).duplicate(true)
	if supply_economy != null:
		var supply_peer_ids := (
			supply_session.get_economy_peer_ids()
			if supply_session != null
			else []
		)
		if supply_peer_ids.is_empty():
			supply_peer_ids = _get_active_encounter_peer_ids()
		snapshot["supply_economy"] = supply_economy.export_snapshot(
			supply_peer_ids
		)
	if rare_chest_economy != null:
		snapshot["rare_chest_economy"] = (
			rare_chest_economy.export_snapshot(target_peer_id)
		)
	return snapshot


func apply_encounter_snapshot(
	encounter_snapshot: Dictionary,
	economy_snapshot: Dictionary
) -> bool:
	var prepared := _prepare_encounter_snapshot_application(
		encounter_snapshot,
		economy_snapshot,
		false
	)
	if prepared.is_empty():
		return false
	var atomic_supply_state := prepared["supply_state"] as Dictionary
	var atomic_snapshot := prepared["encounter_state"] as Dictionary
	var rare_chest_state := prepared["rare_chest_state"] as Dictionary
	var rare_chest_economy_snapshot := prepared[
		"rare_chest_economy"
	] as Dictionary
	if not supply_session.apply_remote_state(atomic_supply_state):
		return false
	# Session 会先让 Economy 校验并提交账本，成功后才写入自身阶段字段；
	# 任一经济字段无效时，遭遇 revision/phase 也保持原值。
	if not encounter_session.apply_remote_state(atomic_snapshot):
		return false
	if not rare_chest_economy.apply_remote_snapshot(
		rare_chest_economy_snapshot
	):
		return false
	return rare_chest_session.apply_remote_state(rare_chest_state)


func _prepare_encounter_snapshot_application(
	encounter_snapshot: Dictionary,
	economy_snapshot: Dictionary,
	structure_only: bool,
	validation_graph: RogueRouteGraph = null
) -> Dictionary:
	if encounter_session == null or encounter_snapshot.is_empty():
		return {}
	if not _validate_map_encounter_assignment(
		encounter_snapshot,
		validation_graph
	):
		return {}
	var supply_state := encounter_snapshot.get("supply_state", {}) as Dictionary
	var supply_economy_snapshot := economy_snapshot.get(
		"supply_economy",
		{}
	) as Dictionary
	var rare_chest_state := encounter_snapshot.get(
		"rare_chest_state",
		{}
	) as Dictionary
	var rare_chest_economy_snapshot := economy_snapshot.get(
		"rare_chest_economy",
		{}
	) as Dictionary
	if (
		supply_session == null
		or supply_state.is_empty()
		or supply_economy_snapshot.is_empty()
		or rare_chest_session == null
		or rare_chest_economy == null
		or rare_chest_state.is_empty()
		or rare_chest_economy_snapshot.is_empty()
		or int(rare_chest_state.get("target_peer_id", -2))
		!= int(rare_chest_economy_snapshot.get("target_peer_id", -3))
		or int(rare_chest_state.get("target_peer_id", -2))
		!= _get_local_encounter_peer_id()
	):
		return {}
	var atomic_supply_state := supply_state.duplicate(true)
	atomic_supply_state["economy_snapshot"] = supply_economy_snapshot.duplicate(true)
	var atomic_snapshot := encounter_snapshot.duplicate(true)
	atomic_snapshot.erase("supply_state")
	atomic_snapshot.erase("rare_chest_state")
	var base_economy_snapshot := economy_snapshot.duplicate(true)
	base_economy_snapshot.erase("supply_economy")
	base_economy_snapshot.erase("rare_chest_economy")
	var embedded := atomic_snapshot.get("economy_snapshot", {}) as Dictionary
	if (
		not embedded.is_empty()
		and not base_economy_snapshot.is_empty()
		and embedded != base_economy_snapshot
	):
		return {}
	if embedded.is_empty():
		if base_economy_snapshot.is_empty():
			return {}
		atomic_snapshot["economy_snapshot"] = base_economy_snapshot
	# 两个 Session 共享同一个 RunState。必须在任一账本落地前同时完成
	# schema/revision/内容预检，避免一边成功、一边拒绝造成半应用快照。
	var valid := (
		(
			supply_session.validate_remote_state_structure(
				atomic_supply_state
			)
			and encounter_session.validate_remote_state_structure(
				atomic_snapshot
			)
			and rare_chest_economy.validate_remote_snapshot_structure(
				rare_chest_economy_snapshot
			)
			and rare_chest_session.validate_remote_state_structure(
				rare_chest_state
			)
		)
		if structure_only
		else (
			supply_session.validate_remote_state(atomic_supply_state)
			and encounter_session.validate_remote_state(atomic_snapshot)
			and rare_chest_economy.validate_remote_snapshot(
				rare_chest_economy_snapshot
			)
			and rare_chest_session.validate_remote_state(rare_chest_state)
		)
	)
	if not valid:
		return {}
	if not _validate_rare_chest_snapshot_consistency(
		rare_chest_state,
		rare_chest_economy_snapshot,
		base_economy_snapshot
	):
		return {}
	return {
		"supply_state": atomic_supply_state,
		"encounter_state": atomic_snapshot,
		"rare_chest_state": rare_chest_state,
		"rare_chest_economy": rare_chest_economy_snapshot,
	}


func _validate_rare_chest_snapshot_consistency(
	rare_chest_state: Dictionary,
	rare_chest_economy_snapshot: Dictionary,
	base_economy_snapshot: Dictionary
) -> bool:
	var target_peer_id := int(rare_chest_state.get("target_peer_id", -2))
	var occurrence_key := str(rare_chest_state.get("occurrence_key", ""))
	var selected_option := StringName(
		rare_chest_state.get("local_selected_option_id", &"")
	)
	var matching_settlement: Dictionary = {}
	var required_stat_totals: Dictionary = {}
	for raw_entry_value in rare_chest_economy_snapshot.get(
		"settled_choices",
		[]
	) as Array:
		var entry := raw_entry_value as Dictionary
		var result := entry.get("result", {}) as Dictionary
		var settled_option := StringName(result.get("option_id", &""))
		var settled_stat_id := RogueRareChestRegistry.get_stat_id(
			settled_option
		)
		var settled_delta := RogueRareChestRegistry.get_stat_delta(
			settled_option
		)
		required_stat_totals[String(settled_stat_id)] = int(
			required_stat_totals.get(String(settled_stat_id), 0)
		) + settled_delta
		if (
			int(result.get("peer_id", -1)) != target_peer_id
			or str(result.get("occurrence_key", "")) != occurrence_key
		):
			continue
		if not matching_settlement.is_empty():
			return false
		matching_settlement = result
	if selected_option.is_empty():
		if not matching_settlement.is_empty():
			return false
	elif (
		matching_settlement.is_empty()
		or StringName(matching_settlement.get("option_id", &""))
		!= selected_option
		or not RogueRareChestRegistry.has_option(selected_option)
	):
		return false
	var party_economy := base_economy_snapshot.get(
		"party_economy",
		{}
	) as Dictionary
	var status_ledger := party_economy.get(
		"party_status_ledger",
		{}
	) as Dictionary
	var bonuses_by_peer := status_ledger.get(
		"player_stat_bonuses",
		{}
	) as Dictionary
	var peer_bonuses := bonuses_by_peer.get(
		str(target_peer_id),
		bonuses_by_peer.get(target_peer_id, {})
	) as Dictionary
	for raw_stat_id in required_stat_totals.keys():
		var stat_id := str(raw_stat_id)
		if int(peer_bonuses.get(stat_id, 0)) < int(
			required_stat_totals[stat_id]
		):
			return false
	return true


func export_shop_snapshot_for_peer(
	target_peer_id: int,
	transaction_result: Dictionary = {}
) -> Dictionary:
	if underground_shop_controller == null:
		return {}
	return underground_shop_controller.export_snapshot_for_peer(
		target_peer_id,
		transaction_result
	)


func apply_shop_snapshot(snapshot: Dictionary) -> bool:
	if (
		underground_shop_controller == null
		or _route_graph == null
		or _runtime_state == null
	):
		return false
	return underground_shop_controller.apply_snapshot(
		snapshot,
		_route_graph,
		_runtime_state
	)


func host_submit_shop_purchase(
	peer_id: int,
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_session_revision: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> bool:
	if not _authority_enabled or underground_shop_controller == null:
		return false
	return underground_shop_controller.host_submit_purchase(
		peer_id,
		request_id,
		occurrence_key,
		offer_index,
		expected_session_revision,
		expected_shelf_revision,
		expected_inventory_revision,
		expected_xirang_revision
	)


func host_submit_shop_sell(
	peer_id: int,
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_session_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> bool:
	if not _authority_enabled or underground_shop_controller == null:
		return false
	return underground_shop_controller.host_submit_sell(
		peer_id,
		request_id,
		occurrence_key,
		slot_index,
		expected_config_path,
		expected_session_revision,
		expected_inventory_revision,
		expected_xirang_revision
	)


func host_submit_shop_exit(
	peer_id: int,
	occurrence_key: String,
	expected_session_revision: int
) -> bool:
	if not _authority_enabled or underground_shop_controller == null:
		return false
	return underground_shop_controller.host_submit_exit(
		peer_id,
		occurrence_key,
		expected_session_revision
	)


func host_remove_shop_peer(peer_id: int) -> void:
	if _authority_enabled and underground_shop_controller != null:
		underground_shop_controller.remove_peer(peer_id)


func host_migrate_shop_peer_as_exited(old_peer_id: int, new_peer_id: int) -> void:
	if _authority_enabled and underground_shop_controller != null:
		underground_shop_controller.migrate_peer_as_exited(
			old_peer_id,
			new_peer_id
		)


func host_add_shop_spectator(peer_id: int) -> void:
	if _authority_enabled and underground_shop_controller != null:
		underground_shop_controller.add_spectator(peer_id)


func get_shop_waiting_peer_ids() -> Array[int]:
	if underground_shop_controller == null:
		return []
	return underground_shop_controller.get_waiting_peer_ids()


func is_shop_departure_ready() -> bool:
	return (
		underground_shop_controller != null
		and underground_shop_controller.is_departure_ready()
	)


func is_encounter_active() -> bool:
	return (
		_normal_combat_active
		or
		_encounter_input_locked
		or _is_local_shop_presentation_active()
		or (
			encounter_session != null
			and encounter_session.is_active()
		)
		or (
			supply_session != null
			and supply_session.is_active()
		)
		or (
			rare_chest_session != null
			and rare_chest_session.is_active()
		)
	)


func is_normal_combat_active() -> bool:
	return _normal_combat_active


func get_normal_combat_occurrence_key() -> String:
	return _normal_combat_occurrence_key


func get_active_combat_config_id() -> StringName:
	return _normal_combat_config_id


func resolve_combat_config(
	combat_config_id: StringName
) -> RogueCombatEncounterConfig:
	if floor_definition == null:
		return null
	return floor_definition.get_combat_config(combat_config_id)


func resolve_normal_combat_config_for_node(
	node_id: int,
	validation_graph: RogueRouteGraph = null
) -> RogueCombatEncounterConfig:
	var graph := validation_graph if validation_graph != null else _route_graph
	if (
		floor_definition == null
		or floor_definition.normal_combat_pool == null
		or generation_config == null
		or graph == null
		or not graph.is_valid_node_id(node_id)
		or graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.NORMAL_COMBAT
	):
		return null
	var node_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.NORMAL_COMBAT
	)
	if (
		node_config == null
		or node_config.content_pool_id
		!= floor_definition.normal_combat_pool.pool_id
	):
		return null
	return floor_definition.select_normal_combat_config(
		graph.get_node_content_seed(node_id)
	)


func resolve_emergency_combat_config_for_node(
	node_id: int,
	validation_graph: RogueRouteGraph = null
) -> RogueCombatEncounterConfig:
	var graph := validation_graph if validation_graph != null else _route_graph
	if (
		floor_definition == null
		or floor_definition.emergency_combat_pool == null
		or generation_config == null
		or graph == null
		or not graph.is_valid_node_id(node_id)
		or graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.EMERGENCY_COMBAT
	):
		return null
	var node_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.EMERGENCY_COMBAT
	)
	if (
		node_config == null
		or node_config.content_pool_id
		!= floor_definition.emergency_combat_pool.pool_id
	):
		return null
	return floor_definition.select_emergency_combat_config(
		graph.get_node_content_seed(node_id)
	)


func export_participant_stable_keys() -> Dictionary:
	return _player_stable_keys.duplicate(true)


func is_special_combat_config_id(combat_config_id: StringName) -> bool:
	return (
		floor_definition != null
		and floor_definition.get_special_combat_config(combat_config_id) != null
	)


func is_emergency_combat_config_id(combat_config_id: StringName) -> bool:
	return (
		floor_definition != null
		and floor_definition.get_emergency_combat_config(combat_config_id) != null
	)


func get_followup_combat_participant_peer_ids(
	combat_occurrence_key: String,
	combat_config_id: StringName
) -> PackedInt32Array:
	var result := PackedInt32Array()
	if (
		not is_special_combat_config_id(combat_config_id)
		or encounter_session == null
		or _normal_combat_node_id < 0
	):
		return result
	var source_occurrence_key := _get_followup_source_occurrence_from_combat_key(
		combat_occurrence_key,
		_normal_combat_node_id,
		_normal_combat_content_seed,
		combat_config_id
	)
	var encounter_snapshot := encounter_session.export_state()
	if not _validate_followup_encounter_snapshot(
		encounter_snapshot,
		_normal_combat_node_id,
		source_occurrence_key,
		combat_config_id
	):
		return result
	for peer_id_variant in encounter_snapshot.get("active_peer_ids", []) as Array:
		var peer_id := int(peer_id_variant)
		if peer_id > 0 and get_player_for_peer(peer_id) != null:
			result.append(peer_id)
	result.sort()
	return result


## 客户端只接受能由当前权威路线状态完整复算出的作战启动数据。
## 相同启动包可安全重放；不同 occurrence 不会覆盖正在进行的作战。
func apply_normal_combat_started(
	node_id: int,
	content_seed: int,
	occurrence_key: String,
	combat_config_id: StringName = &""
) -> bool:
	var resolved_config_id := combat_config_id
	if resolved_config_id == &"":
		var resolved_config := resolve_normal_combat_config_for_node(node_id)
		if resolved_config != null:
			resolved_config_id = resolved_config.encounter_id
	if _authority_enabled or not _validate_combat_start(
		node_id,
		content_seed,
		occurrence_key,
		resolved_config_id
	):
		return false
	if _normal_combat_active:
		return (
			node_id == _normal_combat_node_id
			and content_seed == _normal_combat_content_seed
			and occurrence_key == _normal_combat_occurrence_key
			and resolved_config_id == _normal_combat_config_id
		)
	if (
		_encounter_input_locked
		or (
			encounter_session != null
			and encounter_session.is_active()
		)
		or (supply_session != null and supply_session.is_active())
		or (rare_chest_session != null and rare_chest_session.is_active())
	):
		return false
	_begin_normal_combat_stage(
		node_id,
		content_seed,
		occurrence_key,
		resolved_config_id
	)
	_set_status("房主已发起作战，正在进入战斗区域。", false)
	return true


func complete_normal_combat(occurrence_key: String) -> bool:
	if (
		not _normal_combat_active
		or occurrence_key.is_empty()
		or occurrence_key != _normal_combat_occurrence_key
	):
		return false
	_clear_normal_combat_state()
	# 直接拒绝重放、启动失败与测试/恢复路径都可能只结束 stage，未必紧接
	# presentation lease 的 release。状态 owner 消失的事件边界必须自行
	# reconcile，避免 completed+pending Supply 永久保持被压制状态。
	_reconcile_local_modal_presentations()
	_set_encounter_input_locked(
		(encounter_session != null and encounter_session.is_active())
		or (supply_session != null and supply_session.is_active())
		or (rare_chest_session != null and rare_chest_session.is_active())
	)
	_set_status("作战阶段已结束。", false)
	return true


func set_route_presentation_enabled(enabled: bool) -> void:
	if not is_node_ready():
		return
	_route_presentation_enabled = enabled
	_set_route_presentation_lease(
		RoutePresentationLease.COMBAT,
		not enabled
	)


func _restore_route_camera_after_external_scene() -> void:
	if player == null or not is_instance_valid(player):
		return
	if not world.restore_camera_after_external_scene(
		player,
		get_viewport_rect().size
	):
		push_error("RogueRouteGame: 返回路线后无法重新取得 Viewport 相机所有权。")


func show_combat_result(result: Dictionary) -> bool:
	if combat_result_overlay == null or typeof(result.get("victory")) != TYPE_BOOL:
		return false
	var victory := bool(result["victory"])
	if not victory:
		var failure_reason_value: Variant = result.get("failure_reason", "")
		if typeof(failure_reason_value) not in [TYPE_STRING, TYPE_STRING_NAME]:
			return false
		combat_result_overlay.show_failure(str(failure_reason_value))
		_reconcile_local_modal_presentations()
		_refresh_route_input_lock()
		return true
	if typeof(result.get("extra_xirang")) != TYPE_INT:
		return false
	var extra_xirang := int(result["extra_xirang"])
	if extra_xirang < 0 or typeof(result.get("loot")) != TYPE_DICTIONARY:
		return false
	var loot := result["loot"] as Dictionary
	if typeof(loot.get("config_path")) != TYPE_STRING:
		return false
	var config_path := str(loot["config_path"])
	var loot_config: PickupConfig = null
	if not config_path.is_empty():
		if not ResourceLoader.exists(config_path, "PickupConfig"):
			return false
		loot_config = load(config_path) as PickupConfig
		if loot_config == null:
			return false
	var inventory_full := (
		StringName(loot.get("failure_reason", &"")) == &"inventory_full"
	)
	combat_result_overlay.show_victory(
		extra_xirang,
		loot_config.display_name if loot_config != null else "",
		loot_config.icon_texture if loot_config != null else null,
		inventory_full
	)
	_reconcile_local_modal_presentations()
	_refresh_route_input_lock()
	return true


func hide_combat_result() -> void:
	if combat_result_overlay != null:
		combat_result_overlay.hide_immediately()
	_reconcile_local_modal_presentations()
	_refresh_route_input_lock()


func get_route_revision() -> int:
	return _runtime_state.state_revision if is_route_ready() else -1


func get_runtime_contract_hash() -> String:
	return _get_runtime_contract_hash()


func is_route_ready() -> bool:
	return (
		_route_ready
		and _route_graph != null
		and _runtime_state != null
		and _runtime_state.is_initialized()
	)


func set_authority_enabled(enabled: bool) -> void:
	_authority_enabled = enabled
	if not is_node_ready():
		return
	if not _authority_enabled:
		_clear_pending_move(true)
	route_board.set_authority_enabled(_authority_enabled)
	_sync_underground_shop_identity_context()
	_update_authority_ui()


func activate_runtime() -> void:
	_runtime_activated = true
	_try_play_route_entry_reveal()


func _connect_runtime_activation_signal() -> void:
	var loader := get_node_or_null("/root/GameLoadCoordinator")
	var finished_callable := Callable(self, "_on_loading_finished")
	if (
		loader != null
		and loader.has_signal("loading_finished")
		and not loader.is_connected(&"loading_finished", finished_callable)
	):
		loader.connect(&"loading_finished", finished_callable)


func _activate_runtime_when_loader_is_idle() -> void:
	var loader := get_node_or_null("/root/GameLoadCoordinator")
	if loader == null or not bool(loader.call("is_loading")):
		activate_runtime()


func _on_loading_finished(_multiplayer_load: bool) -> void:
	activate_runtime()


func _try_play_route_entry_reveal() -> void:
	if not _runtime_activated or not is_route_ready() or not is_node_ready():
		return
	var loader := get_node_or_null("/root/GameLoadCoordinator")
	if loader != null and bool(loader.call("is_loading")):
		return
	_reconcile_route_music()
	if is_encounter_active():
		route_board.complete_entry_reveal()
		_set_route_reveal_input_locked(false)
		return
	if not route_board.is_entry_reveal_prepared():
		return
	_set_route_reveal_input_locked(true)
	route_board.play_entry_reveal()


## 路线音乐与入场揭示共用加载门禁。暂停中的 AudioStreamPlayer.playing
## 不能代表已有 playback；以 playback 身份为准，避免重复激活从头重播。
func _reconcile_route_music() -> void:
	if not is_node_ready():
		return
	var combat_lease_active := (
		_route_presentation_leases & RoutePresentationLease.COMBAT
	) != 0
	if not route_music_player.has_stream_playback():
		if not _runtime_activated or not is_route_ready():
			return
		var loader := get_node_or_null("/root/GameLoadCoordinator")
		if loader != null and bool(loader.call("is_loading")):
			return
		route_music_player.play()
	# 首次启动也必须立刻遵循当前 lease，不能短暂泄漏路线音乐。
	route_music_player.stream_paused = (
		combat_lease_active
		or (embedded_session and not visible)
	)


func _on_route_entry_reveal_finished() -> void:
	_set_route_reveal_input_locked(false)


func host_submit_encounter_intro_ack(
	peer_id: int,
	occurrence_key: String,
	expected_revision: int
) -> bool:
	var accepted := (
		_authority_enabled
		and encounter_session != null
		and encounter_session.submit_intro_ack(
			peer_id,
			occurrence_key,
			expected_revision
		)
	)
	if accepted:
		return true
	return (
		_authority_enabled
		and supply_session != null
		and supply_session.submit_intro_ack(
			peer_id,
			occurrence_key,
			expected_revision
		)
	)


func host_submit_encounter_vote(
	peer_id: int,
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> bool:
	var accepted := (
		_authority_enabled
		and encounter_session != null
		and encounter_session.submit_vote(
			peer_id,
			occurrence_key,
			expected_revision,
			option_id
		)
	)
	if accepted:
		return true
	accepted = (
		_authority_enabled
		and rare_chest_session != null
		and rare_chest_session.submit_choice(
			peer_id,
			occurrence_key,
			expected_revision,
			option_id
		)
	)
	if accepted:
		return true
	var wire_option_id := String(option_id)
	if wire_option_id.begins_with(SUPPLY_INVENTORY_DISCARD_WIRE_PREFIX):
		var parts := wire_option_id.split("|", false)
		if (
			parts.size() == 4
			and parts[1].is_valid_int()
			and parts[2].is_valid_int()
		):
			return host_submit_supply_inventory_discard(
				peer_id,
				occurrence_key,
				expected_revision,
				int(parts[1]),
				int(parts[2]),
				parts[3]
			)
	if wire_option_id.begins_with(SUPPLY_COLLECTIBLE_CHOICE_WIRE_PREFIX):
		var raw_index := wire_option_id.trim_prefix(
			SUPPLY_COLLECTIBLE_CHOICE_WIRE_PREFIX
		)
		if raw_index.is_valid_int():
			return host_submit_supply_collectible_choice(
				peer_id,
				occurrence_key,
				expected_revision,
				int(raw_index)
			)
	return (
		_authority_enabled
		and supply_session != null
		and supply_session.submit_vote(
			peer_id,
			occurrence_key,
			expected_revision,
			option_id
		)
	)


func host_submit_encounter_result_ack(
	peer_id: int,
	occurrence_key: String,
	result_sequence: int
) -> bool:
	var accepted := (
		_authority_enabled
		and encounter_session != null
		and encounter_session.submit_result_ack(
			peer_id,
			occurrence_key,
			result_sequence
		)
	)
	if accepted:
		return true
	return (
		_authority_enabled
		and supply_session != null
		and supply_session.submit_completion(
			peer_id,
			occurrence_key,
			result_sequence
		)
	)


func host_submit_supply_collectible_choice(
	peer_id: int,
	occurrence_key: String,
	expected_revision: int,
	offer_index: int
) -> bool:
	return (
		_authority_enabled
		and supply_session != null
		and supply_session.submit_collectible_choice(
			peer_id,
			occurrence_key,
			expected_revision,
			offer_index
		)
	)


func host_submit_supply_inventory_discard(
	peer_id: int,
	occurrence_key: String,
	expected_supply_revision: int,
	slot_index: int,
	expected_inventory_revision: int,
	expected_config_hash: String
) -> bool:
	if (
		not _authority_enabled
		or supply_session == null
		or not supply_session.has_pending_collectible_for_peer(peer_id)
		or supply_session.get_pending_collectible_occurrence_for_peer(peer_id)
		!= occurrence_key
		or supply_session.get_revision() != expected_supply_revision
		or _run_state == null
		or expected_config_hash.is_empty()
	):
		return false
	var current_inventory_revision := (
		_run_state.get_inventory_revision()
		if peer_id == 0
		else _run_state.get_inventory_revision_for_peer(peer_id)
	)
	if current_inventory_revision != expected_inventory_revision:
		return false
	var item := (
		_run_state.get_item(slot_index)
		if peer_id == 0
		else _run_state.get_item_for_peer(peer_id, slot_index)
	)
	if (
		item == null
		or item.inventory_locked
		or item.resource_path.sha256_text() != expected_config_hash
	):
		return false
	var discarded := (
		_run_state.discard_item(slot_index)
		if peer_id == 0
		else _run_state.discard_item_for_peer(peer_id, slot_index)
	)
	if discarded:
		_emit_host_encounter_snapshot()
	return discarded


func host_remove_encounter_peer(peer_id: int) -> void:
	if _authority_enabled and encounter_session != null:
		encounter_session.remove_peer(peer_id)
	if _authority_enabled and supply_session != null:
		supply_session.remove_peer(peer_id)
	if _authority_enabled and rare_chest_session != null:
		rare_chest_session.remove_peer(peer_id)


func host_migrate_encounter_peer(old_peer_id: int, new_peer_id: int) -> void:
	if _authority_enabled and encounter_session != null:
		encounter_session.migrate_peer(old_peer_id, new_peer_id)
	if _authority_enabled and supply_session != null:
		var session_migrated := supply_session.migrate_peer(
			old_peer_id,
			new_peer_id
		)
		if not session_migrated and supply_economy != null:
			if supply_economy.migrate_peer_references(
				old_peer_id,
				new_peer_id
			):
				_emit_host_encounter_snapshot()
	if _authority_enabled and rare_chest_session != null:
		rare_chest_session.migrate_peer(old_peer_id, new_peer_id)


func host_add_encounter_spectator(peer_id: int) -> void:
	if _authority_enabled and encounter_session != null:
		encounter_session.add_spectator(peer_id)
	if _authority_enabled and supply_session != null:
		supply_session.add_spectator(peer_id)
	if _authority_enabled and rare_chest_session != null:
		rare_chest_session.add_spectator(peer_id)


func _initialize_default_session(preparation_generation: int) -> void:
	# call_deferred 可能晚于外部切换到客户端等待周期；旧代不得再生成权威路线。
	if not is_runtime_preparation_generation_preparing(preparation_generation):
		return
	if auto_initialize and not is_route_ready():
		if not start_authoritative_session(
			initial_generation_seed
		):
			mark_runtime_preparation_failed(
				preparation_generation,
				"Rogue 路线图初始化失败：%s" % status_message.text
			)
			return
		mark_runtime_preparation_complete(preparation_generation)


func _create_underground_shop_runtime() -> void:
	if (
		underground_shop_controller == null
		or floor_definition == null
		or floor_definition.underground_shop_config == null
		or _run_state == null
		or not underground_shop_controller.configure(
			floor_definition.underground_shop_config,
			_run_state
		)
	):
		push_error("RogueRouteGame: 地下商店控制器配置失败。")
		return
	_sync_underground_shop_identity_context()


func _sync_underground_shop_identity_context() -> void:
	if underground_shop_controller == null:
		return
	underground_shop_controller.set_identity_context(
		_authority_enabled,
		_get_local_encounter_peer_id(),
		_player_names,
		_player_character_ids,
		_player_stable_keys
	)


func _reset_underground_shop_runtime(authority: bool) -> void:
	if underground_shop_controller == null:
		return
	if not underground_shop_controller.reset_runtime(
		authority,
		_get_local_encounter_peer_id(),
		_player_names,
		_player_character_ids,
		_player_stable_keys
	):
		push_error("RogueRouteGame: 地下商店控制器重置失败。")


func _try_start_underground_shop_for_node(
	node_id: int,
	visit_count: int
) -> bool:
	if (
		not _authority_enabled
		or not is_route_ready()
		or visit_count != 1
		or not _route_graph.is_valid_node_id(node_id)
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.UNDERGROUND_SHOP
		or underground_shop_controller == null
	):
		return false
	return underground_shop_controller.start_authoritative_for_node(
		_route_graph.compute_layout_hash(),
		node_id,
		_route_graph.get_node_content_seed(node_id),
		visit_count,
		_runtime_state.state_revision,
		_get_active_encounter_peer_ids()
	)


func _on_shop_controller_host_snapshot_committed(
	target_peer_id: int,
	snapshot: Dictionary
) -> void:
	host_shop_snapshot_committed.emit(target_peer_id, snapshot.duplicate(true))


func _on_shop_controller_purchase_requested(
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_session_revision: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> void:
	shop_purchase_requested.emit(
		request_id,
		occurrence_key,
		offer_index,
		expected_session_revision,
		expected_shelf_revision,
		expected_inventory_revision,
		expected_xirang_revision
	)


func _on_shop_controller_sell_requested(
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_session_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> void:
	shop_sell_requested.emit(
		request_id,
		occurrence_key,
		slot_index,
		expected_config_path,
		expected_session_revision,
		expected_inventory_revision,
		expected_xirang_revision
	)


func _on_shop_controller_exit_ack_requested(
	occurrence_key: String,
	expected_session_revision: int
) -> void:
	shop_exit_ack_requested.emit(occurrence_key, expected_session_revision)


func _on_shop_controller_presentation_state_changed() -> void:
	_reconcile_local_modal_presentations()
	_refresh_route_input_lock()






func _set_shop_route_presentation_active(active: bool) -> void:
	_set_route_presentation_lease(
		RoutePresentationLease.UNDERGROUND_SHOP,
		not active
	)


func _is_local_shop_presentation_active() -> bool:
	return (
		underground_shop_controller != null
		and underground_shop_controller.is_presentation_active()
	)


func _get_shop_waiting_player_names() -> PackedStringArray:
	if underground_shop_controller == null:
		return PackedStringArray()
	return underground_shop_controller.get_waiting_player_names()




func _create_encounter_runtime() -> void:
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	encounter_economy.reset_runtime(run_state, _player_character_ids)
	encounter_session.reset_remote(encounter_economy, run_state)
	if not encounter_session.state_changed.is_connected(
		_on_encounter_state_changed
	):
		encounter_session.state_changed.connect(_on_encounter_state_changed)
	if not encounter_session.economy_changed.is_connected(
		_on_encounter_economy_changed
	):
		encounter_session.economy_changed.connect(
			_on_encounter_economy_changed
		)
	if encounter_scene != null:
		if not encounter_scene.intro_ack_requested.is_connected(
			_on_encounter_intro_ack_requested
		):
			encounter_scene.intro_ack_requested.connect(
				_on_encounter_intro_ack_requested
			)
		if not encounter_scene.vote_requested.is_connected(
			_on_encounter_vote_requested
		):
			encounter_scene.vote_requested.connect(
				_on_encounter_vote_requested
			)
		if not encounter_scene.encounter_revealed.is_connected(
			_on_encounter_revealed
		):
			encounter_scene.encounter_revealed.connect(
				_on_encounter_revealed
			)
		if not encounter_scene.result_hold_completed.is_connected(
			_on_encounter_result_hold_completed
		):
			encounter_scene.result_hold_completed.connect(
				_on_encounter_result_hold_completed
			)
		if not encounter_overlay.result_ack_requested.is_connected(
			_on_encounter_result_ack_requested
		):
			encounter_overlay.result_ack_requested.connect(
				_on_encounter_result_ack_requested
			)
	_configure_encounter_overlay_context()


func _reset_encounter_runtime(authority: bool) -> void:
	_reset_run_defeat_presentation()
	_encounter_presentation_serial += 1
	_encounter_presented_active = false
	_local_result_hold_completed_occurrence_key = ""
	if encounter_scene != null:
		encounter_scene.hide_immediately()
	_set_route_presentation_active(true)
	_set_encounter_input_locked(false)
	_create_encounter_runtime()
	if authority:
		encounter_session.reset_authority(
			encounter_economy,
			_get_active_encounter_peer_ids(),
			_run_state
		)


func _create_supply_runtime() -> void:
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	supply_economy.reset_runtime(
		run_state,
		_runtime_state,
		_player_character_ids
	)
	supply_session.reset_remote(supply_economy)
	if not supply_session.state_changed.is_connected(_on_supply_state_changed):
		supply_session.state_changed.connect(_on_supply_state_changed)
	if not supply_session.economy_changed.is_connected(
		_on_supply_economy_changed
	):
		supply_session.economy_changed.connect(_on_supply_economy_changed)
	if supply_overlay != null:
		if not supply_overlay.intro_ack_requested.is_connected(
			_on_supply_intro_ack_requested
		):
			supply_overlay.intro_ack_requested.connect(
				_on_supply_intro_ack_requested
			)
		if not supply_overlay.vote_requested.is_connected(
			_on_supply_vote_requested
		):
			supply_overlay.vote_requested.connect(_on_supply_vote_requested)
		if not supply_overlay.collectible_choice_requested.is_connected(
			_on_supply_collectible_choice_requested
		):
			supply_overlay.collectible_choice_requested.connect(
				_on_supply_collectible_choice_requested
			)
		if not supply_overlay.completed_requested.is_connected(
			_on_supply_completed_requested
		):
			supply_overlay.completed_requested.connect(
				_on_supply_completed_requested
			)
		if not supply_overlay.inventory_requested.is_connected(
			_on_supply_inventory_requested
		):
			supply_overlay.inventory_requested.connect(
				_on_supply_inventory_requested
			)
	_configure_supply_overlay_context()


func _reset_supply_runtime(authority: bool) -> void:
	_last_supply_ap_broadcast_occurrence_key = ""
	_local_supply_modal_owner_active = false
	if player_profile_panel != null and player_profile_panel.is_open():
		player_profile_panel.close()
	if supply_overlay != null:
		supply_overlay.hide_supply_immediately()
	_create_supply_runtime()
	if authority:
		supply_session.reset_authority(
			supply_economy,
			_get_active_encounter_peer_ids()
		)
	_reconcile_local_modal_presentations()
	_refresh_route_input_lock()


func _create_rare_chest_runtime() -> void:
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	rare_chest_economy.reset_runtime(run_state, _player_character_ids)
	rare_chest_session.reset_remote(rare_chest_economy)
	if not rare_chest_session.state_changed.is_connected(
		_on_rare_chest_state_changed
	):
		rare_chest_session.state_changed.connect(_on_rare_chest_state_changed)
	if not rare_chest_session.choice_committed.is_connected(
		_on_rare_chest_choice_committed
	):
		rare_chest_session.choice_committed.connect(
			_on_rare_chest_choice_committed
		)
	if (
		rare_chest_overlay != null
		and not rare_chest_overlay.choice_requested.is_connected(
			_on_rare_chest_choice_requested
		)
	):
		rare_chest_overlay.choice_requested.connect(
			_on_rare_chest_choice_requested
		)
	_configure_rare_chest_overlay_context()


func _reset_rare_chest_runtime(
	authority: bool,
	preserve_local_reward_occurrence_key: String = ""
) -> void:
	var preserve_offer_seen := (
		not preserve_local_reward_occurrence_key.is_empty()
		and _rare_chest_local_offer_seen_occurrences.has(
			preserve_local_reward_occurrence_key
		)
	)
	var preserve_heal_applied := (
		not preserve_local_reward_occurrence_key.is_empty()
		and _rare_chest_local_heal_applied_occurrences.has(
			preserve_local_reward_occurrence_key
		)
	)
	var preserve_presented_active := (
		not preserve_local_reward_occurrence_key.is_empty()
		and _rare_chest_presented_active
	)
	_rare_chest_presented_active = preserve_presented_active
	_rare_chest_presentation_dismiss_pending = false
	_rare_chest_presentation_serial += 1
	_rare_chest_local_offer_seen_occurrences.clear()
	_rare_chest_local_heal_applied_occurrences.clear()
	if preserve_offer_seen:
		_rare_chest_local_offer_seen_occurrences[
			preserve_local_reward_occurrence_key
		] = true
	if preserve_heal_applied:
		_rare_chest_local_heal_applied_occurrences[
			preserve_local_reward_occurrence_key
		] = true
	if rare_chest_overlay != null:
		rare_chest_overlay.hide_rare_chest_immediately()
	_create_rare_chest_runtime()
	if authority:
		rare_chest_session.reset_authority(rare_chest_economy)
	_reconcile_local_modal_presentations()
	_refresh_route_input_lock()


func _reset_normal_combat_stage(restore_presentation: bool) -> void:
	var interrupted_occurrence_key := _normal_combat_occurrence_key
	if _briefing_phase != BriefingPhase.NONE:
		if _authority_enabled and is_route_ready():
			_commit_host_briefing_state(
				BriefingPhase.NONE,
				INVALID_NODE_ID,
				"",
				-1
			)
		else:
			_reset_briefing_runtime(false)
	_clear_normal_combat_state()
	if not is_node_ready():
		return
	combat_victory_presentation.interrupt_and_reset()
	combat_scene_transition.hide_immediately()
	hide_combat_result()
	if restore_presentation:
		set_route_presentation_enabled(true)
	_set_encounter_input_locked(
		(encounter_session != null and encounter_session.is_active())
		or (supply_session != null and supply_session.is_active())
		or (rare_chest_session != null and rare_chest_session.is_active())
	)
	normal_combat_stage_reset.emit(interrupted_occurrence_key)


func _clear_normal_combat_state() -> void:
	_normal_combat_active = false
	_normal_combat_node_id = INVALID_NODE_ID
	_normal_combat_content_seed = 0
	_normal_combat_visit_count = 0
	_normal_combat_occurrence_key = ""
	_normal_combat_config_id = &""


func _begin_normal_combat_stage(
	node_id: int,
	content_seed: int,
	occurrence_key: String,
	combat_config_id: StringName = &""
) -> void:
	var resolved_config_id := combat_config_id
	if resolved_config_id == &"":
		var resolved_config := resolve_normal_combat_config_for_node(node_id)
		if resolved_config != null:
			resolved_config_id = resolved_config.encounter_id
	_normal_combat_active = true
	_normal_combat_node_id = node_id
	_normal_combat_content_seed = content_seed
	_normal_combat_visit_count = int(_runtime_state.visited_counts[node_id])
	_normal_combat_occurrence_key = occurrence_key
	_normal_combat_config_id = resolved_config_id
	_reconcile_local_modal_presentations()
	_set_encounter_input_locked(true)


func _validate_combat_start(
	node_id: int,
	content_seed: int,
	occurrence_key: String,
	combat_config_id: StringName
) -> bool:
	if (
		not is_route_ready()
		or occurrence_key.is_empty()
		or combat_config_id == &""
		or resolve_combat_config(combat_config_id) == null
		or not _route_graph.is_valid_node_id(node_id)
		or _runtime_state.current_node_id != node_id
		or _route_graph.get_node_content_seed(node_id) != content_seed
		or node_id >= _runtime_state.visited_counts.size()
	):
		return false
	var visit_count := int(_runtime_state.visited_counts[node_id])
	var expected_normal_config := resolve_normal_combat_config_for_node(node_id)
	if expected_normal_config != null:
		return (
			_route_graph.get_node_type(node_id)
			== RogueRouteGraph.NodeType.NORMAL_COMBAT
			and combat_config_id == expected_normal_config.encounter_id
			and visit_count == 1
			and occurrence_key == _make_normal_combat_occurrence_key(
				node_id,
				content_seed,
				visit_count
			)
		)
	var expected_emergency_config := resolve_emergency_combat_config_for_node(node_id)
	if expected_emergency_config != null:
		return (
			_route_graph.get_node_type(node_id)
			== RogueRouteGraph.NodeType.EMERGENCY_COMBAT
			and combat_config_id == expected_emergency_config.encounter_id
			and visit_count == 1
			and occurrence_key == _make_emergency_combat_occurrence_key(
				node_id,
				content_seed,
				visit_count
			)
		)
	if _route_graph.get_node_type(node_id) != RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER:
		return false
	var source_occurrence_key := _get_followup_source_occurrence_from_combat_key(
		occurrence_key,
		node_id,
		content_seed,
		combat_config_id
	)
	return (
		visit_count >= 1
		and not source_occurrence_key.is_empty()
		and occurrence_key == _make_followup_combat_occurrence_key(
			node_id,
			content_seed,
			source_occurrence_key,
			combat_config_id
		)
		and _validate_followup_encounter_snapshot(
			encounter_session.export_state() if encounter_session != null else {},
			node_id,
			source_occurrence_key,
			combat_config_id
		)
	)


## 兼容仍直接调用旧私有名称的聚焦测试。
func _validate_normal_combat_start(
	node_id: int,
	content_seed: int,
	occurrence_key: String
) -> bool:
	var config := resolve_normal_combat_config_for_node(node_id)
	if config == null:
		return false
	return _validate_combat_start(
		node_id,
		content_seed,
		occurrence_key,
		config.encounter_id
	)


func _make_normal_combat_occurrence_key(
	node_id: int,
	content_seed: int,
	visit_count: int
) -> String:
	if (
		_route_graph == null
		or not _route_graph.is_valid_node_id(node_id)
		or visit_count != 1
	):
		return ""
	return "combat:%s:%d:%d:%d" % [
		_route_graph.compute_layout_hash(),
		node_id,
		content_seed,
		visit_count,
	]


func _make_emergency_combat_occurrence_key(
	node_id: int,
	content_seed: int,
	visit_count: int
) -> String:
	if (
		_route_graph == null
		or not _route_graph.is_valid_node_id(node_id)
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.EMERGENCY_COMBAT
		or visit_count != 1
	):
		return ""
	return "emergency_combat:%s:%d:%d:%d" % [
		_route_graph.compute_layout_hash(),
		node_id,
		content_seed,
		visit_count,
	]


func _make_followup_combat_occurrence_key(
	node_id: int,
	content_seed: int,
	source_encounter_occurrence_key: String,
	combat_config_id: StringName
) -> String:
	if (
		_route_graph == null
		or not _route_graph.is_valid_node_id(node_id)
		or source_encounter_occurrence_key.is_empty()
		or combat_config_id == &""
		or resolve_combat_config(combat_config_id) == null
	):
		return ""
	return "followup_combat:%s:%d:%d:%s:%s" % [
		_route_graph.compute_layout_hash(),
		node_id,
		content_seed,
		source_encounter_occurrence_key,
		String(combat_config_id),
	]


func _get_followup_source_occurrence_from_combat_key(
	combat_occurrence_key: String,
	node_id: int,
	content_seed: int,
	combat_config_id: StringName
) -> String:
	if (
		_route_graph == null
		or combat_occurrence_key.is_empty()
		or combat_config_id == &""
		or not _route_graph.is_valid_node_id(node_id)
	):
		return ""
	var prefix := "followup_combat:%s:%d:%d:" % [
		_route_graph.compute_layout_hash(),
		node_id,
		content_seed,
	]
	var suffix := ":%s" % String(combat_config_id)
	if (
		not combat_occurrence_key.begins_with(prefix)
		or not combat_occurrence_key.ends_with(suffix)
		or combat_occurrence_key.length() <= prefix.length() + suffix.length()
	):
		return ""
	return combat_occurrence_key.substr(
		prefix.length(),
		combat_occurrence_key.length() - prefix.length() - suffix.length()
	)


func _validate_followup_encounter_snapshot(
	snapshot: Dictionary,
	node_id: int,
	source_occurrence_key: String,
	combat_config_id: StringName,
	validation_graph: RogueRouteGraph = null
) -> bool:
	var graph := validation_graph if validation_graph != null else _route_graph
	if (
		snapshot.is_empty()
		or node_id < 0
		or source_occurrence_key.is_empty()
		or combat_config_id == &""
		or combat_config_id != SUITCASE_FOLLOWUP_COMBAT_ID
		or graph == null
		or not graph.is_valid_node_id(node_id)
		or graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
		or floor_definition == null
		or floor_definition.get_special_combat_config(combat_config_id) == null
		or StringName(snapshot.get("phase", &""))
		!= RogueEncounterSession.PHASE_COMPLETED
		or int(snapshot.get("node_id", INVALID_NODE_ID)) != node_id
		or str(snapshot.get("occurrence_key", ""))
		!= source_occurrence_key
		or StringName(snapshot.get("encounter_id", &""))
		!= RogueEncounterRegistry.SUITCASE_FRENZY
		or StringName(snapshot.get("winning_option", &""))
		!= RogueEncounterRegistry.OPTION_CLAIM_SUITCASE
	):
		return false
	var expected_node_seed := graph.get_node_content_seed(node_id)
	var expected_source_occurrence := "%d:%d" % [node_id, expected_node_seed]
	var resolved_node_ids_variant: Variant = snapshot.get("resolved_node_ids")
	var round_recipient_ids_variant: Variant = snapshot.get(
		"round_recipient_peer_ids"
	)
	var result_ack_ids_variant: Variant = snapshot.get("result_ack_peer_ids")
	if (
		int(snapshot.get("node_content_seed", -1)) != expected_node_seed
		or source_occurrence_key != expected_source_occurrence
		or not bool(snapshot.get("terminal_result", false))
		or not bool(snapshot.get("settlement_committed", false))
		or bool(snapshot.get("run_failed", true))
		or int(snapshot.get("result_sequence", 0)) <= 0
		or typeof(resolved_node_ids_variant) != TYPE_ARRAY
		or not (resolved_node_ids_variant as Array).has(node_id)
		or typeof(round_recipient_ids_variant) != TYPE_ARRAY
		or typeof(result_ack_ids_variant) != TYPE_ARRAY
	):
		return false
	var result_ack_ids := result_ack_ids_variant as Array
	for recipient_peer_id in round_recipient_ids_variant as Array:
		if not result_ack_ids.has(recipient_peer_id):
			return false
	var result := snapshot.get("economy_result", {}) as Dictionary
	return (
		bool(result.get("resolved", false))
		and StringName(result.get("encounter_id", &""))
		== RogueEncounterRegistry.SUITCASE_FRENZY
		and StringName(result.get("option_id", &""))
		== RogueEncounterRegistry.OPTION_CLAIM_SUITCASE
		and StringName(result.get("result_code", &""))
		== SUITCASE_FOLLOWUP_RESULT_CODE
		and bool(result.get("terminal", false))
		and StringName(result.get("result_presentation", &""))
		== SUITCASE_FOLLOWUP_PRESENTATION
		and StringName(result.get("followup_combat_id", &""))
		== SUITCASE_FOLLOWUP_COMBAT_ID
	)


func _commit_host_briefing_state(
	phase: int,
	node_id: int,
	occurrence_key: String,
	expected_route_revision: int,
	source_kind: StringName = &"",
	combat_config_id: StringName = &"",
	source_encounter_occurrence_key: String = ""
) -> bool:
	if not _authority_enabled or not is_route_ready():
		return false
	if phase == BriefingPhase.NONE:
		source_kind = &""
		combat_config_id = &""
		source_encounter_occurrence_key = ""
	elif source_kind == &"":
		if (
			node_id == _briefing_node_id
			and occurrence_key == _briefing_occurrence_key
			and _briefing_source_kind != &""
		):
			source_kind = _briefing_source_kind
			combat_config_id = _briefing_combat_config_id
			source_encounter_occurrence_key = (
				_briefing_source_encounter_occurrence_key
			)
		elif (
			_route_graph.is_valid_node_id(node_id)
			and _route_graph.get_node_type(node_id)
			== RogueRouteGraph.NodeType.NORMAL_COMBAT
		):
			var resolved_config := resolve_normal_combat_config_for_node(node_id)
			if resolved_config != null:
				source_kind = (
					RogueRouteNodeBriefingModel.SOURCE_KIND_DEFAULT_COMBAT
				)
				combat_config_id = resolved_config.encounter_id
		elif (
			_route_graph.is_valid_node_id(node_id)
			and _route_graph.get_node_type(node_id)
			== RogueRouteGraph.NodeType.EMERGENCY_COMBAT
		):
			var resolved_config := resolve_emergency_combat_config_for_node(node_id)
			if resolved_config != null:
				source_kind = (
					RogueRouteNodeBriefingModel.SOURCE_KIND_EMERGENCY_COMBAT
				)
				combat_config_id = resolved_config.encounter_id
	var snapshot := {
		"schema_version": BRIEFING_SCHEMA_VERSION,
		"layout_hash": _route_graph.compute_layout_hash(),
		"revision": _briefing_revision + 1,
		"phase": phase,
		"node_id": node_id,
		"occurrence_key": occurrence_key,
		"expected_route_revision": expected_route_revision,
		"source_kind": String(source_kind),
		"combat_config_id": String(combat_config_id),
		"source_encounter_occurrence_key": source_encounter_occurrence_key,
	}
	if not _validate_briefing_state_against(
		snapshot,
		_route_graph,
		_runtime_state,
		encounter_session.export_state() if encounter_session != null else {}
	):
		return false
	var previous_phase := _briefing_phase
	_assign_briefing_state(snapshot)
	_sync_briefing_presentation(previous_phase)
	host_briefing_state_committed.emit(snapshot.duplicate(true))
	return true


func _assign_briefing_state(snapshot: Dictionary) -> void:
	_briefing_revision = int(snapshot["revision"])
	_briefing_phase = int(snapshot["phase"])
	_briefing_node_id = int(snapshot["node_id"])
	_briefing_occurrence_key = str(snapshot["occurrence_key"])
	_briefing_expected_route_revision = int(
		snapshot["expected_route_revision"]
	)
	_briefing_source_kind = StringName(snapshot["source_kind"])
	_briefing_combat_config_id = StringName(snapshot["combat_config_id"])
	_briefing_source_encounter_occurrence_key = str(
		snapshot["source_encounter_occurrence_key"]
	)


func _validate_briefing_state_against(
	snapshot: Dictionary,
	graph: RogueRouteGraph,
	state: RogueRouteRuntimeState,
	encounter_state_snapshot: Dictionary = {}
) -> bool:
	if (
		graph == null
		or state == null
		or generation_config == null
		or typeof(snapshot.get("schema_version")) != TYPE_INT
		or int(snapshot["schema_version"]) != BRIEFING_SCHEMA_VERSION
		or typeof(snapshot.get("layout_hash")) != TYPE_STRING
		or str(snapshot["layout_hash"]) != graph.compute_layout_hash()
		or typeof(snapshot.get("revision")) != TYPE_INT
		or int(snapshot["revision"]) < 0
		or typeof(snapshot.get("phase")) != TYPE_INT
		or typeof(snapshot.get("node_id")) != TYPE_INT
		or typeof(snapshot.get("occurrence_key")) != TYPE_STRING
		or typeof(snapshot.get("expected_route_revision")) != TYPE_INT
		or typeof(snapshot.get("source_kind")) != TYPE_STRING
		or typeof(snapshot.get("combat_config_id")) != TYPE_STRING
		or typeof(snapshot.get("source_encounter_occurrence_key"))
		!= TYPE_STRING
	):
		return false
	var phase := int(snapshot["phase"])
	var node_id := int(snapshot["node_id"])
	var occurrence_key := str(snapshot["occurrence_key"])
	var expected_route_revision := int(
		snapshot["expected_route_revision"]
	)
	var source_kind := StringName(snapshot["source_kind"])
	var combat_config_id := StringName(snapshot["combat_config_id"])
	var source_encounter_occurrence_key := str(
		snapshot["source_encounter_occurrence_key"]
	)
	if phase == BriefingPhase.NONE:
		return (
			node_id == INVALID_NODE_ID
			and occurrence_key.is_empty()
			and expected_route_revision == -1
			and source_kind == &""
			and combat_config_id == &""
			and source_encounter_occurrence_key.is_empty()
		)
	if phase not in [BriefingPhase.PRESENTED, BriefingPhase.ENTERING]:
		return false
	if (
		node_id < 0
		or not graph.is_valid_node_id(node_id)
		or node_id >= state.visited_counts.size()
		or occurrence_key.is_empty()
		or expected_route_revision < 0
		or source_kind not in [
			RogueRouteNodeBriefingModel.SOURCE_KIND_DEFAULT_COMBAT,
			RogueRouteNodeBriefingModel.SOURCE_KIND_EMERGENCY_COMBAT,
			RogueRouteNodeBriefingModel.SOURCE_KIND_SPECIAL_COMBAT,
		]
		or combat_config_id == &""
		or floor_definition == null
		or floor_definition.get_combat_config(combat_config_id) == null
	):
		return false
	if source_kind == RogueRouteNodeBriefingModel.SOURCE_KIND_SPECIAL_COMBAT:
		if (
			graph.get_node_type(node_id)
			!= RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
			or state.current_node_id != node_id
			or int(state.visited_counts[node_id]) < 1
			or state.state_revision != expected_route_revision
			or source_encounter_occurrence_key.is_empty()
			or floor_definition.get_special_combat_config(combat_config_id) == null
			or not _special_combat_briefing_adapters.has(combat_config_id)
			or not _validate_followup_encounter_snapshot(
				encounter_state_snapshot,
				node_id,
				source_encounter_occurrence_key,
				combat_config_id,
				graph
			)
		):
			return false
		var expected_followup_occurrence := (
			"followup_combat:%s:%d:%d:%s:%s" % [
				graph.compute_layout_hash(),
				node_id,
				graph.get_node_content_seed(node_id),
				source_encounter_occurrence_key,
				String(combat_config_id),
			]
		)
		return occurrence_key == expected_followup_occurrence
	var emergency_source := (
		source_kind
		== RogueRouteNodeBriefingModel.SOURCE_KIND_EMERGENCY_COMBAT
	)
	var expected_direct_config := (
		resolve_emergency_combat_config_for_node(node_id, graph)
		if emergency_source
		else resolve_normal_combat_config_for_node(node_id, graph)
	)
	var expected_node_type := (
		RogueRouteGraph.NodeType.EMERGENCY_COMBAT
		if emergency_source
		else RogueRouteGraph.NodeType.NORMAL_COMBAT
	)
	if (
		graph.get_node_type(node_id) != expected_node_type
		or expected_direct_config == null
		or combat_config_id != expected_direct_config.encounter_id
		or not source_encounter_occurrence_key.is_empty()
	):
		return false

	var visit_count := 0
	if state.state_revision == expected_route_revision:
		if (
			not graph.has_edge(state.current_node_id, node_id)
			or int(state.visited_counts[node_id]) != 0
			or not state.get_move_rejection_reason(
				node_id,
				generation_config.move_action_cost,
				expected_route_revision
			).is_empty()
		):
			return false
		visit_count = 1
		if (
				_build_direct_combat_briefing_model(
					node_id,
					state.action_points,
					source_kind,
					combat_config_id,
					graph
				) == null
		):
			return false
	elif (
		phase == BriefingPhase.ENTERING
		and state.state_revision == expected_route_revision + 1
		and state.current_node_id == node_id
		and int(state.visited_counts[node_id]) == 1
	):
		visit_count = 1
	else:
		return false
	var occurrence_prefix := "emergency_combat" if emergency_source else "combat"
	var expected_occurrence_key := "%s:%s:%d:%d:%d" % [
		occurrence_prefix,
		graph.compute_layout_hash(),
		node_id,
		graph.get_node_content_seed(node_id),
		visit_count,
	]
	return occurrence_key == expected_occurrence_key


func _build_normal_combat_briefing_model(
	node_id: int,
	current_action_points: int,
	combat_config_id: StringName = &"",
	validation_graph: RogueRouteGraph = null
) -> RogueRouteNodeBriefingModel:
	var config := resolve_normal_combat_config_for_node(
		node_id,
		validation_graph
	)
	var resolved_config_id := (
		combat_config_id
		if combat_config_id != &""
		else config.encounter_id if config != null else &""
	)
	if (
		config == null
		or resolved_config_id != config.encounter_id
		or not _normal_combat_briefing_adapters.has(resolved_config_id)
		or generation_config == null
		or node_id < 0
	):
		return null
	var node_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.NORMAL_COMBAT
	)
	var adapter := _normal_combat_briefing_adapters[resolved_config_id] as RefCounted
	return adapter.call(
		&"build_model",
		node_config,
		current_action_points,
		generation_config.move_action_cost
	) as RogueRouteNodeBriefingModel


func _build_emergency_combat_briefing_model(
	node_id: int,
	current_action_points: int,
	combat_config_id: StringName = &"",
	validation_graph: RogueRouteGraph = null
) -> RogueRouteNodeBriefingModel:
	var config := resolve_emergency_combat_config_for_node(
		node_id,
		validation_graph
	)
	var resolved_config_id := (
		combat_config_id
		if combat_config_id != &""
		else config.encounter_id if config != null else &""
	)
	if (
		config == null
		or resolved_config_id != config.encounter_id
		or not _emergency_combat_briefing_adapters.has(resolved_config_id)
		or generation_config == null
		or node_id < 0
	):
		return null
	var node_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.EMERGENCY_COMBAT
	)
	var adapter := (
		_emergency_combat_briefing_adapters[resolved_config_id] as RefCounted
	)
	var model := adapter.call(
		&"build_model",
		node_config,
		current_action_points,
		generation_config.move_action_cost
	) as RogueRouteNodeBriefingModel
	if model == null:
		return null
	# 紧急作战的人数由 occurrence key 确定；简报必须展示本场实际人数，
	# 不能继续显示 authored 波次在 5%～10% 增幅前的基数。
	var graph := validation_graph if validation_graph != null else _route_graph
	var occurrence_key := "emergency_combat:%s:%d:%d:1" % [
		graph.compute_layout_hash(),
		node_id,
		graph.get_node_content_seed(node_id),
	]
	var campaign := config.build_occurrence_campaign(occurrence_key)
	if campaign == null:
		return null
	var occurrence_enemy_count := 0
	for wave in campaign.get_waves():
		if wave != null:
			occurrence_enemy_count += wave.get_total_enemy_count()
	if occurrence_enemy_count <= 0:
		return null
	model.enemy_count = occurrence_enemy_count
	return model if model.is_valid() else null


func _build_direct_combat_briefing_model(
	node_id: int,
	current_action_points: int,
	source_kind: StringName,
	combat_config_id: StringName,
	validation_graph: RogueRouteGraph = null
) -> RogueRouteNodeBriefingModel:
	if source_kind == RogueRouteNodeBriefingModel.SOURCE_KIND_EMERGENCY_COMBAT:
		return _build_emergency_combat_briefing_model(
			node_id,
			current_action_points,
			combat_config_id,
			validation_graph
		)
	if source_kind == RogueRouteNodeBriefingModel.SOURCE_KIND_DEFAULT_COMBAT:
		return _build_normal_combat_briefing_model(
			node_id,
			current_action_points,
			combat_config_id,
			validation_graph
		)
	return null


func _create_normal_combat_briefing_adapters() -> void:
	_normal_combat_briefing_adapters.clear()
	if floor_definition == null:
		return
	for config in floor_definition.get_sorted_normal_combat_configs():
		if config == null or not config.is_ready_to_enable():
			continue
		_normal_combat_briefing_adapters[config.encounter_id] = (
			NORMAL_COMBAT_BRIEFING_ADAPTER_SCRIPT.new(
				config,
				config.briefing_visual
			)
		)


func _create_emergency_combat_briefing_adapters() -> void:
	_emergency_combat_briefing_adapters.clear()
	if floor_definition == null:
		return
	for config in floor_definition.get_sorted_emergency_combat_configs():
		if config == null or not config.is_ready_to_enable():
			continue
		_emergency_combat_briefing_adapters[config.encounter_id] = (
			EMERGENCY_COMBAT_BRIEFING_ADAPTER_SCRIPT.new(
				config,
				config.briefing_visual
			)
		)


func _create_special_combat_briefing_adapters() -> void:
	_special_combat_briefing_adapters.clear()
	if floor_definition == null:
		return
	for config in floor_definition.get_sorted_special_combat_configs():
		if config == null or not config.is_ready_to_enable():
			continue
		_special_combat_briefing_adapters[config.encounter_id] = (
			SPECIAL_COMBAT_BRIEFING_ADAPTER_SCRIPT.new(
				config,
				config.briefing_visual,
				_build_special_combat_reward_summary(config)
			)
		)


func _build_special_combat_reward_summary(
	config: RogueCombatEncounterConfig
) -> String:
	if config == null or config.reward_config == null:
		return "特殊作战胜利奖励"
	var reward := config.reward_config
	if config.encounter_id == SUITCASE_FOLLOWUP_COMBAT_ID:
		return "全队额外 +%d～%d 息壤 · 每人 2 件普通收藏品 · 每人 6 块木板" % [
			reward.xirang_minimum,
			reward.xirang_maximum,
		]
	return "额外 +%d～%d 息壤 · 随机 %d 件收藏品" % [
		reward.xirang_minimum,
		reward.xirang_maximum,
		reward.collectible_count,
	]


func _build_special_combat_briefing_model(
	node_id: int,
	combat_config_id: StringName,
	current_action_points: int
) -> RogueRouteNodeBriefingModel:
	if (
		generation_config == null
		or node_id < 0
		or not _special_combat_briefing_adapters.has(combat_config_id)
	):
		return null
	var node_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
	)
	var adapter := _special_combat_briefing_adapters[combat_config_id] as RefCounted
	return adapter.call(
		&"build_model",
		node_config,
		current_action_points,
		0
	) as RogueRouteNodeBriefingModel


func _build_current_briefing_model() -> RogueRouteNodeBriefingModel:
	if _briefing_source_kind == RogueRouteNodeBriefingModel.SOURCE_KIND_DEFAULT_COMBAT:
		return _build_normal_combat_briefing_model(
			_briefing_node_id,
			_runtime_state.action_points,
			_briefing_combat_config_id
		)
	if _briefing_source_kind == RogueRouteNodeBriefingModel.SOURCE_KIND_EMERGENCY_COMBAT:
		return _build_emergency_combat_briefing_model(
			_briefing_node_id,
			_runtime_state.action_points,
			_briefing_combat_config_id
		)
	if _briefing_source_kind == RogueRouteNodeBriefingModel.SOURCE_KIND_SPECIAL_COMBAT:
		return _build_special_combat_briefing_model(
			_briefing_node_id,
			_briefing_combat_config_id,
			_runtime_state.action_points
		)
	return null


func _sync_briefing_presentation(previous_phase: int) -> void:
	if not is_node_ready():
		return
	if _briefing_phase == BriefingPhase.NONE:
		node_briefing.dismiss()
		if (
			previous_phase == BriefingPhase.ENTERING
			and not _normal_combat_active
		):
			combat_scene_transition.hide_immediately()
		_pending_node_id = INVALID_NODE_ID
		_pending_revision = -1
		route_board.clear_selection()
		_reconcile_local_modal_presentations()
		_refresh_route_input_lock()
		return
	_pending_node_id = _briefing_node_id
	_pending_revision = _briefing_expected_route_revision
	route_board.select_node(_briefing_node_id)
	route_board.set_interaction_locked(true)
	_set_local_player_controls_locked(true)
	_camera_drag_active = false
	# Briefing 是显式的路线 Modal owner。无论 PRESENTED 还是 ENTERING，
	# 都必须立即刷新统一输入门禁，并暂压已完成 Supply 的本地待领取层；
	# 不能只依赖上面两处手工 board/player 锁。
	_reconcile_local_modal_presentations()
	_refresh_route_input_lock()
	if _briefing_phase == BriefingPhase.PRESENTED:
		var model := _build_current_briefing_model()
		if model == null:
			push_error("作战简报模型构建失败。")
			return
		node_briefing.present(model, _authority_enabled)
		return
	node_briefing.dismiss()
	if not combat_scene_transition.visible:
		call_deferred(
			&"_cover_then_submit_briefed_move",
			_briefing_revision,
			_briefing_occurrence_key
		)


func _cover_then_submit_briefed_move(
	briefing_revision: int,
	occurrence_key: String
) -> void:
	if (
		_briefing_phase != BriefingPhase.ENTERING
		or briefing_revision != _briefing_revision
		or occurrence_key != _briefing_occurrence_key
	):
		return
	var covered := await combat_scene_transition.cover()
	if (
		not covered
		or _briefing_phase != BriefingPhase.ENTERING
		or briefing_revision != _briefing_revision
		or occurrence_key != _briefing_occurrence_key
	):
		return
	briefing_cover_completed.emit(
		occurrence_key,
		briefing_revision,
		_briefing_expected_route_revision
	)
	if _authority_enabled and manage_return_locally:
		host_commit_briefing_entry(
			occurrence_key,
			briefing_revision,
			_briefing_expected_route_revision
		)


func _recover_failed_briefing_entry(message: String) -> void:
	if _briefing_phase != BriefingPhase.ENTERING:
		return
	if not _commit_host_briefing_state(
		BriefingPhase.NONE,
		INVALID_NODE_ID,
		"",
		-1
	):
		return
	_set_status(message, true)
	var revealed := await combat_scene_transition.reveal()
	if not revealed:
		combat_scene_transition.hide_immediately()


func _reset_briefing_runtime(interrupt_transition: bool) -> void:
	_briefing_revision = 0
	_briefing_phase = BriefingPhase.NONE
	_briefing_node_id = INVALID_NODE_ID
	_briefing_occurrence_key = ""
	_briefing_expected_route_revision = -1
	_briefing_source_kind = &""
	_briefing_combat_config_id = &""
	_briefing_source_encounter_occurrence_key = ""
	if not is_node_ready():
		return
	node_briefing.dismiss()
	if interrupt_transition:
		combat_scene_transition.hide_immediately()
	route_board.clear_selection()
	_refresh_route_input_lock()


func _configure_encounter_overlay_context() -> void:
	if encounter_scene == null:
		return
	var local_peer_id := _get_local_encounter_peer_id()
	var names := _player_names.duplicate(true)
	var character_ids := _player_character_ids.duplicate(true)
	if names.is_empty():
		names[local_peer_id] = "玩家"
	if character_ids.is_empty() and player != null:
		character_ids[local_peer_id] = player.get_character_id()
	encounter_scene.configure_local_context(
		local_peer_id,
		names,
		character_ids
	)


func _configure_supply_overlay_context() -> void:
	if supply_overlay == null:
		return
	var local_peer_id := _get_local_encounter_peer_id()
	var names := _player_names.duplicate(true)
	var character_ids := _player_character_ids.duplicate(true)
	if names.is_empty():
		names[local_peer_id] = "玩家"
	if character_ids.is_empty() and player != null:
		character_ids[local_peer_id] = player.get_character_id()
	supply_overlay.configure_local_context(
		local_peer_id,
		names,
		character_ids
	)


func _configure_rare_chest_overlay_context() -> void:
	if rare_chest_overlay == null:
		return
	var local_peer_id := _get_local_encounter_peer_id()
	var names := _player_names.duplicate(true)
	if names.is_empty():
		names[local_peer_id] = "玩家"
	rare_chest_overlay.configure_local_context(local_peer_id, names)


func _get_local_encounter_peer_id() -> int:
	return _local_peer_id if _local_peer_id > 0 else SINGLEPLAYER_PEER_ID


func _get_active_encounter_peer_ids() -> Array[int]:
	var result: Array[int] = []
	for peer_id_variant in peer_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id > 0:
			result.append(peer_id)
	if result.is_empty():
		result.append(_get_local_encounter_peer_id())
	result.sort()
	return result


func _get_map_assigned_encounter_id(
	node_id: int,
	validation_graph: RogueRouteGraph = null
) -> StringName:
	var graph := validation_graph if validation_graph != null else _route_graph
	if (
		graph == null
		or generation_config == null
		or not graph.is_valid_node_id(node_id)
		or graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
	):
		return &""
	var type_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
	)
	if type_config == null or type_config.content_pool_id == &"":
		return &""
	return RogueEncounterRegistry.select_encounter_for_map(
		type_config.content_pool_id,
		graph.generation_seed,
		graph.get_node_ids_by_type(
			RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
		),
		node_id
	)


func _validate_map_encounter_assignment(
	snapshot: Dictionary,
	validation_graph: RogueRouteGraph = null
) -> bool:
	var phase := StringName(snapshot.get("phase", &""))
	if phase == RogueEncounterSession.PHASE_IDLE:
		return true
	var graph := validation_graph if validation_graph != null else _route_graph
	var node_id := int(snapshot.get("node_id", INVALID_NODE_ID))
	if (
		graph == null
		or generation_config == null
		or not graph.is_valid_node_id(node_id)
		or graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
	):
		return false
	var type_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
	)
	var expected_encounter_id := _get_map_assigned_encounter_id(
		node_id,
		graph
	)
	return (
		type_config != null
		and type_config.content_pool_id != &""
		and StringName(snapshot.get("content_pool_id", &""))
		== type_config.content_pool_id
		and int(snapshot.get("node_content_seed", -1))
		== graph.get_node_content_seed(node_id)
		and not expected_encounter_id.is_empty()
		and StringName(snapshot.get("encounter_id", &""))
		== expected_encounter_id
	)


func _try_start_encounter_for_node(node_id: int) -> bool:
	if (
		not _authority_enabled
		or _normal_combat_active
		or encounter_session == null
		or _route_graph == null
		or not _route_graph.is_valid_node_id(node_id)
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
		or encounter_session.is_active()
		or encounter_session.is_node_resolved(node_id)
		or (supply_session != null and supply_session.is_active())
		or (rare_chest_session != null and rare_chest_session.is_active())
	):
		return false
	var type_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
	)
	if type_config == null or type_config.content_pool_id == &"":
		return false
	var assigned_encounter_id := _get_map_assigned_encounter_id(node_id)
	if assigned_encounter_id.is_empty():
		return false
	return encounter_session.start_for_node(
		node_id,
		type_config.content_pool_id,
		_route_graph.get_node_content_seed(node_id),
		_get_active_encounter_peer_ids(),
		assigned_encounter_id
	)


func _try_start_supply_for_node(node_id: int, target_visit_count: int) -> bool:
	if (
		not _authority_enabled
		or _normal_combat_active
		or supply_session == null
		or _route_graph == null
		or not _route_graph.is_valid_node_id(node_id)
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.WILDERNESS_RESOURCE
		or target_visit_count != 1
		or supply_session.is_active()
		or supply_session.is_node_resolved(node_id)
		or (encounter_session != null and encounter_session.is_active())
		or (rare_chest_session != null and rare_chest_session.is_active())
	):
		return false
	return supply_session.start_for_node(
		node_id,
		_route_graph.get_node_content_seed(node_id),
		_get_active_encounter_peer_ids()
	)


func _try_start_rare_chest_for_node(
	node_id: int,
	target_visit_count: int
) -> bool:
	if (
		not _authority_enabled
		or _normal_combat_active
		or rare_chest_session == null
		or not is_route_ready()
		or not _route_graph.is_valid_node_id(node_id)
		or _runtime_state.current_node_id != node_id
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.PREPARE_AHEAD
		or node_id >= _runtime_state.visited_counts.size()
		or target_visit_count != 1
		or int(_runtime_state.visited_counts[node_id]) != target_visit_count
		or rare_chest_session.is_active()
		or rare_chest_session.is_node_resolved(node_id)
		or (encounter_session != null and encounter_session.is_active())
		or (supply_session != null and supply_session.is_active())
	):
		return false
	return rare_chest_session.start_for_node(
		node_id,
		_route_graph.get_node_content_seed(node_id),
		_get_active_encounter_peer_ids(),
		_player_stable_keys
	)


func _try_start_normal_combat_for_node(
	node_id: int,
	target_visit_count: int
) -> bool:
	if (
		not _authority_enabled
		or _normal_combat_active
		or _encounter_input_locked
		or not is_route_ready()
		or not _route_graph.is_valid_node_id(node_id)
		or _runtime_state.current_node_id != node_id
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.NORMAL_COMBAT
		or node_id >= _runtime_state.visited_counts.size()
		or target_visit_count != 1
		or int(_runtime_state.visited_counts[node_id]) != target_visit_count
		or (
			get_signal_connection_list(&"combat_requested").is_empty()
			and get_signal_connection_list(&"normal_combat_requested").is_empty()
		)
		or (
			encounter_session != null
			and encounter_session.is_active()
		)
		or (supply_session != null and supply_session.is_active())
		or (rare_chest_session != null and rare_chest_session.is_active())
	):
		return false
	var content_seed := _route_graph.get_node_content_seed(node_id)
	var occurrence_key := _make_normal_combat_occurrence_key(
		node_id,
		content_seed,
		target_visit_count
	)
	if occurrence_key.is_empty():
		return false
	var combat_config := resolve_normal_combat_config_for_node(node_id)
	if combat_config == null:
		return false
	var combat_config_id := combat_config.encounter_id
	_begin_normal_combat_stage(
		node_id,
		content_seed,
		occurrence_key,
		combat_config_id
	)
	_set_status("已进入普通作战节点，正在准备战斗。", false)
	if not get_signal_connection_list(&"combat_requested").is_empty():
		combat_requested.emit(
			node_id,
			content_seed,
			occurrence_key,
			combat_config_id
		)
	normal_combat_requested.emit(node_id, content_seed, occurrence_key)
	return true


func _try_start_emergency_combat_for_node(
	node_id: int,
	target_visit_count: int
) -> bool:
	if (
		not _authority_enabled
		or _normal_combat_active
		or _encounter_input_locked
		or not is_route_ready()
		or not _route_graph.is_valid_node_id(node_id)
		or _runtime_state.current_node_id != node_id
		or _route_graph.get_node_type(node_id)
		!= RogueRouteGraph.NodeType.EMERGENCY_COMBAT
		or node_id >= _runtime_state.visited_counts.size()
		or target_visit_count != 1
		or int(_runtime_state.visited_counts[node_id]) != target_visit_count
		or get_signal_connection_list(&"combat_requested").is_empty()
		or (encounter_session != null and encounter_session.is_active())
		or (supply_session != null and supply_session.is_active())
		or (rare_chest_session != null and rare_chest_session.is_active())
	):
		return false
	var content_seed := _route_graph.get_node_content_seed(node_id)
	var occurrence_key := _make_emergency_combat_occurrence_key(
		node_id,
		content_seed,
		target_visit_count
	)
	var combat_config := resolve_emergency_combat_config_for_node(node_id)
	if occurrence_key.is_empty() or combat_config == null:
		return false
	_begin_normal_combat_stage(
		node_id,
		content_seed,
		occurrence_key,
		combat_config.encounter_id
	)
	_set_status("已进入紧急作战节点，正在准备高危战斗。", false)
	combat_requested.emit(
		node_id,
		content_seed,
		occurrence_key,
		combat_config.encounter_id
	)
	return true


func _on_encounter_intro_ack_requested(
	occurrence_key: String,
	expected_revision: int
) -> void:
	if manage_return_locally:
		host_submit_encounter_intro_ack(
			_get_local_encounter_peer_id(),
			occurrence_key,
			expected_revision
		)
		return
	encounter_intro_ack_requested.emit(occurrence_key, expected_revision)


func _on_encounter_vote_requested(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> void:
	if manage_return_locally:
		host_submit_encounter_vote(
			_get_local_encounter_peer_id(),
			occurrence_key,
			expected_revision,
			option_id
		)
		return
	encounter_vote_requested.emit(
		occurrence_key,
		expected_revision,
		option_id
	)


func _on_encounter_revealed(
	occurrence_key: String,
	_expected_revision: int
) -> void:
	if not _authority_enabled or encounter_session == null:
		return
	if encounter_session.get_occurrence_key() != occurrence_key:
		return
	encounter_session.start_voting_timer(
		occurrence_key,
		encounter_session.get_revision()
	)


func _on_encounter_result_hold_completed(
	occurrence_key: String,
	_expected_revision: int
) -> void:
	if encounter_session == null:
		return
	if encounter_session.get_occurrence_key() != occurrence_key:
		return
	_local_result_hold_completed_occurrence_key = occurrence_key
	if _authority_enabled:
		encounter_session.complete_result(
			occurrence_key,
			encounter_session.get_revision()
		)
	_try_dismiss_locally_completed_encounter()


func _on_encounter_result_ack_requested(
	occurrence_key: String,
	result_sequence: int
) -> void:
	if (
		encounter_session == null
		or encounter_session.get_occurrence_key() != occurrence_key
		or result_sequence <= 0
	):
		return
	_local_result_hold_completed_occurrence_key = occurrence_key
	if manage_return_locally:
		host_submit_encounter_result_ack(
			_get_local_encounter_peer_id(),
			occurrence_key,
			result_sequence
		)
	else:
		encounter_result_ack_requested.emit(
			occurrence_key,
			result_sequence
		)
	_try_dismiss_locally_completed_encounter()


func _on_supply_intro_ack_requested(
	occurrence_key: String,
	expected_revision: int
) -> void:
	if manage_return_locally:
		host_submit_encounter_intro_ack(
			_get_local_encounter_peer_id(),
			occurrence_key,
			expected_revision
		)
		return
	encounter_intro_ack_requested.emit(occurrence_key, expected_revision)


func _on_supply_vote_requested(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> void:
	if manage_return_locally:
		host_submit_encounter_vote(
			_get_local_encounter_peer_id(),
			occurrence_key,
			expected_revision,
			option_id
		)
		return
	encounter_vote_requested.emit(
		occurrence_key,
		expected_revision,
		option_id
	)


func _on_supply_collectible_choice_requested(
	occurrence_key: String,
	expected_revision: int,
	offer_index: int
) -> void:
	if manage_return_locally:
		host_submit_supply_collectible_choice(
			_get_local_encounter_peer_id(),
			occurrence_key,
			expected_revision,
			offer_index
		)
		return
	encounter_vote_requested.emit(
		occurrence_key,
		expected_revision,
		StringName(
			SUPPLY_COLLECTIBLE_CHOICE_WIRE_PREFIX + str(offer_index)
		)
	)


func _on_supply_completed_requested(
	occurrence_key: String,
	expected_revision: int
) -> void:
	if manage_return_locally:
		host_submit_encounter_result_ack(
			_get_local_encounter_peer_id(),
			occurrence_key,
			expected_revision
		)
		return
	encounter_result_ack_requested.emit(occurrence_key, expected_revision)


func _on_supply_inventory_requested() -> void:
	var peer_id := _get_local_encounter_peer_id()
	if (
		supply_session == null
		or not supply_session.has_pending_collectible_for_peer(peer_id)
		or player_profile_panel == null
		or _has_modal_priority_over_supply()
	):
		return
	player_profile_panel.configure_multiplayer_requests(not manage_return_locally)
	player_profile_panel.open()


func _on_rare_chest_choice_requested(
	occurrence_key: String,
	expected_offer_revision: int,
	option_id: StringName
) -> void:
	if manage_return_locally:
		host_submit_encounter_vote(
			_get_local_encounter_peer_id(),
			occurrence_key,
			expected_offer_revision,
			option_id
		)
		return
	encounter_vote_requested.emit(
		occurrence_key,
		expected_offer_revision,
		option_id
	)


func _on_rare_chest_choice_committed(
	peer_id: int,
	result: Dictionary
) -> void:
	var heal_delta := int(result.get("heal_delta", 0))
	if heal_delta > 0:
		var target_player := (
			player
			if peer_id == SINGLEPLAYER_PEER_ID and not _multiplayer_avatar_mode
			else get_player_for_peer(peer_id)
		)
		if target_player != null and is_instance_valid(target_player):
			target_player.heal(heal_delta, false)
	_sync_party_status_from_run_state()


func _on_rare_chest_state_changed(snapshot: Dictionary) -> void:
	var local_snapshot := (
		rare_chest_session.export_state_for_peer(
			_get_local_encounter_peer_id()
		)
		if _authority_enabled and rare_chest_session != null
		else snapshot
	)
	var active := (
		rare_chest_session != null and rare_chest_session.is_active()
	)
	var local_phase := StringName(local_snapshot.get("phase", &""))
	var completing_presented_occurrence := (
		not active
		and _rare_chest_presented_active
		and local_phase == RogueRareChestSession.PHASE_COMPLETED
	)
	# Rare Chest 的权威 active 状态优先于路线 Profile 与 completed Supply
	# 待领取层。先收敛低优先级 Modal，再让本帧的宝箱快照呈现。
	if active:
		_rare_chest_presentation_dismiss_pending = false
	_reconcile_local_modal_presentations()
	# Completed 是可重放的权威终态。只有本机确实呈现过这一 occurrence 时
	# 才展示最后 0.8 秒；迟到旁观者和后续同 revision 快照不能重新打开界面。
	if rare_chest_overlay != null:
		if active or completing_presented_occurrence:
			rare_chest_overlay.apply_state(local_snapshot)
		elif local_phase == RogueRareChestSession.PHASE_IDLE:
			rare_chest_overlay.hide_rare_chest_immediately()
	if active or completing_presented_occurrence:
		_apply_remote_rare_chest_local_health_reward(local_snapshot)
	if active:
		if not _rare_chest_presented_active:
			_rare_chest_presentation_serial += 1
		_rare_chest_presented_active = true
		_set_encounter_input_locked(true)
	elif _rare_chest_presented_active:
		_rare_chest_presented_active = false
		_rare_chest_presentation_dismiss_pending = (
			local_phase == RogueRareChestSession.PHASE_COMPLETED
		)
		_rare_chest_presentation_serial += 1
		var presentation_serial := _rare_chest_presentation_serial
		var occurrence_key := str(local_snapshot.get("occurrence_key", ""))
		if local_phase == (
			RogueRareChestSession.PHASE_COMPLETED
		):
			_finish_rare_chest_presentation(
				presentation_serial,
				occurrence_key
			)
		else:
			_hide_rare_chest_presentation(presentation_serial)
	_reconcile_local_modal_presentations()
	_refresh_route_input_lock()
	if _authority_enabled:
		_emit_host_encounter_snapshot()


func _finish_rare_chest_presentation(
	presentation_serial: int,
	occurrence_key: String
) -> void:
	await get_tree().create_timer(0.8).timeout
	if (
		presentation_serial != _rare_chest_presentation_serial
		or rare_chest_session == null
		or rare_chest_session.get_phase()
		!= RogueRareChestSession.PHASE_COMPLETED
		or rare_chest_session.get_occurrence_key() != occurrence_key
	):
		return
	_hide_rare_chest_presentation(presentation_serial)


func _hide_rare_chest_presentation(presentation_serial: int) -> void:
	if presentation_serial != _rare_chest_presentation_serial:
		return
	_rare_chest_presentation_dismiss_pending = false
	if rare_chest_overlay != null:
		rare_chest_overlay.hide_rare_chest_immediately()
	_reconcile_local_modal_presentations()
	_set_encounter_input_locked(
		(encounter_session != null and encounter_session.is_active())
		or (supply_session != null and supply_session.is_active())
	)


func _apply_remote_rare_chest_local_health_reward(
	local_snapshot: Dictionary
) -> void:
	if _authority_enabled:
		return
	var occurrence_key := str(local_snapshot.get("occurrence_key", ""))
	if occurrence_key.is_empty():
		return
	var selected_option := StringName(
		local_snapshot.get("local_selected_option_id", &"")
	)
	var local_options := local_snapshot.get("local_option_ids", []) as Array
	if (
		selected_option.is_empty()
		and StringName(local_snapshot.get("phase", &""))
		== RogueRareChestSession.PHASE_CHOOSING
		and local_options.size() == RogueRareChestRegistry.CHOICE_COUNT
	):
		_rare_chest_local_offer_seen_occurrences[occurrence_key] = true
		return
	if (
		selected_option != RogueRareChestRegistry.OPTION_MAX_HEALTH
		or not _rare_chest_local_offer_seen_occurrences.has(occurrence_key)
		or _rare_chest_local_heal_applied_occurrences.has(occurrence_key)
	):
		return
	var local_player := (
		player
		if not _multiplayer_avatar_mode
		else get_player_for_peer(_get_local_encounter_peer_id())
	)
	if local_player == null or not is_instance_valid(local_player):
		return
	local_player.heal(10, false)
	_rare_chest_local_heal_applied_occurrences[occurrence_key] = true


func _on_supply_state_changed(snapshot: Dictionary) -> void:
	var local_modal_owner := _is_local_supply_modal_owner()
	var newly_acquired_local_owner := (
		local_modal_owner and not _local_supply_modal_owner_active
	)
	_local_supply_modal_owner_active = local_modal_owner
	# 远端 Supply 首帧可能在玩家 Profile 已打开时到达；Supply 是限时/待
	# 领取 Session owner，进入边界必须抢占 Profile。之后玩家从 Supply 内
	# 显式打开背包时不再重复关闭它。
	if (
		newly_acquired_local_owner
		and player_profile_panel != null
		and player_profile_panel.is_open()
	):
		player_profile_panel.close()
	_reconcile_local_modal_presentations()
	_set_encounter_input_locked(
		(supply_session != null and supply_session.is_active())
		or (encounter_session != null and encounter_session.is_active())
		or (rare_chest_session != null and rare_chest_session.is_active())
	)
	var result := snapshot.get("result", {}) as Dictionary
	var occurrence_key := str(snapshot.get("occurrence_key", ""))
	if (
		_authority_enabled
		and int(result.get("action_points_delta", 0)) > 0
		and not occurrence_key.is_empty()
		and occurrence_key != _last_supply_ap_broadcast_occurrence_key
		and is_route_ready()
	):
		_last_supply_ap_broadcast_occurrence_key = occurrence_key
		host_layout_committed.emit(
			export_layout_snapshot(),
			export_state_snapshot()
		)
	if _authority_enabled:
		_emit_host_encounter_snapshot()


func _on_supply_economy_changed(_snapshot: Dictionary) -> void:
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	if _run_state != null:
		set_shared_light_stone_amount(
			_run_state.get_party_light_stone_amount()
		)
	if _authority_enabled:
		_emit_host_encounter_snapshot()


func _on_encounter_state_changed(snapshot: Dictionary) -> void:
	if encounter_scene != null:
		encounter_scene.apply_state(
			_decorate_local_max_health_result(snapshot)
		)
	var phase := StringName(snapshot.get("phase", &"idle"))
	var encounter_active := phase not in [&"idle", &"completed"]
	# 权威遭遇阶段先于异步 cover 取得表现所有权；在等待转场的这一帧就要
	# 压住低优先级 Supply/Profile，不能等到 route lease 真正取得后再处理。
	_reconcile_local_modal_presentations()
	if encounter_active and not _encounter_presented_active:
		_encounter_presented_active = true
		_local_result_hold_completed_occurrence_key = ""
		_encounter_presentation_serial += 1
		_set_encounter_input_locked(true)
		_present_encounter(_encounter_presentation_serial)
	elif phase == &"completed" and _encounter_presented_active:
		_try_dismiss_locally_completed_encounter()
	elif phase == &"completed" and bool(snapshot.get("run_failed", false)):
		# 重连或迟到完整快照可能第一次就落在 completed 终态，本机从未
		# 展示过遭遇，因此没有可等待的退场动画；仍必须恢复权威败局 UI。
		_show_run_defeat()
	_reconcile_local_modal_presentations()
	_refresh_route_input_lock()
	if _authority_enabled:
		_emit_host_encounter_snapshot()


func _try_dismiss_locally_completed_encounter() -> void:
	if (
		not _encounter_presented_active
		or encounter_session == null
		or encounter_session.get_phase() != &"completed"
		or _local_result_hold_completed_occurrence_key
		!= encounter_session.get_occurrence_key()
	):
		return
	_encounter_presented_active = false
	_encounter_presentation_serial += 1
	_dismiss_encounter(_encounter_presentation_serial)


func _on_encounter_economy_changed(_snapshot: Dictionary) -> void:
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	if _authority_enabled:
		_emit_host_encounter_snapshot()


func _emit_host_encounter_snapshot() -> void:
	var encounter_snapshot := export_encounter_snapshot()
	var economy_snapshot := export_encounter_economy_snapshot()
	if encounter_snapshot.is_empty() or economy_snapshot.is_empty():
		return
	host_encounter_snapshot_committed.emit(
		encounter_snapshot,
		economy_snapshot
	)


func _present_encounter(presentation_serial: int) -> void:
	if encounter_scene == null:
		return
	await encounter_scene.cover_route_for_encounter()
	if presentation_serial != _encounter_presentation_serial:
		return
	_set_route_presentation_active(false)
	encounter_scene.apply_state(
		_decorate_local_max_health_result(export_encounter_snapshot())
	)
	await encounter_scene.reveal_encounter()
	if presentation_serial != _encounter_presentation_serial:
		return


func _dismiss_encounter(presentation_serial: int) -> void:
	if encounter_scene != null:
		await encounter_scene.cover_encounter_for_route()
	if presentation_serial != _encounter_presentation_serial:
		return
	_set_route_presentation_active(true)
	if encounter_scene != null:
		await encounter_scene.reveal_route_after_encounter()
	if presentation_serial != _encounter_presentation_serial:
		return
	var completed_state := encounter_session.export_state() if encounter_session != null else {}
	if bool(completed_state.get("run_failed", false)):
		_show_run_defeat()
		return
	_set_encounter_input_locked(
		(supply_session != null and supply_session.is_active())
		or (rare_chest_session != null and rare_chest_session.is_active())
	)
	if _authority_enabled:
		_try_present_followup_combat_briefing(completed_state)


func _try_present_followup_combat_briefing(
	completed_encounter_state: Dictionary
) -> bool:
	if (
		not _authority_enabled
		or not is_route_ready()
		or completed_encounter_state.is_empty()
		or _normal_combat_active
	):
		return false
	var economy_result := completed_encounter_state.get(
		"economy_result",
		{}
	) as Dictionary
	var combat_config_id := StringName(
		economy_result.get("followup_combat_id", &"")
	)
	if combat_config_id == &"":
		return false
	var node_id := int(
		completed_encounter_state.get("node_id", INVALID_NODE_ID)
	)
	var source_occurrence_key := str(
		completed_encounter_state.get("occurrence_key", "")
	)
	if (
		not _route_graph.is_valid_node_id(node_id)
		or not _validate_followup_encounter_snapshot(
		completed_encounter_state,
		node_id,
		source_occurrence_key,
		combat_config_id
		)
	):
		return false
	var content_seed := _route_graph.get_node_content_seed(node_id)
	var combat_occurrence_key := _make_followup_combat_occurrence_key(
		node_id,
		content_seed,
		source_occurrence_key,
		combat_config_id
	)
	if combat_occurrence_key.is_empty():
		return false
	if _briefing_phase != BriefingPhase.NONE:
		return (
			_briefing_node_id == node_id
			and _briefing_occurrence_key == combat_occurrence_key
			and _briefing_combat_config_id == combat_config_id
		)
	if _build_special_combat_briefing_model(
		node_id,
		combat_config_id,
		_runtime_state.action_points
	) == null:
		return false
	if not _commit_host_briefing_state(
		BriefingPhase.PRESENTED,
		node_id,
		combat_occurrence_key,
		_runtime_state.state_revision,
		RogueRouteNodeBriefingModel.SOURCE_KIND_SPECIAL_COMBAT,
		combat_config_id,
		source_occurrence_key
	):
		return false
	_set_status("机器人已经追来，必须进入“皮箱之战”。", false)
	return true


func _show_run_defeat() -> void:
	if _run_failure_presented or run_defeat_overlay == null:
		return
	_run_failure_presented = true
	_reconcile_local_modal_presentations()
	_set_encounter_input_locked(true)
	run_defeat_overlay.show_defeat(not manage_return_locally)


func _reset_run_defeat_presentation() -> void:
	_run_failure_presented = false
	if run_defeat_overlay != null:
		run_defeat_overlay.hide_immediately()
	_reconcile_local_modal_presentations()


func _on_run_defeat_confirmed() -> void:
	return_requested.emit()
	if manage_return_locally and not embedded_session:
		call_deferred(&"_return_to_main_menu")


func _set_encounter_input_locked(locked: bool) -> void:
	_encounter_input_locked = locked
	_camera_drag_active = false
	if not is_node_ready():
		return
	if locked:
		# 遭遇/作战优先于路线入场演出。同步快照可能在展开 Tween
		# 进行中到达，必须先收束演出，避免隐藏 World 后冻结 Tween 与锁。
		route_board.complete_entry_reveal()
		_set_route_reveal_input_locked(false)
		_clear_pending_move(true)
	_refresh_route_input_lock()


func _set_route_reveal_input_locked(locked: bool) -> void:
	if _route_reveal_input_locked == locked:
		return
	_route_reveal_input_locked = locked
	_camera_drag_active = false
	if not is_node_ready():
		return
	if locked:
		_clear_pending_move(true)
	_refresh_route_input_lock()


## Supply completed 后仍可能只对某个重连玩家保留待领取收藏品。这个状态
## 不再阻塞 Host 推进路线，但对该本地玩家仍是一个持久 Modal owner。
func _is_local_supply_modal_owner() -> bool:
	if supply_session == null:
		return false
	return (
		supply_session.is_active()
		or supply_session.has_pending_collectible_for_peer(
			_get_local_encounter_peer_id()
		)
	)


## 这里列出比 Supply 更高的明确表现 owner；不读取旧 visible 快照，也不
## 保存/恢复 UI 可见性。这样乱序 release 或 full snapshot 只能影响自己的
## 状态，最终表现始终由当前权威 Session/lease 重新推导。
func _has_modal_priority_over_supply() -> bool:
	return (
		_route_presentation_leases != 0
		or _normal_combat_active
		or _briefing_phase != BriefingPhase.NONE
		or _run_failure_presented
		or _encounter_presented_active
		or (
			encounter_session != null
			and encounter_session.is_active()
		)
		or _rare_chest_presented_active
		or _rare_chest_presentation_dismiss_pending
		or (
			rare_chest_session != null
			and rare_chest_session.is_active()
		)
		or _is_local_shop_presentation_active()
		or (
			combat_result_overlay != null
			and combat_result_overlay.visible
		)
	)


## 本地 Modal 的单一 reconcile 边界。高优先级 owner 只暂压 Supply，不
## 修改 Session；owner 释放后必须从 Session 完整快照重新 apply，因为
## hide_supply_immediately() 会有意把 Overlay 的 rendered_phase 清为 idle。
func _reconcile_local_modal_presentations() -> void:
	if not is_node_ready():
		return
	var higher_priority_owner := _has_modal_priority_over_supply()
	if (
		higher_priority_owner
		and player_profile_panel != null
		and player_profile_panel.is_open()
	):
		player_profile_panel.close()
	if supply_overlay == null:
		return
	if higher_priority_owner or not _is_local_supply_modal_owner():
		if supply_overlay.visible:
			supply_overlay.hide_supply_immediately()
		return
	var supply_state := supply_session.export_state()
	if StringName(supply_state.get("phase", &"idle")) == &"idle":
		supply_overlay.hide_supply_immediately()
		return
	supply_overlay.apply_state(supply_state)


func _is_route_input_locked() -> bool:
	return (
		_route_presentation_leases != 0
		or _encounter_input_locked
		or _route_reveal_input_locked
		or _briefing_phase != BriefingPhase.NONE
		or _is_local_supply_modal_owner()
		or _is_local_shop_presentation_active()
		or (
			player_profile_panel != null
			and player_profile_panel.is_open()
		)
		or (
			combat_result_overlay != null
			and combat_result_overlay.visible
		)
	)


func _refresh_route_input_lock() -> void:
	if not is_node_ready():
		return
	var locked := (
		_is_route_input_locked()
		or _pending_node_id != INVALID_NODE_ID
	)
	route_board.set_interaction_locked(locked)
	_set_local_player_controls_locked(locked)
	# Profile 自己监听全局 bag。关闭状态下若路线已被其他 owner 锁定，
	# 必须同时停止它的 unhandled input，避免在商店/作战/遭遇上方重开；
	# Supply 显式 open 后则保留输入，以便玩家仍可用 Bag/Esc 关闭。
	if player_profile_panel != null:
		player_profile_panel.set_process_unhandled_input(
			player_profile_panel.is_open() or not locked
		)
	_update_authority_ui()


func _is_shop_departure_blocked() -> bool:
	return (
		underground_shop_controller != null
		and underground_shop_controller.is_departure_blocked()
	)


func _begin_shop_departure_for_route_move() -> bool:
	return (
		underground_shop_controller == null
		or underground_shop_controller.begin_departing()
	)


func _cancel_shop_departure_for_failed_move() -> void:
	if underground_shop_controller != null:
		underground_shop_controller.cancel_departing()


func _set_route_presentation_active(active: bool) -> void:
	_set_route_presentation_lease(
		RoutePresentationLease.MAGICAL_ENCOUNTER,
		not active
	)


func _set_route_presentation_lease(lease: int, acquired: bool) -> void:
	if lease not in [
		RoutePresentationLease.COMBAT,
		RoutePresentationLease.MAGICAL_ENCOUNTER,
		RoutePresentationLease.UNDERGROUND_SHOP,
	]:
		push_error("RogueRouteGame: 未知路线表现 lease：%d。" % lease)
		return
	if acquired and lease == RoutePresentationLease.COMBAT:
		_close_stale_route_modals_for_combat()
	if acquired:
		_route_presentation_leases |= lease
	else:
		_route_presentation_leases &= ~lease
	# 重复 release 也必须 reconcile：重连重放或暂留战场相机可能在
	# owner 已释放后再次改写 Viewport current，但绝不能清除其他 owner。
	_apply_route_presentation_leases()


## 作战取得完整屏幕所有权时只直接收起 Route 自己持有的瞬时 Modal。
## Session Overlay 的压制/恢复统一交给 _reconcile_local_modal_presentations，
## 由权威状态重建，不保存旧 visible 快照。
func _close_stale_route_modals_for_combat() -> void:
	if move_confirmation.visible:
		move_confirmation.dismiss()
	if node_briefing.visible:
		node_briefing.dismiss()


func _apply_route_presentation_leases() -> void:
	if not is_node_ready():
		return
	if embedded_session and not visible:
		_reconcile_route_music()
		_camera_drag_active = false
		world.set_route_pixel_snap_enabled(false)
		world.process_mode = Node.PROCESS_MODE_DISABLED
		world.visible = false
		route_hud.visible = false
		map_camera.enabled = false
		_set_embedded_canvas_layers_visible(false)
		return
	var active_leases := _route_presentation_leases
	_reconcile_route_music()
	var route_world_hidden := active_leases != 0
	var full_hud_hidden := (
		active_leases & ROUTE_PRESENTATION_FULL_HIDE_MASK
	) != 0
	var shop_hides_bottom_bar := (
		active_leases & RoutePresentationLease.UNDERGROUND_SHOP
	) != 0
	var bottom_bar := $HUD/Root/BottomBar as Control

	_camera_drag_active = false
	if route_world_hidden and player_profile_panel.is_open():
		player_profile_panel.close()
	if route_world_hidden and move_confirmation.visible:
		move_confirmation.dismiss()

	world.process_mode = (
		Node.PROCESS_MODE_DISABLED
		if route_world_hidden
		else Node.PROCESS_MODE_INHERIT
	)
	if route_world_hidden:
		world.set_route_pixel_snap_enabled(false)
	world.visible = not route_world_hidden
	route_hud.visible = not full_hud_hidden
	bottom_bar.visible = not shop_hides_bottom_bar
	map_camera.enabled = not route_world_hidden

	if not route_world_hidden:
		world.reset_physics_interpolation()
		if player != null and is_instance_valid(player):
			_restore_route_camera_after_external_scene()
		world.set_route_pixel_snap_enabled(true)
	_reconcile_local_modal_presentations()
	_refresh_route_input_lock()


func _bind_runtime_state(
	new_graph: RogueRouteGraph,
	new_state: RogueRouteRuntimeState
) -> void:
	_disconnect_runtime_state()
	_route_graph = new_graph
	_runtime_state = new_state
	_runtime_state.state_changed.connect(_on_runtime_state_changed)
	_runtime_state.move_committed.connect(_on_runtime_move_committed)
	if supply_economy != null:
		supply_economy.set_route_state(_runtime_state)


func _disconnect_runtime_state() -> void:
	if _runtime_state == null:
		return
	var state_callable := Callable(self, "_on_runtime_state_changed")
	var move_callable := Callable(self, "_on_runtime_move_committed")
	if _runtime_state.state_changed.is_connected(state_callable):
		_runtime_state.state_changed.disconnect(state_callable)
	if _runtime_state.move_committed.is_connected(move_callable):
		_runtime_state.move_committed.disconnect(move_callable)


func _on_route_board_node_pressed(node_id: int) -> void:
	if (
		not _authority_enabled
		or not is_route_ready()
	):
		return
	if _is_shop_departure_blocked():
		_set_status(
			"仍在等待这些玩家退出地下商店：%s"
			% "、".join(_get_shop_waiting_player_names()),
			true
		)
		return
	if _is_route_input_locked() or _pending_node_id != INVALID_NODE_ID:
		return
	if not route_board.can_interact_with_node(node_id):
		_set_status("该节点当前不可移动。", true)
		return
	var rejection_reason := _runtime_state.get_move_rejection_reason(
		node_id,
		generation_config.move_action_cost,
		_runtime_state.state_revision
	)
	if not rejection_reason.is_empty():
		_set_status(rejection_reason, true)
		return
	_pending_node_id = node_id
	_pending_revision = _runtime_state.state_revision
	route_board.select_node(node_id)
	route_board.set_interaction_locked(true)
	_set_local_player_controls_locked(true)
	_camera_drag_active = false
	_show_node_content(node_id, true)
	var node_type := _route_graph.get_node_type(node_id)
	if (
		node_type in [
			RogueRouteGraph.NodeType.NORMAL_COMBAT,
			RogueRouteGraph.NodeType.EMERGENCY_COMBAT,
		]
		and int(_runtime_state.visited_counts[node_id]) == 0
	):
		var emergency_combat := (
			node_type == RogueRouteGraph.NodeType.EMERGENCY_COMBAT
		)
		var combat_config := (
			resolve_emergency_combat_config_for_node(node_id)
			if emergency_combat
			else resolve_normal_combat_config_for_node(node_id)
		)
		var occurrence_key := (
			_make_emergency_combat_occurrence_key(
				node_id,
				_route_graph.get_node_content_seed(node_id),
				int(_runtime_state.visited_counts[node_id]) + 1
			)
			if emergency_combat
			else _make_normal_combat_occurrence_key(
				node_id,
				_route_graph.get_node_content_seed(node_id),
				int(_runtime_state.visited_counts[node_id]) + 1
			)
		)
		if not _commit_host_briefing_state(
			BriefingPhase.PRESENTED,
			node_id,
			occurrence_key,
			_pending_revision,
			(
				RogueRouteNodeBriefingModel.SOURCE_KIND_EMERGENCY_COMBAT
				if emergency_combat
				else RogueRouteNodeBriefingModel.SOURCE_KIND_DEFAULT_COMBAT
			),
			combat_config.encounter_id if combat_config != null else &""
		):
			_set_status(
				"紧急作战简报无法生成，本次移动未执行。"
				if emergency_combat
				else "普通作战简报无法生成，本次移动未执行。",
				true
			)
			_finish_pending_move()
		return
	move_confirmation.present(
		_get_node_display_name(node_id),
		_runtime_state.action_points,
		generation_config.move_action_cost
	)


func _on_move_confirmation_confirmed() -> void:
	var target_node_id := _pending_node_id
	var expected_revision := _pending_revision
	_pending_node_id = INVALID_NODE_ID
	_pending_revision = -1
	if not _authority_enabled or not is_route_ready():
		_finish_pending_move()
		return
	var rejection_reason := _runtime_state.get_move_rejection_reason(
		target_node_id,
		generation_config.move_action_cost,
		expected_revision
	)
	if not rejection_reason.is_empty():
		_set_status(rejection_reason, true)
		_finish_pending_move()
		return
	if not _begin_shop_departure_for_route_move():
		_set_status(
			"仍在等待这些玩家退出地下商店：%s"
			% "、".join(_get_shop_waiting_player_names()),
			true
		)
		_finish_pending_move()
		return
	if not _runtime_state.try_move(
		target_node_id,
		generation_config.move_action_cost,
		expected_revision
	):
		_cancel_shop_departure_for_failed_move()
		_set_status("路线状态已变化，本次移动未执行。", true)
	_finish_pending_move()


func _on_move_confirmation_canceled() -> void:
	_finish_pending_move()
	if is_route_ready():
		_show_node_content(_runtime_state.current_node_id, false)


func _on_node_briefing_confirmed() -> void:
	if (
		not _authority_enabled
		or not is_route_ready()
		or _briefing_phase != BriefingPhase.PRESENTED
		or _pending_node_id != _briefing_node_id
		or _pending_revision != _briefing_expected_route_revision
	):
		return
	if not _commit_host_briefing_state(
		BriefingPhase.ENTERING,
		_briefing_node_id,
		_briefing_occurrence_key,
		_briefing_expected_route_revision
	):
		_set_status("路线状态已变化，本次作战未启动。", true)
		_commit_host_briefing_state(
			BriefingPhase.NONE,
			INVALID_NODE_ID,
			"",
			-1
		)


func _on_node_briefing_canceled() -> void:
	if (
		not _authority_enabled
		or not is_route_ready()
		or _briefing_phase != BriefingPhase.PRESENTED
		or _briefing_source_kind not in [
			RogueRouteNodeBriefingModel.SOURCE_KIND_DEFAULT_COMBAT,
			RogueRouteNodeBriefingModel.SOURCE_KIND_EMERGENCY_COMBAT,
		]
	):
		return
	if not _commit_host_briefing_state(
		BriefingPhase.NONE,
		INVALID_NODE_ID,
		"",
		-1
	):
		return
	_set_status("已取消作战；行动力与路线位置未发生变化。", false)
	_show_node_content(_runtime_state.current_node_id, false)


func _on_runtime_state_changed(_snapshot: Dictionary) -> void:
	if not is_route_ready():
		return
	if not route_board.update_runtime_state(
		_runtime_state.current_node_id,
		_runtime_state.action_points,
		_runtime_state.visited_counts,
		true
	):
		_set_status("路线视觉层拒绝了最新状态。", true)
		return
	_update_route_hud()
	_show_node_content(_runtime_state.current_node_id, false)


func _on_runtime_move_committed(delta: Dictionary) -> void:
	if not _authority_enabled:
		return
	if underground_shop_controller != null:
		underground_shop_controller.close_departing()
	host_move_committed.emit(delta.duplicate(true))
	_set_status(
		"已移动至%s，消耗 %d 行动力。"
		% [
			_get_node_display_name(int(delta.get("to_node_id", INVALID_NODE_ID))),
			int(delta.get("move_cost", 0)),
		],
		false
	)
	var target_node_id := int(delta.get("to_node_id", INVALID_NODE_ID))
	var target_visit_count := int(delta.get("target_visit_count", 0))
	_try_start_rare_chest_for_node(target_node_id, target_visit_count)
	var normal_combat_started := _try_start_normal_combat_for_node(
		target_node_id,
		target_visit_count
	)
	var emergency_combat_started := false
	if not normal_combat_started:
		emergency_combat_started = _try_start_emergency_combat_for_node(
			target_node_id,
			target_visit_count
		)
	if (
		not normal_combat_started
		and not emergency_combat_started
		and _briefing_phase == BriefingPhase.ENTERING
		and _briefing_node_id == target_node_id
	):
		abort_briefing_entry(_briefing_occurrence_key)
	_try_start_underground_shop_for_node(
		target_node_id,
		target_visit_count
	)
	_try_start_encounter_for_node(target_node_id)
	_try_start_supply_for_node(
		target_node_id,
		target_visit_count
	)


func _on_combat_result_overlay_dismissed() -> void:
	# Overlay 会在发出 dismissed 前自行 hide；协调器可能已经完成返回生命周期，
	# 因此不能依赖它再次调用 hide_combat_result() 才恢复被结算层暂压的 Modal。
	_reconcile_local_modal_presentations()
	_refresh_route_input_lock()
	combat_result_dismissed.emit()


func _on_regenerate_button_pressed() -> void:
	if (
		not _authority_enabled
		or _is_route_input_locked()
		or _pending_node_id != INVALID_NODE_ID
	):
		return
	start_authoritative_session()


func _return_to_main_menu() -> void:
	if not is_inside_tree():
		return
	var error := get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)
	if error != OK:
		_set_status("无法返回主菜单：%s" % error_string(error), true)


func configure_multiplayer_players(
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary,
	participant_stable_keys: Dictionary = {}
) -> bool:
	_clear_player_instances()
	_multiplayer_avatar_mode = true
	_local_peer_id = local_peer_id
	_player_names = player_names.duplicate(true)
	_player_character_ids = player_character_ids.duplicate(true)
	_player_stable_keys = participant_stable_keys.duplicate(true)
	_sync_encounter_player_character_ids()
	var peer_ids: Array[int] = []
	for peer_id_variant in player_names:
		var peer_id := int(peer_id_variant)
		if peer_id > 0:
			peer_ids.append(peer_id)
	peer_ids.sort()
	for index in range(peer_ids.size()):
		var peer_id := peer_ids[index]
		var character_id := StringName(
			player_character_ids.get(
				peer_id,
				PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
			)
		)
		_add_multiplayer_player(
			peer_id,
			str(player_names.get(peer_id, "Player %d" % peer_id)),
			character_id,
			_get_avatar_spawn_position(index)
		)
	if player == null:
		push_error("RogueRouteGame: 多人路线场景缺少本地角色。")
		return false
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	_attach_camera_to_local_player()
	_configure_encounter_overlay_context()
	_sync_underground_shop_identity_context()
	return true


func add_multiplayer_player(
	peer_id: int,
	player_name: String,
	character_id: StringName,
	spawn_position: Vector2
) -> bool:
	if (
		not _multiplayer_avatar_mode
		or peer_id <= 0
		or peer_players.has(peer_id)
		or not spawn_position.is_finite()
	):
		return false
	var added := _add_multiplayer_player(
		peer_id,
		player_name,
		character_id,
		clamp_avatar_position(spawn_position)
	)
	if added:
		_player_names[peer_id] = player_name
		_player_character_ids[peer_id] = character_id
		_sync_encounter_player_character_ids()
		_sync_route_player_xirang_from_run_state()
		_sync_party_status_from_run_state()
		_configure_encounter_overlay_context()
		_sync_underground_shop_identity_context()
	return added


func set_multiplayer_participant_stable_key(
	peer_id: int,
	stable_key: String
) -> bool:
	if (
		peer_id <= 0
		or stable_key.is_empty()
		or not peer_players.has(peer_id)
	):
		return false
	_player_stable_keys[peer_id] = stable_key
	_sync_underground_shop_identity_context()
	return true


func migrate_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> bool:
	# 普通调用者只迁移仍在树中的 Player；断线后缺失节点的重建由重连
	# preparation 显式携带 fallback pose，不能在这里猜出生位置。
	if get_player_for_peer(old_peer_id) == null:
		return false
	var stable_key := str(_player_stable_keys.get(old_peer_id, ""))
	var preparation := prepare_reconnected_multiplayer_player_identity(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id,
		stable_key,
		Vector2.ZERO
	)
	var preparation_result := int(preparation.get(
		"result",
		ReconnectedPlayerIdentityProjectionResult.INVALID
	))
	if preparation_result == (
		ReconnectedPlayerIdentityProjectionResult.ALREADY_CURRENT
	):
		return true
	if preparation_result != ReconnectedPlayerIdentityProjectionResult.READY:
		discard_reconnected_multiplayer_player_identity(preparation)
		return false
	var commit_result := commit_reconnected_multiplayer_player_identity(
		preparation
	)
	if commit_result != ReconnectedPlayerIdentityProjectionResult.MIGRATED:
		discard_reconnected_multiplayer_player_identity(preparation)
		return false
	finalize_reconnected_multiplayer_player_identity(preparation)
	return true


## 纯预检并准备一次路线身份投影。缺失旧 Player 时会预先实例化但不入树，
## 因而后续持久账本尚未提交前即可发现资源/角色配置错误。
func prepare_reconnected_multiplayer_player_identity(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	stable_participant_key: String,
	fallback_position: Vector2
) -> Dictionary:
	var result := _classify_reconnected_multiplayer_player_identity(
		old_peer_id,
		new_peer_id,
		character_id,
		stable_participant_key
	)
	if result == ReconnectedPlayerIdentityProjectionResult.ALREADY_CURRENT:
		return {
			"result": result,
			"old_peer_id": old_peer_id,
			"new_peer_id": new_peer_id,
		}
	if result != ReconnectedPlayerIdentityProjectionResult.READY:
		return {"result": result}

	var player_instance := get_player_for_peer(old_peer_id)
	var creates_player := player_instance == null
	if creates_player:
		if not fallback_position.is_finite() or player_container == null:
			return {
				"result": ReconnectedPlayerIdentityProjectionResult.INVALID,
			}
		player_instance = _instantiate_route_player(character_id)
		if player_instance == null:
			return {
				"result": ReconnectedPlayerIdentityProjectionResult.INVALID,
			}
	var stable_key := stable_participant_key
	if stable_key.is_empty():
		stable_key = str(_player_stable_keys.get(old_peer_id, ""))
	return {
		"result": ReconnectedPlayerIdentityProjectionResult.READY,
		"old_peer_id": old_peer_id,
		"new_peer_id": new_peer_id,
		"player_name": player_name,
		"character_id": character_id,
		"stable_participant_key": stable_key,
		"player": player_instance,
		"creates_player": creates_player,
		"preserved_position": (
			fallback_position
			if creates_player
			else player_instance.global_position
		),
		"preserved_velocity": (
			Vector2.ZERO if creates_player else player_instance.velocity
		),
		"committed": false,
	}


## preparation 通过后，此提交只执行固定换键，不刷新 UI、不读取 RunState、
## 不发路线信号。调用方可在其后提交持久账本，再统一 finalize 表现。
func commit_reconnected_multiplayer_player_identity(
	preparation: Dictionary
) -> ReconnectedPlayerIdentityProjectionResult:
	var prepared_result := int(preparation.get(
		"result",
		ReconnectedPlayerIdentityProjectionResult.INVALID
	))
	if prepared_result == (
		ReconnectedPlayerIdentityProjectionResult.ALREADY_CURRENT
	):
		return ReconnectedPlayerIdentityProjectionResult.ALREADY_CURRENT
	if (
		prepared_result != ReconnectedPlayerIdentityProjectionResult.READY
		or bool(preparation.get("committed", false))
	):
		return ReconnectedPlayerIdentityProjectionResult.INVALID
	var old_peer_id := int(preparation.get("old_peer_id", 0))
	var new_peer_id := int(preparation.get("new_peer_id", 0))
	var character_id := StringName(preparation.get("character_id", &""))
	var stable_key := str(preparation.get("stable_participant_key", ""))
	var current_result := _classify_reconnected_multiplayer_player_identity(
		old_peer_id,
		new_peer_id,
		character_id,
		stable_key
	)
	if current_result != ReconnectedPlayerIdentityProjectionResult.READY:
		return current_result
	var player_instance := preparation.get("player") as Player
	var creates_player := bool(preparation.get("creates_player", false))
	if (
		player_instance == null
		or not is_instance_valid(player_instance)
		or (creates_player and player_instance.get_parent() != null)
		or (not creates_player and get_player_for_peer(old_peer_id) != player_instance)
	):
		return ReconnectedPlayerIdentityProjectionResult.INVALID

	# 从这里开始没有可失败分支：路线字典、Player 身份、本地 owner 与稳定身份
	# 在同一调用栈成为 new peer，替代过去只暂存 peer_id/背包 owner 的双真源。
	peer_players.erase(old_peer_id)
	peer_players[new_peer_id] = player_instance
	_player_names.erase(old_peer_id)
	_player_character_ids.erase(old_peer_id)
	_player_stable_keys.erase(old_peer_id)
	_player_names[new_peer_id] = str(preparation.get("player_name", ""))
	_player_character_ids[new_peer_id] = character_id
	if not stable_key.is_empty():
		_player_stable_keys[new_peer_id] = stable_key
	if _local_peer_id == old_peer_id:
		_local_peer_id = new_peer_id
		player = player_instance
	if (
		route_inventory_strip != null
		and route_inventory_strip.inventory_owner_peer_id == old_peer_id
	):
		route_inventory_strip.inventory_owner_peer_id = new_peer_id
	player_instance.peer_id = new_peer_id
	player_instance.name = "RoutePlayer_%d" % new_peer_id
	player_instance.global_position = (
		preparation.get("preserved_position", Vector2.ZERO) as Vector2
	)
	player_instance.velocity = (
		preparation.get("preserved_velocity", Vector2.ZERO) as Vector2
	)
	if creates_player:
		player_container.add_child(player_instance)
	preparation["committed"] = true
	preparation["result"] = ReconnectedPlayerIdentityProjectionResult.MIGRATED
	return ReconnectedPlayerIdentityProjectionResult.MIGRATED


## 持久账本与路线身份都已提交后才刷新依赖 RunState 的 Player、HUD 和交互。
func finalize_reconnected_multiplayer_player_identity(
	preparation: Dictionary
) -> void:
	if int(preparation.get("result", -1)) != (
		ReconnectedPlayerIdentityProjectionResult.MIGRATED
	):
		return
	var new_peer_id := int(preparation.get("new_peer_id", 0))
	var player_instance := preparation.get("player") as Player
	if player_instance == null or get_player_for_peer(new_peer_id) != player_instance:
		return
	_configure_multiplayer_player_node(
		player_instance,
		new_peer_id,
		str(preparation.get("player_name", ""))
	)
	player_instance.global_position = (
		preparation.get("preserved_position", Vector2.ZERO) as Vector2
	)
	player_instance.velocity = (
		preparation.get("preserved_velocity", Vector2.ZERO) as Vector2
	)
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	_sync_encounter_player_character_ids()
	_configure_encounter_overlay_context()
	_sync_underground_shop_identity_context()
	if new_peer_id == _local_peer_id:
		_attach_camera_to_local_player()


func discard_reconnected_multiplayer_player_identity(
	preparation: Dictionary
) -> void:
	if (
		preparation.is_empty()
		or bool(preparation.get("committed", false))
		or not bool(preparation.get("creates_player", false))
	):
		return
	var player_instance := preparation.get("player") as Player
	if (
		player_instance != null
		and is_instance_valid(player_instance)
		and player_instance.get_parent() == null
	):
		player_instance.free()
	preparation.clear()


func _classify_reconnected_multiplayer_player_identity(
	old_peer_id: int,
	new_peer_id: int,
	character_id: StringName,
	stable_participant_key: String
) -> ReconnectedPlayerIdentityProjectionResult:
	if (
		not _multiplayer_avatar_mode
		or old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or not PlayerCharacterRegistry.is_valid_character_id(character_id)
	):
		return ReconnectedPlayerIdentityProjectionResult.INVALID
	var old_player := get_player_for_peer(old_peer_id)
	var new_player := get_player_for_peer(new_peer_id)
	if new_player != null:
		if (
			old_player != null
			or new_player.peer_id != new_peer_id
			or new_player.get_character_id() != character_id
			or not _player_names.has(new_peer_id)
			or not _player_character_ids.has(new_peer_id)
			or _player_names.has(old_peer_id)
			or _player_character_ids.has(old_peer_id)
			or _player_stable_keys.has(old_peer_id)
			or StringName(_player_character_ids.get(new_peer_id, &""))
			!= character_id
			or (
				not stable_participant_key.is_empty()
				and str(_player_stable_keys.get(new_peer_id, ""))
				!= stable_participant_key
			)
			or (
				route_inventory_strip != null
				and route_inventory_strip.inventory_owner_peer_id == old_peer_id
			)
		):
			return ReconnectedPlayerIdentityProjectionResult.CONFLICT
		return ReconnectedPlayerIdentityProjectionResult.ALREADY_CURRENT
	if (
		_player_names.has(new_peer_id)
		or _player_character_ids.has(new_peer_id)
		or _player_stable_keys.has(new_peer_id)
	):
		return ReconnectedPlayerIdentityProjectionResult.CONFLICT
	if old_player != null:
		if (
			old_player.peer_id != old_peer_id
			or old_player.get_character_id() != character_id
		):
			return ReconnectedPlayerIdentityProjectionResult.CONFLICT
		var old_stable_key := str(_player_stable_keys.get(old_peer_id, ""))
		if (
			not stable_participant_key.is_empty()
			and not old_stable_key.is_empty()
			and old_stable_key != stable_participant_key
		):
			return ReconnectedPlayerIdentityProjectionResult.CONFLICT
	return ReconnectedPlayerIdentityProjectionResult.READY


func _add_multiplayer_player(
	peer_id: int,
	player_name: String,
	character_id: StringName,
	spawn_position: Vector2
) -> bool:
	var player_instance := _instantiate_route_player(character_id)
	if player_instance == null:
		return false
	player_instance.name = "RoutePlayer_%d" % peer_id
	player_instance.global_position = spawn_position
	player_container.add_child(player_instance)
	peer_players[peer_id] = player_instance
	_configure_multiplayer_player_node(player_instance, peer_id, player_name)
	return true


func _configure_multiplayer_player_node(
	player_instance: Player,
	peer_id: int,
	player_name: String
) -> void:
	var accepts_local_input := peer_id == _local_peer_id
	player_instance.configure_multiplayer_control(
		peer_id,
		accepts_local_input,
		player_name,
		accepts_local_input,
		accepts_local_input
	)
	player_instance.set_world_movement_mode(true, false)
	player_instance.set_multiplayer_visual_smoothing_enabled(
		not accepts_local_input
	)
	player_instance.physics_interpolation_mode = (
		Node.PHYSICS_INTERPOLATION_MODE_ON
		if accepts_local_input
		else Node.PHYSICS_INTERPOLATION_MODE_OFF
	)
	player_instance.set_physics_process(accepts_local_input)
	if accepts_local_input:
		player = player_instance
		_bind_player_profile(player_instance)


func get_player_for_peer(peer_id: int) -> Player:
	return peer_players.get(peer_id) as Player


func get_local_avatar_snapshot() -> Dictionary:
	if player == null or not is_instance_valid(player):
		return {}
	return {
		"position": player.global_position,
		"velocity": player.velocity,
		"facing": player.get_multiplayer_facing_id(),
		"anim_state": player.get_multiplayer_anim_state(),
	}


func apply_avatar_snapshot(
	peer_id: int,
	remote_position: Vector2,
	remote_velocity: Vector2,
	facing_id: int,
	anim_state: int,
	correct_local_player: bool = false
) -> bool:
	var player_instance := get_player_for_peer(peer_id)
	if (
		player_instance == null
		or not remote_position.is_finite()
		or not remote_velocity.is_finite()
	):
		return false
	if peer_id == _local_peer_id and not correct_local_player:
		return true
	player_instance.apply_world_movement_snapshot(
		clamp_avatar_position(remote_position),
		remote_velocity,
		clampi(facing_id, 0, 3),
		maxi(anim_state, 0)
	)
	return true


func clamp_avatar_position(candidate: Vector2) -> Vector2:
	var bounds := route_board.get_world_bounds().grow(-10.0)
	return Vector2(
		clampf(candidate.x, bounds.position.x, bounds.end.x),
		clampf(candidate.y, bounds.position.y, bounds.end.y)
	)


func is_avatar_position_in_world(candidate: Vector2) -> bool:
	return candidate.is_finite() and route_board.get_world_bounds().grow(-8.0).has_point(
		candidate
	)


func remove_multiplayer_player(peer_id: int) -> void:
	var player_instance := peer_players.get(peer_id) as Player
	if player_instance == null:
		return
	peer_players.erase(peer_id)
	_player_names.erase(peer_id)
	_player_character_ids.erase(peer_id)
	_player_stable_keys.erase(peer_id)
	_sync_encounter_player_character_ids()
	if player_instance == player:
		player = null
		_bind_player_profile(null)
	if map_camera.get_parent() == player_instance:
		world.detach_camera_from_player()
	player_container.remove_child(player_instance)
	player_instance.queue_free()
	_configure_encounter_overlay_context()
	_sync_underground_shop_identity_context()


func _configure_singleplayer_player() -> void:
	if player != null and is_instance_valid(player):
		return
	var character_id := PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state != null:
		character_id = run_state.get_selected_character_id()
	var player_instance := _instantiate_route_player(character_id)
	if player_instance == null:
		return
	player_instance.name = "Player"
	player_instance.global_position = _get_avatar_spawn_position(0)
	player_container.add_child(player_instance)
	player_instance.set_world_movement_mode(true, false)
	player_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	player_instance.reset_physics_interpolation()
	player = player_instance
	_bind_player_profile(player_instance)
	_local_peer_id = SINGLEPLAYER_PEER_ID
	_player_names = {SINGLEPLAYER_PEER_ID: "玩家"}
	_player_character_ids = {SINGLEPLAYER_PEER_ID: character_id}
	_player_stable_keys = {SINGLEPLAYER_PEER_ID: "singleplayer:local"}
	_sync_encounter_player_character_ids()
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	_attach_camera_to_local_player()
	_configure_encounter_overlay_context()
	_sync_underground_shop_identity_context()


func _sync_route_player_xirang_from_run_state() -> void:
	if _run_state == null:
		return
	if _multiplayer_avatar_mode:
		var peer_ids: Array[int] = []
		for raw_peer_id in peer_players.keys():
			var peer_id := int(raw_peer_id)
			if peer_id > 0:
				peer_ids.append(peer_id)
		peer_ids.sort()
		for peer_id in peer_ids:
			var peer_player := peer_players.get(peer_id) as Player
			# 路线身份提交保证字典键与 Player.peer_id 同时换键；缺少持久
			# 成员只可能是事务尚未完成，绝不能在表现同步中补建账本。
			if not _run_state.has_multiplayer_peer_state(peer_id):
				continue
			_apply_route_player_xirang(
				peer_player,
				_run_state.get_party_xirang_balance(peer_id)
			)
		return
	_apply_route_player_xirang(
		player,
		_run_state.get_party_xirang_balance(SINGLEPLAYER_PEER_ID)
	)


func _apply_route_player_xirang(player_instance: Player, amount: int) -> void:
	if player_instance == null or not is_instance_valid(player_instance):
		return
	var resolved_amount := maxi(amount, 0)
	if player_instance == player:
		_update_personal_xirang_hud(resolved_amount)
	player_instance.set_xirang_balance(resolved_amount)


func _update_personal_xirang_hud(amount: int) -> void:
	if not is_node_ready() or top_bar == null:
		return
	top_bar.set_personal_xirang(amount)


func set_shared_light_stone_amount(amount: int) -> void:
	if not is_node_ready() or top_bar == null:
		return
	top_bar.set_shared_light_stone(amount)


func _on_party_xirang_ledger_changed(_snapshot: Dictionary) -> void:
	_sync_route_player_xirang_from_run_state()


func _on_party_light_stone_ledger_changed(snapshot: Dictionary) -> void:
	set_shared_light_stone_amount(int(snapshot.get("amount", 0)))


func _connect_party_status_ledger() -> void:
	_run_state = get_node_or_null("/root/RunState") as RunStateStore
	if _run_state == null:
		_bind_local_inventory_strip(null)
		_update_core_hud(100, 100)
		set_shared_light_stone_amount(0)
		return
	_bind_local_inventory_strip(player)
	if not _run_state.party_status_ledger_changed.is_connected(
		_on_party_status_ledger_changed
	):
		_run_state.party_status_ledger_changed.connect(
			_on_party_status_ledger_changed
		)
	if not _run_state.party_xirang_ledger_changed.is_connected(
		_on_party_xirang_ledger_changed
	):
		_run_state.party_xirang_ledger_changed.connect(
			_on_party_xirang_ledger_changed
		)
	if not _run_state.party_light_stone_ledger_changed.is_connected(
		_on_party_light_stone_ledger_changed
	):
		_run_state.party_light_stone_ledger_changed.connect(
			_on_party_light_stone_ledger_changed
		)
	_sync_route_player_xirang_from_run_state()
	_sync_party_status_from_run_state()
	set_shared_light_stone_amount(_run_state.get_party_light_stone_amount())
	_cache_max_health_penalties(_run_state.export_party_status_ledger())


func _on_party_status_ledger_changed(snapshot: Dictionary) -> void:
	var before_max_health: Dictionary = {}
	var players_by_status_peer: Dictionary = {}
	for raw_peer_id in peer_players.keys():
		var dictionary_peer_id := int(raw_peer_id)
		var peer_player := peer_players.get(dictionary_peer_id) as Player
		if peer_player != null and is_instance_valid(peer_player):
			# RunState 的重连 remap 会先把仍在树中的 Player.peer_id 暂存为
			# new peer，再同步发出账本信号；此刻 peer_players 的字典键仍可能是
			# old peer。必须以节点真实身份读取信号快照，不能调用会 ensure 状态的
			# RunState getter，否则刚移除的 old peer 会被重新创建。
			var status_peer_id := (
				peer_player.peer_id
				if peer_player.peer_id > 0
				else dictionary_peer_id
			)
			before_max_health[status_peer_id] = peer_player.max_health
			players_by_status_peer[status_peer_id] = peer_player
	if not _multiplayer_avatar_mode and player != null and is_instance_valid(player):
		before_max_health[SINGLEPLAYER_PEER_ID] = player.max_health
		players_by_status_peer[SINGLEPLAYER_PEER_ID] = player
	_update_core_hud(
		int(snapshot.get("core_current", 100)),
		int(snapshot.get("core_maximum", 100))
	)
	var incoming_penalties := snapshot.get("max_health_penalties", {}) as Dictionary
	for raw_peer_id in players_by_status_peer.keys():
		var peer_id := int(raw_peer_id)
		var peer_player := players_by_status_peer.get(peer_id) as Player
		if peer_player == null or not is_instance_valid(peer_player):
			continue
		peer_player.set_run_max_health_penalty(
			_get_status_snapshot_penalty(incoming_penalties, peer_id)
		)
	for raw_peer_key in incoming_penalties.keys():
		var peer_id := int(raw_peer_key)
		var penalty_after := int(incoming_penalties[raw_peer_key])
		var penalty_before := int(_cached_max_health_penalties.get(peer_id, 0))
		if penalty_after <= penalty_before or not before_max_health.has(peer_id):
			continue
		var peer_player := players_by_status_peer.get(peer_id) as Player
		if peer_player == null or not is_instance_valid(peer_player):
			continue
		_max_health_transition_by_peer[peer_id] = {
			"before": int(before_max_health[peer_id]),
			"after": peer_player.max_health,
			"penalty_after": penalty_after,
		}
	_cache_max_health_penalties(snapshot)


func _get_status_snapshot_penalty(
	penalties: Dictionary,
	peer_id: int
) -> int:
	return maxi(
		int(penalties.get(str(peer_id), penalties.get(peer_id, 0))),
		0
	)


func _cache_max_health_penalties(snapshot: Dictionary) -> void:
	_cached_max_health_penalties.clear()
	var penalties := snapshot.get("max_health_penalties", {}) as Dictionary
	for raw_peer_key in penalties.keys():
		_cached_max_health_penalties[int(raw_peer_key)] = int(
			penalties[raw_peer_key]
		)


func _decorate_local_max_health_result(snapshot: Dictionary) -> Dictionary:
	var decorated := snapshot.duplicate(true)
	var economy_result := decorated.get("economy_result", {}) as Dictionary
	if StringName(economy_result.get("result_code", &"")) != &"pit_radiation":
		return decorated
	var local_peer_id := _get_local_encounter_peer_id()
	var transition := (
		_max_health_transition_by_peer.get(local_peer_id, {}) as Dictionary
	)
	if transition.is_empty():
		return decorated
	var expected_penalty_after := -1
	var penalty_totals := economy_result.get(
		"max_health_penalty_totals",
		[]
	) as Array
	for raw_entry in penalty_totals:
		if typeof(raw_entry) != TYPE_DICTIONARY:
			continue
		var entry := raw_entry as Dictionary
		if int(entry.get("peer_id", -1)) == local_peer_id:
			expected_penalty_after = int(entry.get("after", -1))
			break
	if expected_penalty_after != int(transition.get("penalty_after", -2)):
		return decorated
	var personal_pages := decorated.get("personal_result_pages", {}) as Dictionary
	personal_pages[local_peer_id] = [{
		"speaker": "",
		"text": "最大生命：%d → %d" % [
			int(transition.get("before", 1)),
			int(transition.get("after", 1)),
		],
		"is_narration": true,
	}]
	decorated["personal_result_pages"] = personal_pages
	return decorated


func _sync_party_status_from_run_state() -> void:
	if _run_state == null:
		_run_state = get_node_or_null("/root/RunState") as RunStateStore
	if _run_state == null:
		_update_core_hud(100, 100)
		return
	_update_core_hud(
		_run_state.get_party_core_health(),
		_run_state.get_party_core_maximum_health()
	)
	if _multiplayer_avatar_mode:
		for raw_peer_id in peer_players.keys():
			var peer_id := int(raw_peer_id)
			var player_instance := peer_players.get(peer_id) as Player
			if player_instance != null and is_instance_valid(player_instance):
				player_instance.set_run_max_health_penalty(
					_run_state.get_max_health_penalty_for_peer(peer_id)
				)
		return
	if player != null and is_instance_valid(player):
		player.set_run_max_health_penalty(
			_run_state.get_max_health_penalty_for_peer(SINGLEPLAYER_PEER_ID)
		)


func _update_core_hud(current_health: int, maximum_health: int) -> void:
	if not is_node_ready() or top_bar == null:
		return
	top_bar.set_core_health(current_health, maximum_health)


func _instantiate_route_player(character_id: StringName) -> Player:
	var resolved_id := character_id
	if not PlayerCharacterRegistry.is_valid_character_id(resolved_id):
		resolved_id = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	var player_instance := PlayerCharacterRegistry.instantiate_character(resolved_id)
	if player_instance == null:
		push_error("RogueRouteGame: 无法实例化路线角色 %s。" % resolved_id)
	else:
		# Rogue 路线使用像素素材；角色与路线节点都固定走最近邻采样。
		player_instance.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	return player_instance


func _get_avatar_spawn_position(index: int) -> Vector2:
	var offset: Vector2 = AVATAR_SPAWN_OFFSETS[
		index % AVATAR_SPAWN_OFFSETS.size()
	]
	return route_board.get_default_spawn_global_position(generation_config) + offset


func _reposition_route_players_at_start() -> void:
	if (
		route_board == null
		or _route_graph == null
		or not _route_graph.is_valid_node_id(_route_graph.start_node_id)
	):
		return
	var start_position := route_board.get_node_global_position(
		_route_graph.start_node_id
	)
	if _multiplayer_avatar_mode:
		var peer_ids: Array[int] = []
		for raw_peer_id in peer_players.keys():
			var peer_id := int(raw_peer_id)
			if peer_id > 0:
				peer_ids.append(peer_id)
		peer_ids.sort()
		for index in range(peer_ids.size()):
			_reposition_route_player(
				peer_players.get(peer_ids[index]) as Player,
				start_position + AVATAR_SPAWN_OFFSETS[
					index % AVATAR_SPAWN_OFFSETS.size()
				]
			)
		return
	_reposition_route_player(player, start_position + AVATAR_SPAWN_OFFSETS[0])


func _reposition_route_player(
	player_instance: Player,
	target_position: Vector2
) -> void:
	if player_instance == null or not is_instance_valid(player_instance):
		return
	var smoothing_enabled := (
		player_instance.is_multiplayer_visual_smoothing_enabled()
	)
	if smoothing_enabled:
		player_instance.set_multiplayer_visual_smoothing_enabled(false)
	player_instance.global_position = target_position
	player_instance.velocity = Vector2.ZERO
	player_instance.reset_physics_interpolation()
	if smoothing_enabled:
		player_instance.set_multiplayer_visual_smoothing_enabled(true)


func _attach_camera_to_local_player() -> void:
	if map_camera == null or player == null:
		return
	if embedded_session and not visible:
		# 隐藏期只保留角色所有权；首次激活由统一 presentation reconcile
		# 负责 reparent + make_current，不能在 Tower Ready 中途抢相机。
		return
	world.attach_camera_to_player(player)
	# 重连身份迁移或完整快照可能在表现 lease 期间重建本地 Player。
	# attach_camera_to_player 会原生启用并 make_current，必须立刻重新应用
	# owner 推导状态，禁止绕过统一协调器抢回隐藏中的路线相机。
	_apply_route_presentation_leases()


func _configure_camera_world_bounds() -> void:
	world.configure_world_bounds()
	_clamp_camera_drag_offset()


func _apply_camera_drag(screen_delta: Vector2) -> void:
	world.apply_camera_drag(player, screen_delta, get_viewport_rect().size)


func _clamp_camera_drag_offset() -> void:
	world.clamp_camera_drag(player, get_viewport_rect().size)


func _recenter_camera_on_player() -> void:
	_camera_drag_active = false
	world.recenter_camera(player, get_viewport_rect().size)


func _on_recenter_button_pressed() -> void:
	if _is_route_input_locked() or _pending_node_id != INVALID_NODE_ID:
		return
	_recenter_camera_on_player()


func _on_route_inventory_bag_requested() -> void:
	if (
		player_profile_panel != null
		and not _is_route_input_locked()
		and _pending_node_id == INVALID_NODE_ID
	):
		player_profile_panel.open()


func _on_player_profile_opened() -> void:
	_refresh_route_input_lock()


func _on_player_profile_closed() -> void:
	player_profile_panel.configure_multiplayer_requests(false)
	_refresh_route_input_lock()


func _on_supply_profile_inventory_discard_requested(slot_index: int) -> void:
	var peer_id := _get_local_encounter_peer_id()
	if (
		supply_session == null
		or not supply_session.has_pending_collectible_for_peer(peer_id)
		or _run_state == null
	):
		return
	var item := (
		_run_state.get_item(slot_index)
		if peer_id == 0
		else _run_state.get_item_for_peer(peer_id, slot_index)
	)
	if item == null or item.inventory_locked or item.resource_path.is_empty():
		return
	var inventory_revision := (
		_run_state.get_inventory_revision()
		if peer_id == 0
		else _run_state.get_inventory_revision_for_peer(peer_id)
	)
	var occurrence_key := (
		supply_session.get_pending_collectible_occurrence_for_peer(peer_id)
	)
	var supply_revision := supply_session.get_revision()
	var config_hash := item.resource_path.sha256_text()
	if manage_return_locally:
		host_submit_supply_inventory_discard(
			peer_id,
			occurrence_key,
			supply_revision,
			slot_index,
			inventory_revision,
			config_hash
		)
		return
	var wire_option := StringName(
		"%s%d|%d|%s" % [
			SUPPLY_INVENTORY_DISCARD_WIRE_PREFIX,
			slot_index,
			inventory_revision,
			config_hash,
		]
	)
	encounter_vote_requested.emit(
		occurrence_key,
		supply_revision,
		wire_option
	)


func _bind_player_profile(player_instance: Player) -> void:
	if player_profile_panel != null:
		player_profile_panel.bind_player(player_instance)
	_bind_local_inventory_strip(player_instance)


func _bind_local_inventory_strip(player_instance: Player) -> void:
	if route_inventory_strip == null:
		return
	if player_instance == null or _run_state == null:
		route_inventory_strip.bind_run_state(null)
		return
	route_inventory_strip.bind_run_state(
		_run_state,
		maxi(player_instance.peer_id, SINGLEPLAYER_PEER_ID)
	)


func _set_local_player_controls_locked(locked: bool) -> void:
	if player != null and is_instance_valid(player):
		player.set_control_lock(ROUTE_INPUT_CONTROL_LOCK_OWNER, locked)


func _clear_player_instances() -> void:
	_bind_player_profile(null)
	world.detach_camera_from_player()
	for child in player_container.get_children():
		player_container.remove_child(child)
		child.queue_free()
	peer_players.clear()
	_player_names.clear()
	_player_character_ids.clear()
	_sync_encounter_player_character_ids()
	player = null


func _sync_encounter_player_character_ids() -> void:
	if encounter_economy != null:
		encounter_economy.set_player_character_ids(_player_character_ids)
	if supply_economy != null:
		supply_economy.set_player_character_ids(_player_character_ids)
	if rare_chest_economy != null:
		rare_chest_economy.set_player_character_ids(_player_character_ids)
	_configure_supply_overlay_context()
	_configure_rare_chest_overlay_context()


func _clear_pending_move(hide_dialog: bool) -> void:
	_pending_node_id = INVALID_NODE_ID
	_pending_revision = -1
	if not is_node_ready():
		return
	if hide_dialog and move_confirmation.visible:
		move_confirmation.dismiss()
	route_board.clear_selection()
	_refresh_route_input_lock()


func _finish_pending_move() -> void:
	_pending_node_id = INVALID_NODE_ID
	_pending_revision = -1
	if move_confirmation.visible:
		move_confirmation.dismiss()
	route_board.clear_selection()
	_refresh_route_input_lock()


func _update_route_hud() -> void:
	if not is_route_ready():
		top_bar.set_action_points(-1)
		return
	top_bar.set_action_points(_runtime_state.action_points)


func _update_authority_ui() -> void:
	if not is_node_ready():
		return
	regenerate_button.disabled = not _authority_enabled or _is_route_input_locked()
	hint_label.text = (
		"遭遇或作战进行中；路线移动与地图拖动已锁定。"
		if _encounter_input_locked
		else "地下路线正在展开…"
		if _route_reveal_input_locked
		else
		"WASD / 左摇杆探索 · 拖动空白处查看地图 · 每次移动消耗 %d AP。"
		% generation_config.move_action_cost
		if _authority_enabled and generation_config != null
		else "WASD / 左摇杆自由探索 · 拖动空白处查看地图；路线由房主确认。"
	)

func _show_node_content(node_id: int, is_preview: bool) -> void:
	if not is_route_ready() or not _route_graph.is_valid_node_id(node_id):
		content_overline.text = "CONTENT PLACEHOLDER"
		content_title.text = "等待路线数据"
		content_body.text = "房主生成或同步路线后，这里会显示当前节点的占位信息。"
		content_meta.text = "尚未载入"
		return
	var display_name := _get_node_display_name(node_id)
	var node_type := _route_graph.get_node_type(node_id)
	content_overline.text = "移动预览" if is_preview else "当前节点"
	content_title.text = display_name
	if node_type == RogueRouteGraph.NodeType.EMPTY:
		content_body.text = (
			"这里暂时没有事件内容。空白节点仍属于路线的一部分，"
			+ "可以用于绕行或返回。"
		)
	elif node_type == RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER:
		content_body.text = (
			"首次抵达会触发全队共享的神奇遭遇；已完成节点回访时"
			+ "不会重复结算。"
		)
	elif node_type == RogueRouteGraph.NodeType.NORMAL_COMBAT:
		content_body.text = (
			"抵达前将显示全队共享的作战简报；仅房主能够确认，"
			+ "确认前不会扣除行动力。"
		)
	elif node_type == RogueRouteGraph.NodeType.EMERGENCY_COMBAT:
		content_body.text = (
			"高危敌群已占据该区域。抵达前会显示红色警戒简报；"
			+ "敌人精英化且数量增加，但胜利奖励也更加丰厚。"
		)
	elif node_type == RogueRouteGraph.NodeType.WILDERNESS_RESOURCE:
		content_body.text = (
			"首次抵达会开启全队共享的物资抉择；从三项补给中投票选出"
			+ "一项，已完成节点回访时不会重复结算。"
		)
	else:
		content_body.text = (
			"「%s」的正式内容尚未接入。本阶段仅验证节点选择、"
			+ "行动力扣除与共享小队移动。"
		) % display_name
	var coord := _route_graph.id_to_coord(node_id)
	content_meta.text = "节点 #%d · 坐标 (%d, %d) · 内容种子 %d" % [
		node_id,
		coord.x,
		coord.y,
		_route_graph.get_node_content_seed(node_id),
	]


func _get_node_display_name(node_id: int) -> String:
	if _route_graph == null or not _route_graph.is_valid_node_id(node_id):
		return "未知节点"
	var node_type := _route_graph.get_node_type(node_id)
	if node_type == RogueRouteGraph.NodeType.EMPTY:
		return "空白区域"
	if generation_config != null:
		var type_config := generation_config.get_type_config(node_type)
		if type_config != null and not type_config.display_name.is_empty():
			return type_config.display_name
	return "未知节点"


func _get_runtime_contract_hash() -> String:
	if floor_definition == null:
		return ""
	return floor_definition.compute_runtime_contract_hash()


func _set_status(message: String, is_error: bool) -> void:
	if not is_node_ready():
		return
	status_message.text = message
	status_message.add_theme_color_override(
		&"font_color",
		Color("e8b978") if is_error else Color("88aaa4")
	)
