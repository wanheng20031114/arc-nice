extends LuoxiMerchant
class_name TowerDefenseLuoxiMerchant

const SPECIAL_GAME_DIALOGUE_LINES := [
	"我注意到你持有赌怪专用券",
	"是否要使用赌怪专用券？",
]
const SPECIAL_GAME_RESUME_DIALOGUE_LINES := [
	"你的奖励还在牌桌上等着。",
	"整理好背包后，要继续结算吗？",
]
const GAMBLER_TICKET := preload(
	"res://resources/config/materials/material_gambler_ticket.tres"
)
const SPECIAL_GAME_SUCCESS_LINE := "这次的收获已经装进背包。"
const SPECIAL_GAME_TICKET_MISSING_LINE := "你身上的赌怪专用券已经不见了。"
const SPECIAL_GAME_INVALID_LINE := "这局暂时无法开始，请稍后再试。"
const SPECIAL_GAME_INVENTORY_FULL_LINE := (
	"背包空间不足。请先整理背包，再次与我交互即可继续结算。"
)
const SPECIAL_GAME_TIMEOUT_STATUS := "主机响应超时，请再次操作重试"

@onready var special_game_overlay: LuoxiSpecialGameOverlay = $LuoxiSpecialGameOverlay

var special_game_dialogue_active := false
var special_game_session_revision := 0
var special_game_player: Player = null
var special_game_request_player: Player = null
var special_game_resume_pending := false


func _connect_mode_extensions() -> void:
	special_game_overlay.card_reveal_requested.connect(
		_on_special_game_card_reveal_requested
	)
	special_game_overlay.finish_requested.connect(
		_on_special_game_finish_requested
	)


func _close_mode_extensions() -> void:
	_close_special_game_overlay()


func _is_mode_overlay_open() -> bool:
	return special_game_overlay.is_open()


func _handle_mode_overlay_input(event: InputEvent) -> bool:
	return special_game_overlay.handle_input(event)


func _try_advance_mode_dialogue() -> bool:
	if not special_game_dialogue_active:
		return false
	_request_special_game_start()
	return true


func _get_mode_dialogue_lines(player_instance: Player) -> Array:
	if special_game_resume_pending and player_instance == special_game_player:
		special_game_dialogue_active = true
		return SPECIAL_GAME_RESUME_DIALOGUE_LINES.duplicate()
	if _player_has_special_game_ticket(player_instance):
		special_game_dialogue_active = true
		return SPECIAL_GAME_DIALOGUE_LINES.duplicate()
	special_game_dialogue_active = false
	return []


func _is_mode_flow_player(player_instance: Player) -> bool:
	return (
		player_instance == special_game_player
		or player_instance == special_game_request_player
	)


func _abort_mode_flow() -> void:
	special_game_dialogue_active = false
	_close_special_game_overlay()


func _handle_mode_player_exited(player_instance: Player) -> bool:
	if player_instance == special_game_player and special_game_overlay.is_open():
		dialogue_bubble.hide_bubble()
		choice_visible = false
		choice_overlay.hide_choices()
		return true
	if player_instance == special_game_request_player:
		_clear_authoritative_request_wait(true)
		_release_special_game_request_player()
	return false


func _clear_mode_request_pending(clear_pending: bool) -> void:
	if clear_pending and special_game_overlay.is_open():
		special_game_overlay.set_pending(false)


func _handle_mode_request_timeout(
	expired_kind: LuoxiMerchant.AuthoritativeRequestKind
) -> void:
	if expired_kind == AuthoritativeRequestKind.SPECIAL_GAME_START:
		if (
			special_game_request_player != null
			and not special_game_request_player.is_dead
		):
			special_game_request_player.set_controls_locked(false)
		result_visible = true
		dialogue_bubble.say(AUTHORITATIVE_OFFER_TIMEOUT_LINE)
	elif expired_kind in [
		AuthoritativeRequestKind.SPECIAL_GAME_REVEAL,
		AuthoritativeRequestKind.SPECIAL_GAME_FINISH,
	]:
		if special_game_overlay.is_open():
			special_game_overlay.set_pending(false)
			special_game_overlay.set_status(SPECIAL_GAME_TIMEOUT_STATUS)


func apply_special_game_started(result: Dictionary) -> void:
	_clear_authoritative_request_wait(true)
	var result_code := int(result.get(
		"result_code",
		LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER
	))
	var result_revision := int(result.get("session_revision", 0))
	var request_player := special_game_request_player
	if (
		result_code == LuoxiSpecialGameCoordinator.ResultCode.SUCCESS
		and (
			request_player == null
			or not is_instance_valid(request_player)
			or request_player.is_dead
			or not nearby_players.has(request_player.get_instance_id())
		)
	):
		_release_special_game_request_player()
		_abandon_special_game_revision(result_revision)
		return
	if result_code != LuoxiSpecialGameCoordinator.ResultCode.SUCCESS:
		_release_special_game_request_player()
		_close_special_game_overlay()
		special_game_dialogue_active = false
		result_visible = true
		dialogue_bubble.say(
			SPECIAL_GAME_TICKET_MISSING_LINE
			if result_code == LuoxiSpecialGameCoordinator.ResultCode.TICKET_MISSING
			else SPECIAL_GAME_INVALID_LINE
		)
		return

	special_game_session_revision = result_revision
	if special_game_session_revision <= 0:
		_release_special_game_request_player()
		_close_special_game_overlay()
		result_visible = true
		dialogue_bubble.say(SPECIAL_GAME_INVALID_LINE)
		return
	special_game_dialogue_active = false
	special_game_resume_pending = false
	special_game_player = request_player
	special_game_request_player = null
	active_player = special_game_player
	choice_visible = false
	result_visible = false
	choice_overlay.hide_choices()
	dialogue_bubble.hide_bubble()
	special_game_overlay.show_game(special_game_session_revision)
	_apply_special_game_revealed_state(result)
	if special_game_player != null and not special_game_player.is_dead:
		special_game_player.set_controls_locked(true)


func apply_special_game_card_revealed(result: Dictionary) -> void:
	if (
		not special_game_overlay.is_open()
		or int(result.get("session_revision", 0)) != special_game_session_revision
	):
		return
	_clear_authoritative_request_wait(true)
	var result_code := int(result.get(
		"result_code",
		LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER
	))
	if (
		result_code == LuoxiSpecialGameCoordinator.ResultCode.PLAYER_DIED
		or bool(result.get("cancelled", false))
	):
		_close_special_game_overlay()
		dialogue_bubble.hide_bubble()
		return
	if result_code == LuoxiSpecialGameCoordinator.ResultCode.STALE_SESSION:
		_close_special_game_overlay()
		result_visible = true
		dialogue_bubble.say(SPECIAL_GAME_INVALID_LINE)
		return
	_apply_special_game_revealed_state(result)
	if result_code == LuoxiSpecialGameCoordinator.ResultCode.CARD_ALREADY_REVEALED:
		special_game_overlay.set_status("这张卡已经翻开，状态已与主机同步")
	elif result_code != LuoxiSpecialGameCoordinator.ResultCode.SUCCESS:
		special_game_overlay.set_pending(false)
		special_game_overlay.set_status("这张卡现在无法翻开，请重试")


func apply_special_game_finished(result: Dictionary) -> void:
	if (
		not special_game_overlay.is_open()
		or int(result.get("session_revision", 0)) != special_game_session_revision
	):
		return
	_clear_authoritative_request_wait(true)
	var result_code := int(result.get(
		"result_code",
		LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER
	))
	if result_code == LuoxiSpecialGameCoordinator.ResultCode.INVENTORY_FULL:
		_suspend_special_game_for_inventory()
		return
	if result_code == LuoxiSpecialGameCoordinator.ResultCode.SUCCESS:
		_close_special_game_overlay()
		result_visible = true
		dialogue_bubble.say(SPECIAL_GAME_SUCCESS_LINE)
		return
	_close_special_game_overlay()
	if result_code != LuoxiSpecialGameCoordinator.ResultCode.PLAYER_DIED:
		result_visible = true
		dialogue_bubble.say(SPECIAL_GAME_INVALID_LINE)


func _request_special_game_start() -> void:
	if active_player == null or active_player.is_dead:
		return
	special_game_request_player = active_player
	special_game_request_player.set_controls_locked(true)
	dialogue_bubble.hide_bubble()
	_arm_authoritative_request_timeout(
		AuthoritativeRequestKind.SPECIAL_GAME_START
	)
	var tower_adapter := (
		multiplayer_mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	if tower_adapter == null or not tower_adapter.request_luoxi_special_game_start():
		apply_special_game_started({
			"result_code": LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER,
		})
		return


func _on_special_game_card_reveal_requested(card_index: int) -> void:
	if special_game_session_revision <= 0:
		return
	_arm_authoritative_request_timeout(
		AuthoritativeRequestKind.SPECIAL_GAME_REVEAL
	)
	var tower_adapter := (
		multiplayer_mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	if (
		tower_adapter == null
		or not tower_adapter.request_luoxi_special_game_card_reveal(
			special_game_session_revision,
			card_index
		)
	):
		apply_special_game_card_revealed({
			"result_code": LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER,
			"session_revision": special_game_session_revision,
		})
		return


func _on_special_game_finish_requested() -> void:
	if special_game_session_revision <= 0:
		return
	_arm_authoritative_request_timeout(
		AuthoritativeRequestKind.SPECIAL_GAME_FINISH
	)
	var tower_adapter := (
		multiplayer_mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	if (
		tower_adapter == null
		or not tower_adapter.request_luoxi_special_game_finish(
			special_game_session_revision
		)
	):
		apply_special_game_finished({
			"result_code": LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER,
			"session_revision": special_game_session_revision,
		})
		return


func _apply_special_game_revealed_state(result: Dictionary) -> void:
	var revealed_cards := result.get("revealed_cards", []) as Array
	for revealed_variant in revealed_cards:
		var revealed := revealed_variant as Dictionary
		var card_index := int(revealed.get("card_index", -1))
		var outcome := revealed.get("outcome", {}) as Dictionary
		if (
			card_index >= 0
			and card_index < special_game_overlay.revealed_cards.size()
			and not outcome.is_empty()
			and not special_game_overlay.revealed_cards[card_index]
		):
			special_game_overlay.reveal_card(card_index, outcome)


func _player_has_special_game_ticket(player_instance: Player) -> bool:
	if player_instance == null:
		return false
	var tower_adapter := (
		multiplayer_mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	if tower_adapter == null or not tower_adapter.supports_luoxi_special_game():
		return false
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state == null:
		return false
	return (
		run_state.get_inventory_item_total_for_peer(
			player_instance.peer_id,
			GAMBLER_TICKET
		)
		if player_instance.peer_id > 0
		else run_state.get_inventory_item_total(GAMBLER_TICKET)
	) > 0


func _close_special_game_overlay() -> void:
	special_game_overlay.hide_game()
	special_game_session_revision = 0
	special_game_resume_pending = false
	_release_special_game_request_player()
	var closing_player := special_game_player
	if special_game_player != null and not special_game_player.is_dead:
		special_game_player.set_controls_locked(false)
	special_game_player = null
	if (
		closing_player != null
		and active_player == closing_player
		and not nearby_players.has(closing_player.get_instance_id())
	):
		active_player = _pick_nearby_player()


func _suspend_special_game_for_inventory() -> void:
	special_game_overlay.hide_game()
	special_game_resume_pending = true
	if special_game_player != null and not special_game_player.is_dead:
		special_game_player.set_controls_locked(false)
	result_visible = true
	dialogue_bubble.say(SPECIAL_GAME_INVENTORY_FULL_LINE)


func _release_special_game_request_player() -> void:
	if (
		special_game_request_player != null
		and is_instance_valid(special_game_request_player)
		and not special_game_request_player.is_dead
		and special_game_request_player != special_game_player
	):
		special_game_request_player.set_controls_locked(false)
	special_game_request_player = null


func _abandon_special_game_revision(session_revision: int) -> void:
	_close_special_game_overlay()
	if session_revision <= 0:
		return
	var tower_adapter := (
		multiplayer_mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	if tower_adapter != null:
		tower_adapter.request_luoxi_special_game_finish(session_revision)


func abort_special_game() -> void:
	_clear_authoritative_request_wait(true)
	special_game_dialogue_active = false
	_close_special_game_overlay()
	choice_visible = false
	choice_overlay.hide_choices()
	dialogue_bubble.hide_bubble()
