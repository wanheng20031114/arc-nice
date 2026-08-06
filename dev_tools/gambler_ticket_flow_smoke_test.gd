extends SceneTree

const TICKET := preload(
	"res://resources/config/materials/material_gambler_ticket.tres"
)
const DIRT := preload(
	"res://resources/config/materials/material_dirt_block.tres"
)
const APPLE := preload(
	"res://resources/config/collectibles/collectible_apple.tres"
)
const LUOXI_SCENE := preload(
	"res://scene/game_modes/tower_defense/merchants/luoxi/tower_defense_luoxi_merchant.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const OVERLAY_SCENE := preload(
	"res://scene/game_modes/tower_defense/merchants/luoxi/luoxi_special_game_overlay.tscn"
)


class TestSceneRoot:
	extends Node
	var finish_requests: Array[int] = []
	var special_game_supported := true

	func supports_luoxi_special_game() -> bool:
		return special_game_supported

	func request_luoxi_special_game_finish(session_revision: int) -> void:
		finish_requests.append(session_revision)


class TestGame:
	extends Node

	var runtime_mode := CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var wave_state := CombatFlowState.State.PRE_WAVE
	var player: Player = null
	var damageable_players: Array[Player] = []
	var test_core_health := 100
	var cancel_sessions_on_core_damage := false
	var coordinator_to_cancel: LuoxiSpecialGameCoordinator = null
	var campaign: TowerDefenseCampaignCoordinator = null
	var home: TowerDefenseHomeDefenseCoordinator = null
	var roster: TowerDefensePlayerRosterCoordinator = null
	var adapter: TowerDefenseMultiplayerModeAdapter = null


class TestMultiplayerAdapter:
	extends TowerDefenseMultiplayerModeAdapter

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
		if next_health <= 0:
			target_player.is_dead = true
		return applied


class TestHomeDefenseCoordinator:
	extends TowerDefenseHomeDefenseCoordinator

	var test_game: TestGame = null

	func apply_base_damage(amount: int) -> int:
		var previous := test_game.test_core_health
		test_game.test_core_health = maxi(
			test_game.test_core_health - maxi(amount, 0),
			0
		)
		if (
			test_game.cancel_sessions_on_core_damage
			and test_game.coordinator_to_cancel != null
		):
			test_game.coordinator_to_cancel.cancel_all()
		return previous - test_game.test_core_health


var failures: Array[String] = []
var test_root: Node
var run_state: RunStateStore


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = TestSceneRoot.new()
	test_root.name = "GamblerTicketFlowSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	run_state = root.get_node("RunState") as RunStateStore

	_test_ticket_dialogue_and_atomic_consumption()
	_test_delayed_rewards_and_immediate_costs()
	_test_inventory_full_keeps_session_atomic()
	_test_player_death_voids_pending_rewards()
	_test_terminal_and_core_interruption_guards()
	await _test_overlay_copy_and_xirang_icon_contract()
	await _test_merchant_session_ui_guards()

	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("GAMBLER_TICKET_FLOW_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_ticket_dialogue_and_atomic_consumption() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(run_state.try_add_item_count(TICKET, 2), "测试背包应能加入两张券。")
	var player_instance := _make_player(0, 100)
	var merchant := LuoxiMerchant.new()
	merchant.is_active = true
	var dialogue_probe := LUOXI_SCENE.instantiate() as TowerDefenseLuoxiMerchant
	test_root.add_child(dialogue_probe)
	var lines := dialogue_probe.call("_build_dialogue_lines", player_instance) as Array
	_expect(
		lines == ["我注意到你持有赌怪专用券", "是否要使用赌怪专用券？"],
		"持券玩家必须优先进入两句精确的特殊对话。"
	)
	(test_root as TestSceneRoot).special_game_supported = false
	var unsupported_lines := dialogue_probe.call(
		"_build_dialogue_lines",
		player_instance
	) as Array
	_expect(
		unsupported_lines == LuoxiMerchant.DIALOGUE_LINES,
		"不支持特殊牌局的标准模式不得被持券对话截断。"
	)
	(test_root as TestSceneRoot).special_game_supported = true
	dialogue_probe.queue_free()

	var game := TestGame.new()
	game.player = player_instance
	game.damageable_players = [player_instance]
	var coordinator := LuoxiSpecialGameCoordinator.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260729
	_configure_coordinator(coordinator, game, merchant, rng)

	var revision_before := run_state.get_inventory_revision()
	var start_result := coordinator.start_for_peer(0)
	_expect(
		int(start_result.get("result_code", -1))
		== LuoxiSpecialGameCoordinator.ResultCode.SUCCESS,
		"合法持券玩家应能开始特殊牌局。"
	)
	_expect(
		run_state.get_inventory_item_total(TICKET) == 1,
		"开始牌局必须恰好消耗一张券。"
	)
	_expect(
		run_state.get_inventory_revision() == revision_before + 1,
		"消费券必须作为一次原子库存事务推进 revision。"
	)
	var resumed_result := coordinator.start_for_peer(0)
	_expect(bool(resumed_result.get("resumed", false)), "重复开始请求应恢复既有牌局。")
	_expect(
		run_state.get_inventory_item_total(TICKET) == 1,
		"重复开始请求不得重复消费券。"
	)
	var revision := int(start_result.get("session_revision", 0))
	var finish_result := coordinator.finish_for_peer(0, revision)
	_expect(
		int(finish_result.get("result_code", -1))
		== LuoxiSpecialGameCoordinator.ResultCode.SUCCESS,
		"零张翻牌时按下“直接跑路”应正常结束。"
	)
	_expect(
		int(coordinator.finish_for_peer(0, revision).get("result_code", -1))
		== LuoxiSpecialGameCoordinator.ResultCode.STALE_SESSION,
		"已结束牌局不得被重复结算。"
	)
	coordinator.free()
	game.campaign.free()
	game.home.free()
	game.roster.free()
	game.adapter.free()
	game.free()
	merchant.free()
	player_instance.free()


func _test_delayed_rewards_and_immediate_costs() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var player_instance := _make_player(0, 100)
	var other_player := _make_player(2, 200)
	var game := TestGame.new()
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.player = player_instance
	game.damageable_players = [player_instance, other_player]
	var coordinator := _make_coordinator(game)
	var session := _make_session(11, [
		_outcome(LuoxiSpecialGameRules.OutcomeKind.MATERIAL, 0, 1, DIRT.resource_path),
		_outcome(LuoxiSpecialGameRules.OutcomeKind.XIRANG, 0, 325),
		_outcome(
			LuoxiSpecialGameRules.OutcomeKind.HEALTH_DAMAGE,
			LuoxiSpecialGameRules.HealthEffect.OTHERS_CURRENT_PERCENT,
			90
		),
		_outcome(LuoxiSpecialGameRules.OutcomeKind.CORE_DAMAGE, 0, 1),
	])
	coordinator.sessions_by_peer[0] = session

	coordinator.reveal_for_peer(0, 11, 0)
	coordinator.reveal_for_peer(0, 11, 1)
	_expect(run_state.get_inventory_item_total(DIRT) == 0, "翻牌时材料必须只暂存。")
	_expect(player_instance.current_xirang == 0, "翻牌时奖励货币必须只暂存。")
	coordinator.reveal_for_peer(0, 11, 2)
	_expect(player_instance.current_health == 100, "90% 群体代价不得伤害自己。")
	_expect(other_player.current_health == 20, "其他玩家应立即损失 90% 当前生命。")
	coordinator.reveal_for_peer(0, 11, 3)
	_expect(game.test_core_health == 99, "核心生命代价必须在翻牌时立即生效。")
	var result := coordinator.finish_for_peer(0, 11)
	_expect(
		int(result.get("result_code", -1))
		== LuoxiSpecialGameCoordinator.ResultCode.SUCCESS,
		"合法的暂存奖励应能统一结算。"
	)
	_expect(run_state.get_inventory_item_total(DIRT) == 1, "结束后应收到暂存材料。")
	_expect(player_instance.current_xirang == 325, "结束后应收到暂存奖励货币。")
	_free_flow_objects(coordinator, game, [player_instance, other_player])


func _test_inventory_full_keeps_session_atomic() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		run_state.inventory[slot_index] = APPLE
		run_state.inventory_stack_counts[slot_index] = 1
	var player_instance := _make_player(0, 100)
	var game := TestGame.new()
	game.player = player_instance
	game.damageable_players = [player_instance]
	var coordinator := _make_coordinator(game)
	coordinator.sessions_by_peer[0] = _make_session(21, [
		_outcome(LuoxiSpecialGameRules.OutcomeKind.MATERIAL, 0, 1, DIRT.resource_path),
		_outcome(LuoxiSpecialGameRules.OutcomeKind.XIRANG, 0, 100),
		_outcome(LuoxiSpecialGameRules.OutcomeKind.CORE_DAMAGE, 0, 1),
		_outcome(LuoxiSpecialGameRules.OutcomeKind.CORE_DAMAGE, 0, 1),
	])
	coordinator.reveal_for_peer(0, 21, 0)
	coordinator.reveal_for_peer(0, 21, 1)
	var blocked := coordinator.finish_for_peer(0, 21)
	_expect(
		int(blocked.get("result_code", -1))
		== LuoxiSpecialGameCoordinator.ResultCode.INVENTORY_FULL,
		"背包满时必须保留牌局等待重试。"
	)
	_expect(player_instance.current_xirang == 0, "物品结算失败时不得先发放货币。")
	_expect(coordinator.has_active_session(0), "结算失败后牌局必须仍然存在。")
	run_state.inventory[0] = null
	run_state.inventory_stack_counts[0] = 0
	var retried := coordinator.finish_for_peer(0, 21)
	_expect(
		int(retried.get("result_code", -1))
		== LuoxiSpecialGameCoordinator.ResultCode.SUCCESS,
		"释放背包空间后应能重试统一结算。"
	)
	_expect(player_instance.current_xirang == 100, "重试成功后货币只能发放一次。")
	_free_flow_objects(coordinator, game, [player_instance])


func _test_player_death_voids_pending_rewards() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var player_instance := _make_player(0, 100)
	var game := TestGame.new()
	game.player = player_instance
	game.damageable_players = [player_instance]
	var coordinator := _make_coordinator(game)
	coordinator.sessions_by_peer[0] = _make_session(31, [
		_outcome(LuoxiSpecialGameRules.OutcomeKind.MATERIAL, 0, 1, DIRT.resource_path),
		_outcome(
			LuoxiSpecialGameRules.OutcomeKind.HEALTH_DAMAGE,
			LuoxiSpecialGameRules.HealthEffect.SELF_FIXED,
			3250
		),
		_outcome(LuoxiSpecialGameRules.OutcomeKind.XIRANG, 0, 9999),
		_outcome(LuoxiSpecialGameRules.OutcomeKind.CORE_DAMAGE, 0, 1),
	])
	coordinator.reveal_for_peer(0, 31, 0)
	var death_result := coordinator.reveal_for_peer(0, 31, 1)
	_expect(player_instance.is_dead, "致死生命代价必须立即杀死当前玩家。")
	_expect(bool(death_result.get("cancelled", false)), "当前玩家死亡必须标记牌局作废。")
	_expect(not coordinator.has_active_session(0), "作废牌局必须立即移除服务端会话。")
	_expect(run_state.get_inventory_item_total(DIRT) == 0, "死亡作废不得发放已暂存物品。")
	_expect(player_instance.current_xirang == 0, "死亡作废不得发放已暂存货币。")
	_free_flow_objects(coordinator, game, [player_instance])


func _test_terminal_and_core_interruption_guards() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(run_state.try_add_item(TICKET), "终局门禁测试应能加入一张券。")
	var player_instance := _make_player(0, 100)
	var game := TestGame.new()
	game.player = player_instance
	game.damageable_players = [player_instance]
	game.wave_state = CombatFlowState.State.VICTORY
	var coordinator := _make_coordinator(game)
	var terminal_result := coordinator.start_for_peer(0)
	_expect(
		int(terminal_result.get("result_code", -1))
		== LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER,
		"胜利或失败状态不得新建特殊牌局。"
	)
	_expect(run_state.get_inventory_item_total(TICKET) == 1, "终局拒绝开局不得扣券。")

	game.wave_state = CombatFlowState.State.PRE_WAVE
	coordinator.sessions_by_peer[0] = _make_session(41, [
		_outcome(LuoxiSpecialGameRules.OutcomeKind.CORE_DAMAGE, 0, 5),
		_outcome(LuoxiSpecialGameRules.OutcomeKind.XIRANG, 0, 100),
		_outcome(LuoxiSpecialGameRules.OutcomeKind.CORE_DAMAGE, 0, 1),
		_outcome(LuoxiSpecialGameRules.OutcomeKind.CORE_DAMAGE, 0, 1),
	])
	game.cancel_sessions_on_core_damage = true
	game.coordinator_to_cancel = coordinator
	var interrupted := coordinator.reveal_for_peer(0, 41, 0)
	_expect(
		bool(interrupted.get("cancelled", false))
		and int(interrupted.get("result_code", -1))
		== LuoxiSpecialGameCoordinator.ResultCode.STALE_SESSION,
		"核心代价触发终局并清局后不得再返回虚假成功。"
	)
	_expect(not coordinator.has_active_session(0), "核心终局中断后不得遗留牌局。")
	_free_flow_objects(coordinator, game, [player_instance])


func _test_overlay_copy_and_xirang_icon_contract() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as LuoxiSpecialGameOverlay
	test_root.add_child(overlay)
	await process_frame
	overlay.show_game(41)
	_expect(overlay.finish_button.text == "直接跑路！", "零张翻牌按钮文案必须精确匹配。")
	overlay.reveal_card(
		0,
		_outcome(LuoxiSpecialGameRules.OutcomeKind.XIRANG, 0, 799)
	)
	_expect(overlay.finish_button.text == "见好就收！", "部分翻牌按钮文案必须精确匹配。")
	_expect(
		not overlay.card_titles[0].text.contains("息壤")
		and not overlay.card_descriptions[0].text.contains("息壤")
		and overlay.card_icons[0].texture != null,
		"该奖励卡必须只使用图标与数量，不得写出名称。"
	)
	overlay.reveal_card(1, LuoxiSpecialGameRules.make_blank_outcome())
	_expect(
		overlay.card_blank_messages[1].visible
		and not overlay.card_contents[1].visible
		and overlay.card_blank_messages[1].text == "什么都没有"
		and overlay.card_icons[1].texture == null
		and overlay.card_titles[1].text.is_empty()
		and overlay.card_descriptions[1].text.is_empty(),
		"空白牌正面必须只显示一行“什么都没有”。"
	)
	_expect(
		overlay.status_label.text == "这张牌什么都没有；你可以继续翻牌或结束",
		"空白牌不得被描述为已经暂存奖励。"
	)
	for card_index in range(2, 4):
		overlay.reveal_card(
			card_index,
			_outcome(LuoxiSpecialGameRules.OutcomeKind.CORE_DAMAGE, 0, 1)
		)
	_expect(overlay.finish_button.text == "结束", "四张全翻按钮文案必须精确匹配。")
	overlay.show_game(42)
	_expect(
		not overlay.card_blank_messages[1].visible
		and overlay.card_contents[1].visible,
		"开启下一局时必须恢复空白牌占用的普通卡牌内容区。"
	)
	overlay.queue_free()
	await process_frame


func _test_merchant_session_ui_guards() -> void:
	var merchant := LUOXI_SCENE.instantiate() as TowerDefenseLuoxiMerchant
	var player_instance := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(merchant)
	test_root.add_child(player_instance)
	await process_frame
	merchant.set_active(true)
	merchant.active_player = player_instance
	merchant.special_game_player = player_instance
	merchant.special_game_session_revision = 51
	merchant.nearby_players[player_instance.get_instance_id()] = player_instance
	merchant.special_game_overlay.show_game(51)
	player_instance.set_controls_locked(true)
	merchant.apply_special_game_finished({
		"result_code": LuoxiSpecialGameCoordinator.ResultCode.INVENTORY_FULL,
		"session_revision": 51,
	})
	_expect(not merchant.special_game_overlay.is_open(), "背包满时应退出全屏遮罩。")
	_expect(not player_instance.controls_locked, "背包满时必须解锁玩家以便整理背包。")
	_expect(merchant.special_game_resume_pending, "背包满时必须保留本局恢复入口。")
	_expect(
		merchant.special_game_session_revision == 51,
		"暂停整理背包不得丢失服务端 session revision。"
	)
	var resume_lines := merchant.call("_build_dialogue_lines", player_instance) as Array
	_expect(
		resume_lines
		== TowerDefenseLuoxiMerchant.SPECIAL_GAME_RESUME_DIALOGUE_LINES,
		"整理背包后再次交互必须恢复原局，而不是要求第二张券。"
	)

	merchant.special_game_request_player = player_instance
	player_instance.set_controls_locked(true)
	merchant.apply_special_game_started({
		"result_code": LuoxiSpecialGameCoordinator.ResultCode.SUCCESS,
		"session_revision": 51,
		"revealed_cards": [],
	})
	_expect(merchant.special_game_overlay.is_open(), "恢复回包应重新打开原局界面。")
	_expect(player_instance.controls_locked, "牌局界面打开时玩家必须保持锁定。")
	merchant.abort_special_game()
	_expect(not player_instance.controls_locked, "终局中止牌局必须恢复玩家控制。")

	merchant.active_player = player_instance
	merchant.special_game_request_player = player_instance
	player_instance.set_controls_locked(true)
	merchant.nearby_players.erase(player_instance.get_instance_id())
	var finish_count_before := (test_root as TestSceneRoot).finish_requests.size()
	merchant.apply_special_game_started({
		"result_code": LuoxiSpecialGameCoordinator.ResultCode.SUCCESS,
		"session_revision": 52,
		"revealed_cards": [],
	})
	_expect(not merchant.special_game_overlay.is_open(), "离开范围后的晚到开局回包不得打开界面。")
	_expect(not player_instance.controls_locked, "拒绝晚到开局回包时必须恢复玩家控制。")
	_expect(
		(test_root as TestSceneRoot).finish_requests.size() == finish_count_before + 1
		and (test_root as TestSceneRoot).finish_requests[-1] == 52,
		"被放弃的晚到牌局必须显式请求服务端结束，不能遗留会话。"
	)

	merchant.queue_free()
	player_instance.queue_free()
	await process_frame


func _make_coordinator(game: TestGame) -> LuoxiSpecialGameCoordinator:
	var merchant := LuoxiMerchant.new()
	merchant.is_active = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var coordinator := LuoxiSpecialGameCoordinator.new()
	_configure_coordinator(coordinator, game, merchant, rng)
	coordinator.set_meta("test_merchant", merchant)
	return coordinator


func _configure_coordinator(
	coordinator: LuoxiSpecialGameCoordinator,
	game: TestGame,
	merchant: LuoxiMerchant,
	rng: RandomNumberGenerator
) -> void:
	game.campaign = TowerDefenseCampaignCoordinator.new()
	game.campaign.wave_state = game.wave_state
	var home := TestHomeDefenseCoordinator.new()
	home.test_game = game
	game.home = home
	game.roster = TowerDefensePlayerRosterCoordinator.new()
	game.roster.runtime_mode = game.runtime_mode
	game.roster.local_player = game.player
	game.roster.peer_players.clear()
	for player_instance in game.damageable_players:
		game.roster.peer_players[player_instance.peer_id] = player_instance
	game.adapter = TestMultiplayerAdapter.new()
	coordinator.setup(
		game.campaign,
		game.home,
		game.roster,
		game.adapter,
		run_state,
		merchant,
		rng,
		true
	)


func _make_player(new_peer_id: int, health: int) -> Player:
	var result := Player.new()
	result.peer_id = new_peer_id
	result.max_health = health
	result.current_health = health
	return result


func _make_session(
	revision: int,
	outcomes: Array[Dictionary]
) -> LuoxiSpecialGameSession:
	var result := LuoxiSpecialGameSession.new()
	_expect(result.setup(revision, outcomes), "测试牌局数据应通过规则校验。")
	return result


func _outcome(
	kind: int,
	effect: int,
	amount: int,
	item_path: String = "",
	rarity: int = -1
) -> Dictionary:
	return {
		"kind": kind,
		"effect": effect,
		"amount": amount,
		"item_path": item_path,
		"rarity": rarity,
	}


func _free_flow_objects(
	coordinator: LuoxiSpecialGameCoordinator,
	game: TestGame,
	players: Array[Player]
) -> void:
	var merchant := coordinator.get_meta("test_merchant") as LuoxiMerchant
	coordinator.free()
	if merchant != null:
		merchant.free()
	game.campaign.free()
	game.home.free()
	game.roster.free()
	game.adapter.free()
	game.free()
	for player_instance in players:
		player_instance.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
