extends SceneTree

const SAMPLE_COUNT := 21
const EVENTS_PER_SAMPLE := 8192
const ARM_ARGUMENT_PREFIX := "--arm="


class LegacyMerchantClaimLedger:
	extends RefCounted

	var claim_counts: Dictionary = {}

	func restore_peer_state(old_peer_id: int, new_peer_id: int) -> void:
		if not claim_counts.has(old_peer_id):
			return
		claim_counts[new_peer_id] = claim_counts[old_peer_id]
		claim_counts.erase(old_peer_id)

	func has_claimed(peer_id: int) -> bool:
		return get_claim_count(peer_id) >= LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND

	func get_claim_count(peer_id: int) -> int:
		return int(claim_counts.get(maxi(peer_id, 0), 0))

	func record_claim(peer_id: int) -> void:
		var claim_key := maxi(peer_id, 0)
		claim_counts[claim_key] = mini(
			get_claim_count(claim_key) + 1,
			LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND
		)

	func mark_claimed(peer_id: int) -> void:
		claim_counts[maxi(peer_id, 0)] = LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var requested_arm := _get_requested_arm()
	if not requested_arm.is_empty():
		_run_isolated_arm(requested_arm)
		return
	_run_comparison()


func _run_comparison() -> void:
	var legacy_samples: Array[int] = []
	var extracted_samples: Array[int] = []
	var legacy_trajectory_hash := 0
	var extracted_trajectory_hash := 0
	_warm_up_arm("legacy")
	_warm_up_arm("extracted")
	for sample_index in range(SAMPLE_COUNT):
		if sample_index % 2 == 0:
			legacy_trajectory_hash ^= _measure_legacy(legacy_samples)
			extracted_trajectory_hash ^= _measure_extracted(extracted_samples)
		else:
			extracted_trajectory_hash ^= _measure_extracted(extracted_samples)
			legacy_trajectory_hash ^= _measure_legacy(legacy_samples)
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
		"提取前后 Standard Merchant 累计轨迹 hash 必须严格一致：legacy=%d extracted=%d。"
		% [legacy_trajectory_hash, extracted_trajectory_hash]
	)
	if failures.is_empty():
		print(
			"STANDARD_MERCHANT_COORDINATOR_AB_PROBE_OK legacy_p50_usec=%d extracted_p50_usec=%d legacy_p95_usec=%d extracted_p95_usec=%d legacy_trajectory_hash=%d extracted_trajectory_hash=%d"
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
		push_error("未知 Standard Merchant A/B arm：%s。" % arm)
		quit(1)
		return
	var samples: Array[int] = []
	var trajectory_hash := 0
	_warm_up_arm(arm)
	for _sample_index in range(SAMPLE_COUNT):
		if arm == "legacy":
			trajectory_hash ^= _measure_legacy(samples)
		else:
			trajectory_hash ^= _measure_extracted(samples)
	samples.sort()
	var p50_usec := samples[_get_nearest_rank_index(samples.size(), 0.50)]
	var p95_usec := samples[_get_nearest_rank_index(samples.size(), 0.95)]
	if failures.is_empty():
		print(
			"STANDARD_MERCHANT_COORDINATOR_AB_ARM_OK arm=%s p50_usec=%d p95_usec=%d trajectory_hash=%d"
			% [arm, p50_usec, p95_usec, trajectory_hash]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_legacy(samples: Array[int]) -> int:
	var ledger := LegacyMerchantClaimLedger.new()
	var trace_checksum: int = 0
	var started_at := Time.get_ticks_usec()
	for event_index in range(EVENTS_PER_SAMPLE):
		var peer_id := event_index % 64 + 1
		var restored_peer_id := peer_id + 1000
		ledger.record_claim(peer_id)
		var first_claimed := int(ledger.has_claimed(peer_id))
		ledger.restore_peer_state(peer_id, restored_peer_id)
		var old_count := ledger.get_claim_count(peer_id)
		var restored_count := ledger.get_claim_count(restored_peer_id)
		ledger.mark_claimed(restored_peer_id)
		var marked_count := ledger.get_claim_count(restored_peer_id)
		trace_checksum += (event_index + 1) * (
			first_claimed * 1000
			+ old_count * 100
			+ restored_count * 10
			+ marked_count
		)
		ledger.claim_counts.erase(restored_peer_id)
	samples.append(Time.get_ticks_usec() - started_at)
	var state_hash := hash([ledger.claim_counts.size(), trace_checksum])
	_expect(
		ledger.claim_counts.is_empty(),
		"旧版 Standard Merchant 对照轨迹必须完整清空 claim ledger。"
	)
	return state_hash


func _measure_extracted(samples: Array[int]) -> int:
	var coordinator := StandardMerchantCoordinator.new()
	var trace_checksum: int = 0
	var started_at := Time.get_ticks_usec()
	for event_index in range(EVENTS_PER_SAMPLE):
		var peer_id := event_index % 64 + 1
		var restored_peer_id := peer_id + 1000
		coordinator.record_luoxi_collectible_claim(peer_id)
		var first_claimed := int(
			coordinator.has_luoxi_collectible_claimed(peer_id)
		)
		coordinator.restore_peer_state(peer_id, restored_peer_id)
		var old_count := coordinator.get_luoxi_collectible_claim_count(peer_id)
		var restored_count := coordinator.get_luoxi_collectible_claim_count(
			restored_peer_id
		)
		coordinator.mark_luoxi_collectible_claimed(restored_peer_id)
		var marked_count := coordinator.get_luoxi_collectible_claim_count(
			restored_peer_id
		)
		trace_checksum += (event_index + 1) * (
			first_claimed * 1000
			+ old_count * 100
			+ restored_count * 10
			+ marked_count
		)
		coordinator.luoxi_collectible_claim_counts.erase(restored_peer_id)
	samples.append(Time.get_ticks_usec() - started_at)
	var state_hash := hash([
		coordinator.luoxi_collectible_claim_counts.size(),
		trace_checksum,
	])
	_expect(
		coordinator.luoxi_collectible_claim_counts.is_empty(),
		"提取后 Standard Merchant 轨迹必须完整清空 claim ledger。"
	)
	coordinator.free()
	return state_hash


func _warm_up_arm(arm: String) -> void:
	var discarded_samples: Array[int] = []
	if arm == "legacy":
		_measure_legacy(discarded_samples)
	else:
		_measure_extracted(discarded_samples)


func _get_requested_arm() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(ARM_ARGUMENT_PREFIX):
			return argument.trim_prefix(ARM_ARGUMENT_PREFIX)
	return ""


func _get_nearest_rank_index(sample_count: int, percentile: float) -> int:
	return clampi(ceili(float(sample_count) * percentile) - 1, 0, sample_count - 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
