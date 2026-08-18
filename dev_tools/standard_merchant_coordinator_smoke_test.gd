extends SceneTree

const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/standard/merchant/standard_merchant_coordinator.tscn"
)
const APPLE_COLLECTIBLE := preload(
	"res://resources/config/collectibles/collectible_apple.tres"
)
const WATER_BOTTLE_MATERIAL := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)

var failures: Array[String] = []
var test_root: Node2D


class MerchantPlayerProbe:
	extends Player

	func has_collectible_effect(_effect_id: String) -> bool:
		return false

	func is_collectible_compatible(_item: PickupConfig) -> bool:
		return true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "StandardMerchantCoordinatorSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_source_boundaries()
	_test_disabled_tree_less_binding()
	_test_tree_less_rules_and_root_facade()
	await _test_disabled_static_runtime()
	await _test_static_runtime_activation()

	test_root.queue_free()
	await process_frame
	await physics_frame
	if failures.is_empty():
		print("STANDARD_MERCHANT_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_source_boundaries() -> void:
	var root_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/standard_game.gd"
	)
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/merchant/standard_merchant_coordinator.gd"
	)
	var standard_scene := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/standard_game.tscn"
	)
	for concrete_rule in [
		"LuoxiMerchant.get_collectible_for_path",
		"try_upgrade_skill1(",
		"is_collectible_available_for_inventory",
		"reset_intermission_state()",
		"bind_multiplayer_mode_adapter(",
	]:
		_expect(
			not root_source.contains(concrete_rule),
			"StandardGame 根不得继续实现商人具体规则：%s。" % concrete_rule
		)
	for forbidden_dependency in [
		"StandardGame",
		"TowerDefense",
		"current_scene",
		"get_tree()",
		"get_parent()",
		"get_node(",
		"get_node_or_null(",
		"DebugCollectibleWindow",
		"NodePath(\"../",
	]:
		_expect(
			not coordinator_source.contains(forbidden_dependency),
			"StandardMerchantCoordinator 不得反向猜测模式根或塔防实现：%s。"
			% forbidden_dependency
		)
	_expect(
		standard_scene.contains(
			"res://scene/game_modes/standard/merchant/standard_merchant_coordinator.tscn"
		)
		and standard_scene.contains("[node name=\"MerchantCoordinator\""),
		"StandardGame 场景必须静态实例化 MerchantCoordinator。"
	)


func _test_disabled_tree_less_binding() -> void:
	var fixture := _create_tree_less_fixture(false)
	var coordinator := fixture.get("coordinator") as StandardMerchantCoordinator
	var signal_count := {"value": 0}
	coordinator.merchant_active_changed.connect(
		func(_active: bool) -> void:
			signal_count["value"] = int(signal_count["value"]) + 1
	)
	_expect(
		coordinator.is_bound()
		and coordinator.get_merchant() == null
		and coordinator.get_luoxi_merchant() == null,
		"禁用标准商人时必须允许 null 商人依赖并保持协调器绑定。"
	)
	coordinator.set_active(true)
	coordinator.set_active(false)
	_expect(
		int(signal_count["value"]) == 0,
		"禁用商人时 active/deactivate 不得产生虚假的联机状态事件。"
	)
	_free_tree_less_fixture(fixture)


func _test_tree_less_rules_and_root_facade() -> void:
	var fixture := _create_tree_less_fixture(true)
	var game := fixture.get("game") as StandardGame
	var coordinator := fixture.get("coordinator") as StandardMerchantCoordinator
	var player := fixture.get("player") as Player
	var luoxi := fixture.get("luoxi") as LuoxiMerchant
	var run_state := fixture.get("run_state") as RunStateStore
	_expect(
		coordinator.is_bound()
		and game.merchant == fixture.get("merchant")
		and game.luoxi_merchant == luoxi,
		"Tree-less fixture 必须通过与生产相同的强类型 bind 驱动根 façade。"
	)

	var initial_charge_duration := player.skill1_charge_duration
	player.current_xirang = 225
	_expect(
		game.try_purchase_skill1_for_peer(4)
		== MerchantPurchaseResult.SkillUpgrade.UPGRADE_SUCCESS,
		"有效 peer 的 Skill1 升级必须保持成功结果码。"
	)
	_expect(
		player.current_xirang == 25
		and player.skill1_upgrade_level == 1
		and is_equal_approx(
			player.skill1_charge_duration,
			initial_charge_duration - 2.0
		),
		"Skill1 成功交易必须先扣除息壤并应用同一升级状态。"
	)
	_expect(
		game.try_purchase_skill1_for_peer(99)
		== MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER,
		"缺失 peer 必须在任何交易变更前返回 INVALID_PLAYER。"
	)

	luoxi.is_active = true
	player.current_xirang = 1800
	var expected_xirang := 1800
	for refresh_index in range(LuoxiMerchant.get_refresh_limit()):
		var cost := LuoxiMerchant.get_refresh_cost(refresh_index)
		_expect(
			game.try_refresh_luoxi_collectibles_for_peer(4)
			== MerchantPurchaseResult.OfferRefresh.SUCCESS,
			"第 %d 次 Luoxi 刷新必须保持成功。" % (refresh_index + 1)
		)
		expected_xirang -= cost
		_expect(
			player.current_xirang == expected_xirang
			and game.get_luoxi_collectible_refresh_count(4)
			== refresh_index + 1,
			"Luoxi 刷新必须保持扣款后再增加 peer refresh count 的顺序。"
		)
	_expect(
		game.try_refresh_luoxi_collectibles_for_peer(4)
		== MerchantPurchaseResult.OfferRefresh.LIMIT_REACHED
		and player.current_xirang == expected_xirang,
		"达到 refresh 上限后必须拒绝且不得继续扣款。"
	)

	_expect(
		game.try_claim_luoxi_collectible_for_peer(
			4,
			APPLE_COLLECTIBLE.resource_path
		) == MerchantPurchaseResult.CollectibleClaim.SUCCESS,
		"有效 peer 的 Luoxi claim 必须成功。"
	)
	_expect(
		run_state.get_item_for_peer(4, 0) == APPLE_COLLECTIBLE
		and game.get_luoxi_collectible_claim_count(4) == 1,
		"成功 claim 必须先写入背包，再记录唯一场间 claim。"
	)
	_expect(
		game.try_claim_luoxi_collectible_for_peer(
			4,
			APPLE_COLLECTIBLE.resource_path
		) == MerchantPurchaseResult.CollectibleClaim.ALREADY_CLAIMED,
		"同一 peer 的第二次 claim 必须在背包变更前被拒绝。"
	)
	var xirang_before_claimed_refresh := player.current_xirang
	_expect(
		game.try_refresh_luoxi_collectibles_for_peer(4)
		== MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
		and player.current_xirang == xirang_before_claimed_refresh,
		"已 claim 的 peer 必须在 refresh 扣款前被拒绝。"
	)

	game.record_luoxi_collectible_claim(7)
	game.call("_on_multiplayer_peer_restored", 7, 17)
	_expect(
		game.get_luoxi_collectible_claim_count(7) == 0
		and game.get_luoxi_collectible_claim_count(17) == 1,
		"peer restore 必须原子迁移 Luoxi claim ledger。"
	)

	if game.allows_debug_collectible_grants():
		_expect(
			game.grant_debug_collectible(APPLE_COLLECTIBLE.resource_path),
			"Debug collectible grant 必须经协调器 catalog/RunState 规则成功。"
		)
		var water_before := run_state.get_inventory_item_total_for_peer(
			4,
			WATER_BOTTLE_MATERIAL
		)
		_expect(
			game.grant_debug_collectible(WATER_BOTTLE_MATERIAL.resource_path)
			and run_state.get_inventory_item_total_for_peer(
				4,
				WATER_BOTTLE_MATERIAL
			)
			== water_before + 1,
			"Debug inventory grant 必须允许受信资源材料且每次只加入一个。"
		)
		_expect(
			not game.has_luoxi_collectible_claimed(0),
			"Debug collectible grant 不得消耗 Luoxi 场间 claim。"
		)
	_free_tree_less_fixture(fixture)


func _test_static_runtime_activation() -> void:
	var game := STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame 必须可实例化用于静态商人组合测试。")
	if game == null:
		return
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Host"},
		{1: &"weishidaier"}
	)
	game.set("auto_start_waves", false)
	var coordinator := game.get_node_or_null(
		"MerchantCoordinator"
	) as StandardMerchantCoordinator
	var coordinator_signal_count := {"value": 0}
	var adapter_signal_count := {"value": 0}
	coordinator.merchant_active_changed.connect(
		func(_active: bool) -> void:
			coordinator_signal_count["value"] = (
				int(coordinator_signal_count["value"]) + 1
			)
	)
	test_root.add_child(game)
	await process_frame
	await physics_frame
	game.multiplayer_mode_adapter.merchant_active_changed.connect(
		func(_active: bool) -> void:
			adapter_signal_count["value"] = (
				int(adapter_signal_count["value"]) + 1
			)
	)
	coordinator_signal_count["value"] = 0
	adapter_signal_count["value"] = 0
	_expect(
		coordinator != null
		and coordinator.is_bound()
		and game.merchant != null
		and game.luoxi_merchant != null,
		"生产 StandardGame 必须绑定静态 MerchantCoordinator 与两商人。"
	)
	game.luoxi_collectible_claim_counts[4] = 1
	game.luoxi_merchant.refresh_counts_by_player_key[4] = 2
	game.call("_set_merchant_active", true)
	_expect(
		game.merchant.is_active
		and game.luoxi_merchant.is_active
		and game.luoxi_collectible_claim_counts.is_empty()
		and game.luoxi_merchant.get_player_refresh_count(4) == 0,
		"进入场间必须依次清 claim/refresh 状态并激活两商人。"
	)
	game.call("_set_merchant_active", true)
	_expect(
		int(coordinator_signal_count["value"]) == 1
		and int(adapter_signal_count["value"]) == 1,
		"重复 active 不得重复发出 host merchant 状态。"
	)
	game.call("_set_merchant_active", false)
	_expect(
		not game.merchant.is_active
		and not game.luoxi_merchant.is_active
		and int(coordinator_signal_count["value"]) == 2
		and int(adapter_signal_count["value"]) == 2,
		"deactivate 必须关闭两商人并只发出一次 host 状态。"
	)
	game.call("_set_merchant_active", false)
	_expect(
		int(coordinator_signal_count["value"]) == 2
		and int(adapter_signal_count["value"]) == 2,
		"重复 deactivate 不得重复发出 host merchant 状态。"
	)
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_disabled_static_runtime() -> void:
	var game := STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "禁用商人场景必须可实例化。")
	if game == null:
		return
	game.standard_merchants_enabled = false
	game.set("auto_start_waves", false)
	for node_name in ["ZhuangfangyiMerchant", "LuoxiMerchant"]:
		var merchant_node := game.get_node_or_null(node_name)
		if merchant_node != null:
			game.remove_child(merchant_node)
			merchant_node.free()
	test_root.add_child(game)
	await process_frame
	await physics_frame
	_expect(
		game.merchant_coordinator != null
		and game.merchant_coordinator.is_bound()
		and game.merchant == null
		and game.luoxi_merchant == null,
		"standard_merchants_enabled=false 必须允许生产层级缺少两商人节点。"
	)
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _create_tree_less_fixture(
	standard_merchants_enabled: bool
) -> Dictionary:
	var game := StandardGame.new()
	game.name = "StandardGameFixture"
	var player_spawn := Marker2D.new()
	player_spawn.name = "PlayerSpawn"
	game.add_child(player_spawn)
	var roster := StandardPlayerRosterCoordinator.new()
	roster.name = "PlayerRosterCoordinator"
	game.add_child(roster)
	var adapter := StandardMultiplayerModeAdapter.new()
	adapter.name = "MultiplayerModeAdapter"
	game.add_child(adapter)
	var merchant := ZhuangfangyiMerchant.new()
	merchant.name = "ZhuangfangyiMerchant"
	game.add_child(merchant)
	var luoxi := LuoxiMerchant.new()
	luoxi.name = "LuoxiMerchant"
	game.add_child(luoxi)
	var coordinator := COORDINATOR_SCENE.instantiate() as StandardMerchantCoordinator
	game.add_child(coordinator)
	var player := MerchantPlayerProbe.new()
	player.name = "Player_4"
	player.peer_id = 4
	player.skill1_charge_duration = 18.0
	game.add_child(player)
	game.player = player
	game.peer_players[4] = player
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	roster.bind_dependencies(game, player_spawn, run_state)
	coordinator.bind_dependencies(
		merchant if standard_merchants_enabled else null,
		luoxi if standard_merchants_enabled else null,
		roster,
		adapter,
		run_state,
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		4,
		standard_merchants_enabled,
		{}
	)
	return {
		"game": game,
		"coordinator": coordinator,
		"merchant": merchant,
		"luoxi": luoxi,
		"player": player,
		"run_state": run_state,
	}


func _free_tree_less_fixture(fixture: Dictionary) -> void:
	var game := fixture.get("game") as StandardGame
	var run_state := fixture.get("run_state") as RunStateStore
	if game != null:
		game.free()
	if run_state != null:
		run_state.free()


func _stop_audio_players(root_node: Node) -> void:
	for child in root_node.get_children():
		if child is AudioStreamPlayer or child is AudioStreamPlayer2D:
			child.stop()
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
