extends Node
class_name LuoxiSpecialGameCoordinator

const GAMBLER_TICKET := preload(
	"res://resources/config/materials/material_gambler_ticket.tres"
)
const CARD_COUNT := 4
const MAXIMUM_INTERACTION_DISTANCE := 40.0

enum ResultCode {
	SUCCESS,
	INVALID_PLAYER,
	TICKET_MISSING,
	STALE_SESSION,
	INVALID_CARD,
	CARD_ALREADY_REVEALED,
	INVENTORY_FULL,
	PLAYER_DIED,
}

var campaign_coordinator: TowerDefenseCampaignCoordinator = null
var home_defense_coordinator: TowerDefenseHomeDefenseCoordinator = null
var player_roster_coordinator: TowerDefensePlayerRosterCoordinator = null
var multiplayer_adapter: TowerDefenseMultiplayerModeAdapter = null
var run_state: RunStateStore = null
var merchant: LuoxiMerchant = null
var random_generator: RandomNumberGenerator = null
var authoritative_enabled := false
var sessions_by_peer: Dictionary = {}
var revision_counters_by_peer: Dictionary = {}


func setup(
	new_campaign_coordinator: TowerDefenseCampaignCoordinator,
	new_home_defense_coordinator: TowerDefenseHomeDefenseCoordinator,
	new_player_roster_coordinator: TowerDefensePlayerRosterCoordinator,
	new_multiplayer_adapter: TowerDefenseMultiplayerModeAdapter,
	new_run_state: RunStateStore,
	new_merchant: LuoxiMerchant,
	new_random_generator: RandomNumberGenerator,
	new_authoritative_enabled: bool
) -> void:
	campaign_coordinator = new_campaign_coordinator
	home_defense_coordinator = new_home_defense_coordinator
	player_roster_coordinator = new_player_roster_coordinator
	multiplayer_adapter = new_multiplayer_adapter
	run_state = new_run_state
	merchant = new_merchant
	random_generator = new_random_generator
	authoritative_enabled = new_authoritative_enabled
	if not authoritative_enabled:
		sessions_by_peer.clear()


func player_has_ticket(peer_id: int) -> bool:
	if run_state == null:
		return false
	return (
		run_state.get_inventory_item_total_for_peer(peer_id, GAMBLER_TICKET)
		if peer_id > 0
		else run_state.get_inventory_item_total(GAMBLER_TICKET)
	) > 0


func has_active_session(peer_id: int) -> bool:
	return sessions_by_peer.has(maxi(peer_id, 0))


func start_for_peer(peer_id: int) -> Dictionary:
	var player_instance := _get_player(peer_id)
	if not _can_start_for_player(player_instance):
		return _make_result(ResultCode.INVALID_PLAYER)
	var session_key := maxi(peer_id, 0)
	var existing_session := (
		sessions_by_peer.get(session_key) as LuoxiSpecialGameSession
	)
	if existing_session != null:
		var resumed := _make_session_result(existing_session, ResultCode.SUCCESS)
		resumed["resumed"] = true
		return resumed
	if not player_has_ticket(peer_id):
		return _make_result(ResultCode.TICKET_MISSING)

	var collectible_pool := _get_collectible_pool_for_player(player_instance)
	var outcomes := LuoxiSpecialGameRules.roll_cards(
		random_generator,
		collectible_pool
	)
	if outcomes.size() != CARD_COUNT:
		return _make_result(ResultCode.INVALID_PLAYER)
	var next_revision := int(revision_counters_by_peer.get(session_key, 0)) + 1
	var session := LuoxiSpecialGameSession.new()
	if not session.setup(next_revision, outcomes):
		return _make_result(ResultCode.INVALID_PLAYER)
	if not _consume_ticket(peer_id):
		return _make_result(ResultCode.TICKET_MISSING)

	revision_counters_by_peer[session_key] = next_revision
	sessions_by_peer[session_key] = session
	return _make_session_result(session, ResultCode.SUCCESS)


func reveal_for_peer(
	peer_id: int,
	session_revision: int,
	card_index: int
) -> Dictionary:
	var session := _get_session(peer_id)
	if session == null or session.revision != session_revision:
		return _make_result(ResultCode.STALE_SESSION, session_revision)
	var player_instance := _get_player(peer_id)
	if player_instance == null or player_instance.is_dead:
		cancel_for_peer(peer_id)
		return _make_result(ResultCode.PLAYER_DIED, session_revision, true)
	if card_index < 0 or card_index >= CARD_COUNT:
		return _make_session_result(session, ResultCode.INVALID_CARD)
	if session.is_card_revealed(card_index):
		return _make_session_result(
			session,
			ResultCode.CARD_ALREADY_REVEALED
		)

	var outcome := session.reveal(card_index)
	if outcome.is_empty():
		return _make_session_result(session, ResultCode.INVALID_CARD)
	_apply_immediate_outcome(player_instance, outcome)
	# 核心生命牌可能同步触发终局；终局流程会取消全部牌局。不能再用手中
	# 的旧 session 拼出一个虚假的成功回包。
	if _get_session(peer_id) != session:
		var interrupted_result := _make_result(
			ResultCode.STALE_SESSION,
			session_revision,
			true
		)
		interrupted_result["card_index"] = card_index
		interrupted_result["outcome"] = outcome.duplicate(true)
		interrupted_result["revealed_count"] = session.get_revealed_count()
		return interrupted_result
	if player_instance.is_dead:
		var cancelled_result := _make_result(
			ResultCode.PLAYER_DIED,
			session_revision,
			true
		)
		cancelled_result["card_index"] = card_index
		cancelled_result["outcome"] = outcome.duplicate(true)
		cancelled_result["revealed_count"] = session.get_revealed_count()
		cancel_for_peer(peer_id)
		return cancelled_result

	var result := _make_session_result(session, ResultCode.SUCCESS)
	result["card_index"] = card_index
	result["outcome"] = outcome.duplicate(true)
	return result


func finish_for_peer(peer_id: int, session_revision: int) -> Dictionary:
	var session := _get_session(peer_id)
	if session == null or session.revision != session_revision:
		return _make_result(ResultCode.STALE_SESSION, session_revision)
	var player_instance := _get_player(peer_id)
	if player_instance == null or player_instance.is_dead:
		cancel_for_peer(peer_id)
		return _make_result(ResultCode.PLAYER_DIED, session_revision, true)

	var item_paths := session.get_pending_item_paths()
	var item_counts := session.get_pending_item_counts()
	var items: Array[PickupConfig] = []
	for item_path in item_paths:
		var item := load(item_path) as PickupConfig
		if item == null or not item.can_store_in_inventory:
			return _make_session_result(session, ResultCode.INVALID_PLAYER)
		items.append(item)
	if not items.is_empty() and not _try_add_pending_items(
		peer_id,
		items,
		item_counts
	):
		return _make_session_result(session, ResultCode.INVENTORY_FULL)

	var pending_xirang := session.get_pending_xirang()
	if pending_xirang > 0:
		player_instance.set_xirang_balance(
			player_instance.current_xirang + pending_xirang
		)
	var result := _make_session_result(session, ResultCode.SUCCESS)
	result["awarded_item_paths"] = item_paths.duplicate()
	result["awarded_item_counts"] = item_counts.duplicate()
	result["awarded_xirang"] = pending_xirang
	result["current_xirang"] = player_instance.current_xirang
	sessions_by_peer.erase(maxi(peer_id, 0))
	return result


func cancel_for_peer(peer_id: int) -> void:
	sessions_by_peer.erase(maxi(peer_id, 0))


func cancel_all() -> void:
	sessions_by_peer.clear()


func _can_start_for_player(player_instance: Player) -> bool:
	return (
		authoritative_enabled
		and campaign_coordinator != null
		and home_defense_coordinator != null
		and player_roster_coordinator != null
		and multiplayer_adapter != null
		and run_state != null
		and merchant != null
		and merchant.is_active
		and random_generator != null
		and player_instance != null
		and is_instance_valid(player_instance)
		and not player_instance.is_dead
		and campaign_coordinator.wave_state not in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
		and player_instance.global_position.distance_squared_to(
			merchant.global_position
		) <= MAXIMUM_INTERACTION_DISTANCE * MAXIMUM_INTERACTION_DISTANCE
	)


func _get_player(peer_id: int) -> Player:
	if player_roster_coordinator == null:
		return null
	return player_roster_coordinator.get_player_for_runtime_peer(peer_id)


func _get_session(peer_id: int) -> LuoxiSpecialGameSession:
	return sessions_by_peer.get(maxi(peer_id, 0)) as LuoxiSpecialGameSession


func _consume_ticket(peer_id: int) -> bool:
	if peer_id > 0:
		var revision := run_state.get_inventory_revision_for_peer(peer_id)
		return run_state.try_consume_item_count_for_peer_if_revision(
			peer_id,
			GAMBLER_TICKET,
			1,
			revision
		)
	var revision := run_state.get_inventory_revision()
	return run_state.try_consume_item_count_if_revision(
		GAMBLER_TICKET,
		1,
		revision
	)


func _try_add_pending_items(
	peer_id: int,
	items: Array[PickupConfig],
	counts: Array[int]
) -> bool:
	if items.size() != counts.size():
		return false
	if peer_id > 0:
		return run_state.try_add_item_counts_for_peer_if_revision(
			peer_id,
			items,
			counts,
			run_state.get_inventory_revision_for_peer(peer_id)
		)
	return run_state.try_add_item_counts_if_revision(
		items,
		counts,
		run_state.get_inventory_revision()
	)


func _get_collectible_pool_for_player(player_instance: Player) -> Array:
	var result: Array = []
	if player_instance == null:
		return result
	for item in CollectibleRegistry.get_standard_random_pool():
		if player_instance.is_collectible_compatible(item):
			result.append(item)
	return result


func _apply_immediate_outcome(
	player_instance: Player,
	outcome: Dictionary
) -> void:
	match int(outcome.get("kind", -1)):
		LuoxiSpecialGameRules.OutcomeKind.HEALTH_DAMAGE:
			_apply_health_outcome(player_instance, outcome)
		LuoxiSpecialGameRules.OutcomeKind.CORE_DAMAGE:
			_apply_core_health_loss(
				maxi(int(outcome.get("amount", 0)), 0)
			)


func _apply_health_outcome(
	player_instance: Player,
	outcome: Dictionary
) -> void:
	var amount := maxi(int(outcome.get("amount", 0)), 0)
	match int(outcome.get("effect", -1)):
		LuoxiSpecialGameRules.HealthEffect.SELF_FIXED:
			_apply_player_health_loss(player_instance, amount)
		LuoxiSpecialGameRules.HealthEffect.SELF_LEAVE_ONE:
			_apply_player_health_loss(
				player_instance,
				player_instance.current_health,
				1
			)
		LuoxiSpecialGameRules.HealthEffect.OTHERS_CURRENT_PERCENT:
			for target in player_roster_coordinator.get_all_players():
				if target == player_instance or target.is_dead:
					continue
				var loss := floori(
					float(target.current_health) * float(amount) / 100.0
				)
				_apply_player_health_loss(target, loss, 1)
		LuoxiSpecialGameRules.HealthEffect.ALL_FIXED:
			for target in player_roster_coordinator.get_all_players():
				if not target.is_dead:
					_apply_player_health_loss(target, amount)


func _apply_core_health_loss(amount: int) -> int:
	if (
		amount <= 0
		or home_defense_coordinator == null
		or player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return 0
	return home_defense_coordinator.apply_base_damage(amount)


func _apply_player_health_loss(
	target_player: Player,
	amount: int,
	minimum_health: int = 0
) -> int:
	if (
		target_player == null
		or not is_instance_valid(target_player)
		or target_player.is_dead
		or amount <= 0
		or player_roster_coordinator == null
		or player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return 0
	if (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		return target_player.apply_direct_health_loss(amount, minimum_health)
	return multiplayer_adapter.apply_luoxi_player_health_loss(
		target_player,
		amount,
		minimum_health
	)


func _make_result(
	result_code: int,
	session_revision: int = 0,
	cancelled: bool = false
) -> Dictionary:
	return {
		"result_code": result_code,
		"session_revision": session_revision,
		"cancelled": cancelled,
	}


func _make_session_result(
	session: LuoxiSpecialGameSession,
	result_code: int
) -> Dictionary:
	var result := _make_result(result_code, session.revision)
	result.merge(session.get_public_state(), true)
	return result
