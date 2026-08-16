extends Node
class_name MpNetworkDiagnosticsCoordinator

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MultiplayerRuntimeMetricsScript := preload(
	"res://scene/multiplayer/multiplayer_runtime_metrics.gd"
)
const SNAPSHOT_PACKET_WARN_BYTES := 1200
const SNAPSHOT_PACKET_WARN_INTERVAL_SECONDS := 5.0
const RPC_PAYLOAD_DIAGNOSTIC_SAMPLE_INTERVAL := 64
const TRANSACTION_RPC_METHODS := {
	&"net_inventory_snapshot": true,
	&"net_inventory_item_used": true,
	&"net_inventory_item_discarded": true,
	&"net_simple_crafting_result": true,
	&"net_pickup_collected": true,
	&"net_upgrade_confirmed": true,
	&"net_skill1_purchase_confirmed": true,
	&"net_luoxi_collectible_confirmed": true,
	&"net_luoxi_collectible_offer_state": true,
	&"net_luoxi_collectible_refresh_confirmed": true,
	&"net_luoxi_special_game_started": true,
	&"net_luoxi_special_game_card_revealed": true,
	&"net_luoxi_special_game_finished": true,
	&"net_warehouse_command_result": true,
	&"net_warehouse_storage_snapshot_batch": true,
	&"net_production_command_result": true,
	&"net_production_state_batch": true,
	&"net_research_command_result": true,
	&"net_research_state_updated": true,
	&"net_cheat_xirang_confirmed": true,
	&"net_debug_collectible_granted": true,
}
const FEEDBACK_RPC_METHODS := {
	&"net_collectible_visual_effect": true,
	&"net_collectible_follow_visual_effect": true,
	&"net_enemy_damage_feedback_batch": true,
	&"net_enemy_damage_applied": true,
	&"net_tiyi_high_noon_targets": true,
	&"net_enemy_action": true,
	&"net_enemy_target_action": true,
	&"net_enemy_lightning_chain": true,
	&"net_plant_health_batch": true,
	&"net_tower_defense_wave_progress_changed": true,
}
const AUTH_RPC_METHODS := {
	&"net_tower_rogue_exploration_snapshot": true,
	&"net_request_route_full_snapshot": true,
	&"net_route_upgrade_requested": true,
	&"net_route_full_snapshot": true,
	&"net_route_move_delta": true,
	&"net_route_briefing_state": true,
	&"net_route_briefing_cover_ready": true,
	&"net_route_encounter_intro_ack": true,
	&"net_route_encounter_vote": true,
	&"net_route_encounter_result_ack": true,
	&"net_route_encounter_snapshot": true,
	&"net_shop_purchase_request": true,
	&"net_shop_sell_request": true,
	&"net_shop_exit_ack": true,
	&"net_shop_snapshot": true,
	&"net_route_avatar_corrected": true,
}

var _snapshot_packet_warn_time_left := 0.0
var _max_player_snapshot_packet_bytes := 0
var _max_enemy_snapshot_packet_bytes := 0
var _large_player_snapshot_packet_count := 0
var _large_enemy_snapshot_packet_count := 0
var _enemy_snapshot_payload_bytes_total := 0
var _enemy_snapshot_packet_count := 0
var _rpc_payload_diagnostics_enabled := false
var _rpc_payload_call_counts: Dictionary[StringName, int] = {}
var _rpc_payload_sample_bytes: Dictionary[StringName, int] = {}
var _rpc_payload_sample_count := 0
var _player_input_rejection_counts: Dictionary[StringName, int] = {}
var _player_input_rejection_total := 0
var _runtime_network_metrics = MultiplayerRuntimeMetricsScript.new(
	_NetConstants.CHANNEL_COUNT
)


func record_outbound_rpc(
	method_name: StringName,
	args: Array,
	packet_count: int = 1
) -> void:
	if packet_count <= 0:
		return
	var channel := get_rpc_traffic_channel(method_name)
	# Packet counts remain exact in production. Payload byte diagnostics are opt-in
	# because serializing live RPC arguments here would duplicate Godot's real RPC
	# serialization work. When enabled, one sample per method is refreshed every
	# fixed number of calls and reused as an explicitly approximate byte estimate.
	if not _rpc_payload_diagnostics_enabled:
		_runtime_network_metrics.record_packet(channel, 0, packet_count)
		return
	var call_count := int(_rpc_payload_call_counts.get(method_name, 0)) + 1
	_rpc_payload_call_counts[method_name] = call_count
	if (
		not _rpc_payload_sample_bytes.has(method_name)
		or call_count % RPC_PAYLOAD_DIAGNOSTIC_SAMPLE_INTERVAL == 0
	):
		_rpc_payload_sample_bytes[method_name] = var_to_bytes(args).size() + 16
		_rpc_payload_sample_count += 1
	var payload_bytes := int(_rpc_payload_sample_bytes.get(method_name, 0))
	_runtime_network_metrics.record_packet(
		channel,
		payload_bytes,
		packet_count
	)


func set_rpc_payload_diagnostics_enabled(enabled: bool) -> void:
	if _rpc_payload_diagnostics_enabled == enabled:
		return
	_rpc_payload_diagnostics_enabled = enabled
	_rpc_payload_call_counts.clear()
	_rpc_payload_sample_bytes.clear()
	_rpc_payload_sample_count = 0


static func get_rpc_traffic_channel(method_name: StringName) -> int:
	if method_name == &"net_route_avatar_input":
		return _NetConstants.CH_INPUT
	if method_name == &"net_route_avatar_snapshot":
		return _NetConstants.CH_PLAYER_STATE
	if AUTH_RPC_METHODS.has(method_name):
		return _NetConstants.CH_AUTH
	if (
		method_name == &"net_projectile_fired"
		or method_name == &"net_tango_laser_volley"
		or method_name == &"net_linglan_skill1_ring_batch"
		or method_name == &"net_plant_projectile_visual"
		or method_name == &"net_corn_machine_gun_burst_batch"
		or method_name == &"net_tiyi_sniper_hit_confirmed"
	):
		return _NetConstants.CH_PROJECTILE
	if TRANSACTION_RPC_METHODS.has(method_name):
		return _NetConstants.CH_TRANSACTION
	if FEEDBACK_RPC_METHODS.has(method_name):
		return _NetConstants.CH_FEEDBACK
	return _NetConstants.CH_WORLD_EVENT


func update_snapshot_packet_warning_timer(delta: float) -> void:
	_snapshot_packet_warn_time_left = maxf(
		_snapshot_packet_warn_time_left - delta,
		0.0
	)


func record_snapshot_packet_size(
	snapshot_type: StringName,
	packet_bytes: int,
	entity_count: int
) -> void:
	if snapshot_type == &"player":
		_runtime_network_metrics.record_packet(
			_NetConstants.CH_PLAYER_STATE,
			packet_bytes + 16
		)
		_max_player_snapshot_packet_bytes = maxi(
			_max_player_snapshot_packet_bytes,
			packet_bytes
		)
		if packet_bytes <= SNAPSHOT_PACKET_WARN_BYTES:
			return
		_large_player_snapshot_packet_count += 1
	elif snapshot_type == &"enemy":
		_runtime_network_metrics.record_packet(
			_NetConstants.CH_ENEMY_STATE,
			packet_bytes + 24
		)
		_max_enemy_snapshot_packet_bytes = maxi(
			_max_enemy_snapshot_packet_bytes,
			packet_bytes
		)
		_enemy_snapshot_payload_bytes_total += packet_bytes
		_enemy_snapshot_packet_count += 1
		if packet_bytes <= SNAPSHOT_PACKET_WARN_BYTES:
			return
		_large_enemy_snapshot_packet_count += 1
	else:
		return
	if _snapshot_packet_warn_time_left > 0.0:
		return
	_snapshot_packet_warn_time_left = SNAPSHOT_PACKET_WARN_INTERVAL_SECONDS
	if is_inside_tree():
		push_warning(
			"MpGame: %s snapshot packet is %d bytes for %d entities; monitor bandwidth under latency/loss."
			% [String(snapshot_type), packet_bytes, entity_count]
		)


func record_state_repair() -> void:
	_runtime_network_metrics.record_state_repair()


func record_transaction_latency_ms(latency_ms: float) -> void:
	_runtime_network_metrics.record_transaction_latency_ms(latency_ms)


## 输入拒绝按原因聚合到会话诊断；不记录完整载荷，避免诊断本身泄露或放大流量。
func record_player_input_rejection(reason: StringName) -> void:
	if reason == &"":
		return
	_player_input_rejection_counts[reason] = int(
		_player_input_rejection_counts.get(reason, 0)
	) + 1
	_player_input_rejection_total += 1


func get_snapshot_packet_metrics(
	player_snapshot_encode_count: int,
	player_snapshot_cohort_size: int,
	enemy_metrics: Dictionary,
	pool_metrics: Dictionary
) -> Dictionary:
	var runtime_metrics := _runtime_network_metrics.get_summary()
	return {
		"max_player_snapshot_packet_bytes": _max_player_snapshot_packet_bytes,
		"max_enemy_snapshot_packet_bytes": _max_enemy_snapshot_packet_bytes,
		"large_player_snapshot_packet_count": _large_player_snapshot_packet_count,
		"large_enemy_snapshot_packet_count": _large_enemy_snapshot_packet_count,
		"enemy_snapshot_payload_bytes_total": _enemy_snapshot_payload_bytes_total,
		"enemy_snapshot_packet_count": _enemy_snapshot_packet_count,
		"enemy_snapshot_batch_count": int(
			enemy_metrics.get("enemy_snapshot_batch_count", 0)
		),
		"player_snapshot_encode_count": player_snapshot_encode_count,
		"enemy_snapshot_chunk_encode_count": int(
			enemy_metrics.get("enemy_snapshot_chunk_encode_count", 0)
		),
		"player_snapshot_cohort_size": player_snapshot_cohort_size,
		"enemy_snapshot_cohort_size": int(
			enemy_metrics.get("enemy_snapshot_cohort_size", 0)
		),
		"enemy_snapshot_completed_batch_count": int(
			enemy_metrics.get("enemy_snapshot_completed_batch_count", 0)
		),
		"enemy_snapshot_incomplete_batch_evict_count": int(
			enemy_metrics.get("enemy_snapshot_incomplete_batch_evict_count", 0)
		),
		"enemy_snapshot_stale_chunk_count": int(
			enemy_metrics.get("enemy_snapshot_stale_chunk_count", 0)
		),
		"offscreen_enemy_proxy_count": int(
			enemy_metrics.get("offscreen_enemy_proxy_count", 0)
		),
		"rpc_payload_diagnostics_enabled": _rpc_payload_diagnostics_enabled,
		"rpc_payload_diagnostic_sample_interval": RPC_PAYLOAD_DIAGNOSTIC_SAMPLE_INTERVAL,
		"rpc_payload_diagnostic_sample_count": _rpc_payload_sample_count,
		"channel_metrics": runtime_metrics.get("channels", []),
		"state_repair_count": runtime_metrics.get("state_repair_count", 0),
		"transaction_latency_sample_count": runtime_metrics.get(
			"transaction_latency_sample_count",
			0
		),
		"transaction_latency_p95_ms": runtime_metrics.get(
			"transaction_latency_p95_ms",
			0.0
		),
		"player_input_rejection_total": _player_input_rejection_total,
		"player_input_rejection_counts": (
			_player_input_rejection_counts.duplicate()
		),
		"pool_metrics": pool_metrics,
	}


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	# All diagnostics are session aggregates. A peer departure intentionally does
	# not erase packets already sent to or received from that peer.


func reset_session_state() -> void:
	_snapshot_packet_warn_time_left = 0.0
	_max_player_snapshot_packet_bytes = 0
	_max_enemy_snapshot_packet_bytes = 0
	_large_player_snapshot_packet_count = 0
	_large_enemy_snapshot_packet_count = 0
	_enemy_snapshot_payload_bytes_total = 0
	_enemy_snapshot_packet_count = 0
	_rpc_payload_diagnostics_enabled = false
	_rpc_payload_call_counts.clear()
	_rpc_payload_sample_bytes.clear()
	_rpc_payload_sample_count = 0
	_player_input_rejection_counts.clear()
	_player_input_rejection_total = 0
	_runtime_network_metrics.reset(_NetConstants.CHANNEL_COUNT)
