extends SceneTree

const PROBE_SEED := 852741963
const ROUNDS := 3


class RecordingHomeDefenseCoordinator:
	extends TowerDefenseHomeDefenseCoordinator

	var damage_warning_count := 0

	func configure_for_probe(
		mode: int,
		run_state: RunStateStore,
		maximum_health: int,
		current_health: int,
		revision: int
	) -> void:
		var runtime := TowerDefenseGame.new()
		runtime.runtime_mode = mode as CombatRuntimeBase.RuntimeMode
		add_child(runtime)
		_runtime = runtime
		_run_state = run_state
		maximum_base_health = maximum_health
		current_base_health = current_health
		base_health_revision = revision

	func _present_base_health(
		play_damage_pulse: bool,
		_was_remote: bool
	) -> void:
		if play_damage_pulse:
			damage_warning_count += 1


class RecordingMultiplayerAdapter:
	extends TowerDefenseMultiplayerModeAdapter

	var applied_losses: Array[int] = []

	func apply_luoxi_player_health_loss(
		target_player: Player,
		amount: int,
		minimum_health: int = 0
	) -> int:
		if target_player == null or target_player.is_dead or amount <= 0:
			return 0
		var next_health := maxi(
			target_player.current_health - amount,
			clampi(minimum_health, 0, target_player.current_health)
		)
		var applied := target_player.current_health - next_health
		target_player.current_health = next_health
		if target_player.current_health <= 0:
			target_player.is_dead = true
		applied_losses.append(applied)
		return applied


class SpawnProbeRoster:
	extends TowerDefensePlayerRosterCoordinator

	func configure_for_probe(
		spawn_point: Marker2D,
		spawn_offsets: Array[Vector2]
	) -> void:
		runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		_spawn_point = spawn_point
		_spawn_offsets = spawn_offsets.duplicate()


var failures: Array[String] = []
var trajectories: Array[Dictionary] = []
var party_ledger_signal_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "A/B 边界探针缺少 RunState。")
	if run_state == null:
		_finish()
		return
	for round_index in range(ROUNDS):
		_run_round(round_index, run_state)
	_finish()


func _run_round(round_index: int, run_state: RunStateStore) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = PROBE_SEED + round_index * 7919
	var round_trace := {
		"round": round_index,
		"base_health": _compare_base_health_boundary(rng, run_state),
		"luoxi_damage": _compare_luoxi_damage_boundary(rng),
		"missing_spawn_slot": _compare_missing_spawn_slot_boundary(rng),
		"fate_state": _compare_fate_state_boundary(round_index),
		"research_state": _compare_research_state_boundary(round_index),
	}
	trajectories.append(round_trace)


func _compare_base_health_boundary(
	rng: RandomNumberGenerator,
	run_state: RunStateStore
) -> Dictionary:
	run_state.begin_new_run(&"weishidaier", false)
	var original_maximum := rng.randi_range(80, 140)
	var original_current := rng.randi_range(20, original_maximum)
	var original_revision := rng.randi_range(2, 12)
	var requested_maximum := rng.randi_range(35, 90)
	var requested_current := 1
	var ledger_revision_before := run_state.get_party_status_ledger_revision()
	var ledger_health_before := run_state.get_party_core_health()
	var ledger_maximum_before := run_state.get_party_core_maximum_health()
	party_ledger_signal_count = 0
	run_state.party_status_ledger_changed.connect(_on_party_status_ledger_changed)

	var legacy := {
		"maximum": maxi(requested_maximum, 1),
		"current": clampi(requested_current, 0, maxi(requested_maximum, 1)),
		"revision": original_revision + 1,
		"damage_warnings": 0,
		"ledger_revision": ledger_revision_before,
		"ledger_health": ledger_health_before,
		"ledger_maximum": ledger_maximum_before,
		"ledger_signals": 0,
	}
	var home := RecordingHomeDefenseCoordinator.new()
	home.configure_for_probe(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		run_state,
		original_maximum,
		original_current,
		original_revision
	)
	var fate := FateCoordinator.new()
	fate.home_defense_coordinator = home
	fate._set_base_health(requested_maximum, requested_current)
	var current := {
		"maximum": home.maximum_base_health,
		"current": home.current_base_health,
		"revision": home.base_health_revision,
		"damage_warnings": home.damage_warning_count,
		"ledger_revision": run_state.get_party_status_ledger_revision(),
		"ledger_health": run_state.get_party_core_health(),
		"ledger_maximum": run_state.get_party_core_maximum_health(),
		"ledger_signals": party_ledger_signal_count,
	}
	run_state.party_status_ledger_changed.disconnect(
		_on_party_status_ledger_changed
	)
	_expect(current == legacy, "命运基地生命边界与迁移前行为不一致。")
	_expect(home.damage_warning_count == 0, "命运基地生命修改不应触发受伤警报。")
	fate.free()
	home.free()
	return {"legacy": legacy, "current": current}


func _compare_luoxi_damage_boundary(rng: RandomNumberGenerator) -> Dictionary:
	var actor := _make_player(1, rng.randi_range(70, 130))
	var other := _make_player(2, rng.randi_range(90, 180))
	var third := _make_player(3, rng.randi_range(60, 150))
	var roster := TowerDefensePlayerRosterCoordinator.new()
	roster.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	roster.peer_players = {1: actor, 2: other, 3: third}
	var adapter := RecordingMultiplayerAdapter.new()
	var home := RecordingHomeDefenseCoordinator.new()
	var core_maximum := rng.randi_range(80, 130)
	var core_current := rng.randi_range(15, core_maximum)
	home.configure_for_probe(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		null,
		core_maximum,
		core_current,
		0
	)
	var coordinator := LuoxiSpecialGameCoordinator.new()
	coordinator.home_defense_coordinator = home
	coordinator.player_roster_coordinator = roster
	coordinator.multiplayer_adapter = adapter

	var percent := rng.randi_range(20, 90)
	var other_before := other.current_health
	var third_before := third.current_health
	var legacy_other := maxi(
		other_before - floori(float(other_before) * float(percent) / 100.0),
		1
	)
	var legacy_third := maxi(
		third_before - floori(float(third_before) * float(percent) / 100.0),
		1
	)
	coordinator._apply_health_outcome(actor, {
		"effect": LuoxiSpecialGameRules.HealthEffect.OTHERS_CURRENT_PERCENT,
		"amount": percent,
	})
	var self_loss := rng.randi_range(5, 30)
	var actor_before_fixed := actor.current_health
	var legacy_actor := maxi(actor_before_fixed - self_loss, 0)
	coordinator._apply_health_outcome(actor, {
		"effect": LuoxiSpecialGameRules.HealthEffect.SELF_FIXED,
		"amount": self_loss,
	})
	var core_loss := rng.randi_range(1, 9)
	var legacy_core := maxi(core_current - core_loss, 0)
	var applied_core_loss := coordinator._apply_core_health_loss(core_loss)
	var legacy := {
		"actor_health": legacy_actor,
		"other_health": legacy_other,
		"third_health": legacy_third,
		"core_health": legacy_core,
		"core_loss": core_current - legacy_core,
	}
	var current := {
		"actor_health": actor.current_health,
		"other_health": other.current_health,
		"third_health": third.current_health,
		"core_health": home.current_base_health,
		"core_loss": applied_core_loss,
	}
	_expect(current == legacy, "洛茜玩家/核心扣血边界与迁移前行为不一致。")
	coordinator.free()
	home.free()
	adapter.free()
	roster.free()
	actor.free()
	other.free()
	third.free()
	return {"legacy": legacy, "current": current}


func _compare_missing_spawn_slot_boundary(
	rng: RandomNumberGenerator
) -> Dictionary:
	var marker := Marker2D.new()
	marker.position = Vector2(rng.randi_range(10, 80), rng.randi_range(10, 80))
	var offsets: Array[Vector2] = [
		Vector2.ZERO,
		Vector2(24.0, 0.0),
		Vector2(0.0, 24.0),
		Vector2(-24.0, 0.0),
	]
	var fallback_slot := rng.randi_range(1, offsets.size() - 1)
	var roster := SpawnProbeRoster.new()
	roster.configure_for_probe(marker, offsets)
	roster.spawn_slot_indices = {2: 0}
	var legacy_position := marker.global_position + offsets[fallback_slot % offsets.size()]
	var current_position := roster.get_world_spawn_position(99, fallback_slot)
	var legacy := _vector_wire(legacy_position)
	var current := _vector_wire(current_position)
	_expect(current == legacy, "缺失 spawn slot 时未沿用旧的遍历槽位。")
	roster.free()
	marker.free()
	return {"legacy": legacy, "current": current, "fallback_slot": fallback_slot}


func _compare_fate_state_boundary(round_index: int) -> Dictionary:
	var known_buffs := TowerDefenseFateRegistry.get_all_permanent_buff_ids()
	var first_buff := known_buffs[round_index % known_buffs.size()]
	var second_buff := known_buffs[(round_index + 1) % known_buffs.size()]
	var incoming := {
		"active_permanent_buff_ids": PackedStringArray([
			String(first_buff),
			"unknown_fate_buff",
			String(second_buff),
			String(first_buff),
		]),
		"elite_bias_day": round_index + 2,
		"double_xirang_day": round_index + 3,
		"player_dash_cooldown_reduction": 0.1 * float(round_index + 1),
		"player_max_health_multiplier": 1.1 + 0.05 * float(round_index),
		"player_move_speed_multiplier": 1.2 + 0.05 * float(round_index),
		"hurt_speed_penalty_enabled": round_index % 2 == 0,
		"pending_stone_peer_ids": [7, 2, 7, -1, 4],
	}
	var legacy := {
		"active_permanent_buff_ids": PackedStringArray([
			String(first_buff),
			String(second_buff),
		]),
		"elite_bias_day": round_index + 2,
		"double_xirang_day": round_index + 3,
		"player_dash_cooldown_reduction": 0.1 * float(round_index + 1),
		"player_max_health_multiplier": 1.1 + 0.05 * float(round_index),
		"player_move_speed_multiplier": 1.2 + 0.05 * float(round_index),
		"hurt_speed_penalty_enabled": round_index % 2 == 0,
		"pending_stone_peer_ids": [2, 4, 7],
	}
	var fate := FateCoordinator.new()
	fate.apply_remote_runtime_state(incoming)
	var current := fate.export_runtime_state()
	_expect(current == legacy, "命运运行时关键状态与迁移前 wire 语义不一致。")
	fate.free()
	return {"legacy": legacy, "current": current}


func _compare_research_state_boundary(round_index: int) -> Dictionary:
	var states := {}
	var elapsed := {}
	var configs := GlobalResearchRegistry.get_all_configs()
	for config in configs:
		var wire_id := String(config.research_id)
		states[wire_id] = ResearchCoordinator.GlobalResearchState.AVAILABLE
		elapsed[wire_id] = 0.0
	var completed := configs[round_index % configs.size()] as GlobalResearchConfig
	states[String(completed.research_id)] = (
		ResearchCoordinator.GlobalResearchState.COMPLETED
	)
	elapsed[String(completed.research_id)] = completed.duration_seconds
	var legacy := {
		"schema": ResearchCoordinator.RUNTIME_STATE_SCHEMA,
		"revision": round_index + 5,
		"active_global_research_id": "",
		"global_states": states,
		"global_elapsed": elapsed,
		"player_levels": {1: round_index, 4: round_index + 1},
	}
	var research := ResearchCoordinator.new()
	research.apply_multiplayer_runtime_state(legacy)
	var current := research.export_runtime_state()
	_expect(current == legacy, "科研运行时关键状态与迁移前 wire 语义不一致。")
	research.free()
	return {"legacy": legacy, "current": current}


func _make_player(peer_id: int, health: int) -> Player:
	var player := Player.new()
	player.peer_id = peer_id
	player.max_health = health
	player.current_health = health
	player.is_dead = false
	return player


func _vector_wire(value: Vector2) -> Array[float]:
	return [value.x, value.y]


func _on_party_status_ledger_changed(_snapshot: Dictionary) -> void:
	party_ledger_signal_count += 1


func _finish() -> void:
	var trace_json := JSON.stringify(trajectories)
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(trace_json.to_utf8_buffer())
	var trace_hash := hashing.finish().hex_encode()
	print("TOWER_FATE_BOUNDARY_AB_HASH=%s" % trace_hash)
	if failures.is_empty():
		print(
			"TOWER_DEFENSE_FATE_FLOW_COORDINATOR_AB_PROBE_OK "
			+ "scope=legacy_current_boundary rounds=%d trajectory_hash=%s"
			% [ROUNDS, trace_hash]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
