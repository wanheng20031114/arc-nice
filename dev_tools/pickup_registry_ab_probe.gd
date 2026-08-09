extends SceneTree

const HEALTH_PICKUP := preload(
	"res://resources/config/consumables/healing_potion.tres"
)
const SAMPLE_COUNT := 21
const EVENTS_PER_SAMPLE := 4096
const ARM_ARGUMENT_PREFIX := "--arm="


class LegacyPickupLifecycle:
	extends RefCounted

	var pickup_index: Dictionary = {}
	var pending_exit_ids: Dictionary = {}
	var gameplay_gateway: MultiplayerGameplayGateway

	func _init(gateway: MultiplayerGameplayGateway) -> void:
		gameplay_gateway = gateway

	func consume(
		pickup: Pickup,
		collector_peer_id: int,
		applied_immediately: bool
	) -> void:
		var net_id := int(pickup.get_meta("net_id", 0))
		if net_id <= 0:
			return
		if not mark_removed(net_id, true):
			return
		gameplay_gateway.pickup_collected.emit(
			net_id,
			collector_peer_id,
			pickup.config,
			applied_immediately
		)

	func tree_exited(net_id: int) -> void:
		mark_removed(net_id)

	func mark_removed(
		net_id: int,
		suppress_next_tree_exit: bool = false
	) -> bool:
		if net_id <= 0:
			return false
		if suppress_next_tree_exit:
			if pending_exit_ids.has(net_id):
				return false
			pending_exit_ids[net_id] = true
		elif pending_exit_ids.erase(net_id):
			return false
		pickup_index.erase(net_id)
		gameplay_gateway.pickup_removed.emit(net_id)
		return true


var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var requested_arm := _get_requested_arm()
	if not requested_arm.is_empty():
		_run_isolated_arm(requested_arm)
		return
	_run_comparison()


func _run_comparison() -> void:
	var pickup := Pickup.new()
	pickup.config = HEALTH_PICKUP
	var legacy_samples: Array[int] = []
	var extracted_samples: Array[int] = []
	var legacy_trajectory_hash := 0
	var extracted_trajectory_hash := 0
	_warm_up_arm(pickup, "legacy")
	_warm_up_arm(pickup, "extracted")
	for sample_index in range(SAMPLE_COUNT):
		if sample_index % 2 == 0:
			legacy_trajectory_hash ^= _measure_legacy(pickup, legacy_samples)
			extracted_trajectory_hash ^= _measure_extracted(
				pickup,
				extracted_samples
			)
		else:
			extracted_trajectory_hash ^= _measure_extracted(
				pickup,
				extracted_samples
			)
			legacy_trajectory_hash ^= _measure_legacy(pickup, legacy_samples)
	legacy_samples.sort()
	extracted_samples.sort()
	var p50_index := _get_nearest_rank_index(legacy_samples.size(), 0.50)
	var p95_index := _get_nearest_rank_index(legacy_samples.size(), 0.95)
	var legacy_p50 := legacy_samples[p50_index]
	var extracted_p50 := extracted_samples[p50_index]
	var legacy_p95 := legacy_samples[p95_index]
	var extracted_p95 := extracted_samples[p95_index]
	_expect(
		legacy_trajectory_hash == extracted_trajectory_hash,
		"提取前后 Pickup 生命周期累计轨迹 hash 必须严格一致：legacy=%d extracted=%d。"
		% [legacy_trajectory_hash, extracted_trajectory_hash]
	)
	pickup.free()
	if failures.is_empty():
		print(
			"PICKUP_REGISTRY_AB_PROBE_OK legacy_p50_usec=%d extracted_p50_usec=%d legacy_p95_usec=%d extracted_p95_usec=%d legacy_trajectory_hash=%d extracted_trajectory_hash=%d"
			% [
				legacy_p50,
				extracted_p50,
				legacy_p95,
				extracted_p95,
				legacy_trajectory_hash,
				extracted_trajectory_hash,
			]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_isolated_arm(arm: String) -> void:
	if arm != "legacy" and arm != "extracted":
		push_error("未知 Pickup A/B arm：%s。" % arm)
		quit(1)
		return
	var pickup := Pickup.new()
	pickup.config = HEALTH_PICKUP
	var samples: Array[int] = []
	var trajectory_hash := 0
	_warm_up_arm(pickup, arm)
	for _sample_index in range(SAMPLE_COUNT):
		if arm == "legacy":
			trajectory_hash ^= _measure_legacy(pickup, samples)
		else:
			trajectory_hash ^= _measure_extracted(pickup, samples)
	samples.sort()
	var p50_usec := samples[_get_nearest_rank_index(samples.size(), 0.50)]
	var p95_usec := samples[_get_nearest_rank_index(samples.size(), 0.95)]
	pickup.free()
	if failures.is_empty():
		print(
			"PICKUP_REGISTRY_AB_ARM_OK arm=%s p50_usec=%d p95_usec=%d trajectory_hash=%d"
			% [arm, p50_usec, p95_usec, trajectory_hash]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _get_requested_arm() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(ARM_ARGUMENT_PREFIX):
			return argument.trim_prefix(ARM_ARGUMENT_PREFIX)
	return ""


func _warm_up_arm(pickup: Pickup, arm: String) -> void:
	var discarded_samples: Array[int] = []
	if arm == "legacy":
		_measure_legacy(pickup, discarded_samples)
	else:
		_measure_extracted(pickup, discarded_samples)


func _get_nearest_rank_index(sample_count: int, percentile: float) -> int:
	return clampi(ceili(float(sample_count) * percentile) - 1, 0, sample_count - 1)


func _measure_legacy(pickup: Pickup, samples: Array[int]) -> int:
	var gateway := MultiplayerGameplayGateway.new()
	var counts := {"removed": 0, "collected": 0}
	gateway.pickup_removed.connect(
		func(_net_id: int) -> void: counts["removed"] = int(counts["removed"]) + 1
	)
	gateway.pickup_collected.connect(
		func(_net_id: int, _peer: int, _config: PickupConfig, _applied: bool) -> void:
			counts["collected"] = int(counts["collected"]) + 1
	)
	var registry := LegacyPickupLifecycle.new(gateway)
	var started_at := Time.get_ticks_usec()
	for event_index in range(EVENTS_PER_SAMPLE):
		var net_id := event_index + 1
		pickup.set_meta("net_id", net_id)
		registry.pickup_index[net_id] = pickup
		registry.consume(pickup, 2, true)
		registry.tree_exited(net_id)
	samples.append(Time.get_ticks_usec() - started_at)
	var state_hash := hash([
		registry.pickup_index.size(),
		registry.pending_exit_ids.size(),
		int(counts["removed"]),
		int(counts["collected"]),
	])
	_expect(
		registry.pickup_index.is_empty()
		and registry.pending_exit_ids.is_empty()
		and int(counts["removed"]) == EVENTS_PER_SAMPLE
		and int(counts["collected"]) == EVENTS_PER_SAMPLE,
		"旧版 Pickup 对照轨迹不完整。"
	)
	gateway.free()
	return state_hash


func _measure_extracted(pickup: Pickup, samples: Array[int]) -> int:
	var gateway := MultiplayerGameplayGateway.new()
	var counts := {"removed": 0, "collected": 0}
	gateway.pickup_removed.connect(
		func(_net_id: int) -> void: counts["removed"] = int(counts["removed"]) + 1
	)
	gateway.pickup_collected.connect(
		func(_net_id: int, _peer: int, _config: PickupConfig, _applied: bool) -> void:
			counts["collected"] = int(counts["collected"]) + 1
	)
	var pickup_index: Dictionary = {}
	var pending_exit_ids: Dictionary = {}
	var enemy_container := Node2D.new()
	var boss_container := Node2D.new()
	var registry := StandardPickupRegistry.new()
	registry.bind_standard_dependencies(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		pickup_index,
		gateway,
		enemy_container,
		boss_container,
		pending_exit_ids,
		PickupRegistryBase.FIRST_DYNAMIC_PICKUP_NET_ID
	)
	var started_at := Time.get_ticks_usec()
	for event_index in range(EVENTS_PER_SAMPLE):
		var net_id := event_index + 1
		pickup.set_meta("net_id", net_id)
		pickup_index[net_id] = pickup
		registry.handle_multiplayer_pickup_consumed(
			pickup,
			2,
			true
		)
		registry.handle_multiplayer_pickup_tree_exited(net_id)
	samples.append(Time.get_ticks_usec() - started_at)
	var state_hash := hash([
		pickup_index.size(),
		pending_exit_ids.size(),
		int(counts["removed"]),
		int(counts["collected"]),
	])
	_expect(
		pickup_index.is_empty()
		and pending_exit_ids.is_empty()
		and int(counts["removed"]) == EVENTS_PER_SAMPLE
		and int(counts["collected"]) == EVENTS_PER_SAMPLE,
		"提取后 Pickup 轨迹必须与旧版严格一致。"
	)
	registry.free()
	enemy_container.free()
	boss_container.free()
	gateway.free()
	return state_hash


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
