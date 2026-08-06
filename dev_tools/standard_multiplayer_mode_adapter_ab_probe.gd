extends SceneTree

const SAMPLE_COUNT := 21
const EVENTS_PER_SAMPLE := 4096
const FIXED_SEED := 0x5A17D46


class LegacyStandardAdapterLogic:
	extends Node

	var runtime: StandardGame = null
	var player_roster: StandardPlayerRosterCoordinator = null

	func bind_dependencies(
		runtime_instance: StandardGame,
		roster: StandardPlayerRosterCoordinator
	) -> void:
		runtime = runtime_instance
		player_roster = roster
		player_roster.peer_restored.connect(_on_multiplayer_peer_restored)

	func is_terminal_combat_state() -> bool:
		return runtime.wave_state in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]

	func get_flow_state_snapshot() -> Dictionary:
		return runtime.get_flow_state_snapshot()

	func record_luoxi_collectible_claim(peer_id: int) -> void:
		runtime.record_luoxi_collectible_claim(peer_id)

	func has_luoxi_collectible_claimed(peer_id: int) -> bool:
		return runtime.has_luoxi_collectible_claimed(peer_id)

	func mark_luoxi_collectible_claimed(peer_id: int) -> void:
		runtime.mark_luoxi_collectible_claimed(peer_id)

	func _on_multiplayer_peer_restored(old_peer_id: int, new_peer_id: int) -> void:
		runtime._on_multiplayer_peer_restored(old_peer_id, new_peer_id)


var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var legacy_samples: Array[int] = []
	var extracted_samples: Array[int] = []
	var legacy_memory_samples: Array[int] = []
	var extracted_memory_samples: Array[int] = []
	var legacy_trajectory_hash := 0
	var extracted_trajectory_hash := 0
	_warm_up_arm(true)
	_warm_up_arm(false)
	for sample_index in range(SAMPLE_COUNT):
		if sample_index % 2 == 0:
			legacy_trajectory_hash ^= _measure_legacy(
				legacy_samples,
				legacy_memory_samples
			)
			extracted_trajectory_hash ^= _measure_extracted(
				extracted_samples,
				extracted_memory_samples
			)
		else:
			extracted_trajectory_hash ^= _measure_extracted(
				extracted_samples,
				extracted_memory_samples
			)
			legacy_trajectory_hash ^= _measure_legacy(
				legacy_samples,
				legacy_memory_samples
			)
	legacy_samples.sort()
	extracted_samples.sort()
	legacy_memory_samples.sort()
	extracted_memory_samples.sort()
	var p50_index := _nearest_rank_index(SAMPLE_COUNT, 0.50)
	var p95_index := _nearest_rank_index(SAMPLE_COUNT, 0.95)
	var legacy_p50 := legacy_samples[p50_index]
	var extracted_p50 := extracted_samples[p50_index]
	var legacy_p95 := legacy_samples[p95_index]
	var extracted_p95 := extracted_samples[p95_index]
	var legacy_memory_p50 := legacy_memory_samples[p50_index]
	var extracted_memory_p50 := extracted_memory_samples[p50_index]
	var legacy_memory_p95 := legacy_memory_samples[p95_index]
	var extracted_memory_p95 := extracted_memory_samples[p95_index]
	_expect(
		legacy_trajectory_hash == extracted_trajectory_hash,
		"Standard adapter A/B 轨迹必须严格一致：legacy=%d extracted=%d。"
		% [legacy_trajectory_hash, extracted_trajectory_hash]
	)
	var p50_limit := legacy_p50 + maxi(ceili(legacy_p50 * 0.05), 200)
	var p95_limit := legacy_p95 + maxi(ceili(legacy_p95 * 0.05), 200)
	var memory_p50_limit := legacy_memory_p50 + maxi(
		ceili(legacy_memory_p50 * 0.05),
		16 * 1024 * 1024
	)
	var memory_p95_limit := legacy_memory_p95 + maxi(
		ceili(legacy_memory_p95 * 0.05),
		16 * 1024 * 1024
	)
	_expect(
		extracted_p50 <= p50_limit,
		"extracted p50 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_p50, extracted_p50, p50_limit]
	)
	_expect(
		extracted_p95 <= p95_limit,
		"extracted p95 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_p95, extracted_p95, p95_limit]
	)
	_expect(
		extracted_memory_p50 <= memory_p50_limit,
		"extracted memory p50 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_memory_p50, extracted_memory_p50, memory_p50_limit]
	)
	_expect(
		extracted_memory_p95 <= memory_p95_limit,
		"extracted memory p95 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_memory_p95, extracted_memory_p95, memory_p95_limit]
	)
	if failures.is_empty():
		print(
			"STANDARD_MULTIPLAYER_MODE_ADAPTER_AB_PROBE_OK legacy_p50_usec=%d extracted_p50_usec=%d legacy_p95_usec=%d extracted_p95_usec=%d p50_limit_usec=%d p95_limit_usec=%d legacy_memory_p50_bytes=%d extracted_memory_p50_bytes=%d legacy_memory_p95_bytes=%d extracted_memory_p95_bytes=%d memory_p50_limit_bytes=%d memory_p95_limit_bytes=%d trajectory_hash=%d"
			% [
				legacy_p50,
				extracted_p50,
				legacy_p95,
				extracted_p95,
				p50_limit,
				p95_limit,
				legacy_memory_p50,
				extracted_memory_p50,
				legacy_memory_p95,
				extracted_memory_p95,
				memory_p50_limit,
				memory_p95_limit,
				legacy_trajectory_hash,
			]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_legacy(samples: Array[int], memory_samples: Array[int]) -> int:
	var fixture := _create_fixture(true)
	var game := fixture["game"] as StandardGame
	var roster := fixture["roster"] as StandardPlayerRosterCoordinator
	var merchant := fixture["merchant"] as StandardMerchantCoordinator
	var adapter := fixture["adapter"] as LegacyStandardAdapterLogic
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = FIXED_SEED
	var trace_checksum := 0
	var started_at := Time.get_ticks_usec()
	for event_index in range(EVENTS_PER_SAMPLE):
		var peer_id := random_generator.randi_range(1, 64)
		var restored_peer_id := peer_id + 1000
		game.wave_state = random_generator.randi_range(
			CombatFlowState.State.PRE_WAVE,
			CombatFlowState.State.BOSS_ACTIVE
		) as CombatFlowState.State
		game.countdown_seconds = random_generator.randi_range(0, 90)
		var snapshot := adapter.get_flow_state_snapshot()
		adapter.record_luoxi_collectible_claim(peer_id)
		var claimed := int(adapter.has_luoxi_collectible_claimed(peer_id))
		roster.peer_restored.emit(peer_id, restored_peer_id)
		var old_count := merchant.get_luoxi_collectible_claim_count(peer_id)
		var restored_count := merchant.get_luoxi_collectible_claim_count(
			restored_peer_id
		)
		adapter.mark_luoxi_collectible_claimed(restored_peer_id)
		var marked_count := merchant.get_luoxi_collectible_claim_count(
			restored_peer_id
		)
		trace_checksum += (event_index + 1) * (
			int(snapshot["state"]) * 100000
			+ int(snapshot["countdown_seconds"]) * 1000
			+ int(adapter.is_terminal_combat_state()) * 100
			+ claimed * 10
			+ old_count
			+ restored_count
			+ marked_count
		)
		merchant.luoxi_collectible_claim_counts.erase(restored_peer_id)
	samples.append(Time.get_ticks_usec() - started_at)
	memory_samples.append(int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	var state_hash := hash([
		merchant.luoxi_collectible_claim_counts.size(),
		trace_checksum,
	])
	_expect(
		merchant.luoxi_collectible_claim_counts.is_empty(),
		"legacy claim ledger 必须完整清空。"
	)
	game.free()
	return state_hash


func _measure_extracted(samples: Array[int], memory_samples: Array[int]) -> int:
	var fixture := _create_fixture(false)
	var game := fixture["game"] as StandardGame
	var roster := fixture["roster"] as StandardPlayerRosterCoordinator
	var merchant := fixture["merchant"] as StandardMerchantCoordinator
	var adapter := fixture["adapter"] as StandardMultiplayerModeAdapter
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = FIXED_SEED
	var trace_checksum := 0
	var started_at := Time.get_ticks_usec()
	for event_index in range(EVENTS_PER_SAMPLE):
		var peer_id := random_generator.randi_range(1, 64)
		var restored_peer_id := peer_id + 1000
		game.wave_state = random_generator.randi_range(
			CombatFlowState.State.PRE_WAVE,
			CombatFlowState.State.BOSS_ACTIVE
		) as CombatFlowState.State
		game.countdown_seconds = random_generator.randi_range(0, 90)
		var snapshot := adapter.get_flow_state_snapshot()
		adapter.runtime_record_luoxi_collectible_claim(peer_id)
		var claimed := int(adapter.runtime_has_luoxi_collectible_claimed(peer_id))
		roster.peer_restored.emit(peer_id, restored_peer_id)
		var old_count := merchant.get_luoxi_collectible_claim_count(peer_id)
		var restored_count := merchant.get_luoxi_collectible_claim_count(
			restored_peer_id
		)
		adapter.runtime_mark_luoxi_collectible_claimed(restored_peer_id)
		var marked_count := merchant.get_luoxi_collectible_claim_count(
			restored_peer_id
		)
		trace_checksum += (event_index + 1) * (
			int(snapshot["state"]) * 100000
			+ int(snapshot["countdown_seconds"]) * 1000
			+ int(adapter.is_terminal_combat_state()) * 100
			+ claimed * 10
			+ old_count
			+ restored_count
			+ marked_count
		)
		merchant.luoxi_collectible_claim_counts.erase(restored_peer_id)
	samples.append(Time.get_ticks_usec() - started_at)
	memory_samples.append(int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	var state_hash := hash([
		merchant.luoxi_collectible_claim_counts.size(),
		trace_checksum,
	])
	_expect(
		merchant.luoxi_collectible_claim_counts.is_empty(),
		"extracted claim ledger 必须完整清空。"
	)
	game.free()
	return state_hash


func _create_fixture(use_legacy: bool) -> Dictionary:
	var game := StandardGame.new()
	var roster := StandardPlayerRosterCoordinator.new()
	roster.name = "PlayerRosterCoordinator"
	game.add_child(roster)
	var merchant := StandardMerchantCoordinator.new()
	merchant.name = "MerchantCoordinator"
	game.add_child(merchant)
	var boss := StandardBossCoordinator.new()
	boss.name = "BossCoordinator"
	game.add_child(boss)
	var profile := StandardPlayerProfilePanel.new()
	game.add_child(profile)
	var debug_window := DebugCollectibleWindow.new()
	game.add_child(debug_window)
	var wave_hud := StandardWaveHUD.new()
	game.add_child(wave_hud)
	var adapter: Node = null
	if use_legacy:
		var legacy_adapter := LegacyStandardAdapterLogic.new()
		legacy_adapter.name = "MultiplayerModeAdapter"
		game.add_child(legacy_adapter)
		legacy_adapter.bind_dependencies(game, roster)
		adapter = legacy_adapter
	else:
		var extracted_adapter := StandardMultiplayerModeAdapter.new()
		extracted_adapter.name = "MultiplayerModeAdapter"
		game.add_child(extracted_adapter)
		extracted_adapter.bind_standard_dependencies(
			game,
			roster,
			boss,
			merchant,
			profile,
			debug_window,
			wave_hud
		)
		adapter = extracted_adapter
	return {
		"game": game,
		"roster": roster,
		"merchant": merchant,
		"adapter": adapter,
	}


func _warm_up_arm(use_legacy: bool) -> void:
	var discarded_samples: Array[int] = []
	var discarded_memory_samples: Array[int] = []
	if use_legacy:
		_measure_legacy(discarded_samples, discarded_memory_samples)
	else:
		_measure_extracted(discarded_samples, discarded_memory_samples)


func _nearest_rank_index(sample_count: int, percentile: float) -> int:
	return clampi(ceili(sample_count * percentile) - 1, 0, sample_count - 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
