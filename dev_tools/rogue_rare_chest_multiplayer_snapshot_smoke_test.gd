extends SceneTree

const ROUTE_SCENE: PackedScene = preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const MP_ROUTE_SOURCE_PATH := "res://scene/multiplayer/mp_rogue_route.gd"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_mp_sender_source_contract()
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state == null:
		run_state = RunStateStore.new()
		run_state.name = "RunState"
		root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	run_state.register_multiplayer_peer_state(1)
	run_state.register_multiplayer_peer_state(2)
	var names := {1: "甲", 2: "乙"}
	var characters := {
		1: PlayerCharacterRegistry.WEISHIDAIER_ID,
		2: PlayerCharacterRegistry.HOE_CAT_ID,
	}
	var stable_keys := {1: "stable:alpha", 2: "stable:beta"}

	var host_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	host_route.auto_initialize = false
	host_route.manage_return_locally = false
	root.add_child(host_route)
	await process_frame
	_expect(
		host_route.configure_multiplayer_players(
			1,
			names,
			characters,
			stable_keys
		)
		and host_route.start_authoritative_session(0x5511, false),
		"多人 RareChest 快照测试必须能建立双人权威路线。"
	)
	var rare_seed := -1
	var peer_two_valid_options := (
		host_route.rare_chest_economy.get_valid_option_ids(2)
	)
	for seed_value in range(1024):
		if RogueRareChestRegistry.select_options(
			seed_value,
			"stable:beta",
			peer_two_valid_options
		).has(RogueRareChestRegistry.OPTION_MAX_HEALTH):
			rare_seed = seed_value
			break
	_expect(
		rare_seed >= 0
		and host_route.rare_chest_session.start_for_node(
			501,
			rare_seed,
			[1, 2],
			stable_keys
		),
		"双人 RareChest Session 必须生成各自私人候选。"
	)
	var peer_one_state := host_route.export_encounter_snapshot(1)
	var peer_two_state := host_route.export_encounter_snapshot(2)
	var public_state := host_route.export_encounter_snapshot()
	var rare_one := peer_one_state["rare_chest_state"] as Dictionary
	var rare_two := peer_two_state["rare_chest_state"] as Dictionary
	var rare_public := public_state["rare_chest_state"] as Dictionary
	_expect(
		(rare_one["local_option_ids"] as Array).size() == 3
		and (rare_two["local_option_ids"] as Array).size() == 3
		and (rare_public["local_option_ids"] as Array).is_empty()
		and int(rare_one["target_peer_id"]) == 1
		and int(rare_two["target_peer_id"]) == 2,
		"Route 必须按目标 peer 导出私人候选，默认缓存只能保留脱敏公共态。"
	)
	var peer_one_choice := StringName(
		(rare_one["local_option_ids"] as Array)[0]
	)
	_expect(
		host_route.host_submit_encounter_vote(
			1,
			str(rare_one["occurrence_key"]),
			int(rare_one["offer_revision"]),
			peer_one_choice
		),
		"既有多人 encounter vote 命令必须提交目标玩家的 RareChest 选择。"
	)
	var economy_for_one := host_route.export_encounter_economy_snapshot(1)
	var economy_for_two := host_route.export_encounter_economy_snapshot(2)
	var rare_economy_one := economy_for_one[
		"rare_chest_economy"
	] as Dictionary
	var rare_economy_two := economy_for_two[
		"rare_chest_economy"
	] as Dictionary
	_expect(
		(rare_economy_one["settled_choices"] as Array).size() == 1
		and (rare_economy_two["settled_choices"] as Array).is_empty(),
		"玩家甲的已选结果不得出现在玩家乙的 RareChest Economy 快照。"
	)

	var client_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	client_route.auto_initialize = false
	client_route.manage_return_locally = false
	root.add_child(client_route)
	await process_frame
	_expect(
		client_route.configure_multiplayer_players(
			2,
			names,
			characters,
			stable_keys
		),
		"客户端路线必须能创建玩家乙的本地角色。"
	)
	client_route.start_client_waiting()
	_expect(
		client_route.apply_full_snapshot(
			host_route.export_layout_snapshot(),
			host_route.export_state_snapshot(),
			host_route.export_encounter_snapshot(2),
			host_route.export_encounter_economy_snapshot(2),
			host_route.export_shop_snapshot_for_peer(2)
		),
		"面向玩家乙的 full snapshot 必须原子应用 RareChest 私人状态和共享属性账本。"
	)
	var client_private := client_route.rare_chest_session.export_state_for_peer(2)
	_expect(
		StringName(client_private.get("phase", &""))
		== RogueRareChestSession.PHASE_CHOOSING
		and (client_private.get("local_option_ids", []) as Array).size() == 3
		and StringName(client_private.get(
			"local_selected_option_id",
			&""
		)).is_empty(),
		"未选择的玩家乙应用完整快照后只能继续自己的私人三选一。"
	)
	_test_invalid_cross_peer_full_snapshot_is_atomic(
		host_route,
		client_route
	)
	_test_same_target_conflict_full_snapshot_is_atomic(
		host_route,
		client_route
	)
	await _test_completed_rewind_preserves_local_heal_lifecycle(
		host_route,
		client_route
	)
	client_route.queue_free()
	await process_frame
	_test_reconnect_does_not_recreate_historical_peer(
		host_route,
		run_state
	)

	host_route.queue_free()
	await process_frame
	_finish()


func _test_same_target_conflict_full_snapshot_is_atomic(
	host_route: RogueRouteGame,
	client_route: RogueRouteGame
) -> void:
	var route_state_before := client_route.export_state_snapshot()
	var advanced_state := host_route.export_state_snapshot().duplicate(true)
	var action_points := int(advanced_state.get("action_points", 0))
	advanced_state["action_points"] = (
		action_points + 1
		if action_points < RogueRouteRuntimeState.MAX_ACTION_POINTS
		else action_points - 1
	)
	advanced_state["action_points_revision"] = int(
		advanced_state.get("action_points_revision", 0)
	) + 1
	var stale_economy := host_route.export_encounter_economy_snapshot(2)
	var stale_rare_economy := stale_economy[
		"rare_chest_economy"
	] as Dictionary
	stale_rare_economy["revision"] = maxi(
		int(stale_rare_economy.get("revision", 0)) - 1,
		0
	)
	stale_economy["rare_chest_economy"] = stale_rare_economy
	_expect(
		not client_route.apply_full_snapshot(
			host_route.export_layout_snapshot(),
			advanced_state,
			host_route.export_encounter_snapshot(2),
			stale_economy,
			host_route.export_shop_snapshot_for_peer(2)
		)
		and client_route.export_state_snapshot() == route_state_before,
		"同目标但陈旧 Rare economy 的 full snapshot 必须在路线状态写入前原子拒绝。"
	)


func _test_completed_rewind_preserves_local_heal_lifecycle(
	host_route: RogueRouteGame,
	client_route: RogueRouteGame
) -> void:
	var local_player := client_route.get_player_for_peer(2)
	_expect(local_player != null, "完成态 rewind 回归必须取得客户端本地玩家。")
	if local_player == null:
		return
	var host_private := host_route.export_encounter_snapshot(2)[
		"rare_chest_state"
	] as Dictionary
	var offered := host_private.get("local_option_ids", []) as Array
	_expect(
		offered.has(String(RogueRareChestRegistry.OPTION_MAX_HEALTH)),
		"完成态 rewind 夹具必须给本地玩家生成生命强化。"
	)
	local_player.current_health = maxi(local_player.max_health - 20, 1)
	var health_before := local_player.current_health
	var client_revision := client_route.rare_chest_session.get_revision()
	_expect(
		host_route.host_submit_encounter_vote(
			2,
			str(host_private["occurrence_key"]),
			int(host_private["offer_revision"]),
			RogueRareChestRegistry.OPTION_MAX_HEALTH
		),
		"完成态 rewind 夹具必须先由 Host 权威结算生命强化。"
	)
	var completed_encounter := host_route.export_encounter_snapshot(2)
	var completed_rare := completed_encounter[
		"rare_chest_state"
	] as Dictionary
	completed_rare["revision"] = maxi(client_revision - 1, 0)
	completed_encounter["rare_chest_state"] = completed_rare
	var completed_economy := host_route.export_encounter_economy_snapshot(2)
	_expect(
		client_route.apply_full_snapshot(
			host_route.export_layout_snapshot(),
			host_route.export_state_snapshot(),
			completed_encounter,
			completed_economy,
			host_route.export_shop_snapshot_for_peer(2)
		)
		and local_player.current_health == health_before + 10
		and client_route.rare_chest_overlay.visible,
		"同 occurrence choosing→completed rewind 必须保留已呈现生命周期并只补发一次治疗。"
	)
	await create_timer(0.85).timeout
	var health_after_first := local_player.current_health
	_expect(
		client_route.apply_full_snapshot(
			host_route.export_layout_snapshot(),
			host_route.export_state_snapshot(),
			completed_encounter,
			completed_economy,
			host_route.export_shop_snapshot_for_peer(2)
		)
		and local_player.current_health == health_after_first
		and not client_route.rare_chest_overlay.visible,
		"同一 completed full snapshot 重放不得重新显示界面或重复治疗。"
	)
	var cumulative_mismatch := completed_economy.duplicate(true)
	var mismatch_rare := cumulative_mismatch[
		"rare_chest_economy"
	] as Dictionary
	var settlements := (
		mismatch_rare.get("settled_choices", []) as Array
	).duplicate(true)
	if not settlements.is_empty():
		var prior_entry := (settlements[0] as Dictionary).duplicate(true)
		var prior_result := (
			prior_entry.get("result", {}) as Dictionary
		).duplicate(true)
		prior_result["occurrence_key"] = "prior:rare_chest"
		prior_entry["settlement_key"] = "prior:rare_chest|peer:2"
		prior_entry["result"] = prior_result
		settlements.append(prior_entry)
	mismatch_rare["revision"] = int(mismatch_rare.get("revision", 0)) + 1
	mismatch_rare["settled_choices"] = settlements
	cumulative_mismatch["rare_chest_economy"] = mismatch_rare
	_expect(
		not client_route.apply_full_snapshot(
			host_route.export_layout_snapshot(),
			host_route.export_state_snapshot(),
			completed_encounter,
			cumulative_mismatch,
			host_route.export_shop_snapshot_for_peer(2)
		),
		"私人 settlement 的同属性累计 delta 超过共享账本绝对值时必须原子拒绝。"
	)


func _test_invalid_cross_peer_full_snapshot_is_atomic(
	host_route: RogueRouteGame,
	client_route: RogueRouteGame
) -> void:
	var local_player := client_route.get_player_for_peer(2)
	_expect(local_player != null, "原子拒绝回归必须取得客户端本地玩家。")
	if local_player == null:
		return
	local_player.current_health = maxi(local_player.max_health - 30, 1)
	var choosing := {
		"phase": String(RogueRareChestSession.PHASE_CHOOSING),
		"occurrence_key": "atomic:heal:rare_chest",
		"local_option_ids": [
			String(RogueRareChestRegistry.OPTION_MAX_HEALTH),
			String(RogueRareChestRegistry.OPTION_ATTACK_DAMAGE),
			String(RogueRareChestRegistry.OPTION_MOVE_SPEED),
		],
		"local_selected_option_id": "",
	}
	client_route.call("_apply_remote_rare_chest_local_health_reward", choosing)
	var selected := choosing.duplicate(true)
	selected["phase"] = String(RogueRareChestSession.PHASE_WAITING)
	selected["local_selected_option_id"] = String(
		RogueRareChestRegistry.OPTION_MAX_HEALTH
	)
	client_route.call("_apply_remote_rare_chest_local_health_reward", selected)
	var health_after_reward: int = local_player.current_health
	var session_revision := client_route.rare_chest_session.get_revision()
	var session_occurrence := client_route.rare_chest_session.get_occurrence_key()
	var invalid_encounter := host_route.export_encounter_snapshot(1)
	var invalid_rare := invalid_encounter["rare_chest_state"] as Dictionary
	invalid_rare["revision"] = maxi(session_revision - 1, 0)
	invalid_encounter["rare_chest_state"] = invalid_rare
	_expect(
		not client_route.apply_full_snapshot(
			host_route.export_layout_snapshot(),
			host_route.export_state_snapshot(),
			invalid_encounter,
			host_route.export_encounter_economy_snapshot(1),
			host_route.export_shop_snapshot_for_peer(2)
		)
		and client_route.rare_chest_session.get_revision() == session_revision
		and client_route.rare_chest_session.get_occurrence_key()
		== session_occurrence,
		"交叉投递其他 peer 私照必须在 full snapshot 任一运行态重置前原子拒绝。"
	)
	client_route.call("_apply_remote_rare_chest_local_health_reward", selected)
	_expect(
		local_player.current_health == health_after_reward,
		"无效 full snapshot 不得清除旧 occurrence 的本地治疗去重记录。"
	)


func _test_reconnect_does_not_recreate_historical_peer(
	host_route: RogueRouteGame,
	run_state: RunStateStore
) -> void:
	const OLD_PEER_ID := 2
	const NEW_PEER_ID := 4
	var membership_revision := (
		run_state.get_multiplayer_session_membership_revision() + 1
	)
	var remap_result := run_state.remap_multiplayer_peer_state(
		OLD_PEER_ID,
		NEW_PEER_ID,
		membership_revision
	)
	var route_migrated := (
		remap_result == RunStateStore.MultiplayerPeerRemapResult.MIGRATED
		and host_route.migrate_multiplayer_player(
			OLD_PEER_ID,
			NEW_PEER_ID,
			"乙重连",
			PlayerCharacterRegistry.HOE_CAT_ID
		)
	)
	var stable_key_updated := (
		route_migrated
		and host_route.set_multiplayer_participant_stable_key(
			NEW_PEER_ID,
			"stable:beta"
		)
	)
	_expect(
		stable_key_updated,
		(
			"重连回归夹具必须先完成 RunState、角色节点与稳定身份迁移"
			+ "（remap=%d route=%s stable=%s）。"
			% [remap_result, route_migrated, stable_key_updated]
		)
	)
	var xirang_revision := run_state.get_party_xirang_ledger_revision()
	var status_revision := run_state.get_party_status_ledger_revision()
	host_route.host_migrate_encounter_peer(OLD_PEER_ID, NEW_PEER_ID)
	# 强制走一次完整经济导出；旧实现会在这里通过 ensure 重建 old peer。
	host_route.export_encounter_economy_snapshot(NEW_PEER_ID)
	_expect(
		not run_state.has_multiplayer_peer_state(OLD_PEER_ID)
		and run_state.has_multiplayer_peer_state(NEW_PEER_ID)
		and not host_route.rare_chest_session.get_economy_peer_ids().has(
			OLD_PEER_ID
		)
		and host_route.rare_chest_session.get_economy_peer_ids().has(
			NEW_PEER_ID
		)
		and run_state.get_party_xirang_ledger_revision() == xirang_revision
		and run_state.get_party_status_ledger_revision() == status_revision,
		"RareChest 历史参与者只能保留进度，不得重建 ghost RunState 或额外推进账本 revision。"
	)


func _test_mp_sender_source_contract() -> void:
	var file := FileAccess.open(MP_ROUTE_SOURCE_PATH, FileAccess.READ)
	_expect(file != null, "多人路线脚本必须可读。")
	if file == null:
		return
	var source := file.get_as_text()
	_expect(
		source.count("export_encounter_snapshot(peer_id)") >= 2
		and source.count("export_encounter_economy_snapshot(peer_id)") >= 2
		and source.contains("_send_encounter_snapshot_to_peer(peer_id)"),
		"增量与完整快照发送都必须逐 peer 现场导出，不能复用含私人状态的共享缓存。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_RARE_CHEST_MULTIPLAYER_SNAPSHOT_SMOKE_TEST_OK")
		quit(0)
		return
	for message in failures:
		print("FAILED: %s" % message)
	quit(1)
