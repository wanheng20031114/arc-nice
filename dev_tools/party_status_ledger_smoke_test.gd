extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	_test_default_state_and_atomic_transaction(run_state)
	await _test_player_penalty_application(run_state)
	await _test_tower_defense_hydration_and_writeback(run_state)
	await _test_tower_defense_client_mirror(run_state)
	run_state.begin_new_run(&"weishidaier")

	if failures.is_empty():
		print("PARTY_STATUS_LEDGER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_default_state_and_atomic_transaction(run_state: RunStateStore) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var initial_status := run_state.export_party_status_ledger()
	_expect(
		int(initial_status.get("schema_version", 0))
		== RunStateStore.PARTY_STATUS_LEDGER_SCHEMA_VERSION
		and int(initial_status.get("revision", -1)) == 0
		and int(initial_status.get("core_current", 0)) == 100
		and int(initial_status.get("core_maximum", 0)) == 100
		and int(
			(initial_status.get("max_health_penalties", {}) as Dictionary).get(
				"0",
				-1
			)
		) == 0,
		"新局必须建立100/100、无最大生命惩罚且revision为0的状态账本。"
	)

	run_state.ensure_multiplayer_peer_state(1)
	run_state.ensure_multiplayer_peer_state(2)
	var party_snapshot := run_state.export_party_economy_snapshot(
		PackedInt32Array([1, 2])
	)
	_expect(
		int(party_snapshot.get("schema_version", 0))
		== RunStateStore.PARTY_ECONOMY_SCHEMA_VERSION
		and party_snapshot.has("party_status_ledger"),
		"Party economy schema 4必须携带状态账本。"
	)
	var status_before := party_snapshot["party_status_ledger"] as Dictionary
	var next_status := status_before.duplicate(true)
	next_status["revision"] = int(status_before["revision"]) + 1
	next_status["core_current"] = 98
	var penalties := next_status["max_health_penalties"] as Dictionary
	penalties["1"] = 20
	penalties["2"] = 20
	var expected_inventory_revisions := {
		1: run_state.get_inventory_revision_for_peer(1),
		2: run_state.get_inventory_revision_for_peer(2),
	}
	var warehouse_revision := int(
		(party_snapshot["warehouse_ledger"] as Dictionary)["revision"]
	)
	var xirang_revision := int(
		(party_snapshot["xirang_ledger"] as Dictionary)["revision"]
	)
	_expect(
		run_state.apply_authoritative_party_transaction(
			party_snapshot,
			warehouse_revision,
			expected_inventory_revisions,
			xirang_revision,
			{},
			int(status_before["revision"]),
			next_status
		),
		"核心扣血与逐玩家最大生命惩罚必须能在同一个CAS中原子提交。"
	)
	_expect(
		run_state.get_party_core_health() == 98
		and run_state.get_max_health_penalty_for_peer(1) == 20
		and run_state.get_max_health_penalty_for_peer(2) == 20
		and run_state.get_party_status_ledger_revision()
		== int(status_before["revision"]) + 1,
		"原子提交必须精确发布核心、惩罚与单步revision。"
	)
	var committed := run_state.export_party_economy_snapshot(
		PackedInt32Array([1, 2])
	)
	_expect(
		not run_state.apply_authoritative_party_transaction(
			party_snapshot,
			warehouse_revision,
			expected_inventory_revisions,
			xirang_revision,
			{},
			int(status_before["revision"]),
			next_status
		)
		and run_state.export_party_economy_snapshot(
			PackedInt32Array([1, 2])
		) == committed,
		"过期状态revision必须拒绝，且不得留下部分经济写入。"
	)
	var penalty_revision := run_state.get_party_status_ledger_revision()
	_expect(
		run_state.add_max_health_penalty_for_peer(1, 20) == 40
		and run_state.add_max_health_penalty_for_peer(1, 20) == 60
		and run_state.get_max_health_penalty_for_peer(1) == 60
		and run_state.get_party_status_ledger_revision()
		== penalty_revision + 2,
		"最大生命惩罚必须跨事件连续累加，并为每次权威修改推进一次revision。"
	)
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.get_party_core_health() == 100
		and run_state.get_party_core_maximum_health() == 100
		and run_state.get_max_health_penalty_for_peer(1) == 0,
		"只有新开一局才会把共享核心和累计最大生命惩罚恢复为默认值。"
	)


func _test_player_penalty_application(run_state: RunStateStore) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var fixture := Node2D.new()
	root.add_child(fixture)
	var player := PLAYER_SCENE.instantiate() as Player
	player.set_run_max_health_penalty(20)
	fixture.add_child(player)
	player.set_physics_process(false)
	await process_frame
	var normal_maximum := player.get_character_config().starting_max_health
	_expect(
		player.get_run_max_health_penalty() == 20
		and player.max_health == maxi(normal_maximum - 20, 1)
		and player.current_health == player.max_health,
		"玩家首次进入场景时必须在所有正常上限之后扣除本局惩罚。"
	)
	player.set_run_max_health_penalty(normal_maximum + 500)
	_expect(
		player.max_health == 1 and player.current_health <= player.max_health,
		"过量惩罚必须把最大生命限制在1，并仅截断超出上限的当前生命。"
	)
	var clamped_health := player.current_health
	player.set_run_max_health_penalty(0)
	_expect(
		player.max_health == normal_maximum
		and player.current_health == clamped_health,
		"惩罚减轻只提高生命上限，不得把当前生命自动治疗到新上限。"
	)
	fixture.queue_free()
	await process_frame


func _test_tower_defense_hydration_and_writeback(
	run_state: RunStateStore
) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.set_party_core_health(82, 100)
		and run_state.set_max_health_penalty_for_peer(0, 20),
		"塔防跨场景测试状态必须可预置。"
	)
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame
	_expect(
		game.current_base_health == 82
		and game.maximum_base_health == 100
		and game.player.get_run_max_health_penalty() == 20,
		"单人塔防必须从RunState恢复共享核心与本地最大生命惩罚。"
	)
	var revision_before_loss := run_state.get_party_status_ledger_revision()
	_expect(
		game.luoxi_special_game_coordinator._apply_core_health_loss(2) == 2
		and game.current_base_health == 80
		and run_state.get_party_core_health() == 80
		and run_state.get_party_status_ledger_revision()
		== revision_before_loss + 1,
		"塔防权威核心扣血必须单步回写共享状态账本。"
	)
	game.queue_free()
	await process_frame
	await process_frame


func _test_tower_defense_client_mirror(run_state: RunStateStore) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	run_state.ensure_multiplayer_peer_state(1)
	run_state.ensure_multiplayer_peer_state(2)
	_expect(
		run_state.set_party_core_health(76, 100)
		and run_state.set_max_health_penalty_for_peer(2, 20),
		"塔防客户端镜像测试状态必须可预置。"
	)
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		2,
		{1: "Host", 2: "Client"},
		{1: &"weishidaier", 2: &"weishidaier"}
	)
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame
	_expect(
		game.current_base_health == 76
		and game.player.get_run_max_health_penalty() == 20,
		"塔防客户端必须从权威economy镜像恢复核心与本地生命惩罚。"
	)
	var observed_signals := [0]
	var signal_callback := func(_snapshot: Dictionary) -> void:
		observed_signals[0] = int(observed_signals[0]) + 1
	run_state.party_status_ledger_changed.connect(signal_callback)
	var status_revision_before := run_state.get_party_status_ledger_revision()
	var remote_revision := game.base_health_revision + 1
	game.apply_remote_base_health(74, 100, remote_revision)
	_expect(
		game.current_base_health == 74
		and run_state.get_party_core_health() == 74
		and run_state.get_party_status_ledger_revision()
		== status_revision_before + 1
		and int(observed_signals[0]) == 0,
		"客户端核心网络快照必须静默镜像到账本，禁止形成信号回写环。"
	)
	run_state.party_status_ledger_changed.disconnect(signal_callback)
	game.queue_free()
	await process_frame
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
