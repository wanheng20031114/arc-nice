extends SceneTree

const TANGO_SCENE := preload("res://scene/player/tango/player_tango.tscn")
const FIELD_SCENE := preload(
	"res://scene/player/tango/tango_electric_surge_field.tscn"
)
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")


class HostNetManagerStub:
	extends Node

	func is_host() -> bool:
		return true

	func is_client() -> bool:
		return false

	func get_local_peer_id() -> int:
		return 7

	func get_host_peer_id() -> int:
		return 7


class RecordingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var sent_methods: Array[StringName] = []
	var sent_arguments: Array[Array] = []
	var ownerless_visual_spawns: Array[Dictionary] = []

	func _ready() -> void:
		set_process(false)
		set_physics_process(false)

	func _exit_tree() -> void:
		pass

	func _rpc_to_connected_clients(
		method_name: StringName,
		args: Array = []
	) -> void:
		sent_methods.append(method_name)
		sent_arguments.append(args.duplicate(true))

	func clear_recording() -> void:
		sent_methods.clear()
		sent_arguments.clear()

	func spawn_remote_tango_electric_surge_visual_field(
		activation_id: int,
		origin: Vector2,
		remaining_seconds: float
	) -> bool:
		ownerless_visual_spawns.append({
			"activation_id": activation_id,
			"origin": origin,
			"remaining_seconds": remaining_seconds,
		})
		var spawn_parent := get_tree().current_scene
		if spawn_parent == null:
			return false
		var field := FIELD_SCENE.instantiate() as TangoElectricSurgeField
		if field == null:
			return false
		spawn_parent.add_child(field)
		field.global_position = origin
		field.setup_multiplayer_visual_only(activation_id, remaining_seconds)
		return true


var failures: Array[String] = []
var fixture: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "TangoElectricSurgeNetworkFixture"
	root.add_child(fixture)
	current_scene = fixture

	await _test_host_authority_and_auto_barrage()
	await _test_client_recovery_visual()
	_test_passive_aim_input_send_gate()

	fixture.queue_free()
	await process_frame
	if failures.is_empty():
		print("TANGO_ELECTRIC_SURGE_NETWORK_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_host_authority_and_auto_barrage() -> void:
	var player := TANGO_SCENE.instantiate() as PlayerTango
	player.peer_id = 7
	fixture.add_child(player)
	await process_frame
	player.set_process(false)
	player.set_physics_process(false)
	player.skill1_charge = player.skill1_charge_duration
	player.global_position = Vector2(120.0, 76.0)

	var game := Game.new()
	game.peer_players[7] = player
	var mp_game := RecordingMpGame.new()
	var host_net := HostNetManagerStub.new()
	var keepalive := HTTPRequest.new()
	keepalive.name = "PublicRoomKeepaliveRequest"
	mp_game.add_child(host_net)
	mp_game.add_child(keepalive)
	mp_game.set("net_manager", host_net)
	mp_game.set("game", game)
	fixture.add_child(mp_game)
	await process_frame
	mp_game.set("net_manager", host_net)

	var old_charge_accepted := bool(mp_game.call(
		"_apply_authoritative_tango_charge_started",
		7,
		Vector2.LEFT,
		1
	))
	var active_charges := mp_game.get("_active_tango_charges_by_peer") as Dictionary
	_expect(
		old_charge_accepted
		and active_charges.has(7)
		and mp_game.sent_methods == [&"net_tango_charge_started"],
		"技能接管测试必须先建立一个Host认可的普通充能。"
	)
	mp_game.clear_recording()
	var accepted := bool(mp_game.call(
		"_apply_authoritative_tango_electric_surge_request",
		7,
		1
	))
	var records := mp_game.get(
		"_active_tango_electric_surges_by_peer"
	) as Dictionary
	_expect(
		accepted
		and player.is_electric_surge_active()
		and player.is_electric_surge_auto_fire_active()
		and player.is_tango_barrage_active()
		and is_equal_approx(player.get_tango_release_ratio(), 1.0)
		and player.get_tango_barrage_damage() == 15
		and player.electric_surge_audio.playing
		and is_zero_approx(player.skill1_charge)
		and records.has(7)
		and active_charges.is_empty()
		and int((mp_game.get("_tango_charge_sequences_by_peer") as Dictionary).get(7, 0)) == 2
		and mp_game.sent_methods == [
			&"net_tango_charge_cancelled",
			&"net_tango_electric_surge_started",
		],
		"Host必须终止旧充能、分配独立弹幕序列，并让技能直接进入满充自动射击。"
	)
	if mp_game.sent_arguments.size() >= 2:
		var cancel_payload := mp_game.sent_arguments[0]
		var payload := mp_game.sent_arguments[1]
		_expect(
			int(cancel_payload[0]) == 7
			and int(cancel_payload[1]) == 1
			and int(cancel_payload[2]) == 1
			and int(payload[0]) == 7
			and int(payload[1]) == 1
			and payload[2] == Vector2(120.0, 76.0)
			and is_equal_approx(float(payload[3]), 8.0)
			and is_finite(float(payload[4]))
			and bool(payload[5])
			and int(payload[6]) == 1
			and int(payload[7]) == 2,
			"旧充能终端必须先送达，开始包随后携带Host位置、剩余8秒与绑定的自动弹幕序列。"
		)
	_expect(
		not bool(mp_game.call(
			"_apply_authoritative_tango_electric_surge_request", 7, 1
		))
		and not bool(mp_game.call(
			"_apply_authoritative_tango_electric_surge_request", 7, 2
		)),
		"重复请求与尚未结束时的二次激活都必须被Host拒绝。"
	)

	var host_field := _find_field(true, 1)
	_expect(
		host_field != null
		and host_field.global_position == Vector2(120.0, 76.0),
		"Host场域必须在Tango激活瞬间的位置生成。"
	)
	player.global_position = Vector2(280.0, 140.0)
	_expect(
		host_field != null
		and host_field.global_position == Vector2(120.0, 76.0),
		"玩家移动后电涌场域不得跟随。"
	)

	mp_game.clear_recording()
	mp_game.call("_clear_peer_network_state", 7)
	_expect(
		records.has(7)
		and host_field != null
		and host_field.is_active()
		and mp_game.sent_methods.is_empty(),
		"施术者断线只能清理玩家状态；固定场域roster必须保留到场域自然结束。"
	)
	mp_game.call("_finish_authoritative_tango_electric_surge", 7, 1)
	var surge_sequences := mp_game.get(
		"_tango_electric_surge_sequences_by_peer"
	) as Dictionary
	var surge_request_ids := mp_game.get(
		"_last_tango_electric_surge_request_ids"
	) as Dictionary
	_expect(
		not records.has(7)
		and not surge_sequences.has(7)
		and not surge_request_ids.has(7)
		and mp_game.sent_methods == [&"net_tango_electric_surge_finished"],
		"断线施术者的场域结束后必须O(1)清理roster与序列守卫并可靠广播。"
	)
	if host_field != null and is_instance_valid(host_field):
		host_field.finish()
	player.queue_free()
	await process_frame
	mp_game.queue_free()
	game.free()


func _test_client_recovery_visual() -> void:
	var remote_player := TANGO_SCENE.instantiate() as PlayerTango
	remote_player.peer_id = 7
	fixture.add_child(remote_player)
	await process_frame
	remote_player.set_process(false)
	remote_player.set_physics_process(false)

	var game := Game.new()
	game.peer_players[7] = remote_player
	var mp_game := RecordingMpGame.new()
	var keepalive := HTTPRequest.new()
	keepalive.name = "PublicRoomKeepaliveRequest"
	mp_game.add_child(keepalive)
	mp_game.set("game", game)
	fixture.add_child(mp_game)
	await process_frame
	var host_now := float(mp_game.call("_get_net_time"))
	mp_game.call(
		"net_tango_electric_surge_started",
		7,
		5,
		Vector2(44.0, 88.0),
		5.0,
		host_now,
		true,
		11,
		42
	)
	var remaining := remote_player.get_electric_surge_remaining_seconds()
	var visual_field := _find_field(false, 5)
	_expect(
		remote_player.is_electric_surge_active()
		and remote_player.is_electric_surge_auto_fire_active()
		and remote_player.is_tango_barrage_active()
		and is_equal_approx(remote_player.get_tango_release_ratio(), 1.0)
		and not remote_player.electric_surge_audio.playing
		and not bool(mp_game.get("_has_host_time_offset"))
		and remaining > 4.7
		and remaining <= 5.3
		and visual_field != null
		and not visual_field.monitoring
		and visual_field.collision_mask == 0
		and visual_field.global_position == Vector2(44.0, 88.0),
		(
			"无时钟样本的恢复客户端必须采用Host剩余约5秒、不重放施法音，且不得污染时钟偏移。"
			+ " active=%s remaining=%.3f field=%s valid=%s records=%s"
			% [
				remote_player.is_electric_surge_active(),
				remaining,
				visual_field,
				mp_game.call("_is_valid_tango_player", remote_player),
				mp_game.get("_active_tango_electric_surges_by_peer"),
			]
		)
	)
	var visual_count_before_duplicate := _count_fields(false, 5)
	mp_game.call(
		"net_tango_electric_surge_started",
		7,
		5,
		Vector2(400.0, 400.0),
		7.0,
		host_now,
		true,
		11,
		42
	)
	_expect(
		_count_fields(false, 5) == visual_count_before_duplicate
		and visual_field != null
		and visual_field.global_position == Vector2(44.0, 88.0),
		"同一激活序列的重复/乱序恢复包不得延长时间或复制场域。"
	)

	mp_game.call("net_tango_electric_surge_finished", 7, 5)
	_expect(
		not remote_player.is_electric_surge_active()
		and not remote_player.is_electric_surge_auto_fire_active()
		and int((mp_game.get("_tango_charge_sequences_by_peer") as Dictionary).get(7, 0)) == 42
		and visual_field != null
		and visual_field.is_active(),
		"结束事件应清理玩家强化；独立场域视觉按自身剩余时长完成。"
	)
	var state_after_finish := remote_player.get_tango_casting_state()
	remote_player.apply_remote_tango_barrage_snapshot(
		Vector2.LEFT,
		1.0,
		42,
		0.1
	)
	_expect(
		remote_player.get_tango_casting_state() == state_after_finish,
		"可靠结束先到时，绑定序列的迟到尾批不得重新拉起已结束的自动弹幕炮位。"
	)
	remote_player.apply_remote_tango_barrage_snapshot(
		Vector2.UP,
		1.0,
		43,
		0.1
	)
	_expect(
		remote_player.get_tango_casting_state() == PlayerTango.CastingState.FIRING,
		"结束水位只能拒绝旧自动序列，后续合法普通弹幕序列仍必须可恢复。"
	)
	remote_player.call("_reset_tango_combat_state", true)
	mp_game.call(
		"net_tango_electric_surge_started",
		7,
		6,
		Vector2.ZERO,
		9.0,
		host_now,
		true,
		12,
		43
	)
	_expect(
		not remote_player.is_electric_surge_active(),
		"客户端必须拒绝超过8秒的畸形电涌剩余时间。"
	)
	remote_player.is_dead = true
	mp_game.call(
		"net_tango_electric_surge_started",
		7,
		7,
		Vector2(9.0, 13.0),
		8.0,
		host_now,
		false,
		13,
		44
	)
	var dead_owner_visual := _find_field(false, 7)
	_expect(
		not remote_player.is_electric_surge_active()
		and dead_owner_visual != null
		and dead_owner_visual.global_position == Vector2(9.0, 13.0),
		"中途加入时即使施术者已死亡，也必须恢复仍独立存在的固定场域视觉。"
	)
	remote_player.is_dead = false
	var dead_owner_visual_count := _count_fields(false, 7)
	mp_game.call(
		"net_tango_electric_surge_started",
		7,
		7,
		Vector2(9.0, 13.0),
		6.0,
		host_now,
		false,
		13,
		44
	)
	_expect(
		not remote_player.is_electric_surge_active()
		and _count_fields(false, 7) == dead_owner_visual_count,
		"场域仍在但Host强化已结束时，复活/重建的Tango不得恢复强化或复制视觉。"
	)
	mp_game.call(
		"net_tango_electric_surge_started",
		19,
		1,
		Vector2(31.0, 47.0),
		4.0,
		host_now,
		false,
		1,
		1
	)
	_expect(
		mp_game.ownerless_visual_spawns.size() == 3
		and int(mp_game.ownerless_visual_spawns[2].get("activation_id", 0)) == 1
		and mp_game.ownerless_visual_spawns[2].get("origin") == Vector2(31.0, 47.0)
		and is_equal_approx(
			float(mp_game.ownerless_visual_spawns[2].get("remaining_seconds", 0.0)),
			4.0
		),
		"施术者已断线或尚未重建时，恢复包仍必须独立生成固定场域视觉。"
	)
	mp_game.call("net_tango_electric_surge_finished", 19, 1)
	var recovery_records := mp_game.get(
		"_active_tango_electric_surges_by_peer"
	) as Dictionary
	var recovery_sequences := mp_game.get(
		"_tango_electric_surge_sequences_by_peer"
	) as Dictionary
	var recovery_seen := mp_game.get(
		"_last_tango_electric_surge_seen_by_peer"
	) as Dictionary
	_expect(
		not recovery_records.has(19)
		and not recovery_sequences.has(19)
		and not recovery_seen.has(19),
		"ownerless恢复场域结束后必须清理本地peer序列守卫，允许peer ID安全复用。"
	)
	if visual_field != null and is_instance_valid(visual_field):
		visual_field.finish()
	if dead_owner_visual != null and is_instance_valid(dead_owner_visual):
		dead_owner_visual.finish()
	remote_player.queue_free()
	await process_frame
	mp_game.queue_free()
	game.free()


func _test_passive_aim_input_send_gate() -> void:
	var mp_game := RecordingMpGame.new()
	var steady_directions: Array[Vector2] = []
	for _frame_index in range(480):
		steady_directions.append(Vector2.RIGHT)
	var legacy_active_frames := _simulate_input_send_frames(
		mp_game,
		steady_directions,
		false
	)
	var passive_frames := _simulate_input_send_frames(
		mp_game,
		steady_directions,
		true
	)
	_expect(
		legacy_active_frames.size() == 480
		and passive_frames.size() == 80
		and passive_frames.front() == 0
		and passive_frames.back() == 474,
		(
			"A/B：固定8秒方向下，主动输入必须保持480包；Tango被动瞄准必须"
			+ "降为首帧加每6帧保活的80包。"
		)
	)
	print(
		"TANGO_PASSIVE_AIM_INPUT_AB baseline_packets=",
		legacy_active_frames.size(),
		" optimized_packets=",
		passive_frames.size(),
		" reduction_percent=83.333"
	)

	var changed_directions: Array[Vector2] = []
	for frame_index in range(12):
		if frame_index <= 7:
			changed_directions.append(Vector2.RIGHT)
		elif frame_index == 8:
			changed_directions.append(Vector2.UP)
		else:
			changed_directions.append(Vector2.ZERO)
	var changed_frames := _simulate_input_send_frames(
		mp_game,
		changed_directions,
		true
	)
	_expect(
		changed_frames == [0, 6, 8, 9],
		"被动瞄准必须在方向变化与归零当帧发送，同时保留6帧静态保活。"
	)
	_expect(
		bool(mp_game.call(
			"_is_client_input_state_active",
			Vector2.RIGHT,
			Vector2.RIGHT,
			Vector2.ZERO,
			true
		)),
		"移动输入必须继续保持active_input_state，即使Tango同时处于被动瞄准。"
	)
	mp_game.free()


func _simulate_input_send_frames(
	mp_game: RecordingMpGame,
	directions: Array[Vector2],
	uses_passive_tango_mouse_aim: bool
) -> Array[int]:
	var sent_frames: Array[int] = []
	var has_sent := false
	var last_direction := Vector2.ZERO
	var frames_since_last_send := NET_CONSTANTS.INPUT_KEEPALIVE_INTERVAL_FRAMES
	for frame_index in directions.size():
		frames_since_last_send += 1
		var direction := directions[frame_index]
		var input_changed := not has_sent or direction != last_direction
		var keepalive_due := (
			frames_since_last_send >= NET_CONSTANTS.INPUT_KEEPALIVE_INTERVAL_FRAMES
		)
		var active := bool(mp_game.call(
			"_is_client_input_state_active",
			Vector2.ZERO,
			direction,
			Vector2.ZERO,
			uses_passive_tango_mouse_aim
		))
		if not input_changed and not keepalive_due and not active:
			continue
		sent_frames.append(frame_index)
		has_sent = true
		last_direction = direction
		frames_since_last_send = 0
	return sent_frames


func _find_field(authoritative: bool, zone_id: int) -> TangoElectricSurgeField:
	for child in fixture.get_children():
		var field := child as TangoElectricSurgeField
		if (
			field != null
			and field.is_authoritative() == authoritative
			and field.zone_id == zone_id
		):
			return field
	return null


func _count_fields(authoritative: bool, zone_id: int) -> int:
	var count := 0
	for child in fixture.get_children():
		var field := child as TangoElectricSurgeField
		if (
			field != null
			and field.is_authoritative() == authoritative
			and field.zone_id == zone_id
		):
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
