extends RuntimePreparationProvider
class_name MiragePvp

signal state_updated
signal kill_feed(killer: String, victim: String, headshot: bool)
signal round_announced(text: String)
signal shot_presented(peer_id: int, weapon: String)

const Rules := preload("res://scene/pvp/pvp_rules.gd")
const PlayerScene := preload("res://scene/pvp/pvp_player.tscn")
const ProjectileScene := preload("res://scene/pvp/pvp_projectile.tscn")
const PickupScene := preload("res://scene/pvp/pvp_weapon_pickup.tscn")
const LOBBY_PATH := "res://scene/multiplayer/multiplayer_lobby.tscn"
const SNAPSHOT_INTERVAL := 0.05
const INPUT_INTERVAL := 0.033
const INPUT_TIMEOUT := 0.35
const SNAPSHOT_CHUNK_BYTES := 1024
const MAX_SNAPSHOT_CHUNKS := 64
const MAX_SNAPSHOT_DECODED_BYTES := 131072

## Standalone scene runs a local training preview; the lobby always supplies real teams.
@export var training_preview := false
@export var disable_presentation := false

var players: Dictionary[int, PvpPlayer] = {}
var projectiles: Dictionary[int, PvpProjectile] = {}
var pickups: Dictionary[int, PvpWeaponPickup] = {}
var local_player: PvpPlayer
var phase := "loading"
var round_number := 0
var phase_time_left := 0.0
var scores: Dictionary = {"CT": 0, "T": 0}
var winner_team := ""

var _host := false
var _offline := false
var _started := false
var _leaving := false
var _local_peer_id := 1
var _host_peer_id := 1
var _session_id := 0
var _clock := 0.0
var _snapshot_timer := 0.0
var _input_timer := 0.0
var _hud_timer := 0.0
var _projectile_sequence := 0
var _pickup_sequence := 0
var _input_sequence := 0
var _action_sequence := 0
var _snapshot_sequence := 0
var _last_snapshot_sequence := -1
var _incoming_snapshot_sequence := -1
var _incoming_snapshot_chunk_count := 0
var _incoming_snapshot_chunks: Dictionary[int, PackedByteArray] = {}
var _last_input: Dictionary[int, int] = {}
var _last_action: Dictionary[int, int] = {}
var _last_action_time: Dictionary[int, float] = {}
var _input_queue: Dictionary[int, Dictionary] = {}
var _action_queue: Array[Dictionary] = []
var _loading_time := 0.0
var _message := ""
var _ui_blocks_input := false

@onready var net_manager: NetManagerStore = NetManagerStore.get_autoload_instance()
@onready var map: Node2D = $Map
@onready var players_root: Node2D = $Players
@onready var projectile_root: Node2D = $Projectiles
@onready var pickup_root: Node2D = $Pickups
@onready var hud: CanvasLayer = $HUD
@onready var visibility_controller: Node = $Visibility

func _ready() -> void:
	var preparation := begin_runtime_preparation("准备荒漠迷城与交战队伍", 1)
	_offline = not net_manager.is_multiplayer_active()
	_host = _offline or net_manager.is_host()
	_local_peer_id = 1 if _offline else net_manager.get_local_peer_id()
	_host_peer_id = 1 if _offline else net_manager.get_host_peer_id()
	_session_id = 0 if _offline else net_manager.get_game_session_incarnation()
	set_multiplayer_authority(_host_peer_id)
	if not disable_presentation:
		hud.buy_ak_requested.connect(func(): request_action("buy_ak"))
		hud.leave_requested.connect(leave_match)
		hud.buy_menu_toggled.connect(func(opened: bool): _ui_blocks_input = opened)
	else:
		hud.hide()
		visibility_controller.process_mode = Node.PROCESS_MODE_DISABLED
	if _offline:
		training_preview = true
		_create_player(1, "CT", "维什戴尔 · 本地演练")
		_create_player(2, "T", "T · 训练靶")
	else:
		net_manager.connection_state_changed.connect(_on_connection_state_changed)
		net_manager.player_left.connect(_on_player_left)
		for id_variant: Variant in net_manager.connected_players:
			var id := int(id_variant)
			_create_player(id, net_manager.get_player_team(id), net_manager.get_player_name_by_id(id))
		if _host:
			net_manager.host_broadcast_start_game()
	if not disable_presentation:
		hud.set_map(map)
		visibility_controller.set_context(local_player, map, players_root)
	mark_runtime_preparation_complete(preparation)
	if _offline:
		activate_runtime()
	else:
		net_manager.report_game_loaded()
		if _host:
			net_manager.mark_in_game()
		if net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME:
			_on_connection_state_changed(NetManagerStore.ConnectionState.IN_GAME)
	_refresh_hud()

func activate_runtime() -> void:
	if is_runtime_preparation_complete() and _host:
		_start_match()

func _create_player(id: int, player_team: String, player_name: String) -> PvpPlayer:
	var player := PlayerScene.instantiate() as PvpPlayer
	player.name = "Peer_%d" % id
	player.peer_id = id
	player.team = player_team
	player.display_name = player_name
	player.is_local = id == _local_peer_id
	players_root.add_child(player)
	players[id] = player
	if player.is_local:
		local_player = player
	return player

func _start_match() -> void:
	if _started or not _host:
		return
	_started = true
	_start_round()

func _start_round() -> void:
	round_number += 1
	phase = "buy"
	phase_time_left = Rules.BUY_SECONDS
	winner_team = ""
	_clear_projectiles()
	_clear_pickups()
	_input_queue.clear()
	_action_queue.clear()
	var counts: Dictionary = {"CT": 0, "T": 0}
	for player: PvpPlayer in players.values():
		var index := int(counts[player.team])
		player.reset_round(map.get_spawn_position(player.team, index))
		counts[player.team] = index + 1
		player.input_time = _clock
	_announce("第 %d 回合 · 购买阶段" % round_number, "B 购买 AK · 15 秒后开始交火")
	_broadcast_snapshot()

func _physics_process(delta: float) -> void:
	if _leaving:
		return
	_clock += delta
	if phase == "loading":
		_loading_time += delta
		if _loading_time > 45.0 and _host:
			phase = "match_end"
			_announce("对局已取消", "玩家加载超时，请返回大厅重新创建房间")
		_refresh_hud()
		return
	if not _started:
		return
	_collect_local_input(delta)
	if _host:
		_consume_requests()
		for player: PvpPlayer in players.values():
			if _clock - player.input_time > INPUT_TIMEOUT:
				player.move_input = Vector2.ZERO
				player.fire_held = false
			player.authority_tick(delta, phase == "live")
			if phase == "live" and player.fire_held:
				_try_fire(player)
		_step_projectiles(delta)
		if phase in ["buy", "live", "round_end"]:
			phase_time_left = maxf(0.0, phase_time_left - delta)
			if phase_time_left == 0.0:
				_advance_phase()
		_snapshot_timer -= delta
		if _snapshot_timer <= 0.0:
			_snapshot_timer = SNAPSHOT_INTERVAL
			_broadcast_snapshot()
	else:
		for player: PvpPlayer in players.values():
			player.client_tick(delta, phase == "live")
		for projectile: PvpProjectile in projectiles.values():
			projectile.global_position += projectile.direction * Rules.BULLET_SPEED * delta
		phase_time_left = maxf(0.0, phase_time_left - delta)
	if not disable_presentation and local_player != null:
		local_player.camera.global_position = visibility_controller.get_observer_position()
		map.update_archway_visibility(visibility_controller.get_observer_position())
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.1
		_refresh_hud()

func _collect_local_input(delta: float) -> void:
	if local_player == null or disable_presentation:
		return
	var menu_open := _ui_blocks_input
	var move := Vector2.ZERO if menu_open else Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var aim := local_player.global_position.direction_to(get_global_mouse_position())
	if aim.is_zero_approx():
		aim = local_player.aim_direction
	var fire := not menu_open and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	local_player.move_input = move
	local_player.aim_direction = aim
	_input_timer -= delta
	if _input_timer > 0.0:
		return
	_input_timer = INPUT_INTERVAL
	_input_sequence += 1
	if _host:
		_accept_input(_local_peer_id, _input_sequence, move, aim, fire)
	else:
		_rpc_input.rpc_id(_host_peer_id, _session_id, round_number, _input_sequence, move, aim, fire)

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or _leaving:
		return
	match event.physical_keycode:
		KEY_B:
			hud.set_buy_open(not hud.is_buy_open())
		KEY_G:
			request_action("drop")
		KEY_R:
			request_action("reload")
		KEY_F:
			request_action("pickup")
		KEY_1:
			request_action("slot1")
		KEY_2:
			request_action("slot2")
		_:
			return
	get_viewport().set_input_as_handled()

func request_action(action: String) -> void:
	if _leaving or not _started:
		return
	_action_sequence += 1
	if _host:
		_accept_action(_local_peer_id, _action_sequence, action)
	else:
		_rpc_action.rpc_id(_host_peer_id, _session_id, round_number, _action_sequence, action)

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rpc_input(session: int, round_id: int, sequence: int, move: Vector2, aim: Vector2, fire: bool) -> void:
	if not _host or session != _session_id or round_id != round_number:
		return
	_accept_input(multiplayer.get_remote_sender_id(), sequence, move, aim, fire)

func _accept_input(id: int, sequence: int, move: Vector2, aim: Vector2, fire: bool) -> void:
	if not players.has(id) or sequence <= int(_last_input.get(id, -1)):
		return
	if not move.is_finite() or not aim.is_finite() or aim.length_squared() < 0.01:
		return
	_last_input[id] = sequence
	_input_queue[id] = {"move": move.limit_length(), "aim": aim.normalized(), "fire": fire}

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_action(session: int, round_id: int, sequence: int, action: String) -> void:
	if not _host or session != _session_id or round_id != round_number:
		return
	_accept_action(multiplayer.get_remote_sender_id(), sequence, action)

func _accept_action(id: int, sequence: int, action: String) -> void:
	if not players.has(id) or sequence <= int(_last_action.get(id, -1)):
		return
	if action not in ["buy_ak", "drop", "reload", "pickup", "slot1", "slot2"]:
		return
	_last_action[id] = sequence
	# A single bounded queue also ensures physics queries run in the physics frame.
	if _clock - float(_last_action_time.get(id, -1.0)) < 0.075:
		return
	_last_action_time[id] = _clock
	_action_queue.append({"id": id, "action": action})

func _consume_requests() -> void:
	for id: int in _input_queue:
		var player: PvpPlayer = players[id]
		var input: Dictionary = _input_queue[id]
		player.move_input = input.move
		player.aim_direction = input.aim
		player.fire_held = input.fire
		player.input_time = _clock
	_input_queue.clear()
	for request: Dictionary in _action_queue:
		if players.has(int(request.id)):
			_perform_action(players[int(request.id)], str(request.action))
	_action_queue.clear()

func _perform_action(player: PvpPlayer, action: String) -> bool:
	if not player.alive or phase not in ["buy", "live"]:
		return false
	match action:
		"buy_ak":
			if phase != "buy" or not map.is_in_buy_zone(player.global_position, player.team):
				_feedback(player.peer_id, "只能在购买阶段的本队出生区购买")
				return false
			if player.loadout.has("ak"):
				_feedback(player.peer_id, "已持有 AK-47")
				return false
			if player.money < Rules.AK_PRICE:
				_feedback(player.peer_id, "资金不足，需要 $2700")
				return false
			player.money -= Rules.AK_PRICE
			player.loadout["ak"] = Rules.new_weapon("ak")
			player.equip("ak")
			_feedback(player.peer_id, "已购买 AK-47")
		"drop":
			return _drop_weapon(player, player.current_weapon)
		"pickup":
			return _pickup_weapon(player)
		"reload":
			return _start_reload(player)
		"slot1":
			return player.equip("ak")
		"slot2":
			return player.equip("deagle")
	return true

func _try_fire(player: PvpPlayer) -> bool:
	if phase != "live" or not player.alive or not player.loadout.has(player.current_weapon):
		return false
	if player.fire_cooldown > 0.0 or player.reload_remaining > 0.0:
		return false
	if player.ammo <= 0:
		_start_reload(player)
		return false
	var weapon := player.current_weapon
	player.loadout[weapon].ammo = player.ammo - 1
	player.fire_cooldown = float(Rules.WEAPONS[weapon].fire_interval)
	player.shot_sequence += 1
	player.last_shot_weapon = weapon
	var origin := player.global_position + Vector2(0, -1)
	_play_shot(origin, weapon, player.peer_id)
	var muzzle := origin + player.aim_direction * 13.0
	var wall_query := PhysicsRayQueryParameters2D.create(origin, muzzle, 1)
	wall_query.hit_from_inside = true
	if not get_world_2d().direct_space_state.intersect_ray(wall_query).is_empty():
		return true
	var exclusions: Array[RID] = []
	for ally: PvpPlayer in players.values():
		if ally.team == player.team:
			exclusions.append(ally.body_hitbox.get_rid())
			exclusions.append(ally.head_hitbox.get_rid())
	_projectile_sequence += 1
	var projectile := ProjectileScene.instantiate() as PvpProjectile
	projectile_root.add_child(projectile)
	projectile.setup(_projectile_sequence, player, weapon, muzzle, player.aim_direction, exclusions)
	projectiles[projectile.projectile_id] = projectile
	return true

func _start_reload(player: PvpPlayer) -> bool:
	if not player.start_reload():
		return false
	_play_reload(player)
	return true

func _play_reload(player: PvpPlayer) -> void:
	if disable_presentation:
		return
	$ReloadSound.global_position = player.global_position
	$ReloadSound.play()

func _step_projectiles(delta: float) -> void:
	for id: int in projectiles.keys():
		var projectile: PvpProjectile = projectiles[id]
		var hit := projectile.authority_step(delta)
		if not hit.is_empty() and hit.collider is Area2D:
			var hitbox := hit.collider as Area2D
			var victim := hitbox.get_parent() as PvpPlayer
			if victim != null and victim.alive and victim.team != projectile.shooter_team:
				_apply_hit(projectile, victim, hitbox.name == &"HeadHitbox")
		if projectile.expired:
			projectile.queue_free()
			projectiles.erase(id)

func _apply_hit(projectile: PvpProjectile, victim: PvpPlayer, headshot: bool) -> void:
	if phase != "live":
		return
	if not victim.take_damage(Rules.damage(projectile.weapon, headshot)):
		return
	var killer_name := "环境"
	if players.has(projectile.shooter_id):
		var killer: PvpPlayer = players[projectile.shooter_id]
		killer.kills += 1
		killer.money = mini(Rules.MAX_MONEY, killer.money + 300)
		killer_name = killer.display_name
	for weapon: String in victim.loadout.keys():
		_drop_weapon(victim, weapon, true)
	_show_kill(killer_name, victim.display_name, projectile.weapon, headshot)
	if not _offline:
		for id: int in players:
			if id != _local_peer_id and net_manager.is_peer_send_ready(id):
				_rpc_kill.rpc_id(id, _session_id, killer_name, victim.display_name, projectile.weapon, headshot)
	_check_elimination()

func _drop_weapon(player: PvpPlayer, weapon: String, on_death: bool = false) -> bool:
	if not player.loadout.has(weapon):
		return false
	var location := player.global_position
	if not on_death:
		var desired := location + player.aim_direction * 20.0
		var query := PhysicsRayQueryParameters2D.create(location, desired, 1)
		var wall := get_world_2d().direct_space_state.intersect_ray(query)
		location = desired if wall.is_empty() else (wall.position as Vector2) - player.aim_direction * 4.0
	_pickup_sequence += 1
	var pickup := PickupScene.instantiate() as PvpWeaponPickup
	pickup_root.add_child(pickup)
	pickup.configure(_pickup_sequence, weapon, player.loadout[weapon], location)
	pickups[_pickup_sequence] = pickup
	player.loadout.erase(weapon)
	if weapon == player.current_weapon:
		player.current_weapon = "ak" if player.loadout.has("ak") else ("deagle" if player.loadout.has("deagle") else "empty")
	player.reload_remaining = 0.0
	return true

func _find_nearby_pickup(player: PvpPlayer) -> PvpWeaponPickup:
	var nearest: PvpWeaponPickup
	var distance := Rules.PICKUP_DISTANCE
	for pickup: PvpWeaponPickup in pickups.values():
		var candidate_distance := player.global_position.distance_to(pickup.global_position)
		if candidate_distance >= distance:
			continue
		var query := PhysicsRayQueryParameters2D.create(player.global_position, pickup.global_position, 1)
		if not get_world_2d().direct_space_state.intersect_ray(query).is_empty():
			continue
		nearest = pickup
		distance = candidate_distance
	return nearest

func _pickup_weapon(player: PvpPlayer) -> bool:
	var pickup := _find_nearby_pickup(player)
	if pickup == null:
		return false
	if player.loadout.has(pickup.weapon):
		_drop_weapon(player, pickup.weapon)
	player.loadout[pickup.weapon] = pickup.ammunition.duplicate(true)
	player.equip(pickup.weapon)
	pickups.erase(pickup.pickup_id)
	pickup.queue_free()
	return true

func _check_elimination() -> void:
	if phase != "live":
		return
	var alive_ct := 0
	var alive_t := 0
	for player: PvpPlayer in players.values():
		if player.alive:
			if player.team == "CT":
				alive_ct += 1
			else:
				alive_t += 1
	if alive_t == 0:
		_finish_round("CT", "T 队已被消灭")
	elif alive_ct == 0:
		_finish_round("T", "CT 队已被消灭")

func _finish_round(winning_team: String, reason: String) -> void:
	if phase != "live":
		return
	winner_team = winning_team
	scores[winning_team] = int(scores[winning_team]) + 1
	for player: PvpPlayer in players.values():
		player.money = mini(Rules.MAX_MONEY, player.money + (3250 if player.team == winning_team else 1900))
		player.fire_held = false
	phase = "match_end" if int(scores[winning_team]) >= Rules.WIN_SCORE else "round_end"
	phase_time_left = 0.0 if phase == "match_end" else Rules.RESULT_SECONDS
	_announce("%s %s" % [winning_team, "赢得比赛" if phase == "match_end" else "赢得回合"], reason)
	_broadcast_snapshot()

func _advance_phase() -> void:
	match phase:
		"buy":
			phase = "live"
			phase_time_left = Rules.ROUND_SECONDS
			_announce("交火开始", "消灭敌队 · 90 秒到时 CT 获胜")
			_check_elimination()
		"live":
			_finish_round("CT", "时间耗尽，CT 守住了阵地")
		"round_end":
			_start_round()

func _broadcast_snapshot() -> void:
	state_updated.emit()
	if _offline or not _host:
		return
	_snapshot_sequence += 1
	var payload := var_to_bytes(_make_snapshot()).compress(FileAccess.COMPRESSION_DEFLATE)
	var chunk_count := ceili(float(payload.size()) / SNAPSHOT_CHUNK_BYTES)
	assert(chunk_count <= MAX_SNAPSHOT_CHUNKS, "PVP snapshot exceeded its bounded wire contract")
	for id: int in players:
		if id != _local_peer_id and net_manager.is_peer_send_ready(id):
			for chunk_index: int in range(chunk_count):
				var start := chunk_index * SNAPSHOT_CHUNK_BYTES
				_rpc_snapshot.rpc_id(id, _session_id, _snapshot_sequence, chunk_index, chunk_count, payload.slice(start, start + SNAPSHOT_CHUNK_BYTES))

func _make_snapshot() -> Dictionary:
	var player_states: Array[Dictionary] = []
	for player: PvpPlayer in players.values():
		player_states.append(player.serialize())
	var bullet_states: Array[Dictionary] = []
	for projectile: PvpProjectile in projectiles.values():
		bullet_states.append(projectile.serialize())
	var drop_states: Array[Dictionary] = []
	for pickup: PvpWeaponPickup in pickups.values():
		drop_states.append(pickup.serialize())
	return {"round": round_number, "phase": phase, "time": phase_time_left,
		"scores": scores.duplicate(), "winner": winner_team,
		"players": player_states, "projectiles": bullet_states, "pickups": drop_states}

@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_snapshot(session: int, sequence: int, chunk_index: int, chunk_count: int, payload: PackedByteArray) -> void:
	if _host or session != _session_id or sequence <= _last_snapshot_sequence:
		return
	var state := _receive_snapshot_chunk(sequence, chunk_index, chunk_count, payload)
	if state.is_empty():
		return
	_last_snapshot_sequence = sequence
	_apply_snapshot(state)

## Bounded fragments stay below ENet MTU even with eight simultaneous AK users.
## A lost fragment costs one 20 Hz snapshot; newer complete state supersedes it.
func _receive_snapshot_chunk(sequence: int, chunk_index: int, chunk_count: int, payload: PackedByteArray) -> Dictionary:
	if sequence < _incoming_snapshot_sequence or chunk_count < 1 or chunk_count > MAX_SNAPSHOT_CHUNKS:
		return {}
	if chunk_index < 0 or chunk_index >= chunk_count or payload.is_empty() or payload.size() > SNAPSHOT_CHUNK_BYTES:
		return {}
	if sequence != _incoming_snapshot_sequence:
		_incoming_snapshot_sequence = sequence
		_incoming_snapshot_chunk_count = chunk_count
		_incoming_snapshot_chunks.clear()
	if chunk_count != _incoming_snapshot_chunk_count:
		return {}
	_incoming_snapshot_chunks[chunk_index] = payload
	if _incoming_snapshot_chunks.size() != chunk_count:
		return {}
	var compressed := PackedByteArray()
	for index: int in range(chunk_count):
		compressed.append_array(_incoming_snapshot_chunks[index])
	_incoming_snapshot_chunks.clear()
	var decoded := compressed.decompress_dynamic(MAX_SNAPSHOT_DECODED_BYTES, FileAccess.COMPRESSION_DEFLATE)
	if decoded.is_empty():
		return {}
	var state: Variant = bytes_to_var(decoded)
	return state if state is Dictionary else {}

func _apply_snapshot(state: Dictionary) -> void:
	var first_snapshot := not _started or int(state.round) != round_number
	_started = true
	round_number = int(state.round)
	phase = str(state.phase)
	phase_time_left = float(state.time)
	scores = state.scores.duplicate()
	winner_team = str(state.winner)
	var present: Dictionary[int, bool] = {}
	for player_state: Dictionary in state.players:
		var id := int(player_state.peer_id)
		present[id] = true
		if not players.has(id):
			_create_player(id, str(player_state.team), str(player_state.display_name))
		if players[id].reload_remaining <= 0.0 and float(player_state.reload_remaining) > 0.0:
			_play_reload(players[id])
		var new_shot := not first_snapshot and int(player_state.shot_sequence) > players[id].shot_sequence
		players[id].apply_snapshot(player_state, first_snapshot)
		# Wall impacts and close-range hits may leave no projectile in a 20 Hz snapshot.
		# The monotonic shot counter records accepted fire independently of bullet lifetime.
		if new_shot:
			_play_shot(player_state.position, str(player_state.last_shot_weapon), id)
	for id: int in players.keys():
		if not present.has(id):
			players[id].queue_free()
			players.erase(id)
	_sync_projectiles(state.projectiles)
	_sync_pickups(state.pickups)
	state_updated.emit()

func _sync_projectiles(states: Array) -> void:
	var present: Dictionary[int, bool] = {}
	for state: Dictionary in states:
		var id := int(state.id)
		present[id] = true
		if not projectiles.has(id):
			var fresh := ProjectileScene.instantiate() as PvpProjectile
			projectile_root.add_child(fresh)
			fresh.projectile_id = id
			fresh.shooter_id = int(state.shooter)
			fresh.shooter_team = str(state.team)
			fresh.weapon = str(state.weapon)
			projectiles[id] = fresh
		var projectile: PvpProjectile = projectiles[id]
		projectile.global_position = state.position
		projectile.direction = state.direction
		projectile.rotation = projectile.direction.angle()
	for id: int in projectiles.keys():
		if not present.has(id):
			projectiles[id].queue_free()
			projectiles.erase(id)

func _sync_pickups(states: Array) -> void:
	var present: Dictionary[int, bool] = {}
	for state: Dictionary in states:
		var id := int(state.id)
		present[id] = true
		if not pickups.has(id):
			var pickup := PickupScene.instantiate() as PvpWeaponPickup
			pickup_root.add_child(pickup)
			pickup.configure(id, str(state.weapon), state.ammunition, state.position)
			pickups[id] = pickup
	for id: int in pickups.keys():
		if not present.has(id):
			pickups[id].queue_free()
			pickups.erase(id)

func _announce(title: String, detail: String) -> void:
	round_announced.emit(title)
	if not disable_presentation:
		hud.show_banner(title, detail)
	if not _offline:
		for id: int in players:
			if id != _local_peer_id and net_manager.is_peer_send_ready(id):
				_rpc_announce.rpc_id(id, _session_id, title, detail)

@rpc("authority", "call_remote", "reliable", 0)
func _rpc_announce(session: int, title: String, detail: String) -> void:
	if session == _session_id and not disable_presentation:
		hud.show_banner(title, detail)

func _feedback(id: int, message: String) -> void:
	if id == _local_peer_id:
		_message = message
		if not disable_presentation:
			hud.show_banner(message, "")
	elif not _offline:
		_rpc_feedback.rpc_id(id, _session_id, message)

@rpc("authority", "call_remote", "reliable", 0)
func _rpc_feedback(session: int, message: String) -> void:
	if session == _session_id and not disable_presentation:
		hud.show_banner(message, "")

func _show_kill(killer: String, victim: String, weapon: String, headshot: bool) -> void:
	kill_feed.emit(killer, victim, headshot)
	if not disable_presentation:
		hud.add_kill_feed(killer, victim, weapon, headshot)

@rpc("authority", "call_remote", "reliable", 0)
func _rpc_kill(session: int, killer: String, victim: String, weapon: String, headshot: bool) -> void:
	if session == _session_id:
		_show_kill(killer, victim, weapon, headshot)

func _play_shot(origin: Vector2, weapon: String, shooter_id: int) -> void:
	shot_presented.emit(shooter_id, weapon)
	if disable_presentation or local_player == null or local_player.global_position.distance_to(origin) > 650.0:
		return
	if players.has(shooter_id):
		players[shooter_id].play_fire_effect(weapon)
	var sound: AudioStreamPlayer2D = $AKSound if weapon == "ak" else $DeagleSound
	sound.global_position = origin
	sound.play()

func _refresh_hud() -> void:
	if disable_presentation:
		return
	var states: Array[Dictionary] = []
	for player: PvpPlayer in players.values():
		states.append(player.serialize())
	var nearby := ""
	if local_player != null and local_player.alive:
		var pickup := _find_nearby_pickup(local_player)
		if pickup != null:
			nearby = pickup.weapon
	var can_buy: bool = local_player != null and local_player.alive and phase == "buy" and map.is_in_buy_zone(local_player.global_position, local_player.team)
	hud.update_match_state({"phase": phase, "phase_time_left": phase_time_left,
		"round_number": round_number, "scores": scores, "winner_team": winner_team,
		"local_peer_id": _local_peer_id, "players": states,
		"local_player": local_player.serialize() if local_player != null else {},
		"buy_allowed": can_buy, "nearby_weapon": nearby,
		"callout": map.get_callout(local_player.global_position) if local_player != null else "加载中",
		"training_preview": training_preview, "message": _message})

func _on_connection_state_changed(state: int) -> void:
	if _leaving:
		return
	if state == NetManagerStore.ConnectionState.IN_GAME and _host:
		activate_runtime()
	elif state == NetManagerStore.ConnectionState.DISCONNECTED:
		phase = "match_end"
		phase_time_left = 0.0
		_started = false
		if not disable_presentation:
			hud.show_banner("连接已断开", "请返回大厅重新加入房间")
		_refresh_hud()

func _on_player_left(id: int) -> void:
	if not players.has(id) or _leaving:
		return
	var departing: PvpPlayer = players[id]
	players.erase(id)
	departing.queue_free()
	_input_queue.erase(id)
	if not _host:
		return
	var ct_count := 0
	var t_count := 0
	for player: PvpPlayer in players.values():
		if player.team == "CT":
			ct_count += 1
		else:
			t_count += 1
	if ct_count == 0 or t_count == 0:
		phase = "match_end"
		phase_time_left = 0.0
		winner_team = "T" if ct_count == 0 else "CT"
		_announce("%s 获胜 · 对方已离场" % winner_team, "返回大厅开始下一场比赛")
	else:
		_check_elimination()
	_broadcast_snapshot()

func leave_match() -> void:
	if _leaving:
		return
	_leaving = true
	_clear_projectiles()
	var lease := PublicRoomLeaseStore.get_autoload_instance()
	if lease != null:
		await lease.release_current_and_wait(&"mirage_pvp_return_to_lobby")
	if not is_inside_tree():
		return
	if net_manager.is_multiplayer_active():
		net_manager.disconnect_from_game()
	get_tree().change_scene_to_file(LOBBY_PATH)

func _clear_projectiles() -> void:
	for projectile: PvpProjectile in projectiles.values():
		projectile.queue_free()
	projectiles.clear()

func _clear_pickups() -> void:
	for pickup: PvpWeaponPickup in pickups.values():
		pickup.queue_free()
	pickups.clear()
