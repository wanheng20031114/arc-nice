extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const PROFILE_SCENE := preload(
	"res://scene/ui/shared/profile/basic_player_profile_panel.tscn"
)

var failures: Array[String] = []
var fixture: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "PlayerRunProgressionSceneTransitionSmokeTest"
	root.add_child(fixture)
	await _test_combat_route_combat_boundary()
	await _test_multiplayer_identity_and_owner_guards()
	await _test_tower_persistent_modifier_projection()
	await _test_persistent_projection_signal_barrier()
	fixture.queue_free()
	for _frame in range(4):
		await process_frame
	if failures.is_empty():
		print("PLAYER_RUN_PROGRESSION_SCENE_TRANSITION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_combat_route_combat_boundary() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	_add_collectible_projection_fixtures(run_state)
	_apply_all_persistent_stat_bonus_fixtures(run_state, 0)
	_expect(
		run_state.set_max_health_penalty_for_peer(0, 9),
		"最大生命惩罚夹具必须进入 party status ledger。"
	)

	var combat_a := await _spawn_player("CombatA")
	combat_a.set_xirang_balance(20_000)
	_expect(
		combat_a.xirang_ownership == Player.XirangOwnership.SCENE_LOCAL,
		"Rogue 作战 Player 默认必须使用场景内 staged 账户。"
	)
	for stat_case in [
		[RunStateStore.StatType.ATTACK, 3],
		[RunStateStore.StatType.HEALTH, 2],
		[RunStateStore.StatType.ATTACK_SPEED, 4],
		[RunStateStore.StatType.DODGE, 2],
	]:
		for _level in range(int(stat_case[1])):
			if int(stat_case[0]) == RunStateStore.StatType.HEALTH:
				combat_a.current_health = 1
			_expect(
				run_state.try_upgrade(int(stat_case[0]), combat_a),
				"Combat A 的多种基础升级必须持久提交。"
			)
			if int(stat_case[0]) == RunStateStore.StatType.HEALTH:
				_expect(
					combat_a.current_health == combat_a.max_health,
					"生命升级必须保持购买即回满语义。"
				)
	for _skill_level in range(3):
		_expect(combat_a.try_upgrade_skill1(), "Combat A 技能升级必须进入同一持久账本。")
	_expect(
		combat_a.skill1_upgrade_level == 3
		and is_equal_approx(combat_a.skill1_charge_duration, 12.0),
		"技能等级3必须从作者18秒基础冷却绝对计算为12秒。"
	)
	combat_a.restore_current_health_to_maximum()
	var combat_a_profile := _capture_profile_projection(combat_a)
	var final_battle_xirang := combat_a.current_xirang
	_expect(
		run_state.set_party_xirang_balance(0, final_battle_xirang),
		"Combat A 退出屏障必须把 staged 最终余额结算进 party ledger。"
	)

	combat_a.queue_free()
	await process_frame
	var route_player := await _spawn_player("RoutePlayer")
	_expect(
		route_player.configure_xirang_ownership(
			Player.XirangOwnership.RUN_PARTY_LEDGER,
			0
		),
		"Route Player 必须显式绑定 RUN_PARTY 余额所有权。"
	)
	var progression := run_state.export_player_run_progression(0)
	# 先复现旧 bug：低血条件收藏品把临时上限抬高；合法场景入口必须
	# 以健康态重算，不能把这个旧场景条件值锁进新场景。
	route_player.current_health = 1
	_expect(
		route_player.apply_run_progression_snapshot(progression, true),
		"低血条件夹具必须先完成合法成长投影。"
	)
	var low_health_inflated_max := route_player.max_health
	_expect(
		low_health_inflated_max > int(combat_a_profile["max_health"]),
		"低血条件最大生命夹具必须确实激活。"
	)
	_contaminate_scene_transients(route_player)
	var malformed := progression.duplicate(true)
	malformed["extra"] = true
	var before_malformed := _capture_boundary_state(route_player)
	_expect(
		not route_player.restore_run_scene_entry(malformed)
		and _capture_boundary_state(route_player) == before_malformed,
		"malformed 场景入口快照必须在任何属性、生命或异常清理前整体拒绝。"
	)
	_expect(
		route_player.restore_run_scene_entry(progression),
		"Combat A→Route 必须从权威账本完成统一场景入口恢复。"
	)
	_expect(
		_capture_profile_projection(route_player) == combat_a_profile,
		"Route 面板实际读取的攻击/生命/攻速/移速/闪避/双防/技能/余额必须与 Combat A 全等。"
	)
	_expect_clean_full_health(route_player, "Route 场景入口")
	var first_route_projection := _capture_boundary_state(route_player)
	_expect(
		route_player.restore_run_scene_entry(progression)
		and _capture_boundary_state(route_player) == first_route_projection,
		"重复进入同一 Route 边界必须幂等，不能再次累加升级或收藏品。"
	)
	await _assert_profile_ui_reads_all_fields(route_player)

	route_player.queue_free()
	await process_frame
	var combat_b := await _spawn_player("CombatB")
	combat_b.set_xirang_balance(run_state.get_party_xirang_balance(0))
	_contaminate_scene_transients(combat_b)
	_expect(
		combat_b.restore_run_scene_entry(progression),
		"Route→Combat B 必须从同一稳定身份账本重建。"
	)
	_expect(
		_capture_profile_projection(combat_b) == combat_a_profile,
		"销毁旧 Player 后的新 Combat B 必须完整保持面板、收藏品、余额与技能冷却。"
	)
	_expect_clean_full_health(combat_b, "Combat B 场景入口")
	combat_b.queue_free()
	await process_frame


func _test_multiplayer_identity_and_owner_guards() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.register_multiplayer_peer_states(PackedInt32Array([41, 42])),
		"多人隔离夹具必须注册两个稳定成员。"
	)
	_expect(
		run_state.set_upgrade_level_for_peer(41, RunStateStore.StatType.ATTACK, 7)
		and run_state.set_skill1_upgrade_level_for_peer(41, 4)
		and run_state.set_upgrade_level_for_peer(42, RunStateStore.StatType.HEALTH, 5)
		and run_state.set_skill1_upgrade_level_for_peer(42, 1),
		"两名成员的不同成长高水位必须可独立建立。"
	)
	var peer_41 := await _spawn_multiplayer_player("Peer41", 41)
	var peer_42 := await _spawn_multiplayer_player("Peer42", 42)
	peer_41.set_xirang_balance(9_000)
	peer_42.set_xirang_balance(8_000)
	_expect(
		peer_41.restore_run_scene_entry(run_state.export_player_run_progression(41))
		and peer_42.restore_run_scene_entry(run_state.export_player_run_progression(42))
		and peer_41.attack_damage > peer_42.attack_damage
		and peer_42.max_health > peer_41.max_health
		and peer_41.skill1_upgrade_level == 4
		and peer_42.skill1_upgrade_level == 1,
		"多人新 Player 必须按 peer 独立重建，任何字段都不得串玩家。"
	)
	var before_wrong_owner := {
		"ledger": run_state.export_player_upgrade_ledger(),
		"balance_41": peer_41.current_xirang,
		"balance_42": peer_42.current_xirang,
	}
	_expect(
		not run_state.try_upgrade_for_peer(
			42,
			RunStateStore.StatType.DODGE,
			peer_41
		)
		and not run_state.try_upgrade_skill1_for_peer(42, peer_41)
		and run_state.export_player_upgrade_ledger()
		== before_wrong_owner["ledger"]
		and peer_41.current_xirang == int(before_wrong_owner["balance_41"])
		and peer_42.current_xirang == int(before_wrong_owner["balance_42"]),
		"wrong-player 购买必须零余额、零等级、零 revision 写入。"
	)
	var unstarted := RunStateStore.new()
	var balance_before_unstarted := peer_41.current_xirang
	_expect(
		not unstarted.try_upgrade(RunStateStore.StatType.ATTACK, peer_41)
		and not unstarted.try_upgrade_skill1_for_peer(41, peer_41)
		and not unstarted.run_started
		and unstarted.get_player_upgrade_ledger_revision() == 0
		and peer_41.current_xirang == balance_before_unstarted,
		"未开始 Run 的所有购买入口必须 fail-close 且不得隐式开局。"
	)
	unstarted.free()
	peer_41.queue_free()
	peer_42.queue_free()
	await process_frame


func _test_tower_persistent_modifier_projection() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	var research := ResearchCoordinator.new()
	research.player_technology_levels[0] = 3
	research.global_research_states[
		ResearchCoordinator.PLAYER_MOVE_SPEED_RESEARCH_ID
	] = ResearchCoordinator.GlobalResearchState.COMPLETED
	var fate := FateCoordinator.new()
	fate.player_max_health_multiplier = 1.25
	fate.player_move_speed_multiplier = 1.20
	fate.player_dash_cooldown_reduction = 0.75
	fate.hurt_speed_penalty_enabled = true
	fate.active_permanent_buff_ids.append(
		TowerDefenseFateRegistry.BUFF_LOW_HEALTH_REDUCTION
	)
	var projector := TowerRoguePlayerPersistentModifierProjector.new()
	_expect(projector.setup(research, fate), "Tower 持久投影器必须绑定 Research/Fate owner。")
	var progression := run_state.export_player_run_progression(0)

	var tower_player := await _spawn_player("TowerPlayer")
	_expect(
		tower_player.restore_run_scene_entry(progression, projector),
		"Tower Player 必须消费同一强类型持久层。"
	)
	var persistent_fields := _capture_tower_persistent_fields(tower_player)
	tower_player.set_tower_defense_life_tower_bonus_ratio(0.40)
	tower_player.set_tower_defense_speed_tower_bonus(25.0)
	tower_player.set_tower_defense_attack_speed_tower_bonus_ratio(0.30)

	var route_player := await _spawn_player("TowerRoutePlayer")
	_expect(
		route_player.restore_run_scene_entry(progression, projector)
		and _capture_tower_persistent_fields(route_player) == persistent_fields
		and is_zero_approx(route_player.get_tower_defense_life_tower_bonus_ratio())
		and is_zero_approx(route_player.get_tower_defense_speed_tower_bonus())
		and is_zero_approx(
			route_player.get_tower_defense_attack_speed_tower_bonus_ratio()
		),
		"Tower→Route 必须保留 Research/Fate 永久层，但不得携带建筑/aura 世界派生层。"
	)
	route_player.set_research_temporary_defense_bonuses(9, 8)
	route_player.tower_defense_fate_hurt_speed_time_left = 5.0
	_expect(
		route_player.restore_run_scene_entry(progression, projector)
		and route_player.research_temporary_physical_defense_bonus == 0
		and route_player.research_temporary_magic_defense_bonus == 0
		and is_zero_approx(route_player.tower_defense_fate_hurt_speed_time_left),
		"Research temporary 与 Fate hurt slow 必须作为场景瞬态清空。"
	)

	var combat_player := await _spawn_player("TowerCombatPlayer")
	_expect(
		combat_player.restore_run_scene_entry(progression, projector)
		and _capture_tower_persistent_fields(combat_player) == persistent_fields
		and is_zero_approx(combat_player.get_tower_defense_speed_tower_bonus()),
		"Route→Rogue Combat 新实例必须继续保留永久层且不带 Tower aura。"
	)
	# Tower 原实例仍由世界 owner 保有并重算自己的 aura；地下实例从未复制它。
	_expect(
		_capture_tower_persistent_fields(tower_player) == persistent_fields
		and is_equal_approx(tower_player.get_tower_defense_life_tower_bonus_ratio(), 0.40)
		and is_equal_approx(tower_player.get_tower_defense_speed_tower_bonus(), 25.0)
		and is_equal_approx(
			tower_player.get_tower_defense_attack_speed_tower_bonus_ratio(),
			0.30
		),
		"返回 Tower 后永久 owner 与世界局部 aura 必须各自保持唯一所有权。"
	)
	tower_player.queue_free()
	route_player.queue_free()
	combat_player.queue_free()
	research.free()
	fate.free()
	await process_frame


func _test_persistent_projection_signal_barrier() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	var xirang_scaling := PickupConfig.new()
	xirang_scaling.pickup_type = PickupConfig.PickupType.COLLECTIBLE
	xirang_scaling.can_store_in_inventory = true
	xirang_scaling.collectible_effect_id = "test_projection_signal_xirang"
	xirang_scaling.attack_speed_xirang_step = 1_000
	xirang_scaling.attack_speed_bonus_per_xirang_step = 2.0
	xirang_scaling.conditional_effect_id = PickupConfig.CONDITION_XIRANG_AT_LEAST
	xirang_scaling.conditional_xirang_threshold = 1_000
	xirang_scaling.conditional_attack_bonus = 9
	xirang_scaling.conditional_move_speed_bonus = 7.0
	_expect(
		run_state.try_add_item(xirang_scaling),
		"持久投影 signal 屏障夹具必须安装息壤条件收藏品。"
	)
	var route_player := await _spawn_player("ProjectionSignalPlayer")
	_expect(
		route_player.configure_xirang_ownership(
			Player.XirangOwnership.RUN_PARTY_LEDGER,
			0
		),
		"持久投影 signal 屏障夹具必须绑定 Party 息壤账本。"
	)
	var baseline_attack := route_player.attack_damage
	var baseline_move_speed := route_player.move_speed
	var baseline_attack_speed := route_player.get_attack_speed()
	route_player.current_health = 1
	_contaminate_scene_transients(route_player)
	var signal_counts := {
		"health": 0,
		"xirang": 0,
		"attack_speed": 0,
		"transient": 0,
		"revived": 0,
		"profile": 0,
	}
	route_player.health_changed.connect(func(_current: int, _maximum: int) -> void:
		signal_counts["health"] += 1
	)
	route_player.xirang_changed.connect(func(_total: int, _delta: int) -> void:
		signal_counts["xirang"] += 1
	)
	route_player.attack_speed_changed.connect(func(_value: float) -> void:
		signal_counts["attack_speed"] += 1
	)
	route_player.scene_transient_combat_state_cleared.connect(func() -> void:
		signal_counts["transient"] += 1
	)
	route_player.revived.connect(func() -> void:
		signal_counts["revived"] += 1
	)
	route_player.profile_display_changed.connect(func() -> void:
		signal_counts["profile"] += 1
	)
	var owner_observation := {
		"count": 0,
		"player_signals_before_owner_publish": false,
		"final_player_visible": false,
	}
	var owner_callback := func(_snapshot: Dictionary) -> void:
		owner_observation["count"] += 1
		owner_observation["player_signals_before_owner_publish"] = (
			int(signal_counts["health"]) != 0
			or int(signal_counts["xirang"]) != 0
			or int(signal_counts["attack_speed"]) != 0
			or int(signal_counts["transient"]) != 0
			or int(signal_counts["revived"]) != 0
			or int(signal_counts["profile"]) != 0
		)
		owner_observation["final_player_visible"] = (
			route_player.current_xirang == 1_500
			and route_player.attack_damage == baseline_attack + 9
			and is_equal_approx(
				route_player.move_speed,
				baseline_move_speed + 7.0
			)
			and route_player.get_attack_speed() > baseline_attack_speed
			and route_player.current_health == route_player.max_health
			and not route_player.is_dead
			and not route_player.has_damage_over_time_status(
				Player.BURN_STATUS_ID
			)
			and not route_player.has_damage_over_time_status(
				Player.BLEED_STATUS_ID
			)
		)
	run_state.party_xirang_ledger_changed.connect(owner_callback)
	route_player.begin_validated_persistent_projection_batch()
	_expect(
		run_state.set_party_xirang_balance(0, 1_500, false),
		"组合事务必须能先静默提交新的 Party 息壤高水位。"
	)
	route_player.commit_validated_run_party_xirang_balance(0, 1_500)
	route_player.stage_validated_persistent_projection_publish(true, true)
	# 先发布 owner；回调此时必须已能读到完整最终 Player，但任何 Player
	# signal 都不能抢在 owner 账本之前泄露半事务。
	run_state.party_xirang_ledger_changed.emit(
		run_state.export_party_xirang_ledger()
	)
	route_player.publish_validated_persistent_projection_batch()
	run_state.party_xirang_ledger_changed.disconnect(owner_callback)
	_expect(
		int(owner_observation["count"]) == 1
		and not bool(
			owner_observation["player_signals_before_owner_publish"]
		)
		and bool(owner_observation["final_player_visible"]),
		"首个 owner 回调只能观察到已同步息壤、条件收藏品、满血与无异常的完整 Player。"
	)
	_expect(
		int(signal_counts["health"]) == 1
		and int(signal_counts["xirang"]) == 1
		and int(signal_counts["attack_speed"]) == 1
		and int(signal_counts["transient"]) == 1
		and int(signal_counts["revived"]) == 1
		and int(signal_counts["profile"]) == 1,
		"事务发布必须精确补发一次 health/xirang/attack-speed/transient/revived/profile 契约 signal。"
	)
	route_player.queue_free()
	await process_frame


func _spawn_player(node_name: String) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.name = node_name
	fixture.add_child(player)
	player.set_physics_process(false)
	await process_frame
	return player


func _spawn_multiplayer_player(node_name: String, peer_id: int) -> Player:
	var player := await _spawn_player(node_name)
	player.configure_multiplayer_control(peer_id, false, node_name)
	return player


func _add_collectible_projection_fixtures(run_state: RunStateStore) -> void:
	var permanent := PickupConfig.new()
	permanent.pickup_type = PickupConfig.PickupType.COLLECTIBLE
	permanent.can_store_in_inventory = true
	permanent.collectible_effect_id = "test_scene_persistent"
	permanent.collectible_max_health_bonus = 7
	permanent.collectible_move_speed_bonus = 3.0
	permanent.collectible_attack_speed_bonus = 1.5
	permanent.collectible_physical_defense_bonus = 2
	permanent.collectible_magic_defense_bonus = 1
	var xirang_condition := PickupConfig.new()
	xirang_condition.pickup_type = PickupConfig.PickupType.COLLECTIBLE
	xirang_condition.can_store_in_inventory = true
	xirang_condition.collectible_effect_id = "test_scene_xirang_condition"
	xirang_condition.conditional_effect_id = PickupConfig.CONDITION_XIRANG_AT_LEAST
	xirang_condition.conditional_xirang_threshold = 1_000
	xirang_condition.conditional_attack_bonus = 5
	xirang_condition.conditional_move_speed_bonus = 4.0
	var low_health_condition := PickupConfig.new()
	low_health_condition.pickup_type = PickupConfig.PickupType.COLLECTIBLE
	low_health_condition.can_store_in_inventory = true
	low_health_condition.collectible_effect_id = "test_scene_low_health_condition"
	low_health_condition.conditional_effect_id = PickupConfig.CONDITION_HEALTH_BELOW
	low_health_condition.conditional_health_ratio_threshold = 0.40
	low_health_condition.conditional_max_health_bonus = 50
	_expect(
		run_state.try_add_item(permanent)
		and run_state.try_add_item(xirang_condition)
		and run_state.try_add_item(low_health_condition),
		"收藏品投影夹具必须进入 RunState 背包。"
	)


func _apply_all_persistent_stat_bonus_fixtures(
	run_state: RunStateStore,
	peer_id: int
) -> void:
	for bonus_case in [
		[&"max_health", 11],
		[&"physical_defense", 3],
		[&"magic_defense", 2],
		[&"move_speed", 6],
		[&"ammo_capacity", 2],
		[&"attack_damage", 4],
		[&"dodge_percent_points", 2],
		[&"dash_cooldown_reduction", 1],
	]:
		var next := run_state.build_party_status_ledger_with_player_stat_bonus(
			peer_id,
			StringName(bonus_case[0]),
			int(bonus_case[1])
		)
		_expect(
			not next.is_empty() and run_state.apply_party_status_ledger(next),
			"八类持久属性奖励必须逐项绝对提交。"
		)


func _contaminate_scene_transients(player: Player) -> void:
	_expect(player.apply_burn_status(&"scene_transition_test", 30.0, 1), "燃烧夹具必须激活。")
	_expect(player.apply_bleed_status(&"scene_transition_test", 30.0, 1), "流血夹具必须激活。")
	_expect(player.apply_cold_status(), "寒冷夹具必须激活。")
	_expect(
		player.apply_timed_move_slow(&"scene_transition_test", 30.0, 0.5),
		"限时减速夹具必须激活。"
	)
	player.network_effective_move_speed_multiplier_override = 0.25
	player.current_move_speed_multiplier = 1.8
	player.speed_buff_time_left = 20.0
	player.potion_move_speed_multiplier = 1.5
	player.potion_move_speed_time_left = 20.0
	player.potion_attack_damage_multiplier = 2.0
	player.potion_attack_damage_time_left = 20.0
	player.tower_defense_fate_hurt_speed_time_left = 20.0
	player.research_temporary_physical_defense_bonus = 9
	player.research_temporary_magic_defense_bonus = 8
	player.skill1_charge = player.skill1_charge_duration
	player.is_dead = true
	player.set_control_lock(Player.DEATH_CONTROL_LOCK_OWNER, true)


func _expect_clean_full_health(player: Player, boundary_name: String) -> void:
	_expect(
		player.current_health == player.max_health
		and not player.is_dead
		and not player.has_control_lock(Player.DEATH_CONTROL_LOCK_OWNER),
		"%s 必须复活、解除死亡锁并恢复满血。" % boundary_name
	)
	_expect(
		not player.has_damage_over_time_status(Player.BURN_STATUS_ID)
		and not player.has_damage_over_time_status(Player.BLEED_STATUS_ID)
		and player.get_cold_stack_count() == 0
		and is_equal_approx(player.timed_move_slow_multiplier, 1.0)
		and is_zero_approx(player.network_effective_move_speed_multiplier_override)
		and is_equal_approx(
			player.current_move_speed_multiplier,
			Player.DEFAULT_MOVE_SPEED_MULTIPLIER
		)
		and is_zero_approx(player.speed_buff_time_left)
		and is_zero_approx(player.potion_move_speed_time_left)
		and is_zero_approx(player.potion_attack_damage_time_left)
		and is_zero_approx(player.tower_defense_fate_hurt_speed_time_left)
		and player.research_temporary_physical_defense_bonus == 0
		and player.research_temporary_magic_defense_bonus == 0
		and is_zero_approx(player.skill1_charge),
		"%s 必须清除燃烧/流血/寒冷/减速/药水/网络覆盖/Fate hurt/研究临时层/技能充能。"
		% boundary_name
	)


func _capture_profile_projection(player: Player) -> Dictionary:
	return {
		"attack_damage": player.attack_damage,
		"max_health": player.max_health,
		"attack_speed": player.get_attack_speed(),
		"move_speed": player.move_speed,
		"dodge_chance": player.dodge_chance,
		"physical_defense": player.physical_defense,
		"magic_defense": player.magic_defense,
		"ammo_capacity": (player as AmmoRangedPlayer).get_ammo_capacity(),
		"dash_cooldown": player.get_dash_cooldown(),
		"skill1_upgrade_level": player.skill1_upgrade_level,
		"skill1_charge_duration": player.skill1_charge_duration,
		"current_xirang": player.current_xirang,
	}


func _capture_boundary_state(player: Player) -> Dictionary:
	return {
		"profile": _capture_profile_projection(player),
		"current_health": player.current_health,
		"is_dead": player.is_dead,
		"burn": player.has_damage_over_time_status(Player.BURN_STATUS_ID),
		"bleed": player.has_damage_over_time_status(Player.BLEED_STATUS_ID),
		"cold": player.get_cold_stack_count(),
		"timed_slow": player.timed_move_slow_multiplier,
		"network_override": player.network_effective_move_speed_multiplier_override,
		"potion_time": player.potion_move_speed_time_left,
	}


func _capture_tower_persistent_fields(player: Player) -> Dictionary:
	return {
		"technology": player.get_research_technology_level(),
		"research_move": player.research_global_move_speed_bonus,
		"fate_health": player.tower_defense_fate_max_health_multiplier,
		"fate_move": player.tower_defense_fate_move_speed_multiplier,
		"fate_dash": player.tower_defense_fate_dash_cooldown_reduction,
		"fate_low_ratio": player.tower_defense_fate_low_health_ratio,
		"fate_low_reduction": player.tower_defense_fate_low_health_damage_reduction,
	}


func _assert_profile_ui_reads_all_fields(player: Player) -> void:
	var panel := PROFILE_SCENE.instantiate() as BasicPlayerProfilePanel
	fixture.add_child(panel)
	await process_frame
	panel.bind_player(player)
	panel.stats_view.refresh()
	_expect(
		panel.attack_value.text == str(player.attack_damage)
		and panel.health_value.text == "%d / %d" % [player.current_health, player.max_health]
		and panel.move_speed_value.text == str(roundi(player.move_speed))
		and panel.dodge_value.text
		== "%.0f%%" % (clampf(player.dodge_chance, 0.0, 1.0) * 100.0)
		and panel.physical_defense_value.text == str(player.physical_defense)
		and panel.magic_defense_value.text == str(player.magic_defense)
		and panel.skill_cost_label.text
		== "技力需求%d" % roundi(player.skill1_charge_duration),
		"Profile UI 必须从 Player 当前权威投影读取全部面板字段与技能需求。"
	)
	var rounded_attack_speed := roundf(player.get_attack_speed())
	var expected_attack_speed_text := (
		str(roundi(rounded_attack_speed))
		if is_equal_approx(player.get_attack_speed(), rounded_attack_speed)
		else "%.2f" % player.get_attack_speed()
	)
	_expect(
		panel.attack_speed_value.text == expected_attack_speed_text,
		"Profile UI 攻速格式化也必须来自持久后的最终值。"
	)
	panel.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
