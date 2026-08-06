class_name PlayerSnapshotEncoder
extends RefCounted

var _states_by_peer_id: Dictionary = {}
var _output: Array[SnapshotManager.PlayerState] = []
var _live_peer_ids: Dictionary = {}
var _stale_peer_ids: Array = []


func collect(
	peer_players: Dictionary
) -> Array[SnapshotManager.PlayerState]:
	_output.clear()
	_live_peer_ids.clear()
	_stale_peer_ids.clear()
	for peer_id_variant in peer_players:
		var peer_id := int(peer_id_variant)
		var player_instance := peer_players[peer_id] as Player
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		_live_peer_ids[peer_id] = true
		var state := _states_by_peer_id.get(peer_id) as SnapshotManager.PlayerState
		if state == null:
			state = SnapshotManager.PlayerState.new()
			_states_by_peer_id[peer_id] = state
		# 广播层会覆盖这两个字段；采样时必须恢复旧的“新对象”默认语义。
		state.sequence = 0
		state.health_revision = 0
		state.peer_id = peer_id
		state.character_id = player_instance.get_character_id()
		state.position = player_instance.global_position
		state.velocity = player_instance.velocity
		state.facing = player_instance.get_multiplayer_facing_id()
		state.anim_state = player_instance.get_multiplayer_anim_state()
		state.current_health = player_instance.current_health
		state.max_health = player_instance.max_health
		state.current_xirang = player_instance.current_xirang
		state.is_dead = player_instance.is_dead
		state.invincibility_time_left = player_instance.invincibility_time_left
		state.skill1_unlocked = player_instance.skill1_unlocked
		state.skill1_charge = player_instance.skill1_charge
		state.skill1_charge_duration = player_instance.skill1_charge_duration
		state.skill1_upgrade_level = player_instance.skill1_upgrade_level
		state.form_mode = player_instance.get_multiplayer_form_mode()
		state.shot_pattern = player_instance.get_multiplayer_shot_pattern()
		state.ammo_capacity = player_instance.get_multiplayer_ammo_capacity()
		state.current_ammo = player_instance.get_multiplayer_current_ammo()
		state.is_reloading = player_instance.get_multiplayer_is_reloading()
		state.reload_progress = player_instance.get_multiplayer_reload_progress()
		state.primary_cooldown_ratio = clampf(
			player_instance.get_primary_cooldown_ratio(),
			0.0,
			1.0
		)
		state.effective_move_speed_multiplier = (
			player_instance.get_authoritative_move_speed_multiplier()
		)
		_output.append(state)
	for peer_id_variant in _states_by_peer_id:
		if not _live_peer_ids.has(int(peer_id_variant)):
			_stale_peer_ids.append(peer_id_variant)
	for peer_id_variant in _stale_peer_ids:
		_states_by_peer_id.erase(peer_id_variant)
	return _output


func forget_peer(peer_id: int) -> void:
	_states_by_peer_id.erase(peer_id)


func clear() -> void:
	_states_by_peer_id.clear()
	_output.clear()
	_live_peer_ids.clear()
	_stale_peer_ids.clear()
