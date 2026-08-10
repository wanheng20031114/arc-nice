extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		PlayerCharacterRegistry.supports_ammunition_reward(&"weishidaier")
		and PlayerCharacterRegistry.supports_ammunition_reward(&"tiyi")
		and not PlayerCharacterRegistry.supports_ammunition_reward(&"tango")
		and not PlayerCharacterRegistry.supports_ammunition_reward(&"hoe_cat"),
		"弹夹奖励资格必须由角色配置统一声明。"
	)
	_test_default_ledger(run_state)

	var first_health := run_state.build_party_status_ledger_with_player_stat_bonus(
		0,
		&"max_health",
		10
	)
	_expect(
		not first_health.is_empty()
		and run_state.apply_party_status_ledger(first_health),
		"生命奖励必须生成并应用单步状态账本。"
	)

	var fixture := Node2D.new()
	root.add_child(fixture)
	var player := PLAYER_SCENE.instantiate() as AmmoRangedPlayer
	fixture.add_child(player)
	player.set_physics_process(false)
	await process_frame
	var config := player.get_character_config()
	_expect(
		player.max_health == config.starting_max_health + 10
		and player.current_health == player.max_health,
		"新建玩家必须从绝对账本恢复生命上限，且正常出生为满血。"
	)

	player.current_health = player.max_health - 20
	var health_before_second_reward := player.current_health
	var second_health := (
		run_state.build_party_status_ledger_with_player_stat_bonus(
			0,
			&"max_health",
			10
		)
	)
	_expect(
		run_state.apply_party_status_ledger(second_health)
		and player.max_health == config.starting_max_health + 20
		and player.current_health == health_before_second_reward,
		"重复宝箱必须叠加上限，但账本重放本身不得治疗。"
	)
	_expect(
		player.heal(10, false) == 10
		and player.current_health == health_before_second_reward + 10,
		"生命奖励提交后必须能精确回复10点生命。"
	)

	for reward in [
		[&"physical_defense", 2],
		[&"magic_defense", 1],
		[&"move_speed", 5],
		[&"ammo_capacity", 1],
		[&"attack_damage", 2],
		[&"dodge_percent_points", 1],
	]:
		var next_status := (
			run_state.build_party_status_ledger_with_player_stat_bonus(
				0,
				StringName(reward[0]),
				int(reward[1])
			)
		)
		_expect(
			not next_status.is_empty()
			and run_state.apply_party_status_ledger(next_status),
			"七类持久属性必须逐项通过状态账本应用。"
		)

	_expect(
		player.physical_defense == 2
		and player.magic_defense == 1
		and is_equal_approx(player.move_speed, config.starting_move_speed + 5.0)
		and player.get_ammo_capacity() == player.ammo_capacity + 1
		and player.attack_damage == config.starting_attack_damage + 2
		and is_equal_approx(player.dodge_chance, 0.01),
		"玩家统一重算必须准确包含防御、移速、弹夹、攻击与闪避奖励。"
	)

	var committed := run_state.export_party_status_ledger()
	var health_before_replay := player.current_health
	_expect(
		run_state.apply_party_status_ledger(committed)
		and player.current_health == health_before_replay,
		"同revision同内容重放必须幂等且不得再次治疗。"
	)
	_expect(
		run_state.build_party_status_ledger_with_player_stat_bonus(
			0,
			&"magic_defense",
			100
		).is_empty()
		and run_state.build_party_status_ledger_with_player_stat_bonus(
			0,
			&"dodge_percent_points",
			100
		).is_empty(),
		"超过100的魔防与闪避奖励必须在候选结算前判定无效。"
	)

	fixture.queue_free()
	await process_frame
	run_state.begin_new_run(&"weishidaier", false)
	var cleared_bonuses := run_state.get_player_stat_bonuses(0)
	var all_cleared := true
	for raw_value in cleared_bonuses.values():
		if int(raw_value) != 0:
			all_cleared = false
			break
	_expect(
		all_cleared,
		"新一局必须清空全部持久属性奖励。"
	)
	await _test_authoritative_cas_and_schema_guards()
	_test_multiplayer_identity_lifecycle()

	if failures.is_empty():
		print("PLAYER_RUN_STAT_BONUS_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_default_ledger(run_state: RunStateStore) -> void:
	var status := run_state.export_party_status_ledger()
	var bonuses := status.get("player_stat_bonuses", {}) as Dictionary
	var local_bonuses := bonuses.get("0", {}) as Dictionary
	_expect(
		int(status.get("schema_version", 0))
		== RunStateStore.PARTY_STATUS_LEDGER_SCHEMA_VERSION
		and RunStateStore.PARTY_STATUS_LEDGER_SCHEMA_VERSION == 2
		and RunStateStore.PARTY_ECONOMY_SCHEMA_VERSION == 5
		and local_bonuses.size() == RunStateStore.PLAYER_STAT_BONUS_KEYS.size(),
		"状态账本schema2必须携带本地玩家的七项零值奖励。"
	)


func _test_authoritative_cas_and_schema_guards() -> void:
	var isolated := RunStateStore.new()
	isolated.begin_new_run(&"weishidaier", false)
	var base_economy := isolated.export_party_economy_snapshot()
	var next_status := (
		isolated.build_party_status_ledger_with_player_stat_bonus(
			0,
			&"attack_damage",
			2
		)
	)
	var expected_inventory_revisions: Dictionary = {}
	for raw_inventory in base_economy.get("inventories", []) as Array:
		var inventory := raw_inventory as Dictionary
		expected_inventory_revisions[int(inventory.get("peer_id", -1))] = int(
			inventory.get("revision", -1)
		)
	var expected_status_revision := int(
		(base_economy["party_status_ledger"] as Dictionary)["revision"]
	)
	var committed := isolated.apply_authoritative_party_transaction(
		base_economy,
		int((base_economy["warehouse_ledger"] as Dictionary)["revision"]),
		expected_inventory_revisions,
		-1,
		{},
		expected_status_revision,
		next_status
	)
	_expect(
		committed
		and isolated.get_player_stat_bonus_value(0, &"attack_damage") == 2,
		"权威 Party Economy CAS 必须原子提交属性奖励。"
	)
	_expect(
		not isolated.apply_authoritative_party_transaction(
			base_economy,
			int(
				(base_economy["warehouse_ledger"] as Dictionary)["revision"]
			),
			expected_inventory_revisions,
			-1,
			{},
			expected_status_revision,
			next_status
		)
		and isolated.get_player_stat_bonus_value(0, &"attack_damage") == 2,
		"陈旧 revision 的重复事务必须拒绝且不得重复叠加。"
	)

	var valid_status := isolated.export_party_status_ledger()
	var malformed_cases: Array[Dictionary] = []
	var missing_field := valid_status.duplicate(true)
	missing_field["revision"] = int(valid_status["revision"]) + 1
	(
		missing_field["player_stat_bonuses"] as Dictionary
	)["0"].erase("move_speed")
	malformed_cases.append(missing_field)
	var extra_field := valid_status.duplicate(true)
	extra_field["revision"] = int(valid_status["revision"]) + 1
	(
		extra_field["player_stat_bonuses"] as Dictionary
	)["0"]["unexpected"] = 1
	malformed_cases.append(extra_field)
	var wrong_type := valid_status.duplicate(true)
	wrong_type["revision"] = int(valid_status["revision"]) + 1
	(
		wrong_type["player_stat_bonuses"] as Dictionary
	)["0"]["physical_defense"] = 2.0
	malformed_cases.append(wrong_type)
	var over_cap := valid_status.duplicate(true)
	over_cap["revision"] = int(valid_status["revision"]) + 1
	(
		over_cap["player_stat_bonuses"] as Dictionary
	)["0"]["magic_defense"] = 101
	malformed_cases.append(over_cap)
	for malformed in malformed_cases:
		_expect(
			not isolated.apply_party_status_ledger(malformed),
			"属性账本必须拒绝缺字段、额外字段、错误类型和超上限值。"
		)

	var ammo_player := PLAYER_SCENE.instantiate() as AmmoRangedPlayer
	var fixture := Node2D.new()
	root.add_child(fixture)
	fixture.add_child(ammo_player)
	ammo_player.set_physics_process(false)
	await process_frame
	ammo_player.configure_run_stat_bonuses({"ammo_capacity": 65535})
	_expect(
		ammo_player.get_ammo_capacity() == 65535,
		"弹夹加算与百分比倍率后的最终容量必须钳制为65535。"
	)
	fixture.queue_free()
	await process_frame
	isolated.free()


func _test_multiplayer_identity_lifecycle() -> void:
	var isolated := RunStateStore.new()
	isolated.begin_new_run(&"tiyi", false)
	isolated.ensure_multiplayer_peer_state(11)
	var next_status := (
		isolated.build_party_status_ledger_with_player_stat_bonus(
			11,
			&"move_speed",
			5
		)
	)
	_expect(
		isolated.apply_party_status_ledger(next_status),
		"多人属性奖励夹具必须成功写入。"
	)
	var revision_before_remap := isolated.party_status_ledger_revision
	_expect(
		isolated.remap_multiplayer_peer_state(11, 22)
		and isolated.get_player_stat_bonus_value(22, &"move_speed") == 5
		and isolated.get_player_stat_bonus_value(11, &"move_speed") == 0
		and isolated.party_status_ledger_revision
		== revision_before_remap + 1,
		"重连身份迁移必须将绝对属性账本移动到新 peer 并只推进一次 revision。"
	)
	var revision_before_prune := isolated.party_status_ledger_revision
	_expect(
		isolated.prune_multiplayer_peer_states(PackedInt32Array()) == 1
		and isolated.get_player_stat_bonus_value(22, &"move_speed") == 0
		and isolated.party_status_ledger_revision
		== revision_before_prune + 1,
		"清理离队 peer 时必须删除属性账本并推进一次 revision。"
	)
	isolated.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
