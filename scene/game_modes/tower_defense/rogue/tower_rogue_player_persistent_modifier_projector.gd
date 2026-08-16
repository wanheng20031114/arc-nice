extends PlayerPersistentModifierProjector
class_name TowerRoguePlayerPersistentModifierProjector

var _research: ResearchCoordinator = null
var _fate: FateCoordinator = null


func setup(research: ResearchCoordinator, fate: FateCoordinator) -> bool:
	if research == null or fate == null:
		return false
	_research = research
	_fate = fate
	return true


func apply_to_player(player: Player, ledger_peer_id: int) -> bool:
	if (
		player == null
		or not is_instance_valid(player)
		or ledger_peer_id < 0
		or _research == null
		or _fate == null
	):
		return false
	return (
		_research.apply_persistent_player_modifiers(player, ledger_peer_id)
		and _fate.apply_persistent_player_modifiers(player, ledger_peer_id)
	)


## 从同一份 Tower 外层快照的冻结 Research/Fate token 计算每个玩家的
## 永久面板，不读取 owner 当前值。这样 CH0 即使先于独立 CH5/CH6 到达，
## Player 也只会在权威永久层齐备后发布。
func prepare_for_players(
	players_by_peer: Dictionary,
	prepared_research: Dictionary,
	prepared_fate: Dictionary
) -> Dictionary:
	if (
		_research == null
		or _fate == null
		or players_by_peer.is_empty()
		or not _research.can_commit_prepared_multiplayer_runtime_state(
			prepared_research
		)
		or not _fate.can_commit_prepared_persistent_player_modifier_snapshot(
			prepared_fate
		)
	):
		return {}
	var research_levels := prepared_research["player_levels"] as Dictionary
	var global_states := prepared_research["global_states"] as Dictionary
	var research_move_speed_bonus := 0.0
	for config in GlobalResearchRegistry.get_all_configs():
		if (
			config.effect_type
			== GlobalResearchConfig.EffectType.PLAYER_MOVE_SPEED
			and int(global_states.get(config.research_id, -1))
			== ResearchCoordinator.GlobalResearchState.COMPLETED
		):
			research_move_speed_bonus += config.effect_amount
	var active_buff_ids := prepared_fate[
		"active_permanent_buff_ids"
	] as Array
	var low_health_config := (
		TowerDefenseFateRegistry.get_permanent_buff_config(
			TowerDefenseFateRegistry.BUFF_LOW_HEALTH_REDUCTION
		)
		if active_buff_ids.has(
			TowerDefenseFateRegistry.BUFF_LOW_HEALTH_REDUCTION
		)
		else null
	)
	var low_health_ratio := (
		low_health_config.secondary_magnitude
		if low_health_config != null
		else 0.0
	)
	var low_health_reduction := (
		low_health_config.magnitude if low_health_config != null else 0.0
	)
	var normalized_players: Dictionary = {}
	var instance_ids: Dictionary = {}
	var values: Dictionary = {}
	for raw_peer_id in players_by_peer.keys():
		if typeof(raw_peer_id) != TYPE_INT:
			return {}
		var peer_id := int(raw_peer_id)
		var player_instance := players_by_peer[raw_peer_id] as Player
		var expected_peer_id := (
			player_instance.peer_id
			if player_instance != null and player_instance.peer_id > 0
			else 0
		)
		if (
			player_instance == null
			or not is_instance_valid(player_instance)
			or expected_peer_id != peer_id
			or not research_levels.has(peer_id)
			or typeof(research_levels[peer_id]) != TYPE_INT
		):
			return {}
		normalized_players[peer_id] = player_instance
		instance_ids[peer_id] = player_instance.get_instance_id()
		values[peer_id] = {
			"research_technology_level": int(research_levels[peer_id]),
			"research_move_speed_bonus": research_move_speed_bonus,
			"fate_max_health_multiplier": float(
				prepared_fate["player_max_health_multiplier"]
			),
			"fate_move_speed_multiplier": float(
				prepared_fate["player_move_speed_multiplier"]
			),
			"fate_dash_cooldown_reduction": float(
				prepared_fate["player_dash_cooldown_reduction"]
			),
			"fate_low_health_ratio": low_health_ratio,
			"fate_low_health_reduction": low_health_reduction,
		}
	return {
		"players": normalized_players,
		"instance_ids": instance_ids,
		"values": values,
	}


func can_commit_prepared_for_players(prepared: Dictionary) -> bool:
	if (
		prepared.size() != 3
		or typeof(prepared.get("players")) != TYPE_DICTIONARY
		or typeof(prepared.get("instance_ids")) != TYPE_DICTIONARY
		or typeof(prepared.get("values")) != TYPE_DICTIONARY
	):
		return false
	var players := prepared["players"] as Dictionary
	var instance_ids := prepared["instance_ids"] as Dictionary
	var values := prepared["values"] as Dictionary
	if (
		players.is_empty()
		or players.keys().size() != instance_ids.keys().size()
		or players.keys().size() != values.keys().size()
	):
		return false
	for raw_peer_id in players.keys():
		var player_instance := players[raw_peer_id] as Player
		if (
			player_instance == null
			or not is_instance_valid(player_instance)
			or player_instance.get_instance_id()
			!= int(instance_ids.get(raw_peer_id, 0))
			or not values.has(raw_peer_id)
		):
			return false
	return true


## prepare 已把研究和命运值归一化；此处只对冻结 Player 做绝对投影。
func commit_validated_for_players(prepared: Dictionary) -> void:
	var players := prepared["players"] as Dictionary
	var values := prepared["values"] as Dictionary
	for raw_peer_id in players.keys():
		var player_instance := players[raw_peer_id] as Player
		var player_values := values[raw_peer_id] as Dictionary
		player_instance.set_research_technology_level(
			int(player_values["research_technology_level"])
		)
		player_instance.set_research_global_move_speed_bonus(
			float(player_values["research_move_speed_bonus"])
		)
		player_instance.configure_tower_defense_fate_modifiers(
			float(player_values["fate_max_health_multiplier"]),
			float(player_values["fate_move_speed_multiplier"]),
			float(player_values["fate_dash_cooldown_reduction"]),
			float(player_values["fate_low_health_ratio"]),
			float(player_values["fate_low_health_reduction"]),
			1.0,
			0.0
		)
