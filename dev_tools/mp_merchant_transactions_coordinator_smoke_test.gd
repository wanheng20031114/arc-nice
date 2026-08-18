extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/merchant_transactions/mp_merchant_transactions_coordinator.tscn"
)
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"
const LUOXI_SCENE := preload("res://scene/merchants/luoxi/luoxi_merchant.tscn")
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const OFFER_SEED := 0x4D45524348414E54
const OUTSIDE_PICKUP_PATH := (
	"res://dev_tools/fixtures/runtime_content_catalog_outside_pickup.tres"
)


class TestRuntime:
	extends CombatRuntimeBase

	var test_player: Player = null

	func _ready() -> void:
		pass

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return test_player if test_player != null and test_player.peer_id == peer_id else null

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func ensure_reconnected_multiplayer_player(
		_old_peer_id: int,
		new_peer_id: int,
		_player_name: String,
		_character_id: StringName,
		_state: SnapshotManager.PlayerState,
		_spawn_slot_index: int,
		_reconnect_state: Dictionary = {}
	) -> CombatRuntimeBase.ReconnectedPlayerProjection:
		var player := (
			test_player
			if test_player != null and test_player.peer_id == new_peer_id
			else null
		)
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			(
				CombatRuntimeBase.ReconnectedPlayerProjectionStatus.EXISTING_CURRENT
				if player != null
				else CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
			),
			player
		)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class HostNetManager:
	extends NetManagerStore

	func get_local_peer_id() -> int:
		return 1

	func is_peer_send_ready(peer_id: int) -> bool:
		return peer_id > 0


class MerchantAdapter:
	extends MultiplayerModeAdapter

	var merchant: LuoxiMerchant = null
	var refresh_count := 0
	var claimed := false
	var claim_paths: Array[String] = []
	var local_collectible_results: Array[int] = []
	var special_calls: Array[Dictionary] = []
	var local_special_methods: Array[StringName] = []

	func get_luoxi_merchant() -> LuoxiMerchant:
		return merchant

	func runtime_try_refresh_luoxi_collectibles_for_peer(peer_id: int) -> int:
		if peer_id <= 0 or claimed:
			return MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
		refresh_count += 1
		return MerchantPurchaseResult.OfferRefresh.SUCCESS

	func runtime_get_luoxi_collectible_refresh_count(_peer_id: int) -> int:
		return refresh_count

	func runtime_try_claim_luoxi_collectible_for_peer(
		peer_id: int,
		config_path_or_choice: Variant
	) -> int:
		if peer_id <= 0 or claimed:
			return MerchantPurchaseResult.CollectibleClaim.ALREADY_CLAIMED
		var config_path := str(config_path_or_choice)
		if config_path.is_empty():
			return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER
		claimed = true
		claim_paths.append(config_path)
		return MerchantPurchaseResult.CollectibleClaim.SUCCESS

	func runtime_has_luoxi_collectible_claimed(_peer_id: int) -> bool:
		return claimed

	func runtime_record_luoxi_collectible_claim(_peer_id: int) -> void:
		claimed = true

	func runtime_mark_luoxi_collectible_claimed(_peer_id: int) -> void:
		claimed = true

	func show_local_luoxi_collectible_result(result_code: int) -> void:
		local_collectible_results.append(result_code)

	func runtime_supports_luoxi_special_game() -> bool:
		return true

	func runtime_try_start_luoxi_special_game_for_peer(peer_id: int) -> Dictionary:
		var result := {
			"result_code": 0,
			"session_revision": 61,
			"peer_id": peer_id,
		}
		special_calls.append({"method": &"start", "result": result})
		return result

	func runtime_try_reveal_luoxi_special_game_card_for_peer(
		peer_id: int,
		session_revision: int,
		card_index: int
	) -> Dictionary:
		var result := {
			"result_code": 0,
			"session_revision": session_revision,
			"card_index": card_index,
			"peer_id": peer_id,
		}
		special_calls.append({"method": &"reveal", "result": result})
		return result

	func runtime_try_finish_luoxi_special_game_for_peer(
		peer_id: int,
		session_revision: int
	) -> Dictionary:
		var result := {
			"result_code": 0,
			"session_revision": session_revision,
			"current_xirang": 800,
			"peer_id": peer_id,
		}
		special_calls.append({"method": &"finish", "result": result})
		return result

	func show_local_luoxi_special_game_started(_result: Dictionary) -> void:
		local_special_methods.append(&"start")

	func show_local_luoxi_special_game_card_revealed(_result: Dictionary) -> void:
		local_special_methods.append(&"reveal")

	func show_local_luoxi_special_game_finished(_result: Dictionary) -> void:
		local_special_methods.append(&"finish")


class TrackingLuoxiMerchant:
	extends LuoxiMerchant

	var applied_refresh_result_codes: Array[int] = []
	var applied_xirang_balances: Array[int] = []

	func apply_authoritative_offer_state(
		offer_revision: int,
		config_paths: PackedStringArray,
		_confirmed_refresh_count: int,
		confirmed_current_xirang: int,
		refresh_result_code: int = -1
	) -> bool:
		if active_player == null or offer_revision <= 0 or config_paths.is_empty():
			return false
		applied_refresh_result_codes.append(refresh_result_code)
		applied_xirang_balances.append(confirmed_current_xirang)
		active_player.set_xirang_balance(confirmed_current_xirang)
		authoritative_offer_revision = offer_revision
		return true


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := (
		COORDINATOR_SCENE.instantiate() as MpMerchantTransactionsCoordinator
	)
	_expect(coordinator != null, "Merchant transactions scene must instantiate.")
	if coordinator == null:
		_finish()
		return
	_test_static_boundary(coordinator)
	await _test_offer_refresh_choice_and_special_game(coordinator)
	coordinator.free()
	_finish()


func _test_static_boundary(
	coordinator: MpMerchantTransactionsCoordinator
) -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(
		mp_game != null
		and mp_game.get_node_or_null("MerchantTransactionsCoordinator")
		is MpMerchantTransactionsCoordinator,
		"MpGame must statically contain MerchantTransactionsCoordinator."
	)
	if mp_game != null:
		mp_game.free()
	var source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	var rpc_pattern := RegEx.new()
	rpc_pattern.compile("(?m)^@rpc\\(")
	_expect(
		rpc_pattern.search_all(source).size() == 145,
		"Merchant extraction must preserve all 145 protocol-v86 MpGame RPC facades."
	)
	for function_name in [
		"net_luoxi_collectible_offer_requested",
		"net_luoxi_collectible_choice_requested",
		"net_luoxi_collectible_refresh_requested",
		"net_luoxi_special_game_start_requested",
		"net_luoxi_special_game_card_reveal_requested",
		"net_luoxi_special_game_finish_requested",
		"net_cheat_xirang_requested",
		"net_debug_collectible_requested",
	]:
		_expect(
			_rpc_entry_captures_sender_first(source, function_name),
			"%s must capture sender first." % function_name
		)
		_expect(
			_rpc_entry_uses_shared_admission_before_delegate(source, function_name),
			"%s must consume shared admission before its domain delegate."
			% function_name
		)
	_expect(
		not source.contains("func _create_luoxi_offer_for_peer")
		and not source.contains("func _apply_luoxi_special_game_start_for_peer")
		and not source.contains("func _apply_cheat_xirang_for_peer")
		and not source.contains("func _spawn_collectible_visual_effect")
		and not source.contains("func _spawn_collectible_follow_visual_effect")
		and source.contains("collectible_presentation_coordinator"),
		"MpGame must keep merchant and collectible presentation boundaries separate."
	)
	var coordinator_source := coordinator.get_script().source_code as String
	_expect(
		not coordinator_source.contains("current_scene")
		and not coordinator_source.contains("has_method")
		and not coordinator_source.contains(".call(")
		and not coordinator_source.contains("load(config_path)"),
		"Merchant coordinator must only use typed runtime dependencies."
	)


func _test_offer_refresh_choice_and_special_game(
	coordinator: MpMerchantTransactionsCoordinator
) -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	run_state.register_multiplayer_peer_state(1)
	var test_root := Node2D.new()
	test_root.name = "MerchantTransactionsSmokeTest"
	root.add_child(test_root)
	var merchant := LUOXI_SCENE.instantiate() as LuoxiMerchant
	var player := PLAYER_SCENE.instantiate() as Player
	player.peer_id = 1
	player.current_xirang = 1000
	test_root.add_child(merchant)
	test_root.add_child(player)
	merchant.set_active(true)
	await process_frame
	await physics_frame
	merchant.active_player = player

	var runtime := TestRuntime.new()
	runtime.test_player = player
	var adapter := MerchantAdapter.new()
	adapter.merchant = merchant
	var net_manager := HostNetManager.new()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	coordinator.bind_runtime(runtime, adapter, run_state, net_manager, 0.0)
	var outside_snapshot := (
		run_state.export_inventory_snapshot_for_peer(1)
	).duplicate(true)
	_expect(
		RunStateStore.advance_inventory_snapshot_revision(outside_snapshot, 0),
		"目录外商人确认测试必须构造可推进的权威背包快照。"
	)
	_expect(
		not coordinator.receive_luoxi_collectible_confirmation(
			1,
			0,
			OUTSIDE_PICKUP_PATH,
			MerchantPurchaseResult.CollectibleClaim.SUCCESS,
			0,
			outside_snapshot
		)
		and run_state.get_inventory_revision_for_peer(1) == 0
		and not adapter.claimed,
		"目录外合法 PickupConfig 必须在商人确认的背包与领取状态首写前拒绝。"
	)
	var offer_rng := coordinator.get(
		"_luoxi_offer_random_generator"
	) as RandomNumberGenerator
	offer_rng.seed = OFFER_SEED
	var expected_rng := RandomNumberGenerator.new()
	expected_rng.seed = OFFER_SEED
	var expected_first := merchant.build_authoritative_offer_paths(
		player,
		[],
		expected_rng
	)
	var expected_refresh := merchant.build_authoritative_offer_paths(
		player,
		expected_first,
		expected_rng
	)

	var broadcast_methods: Array[StringName] = []
	coordinator.rpc_broadcast_requested.connect(
		func(method_name: StringName, _args: Array) -> void:
			broadcast_methods.append(method_name)
	)
	coordinator.request_luoxi_collectible_offer()
	var first_state := _get_offer_state(coordinator, 1)
	var first_paths := _get_offer_paths(first_state)
	_expect(
		int(first_state.get("offer_revision", 0)) == 1
		and first_paths == expected_first
		and first_paths.size() == LuoxiMerchant.get_choice_count(),
		"The first authoritative offer must preserve deterministic three-choice RNG order."
	)
	coordinator.request_luoxi_collectible_refresh(1)
	var refresh_state := _get_offer_state(coordinator, 1)
	var refresh_paths := _get_offer_paths(refresh_state)
	_expect(
		int(refresh_state.get("offer_revision", 0)) == 2
		and int(refresh_state.get("refresh_count", 0)) == 1
		and refresh_paths == expected_refresh,
		"A successful refresh must consume the next RNG roll and increment revision once."
	)
	coordinator.request_luoxi_collectible_choice(0, 2)
	_expect(
		adapter.claimed
		and adapter.claim_paths == [refresh_paths[0]]
		and adapter.local_collectible_results
		== [MerchantPurchaseResult.CollectibleClaim.SUCCESS]
		and broadcast_methods.has(&"net_luoxi_collectible_confirmed"),
		"Choice confirmation must resolve the authoritative refreshed path exactly once."
	)
	coordinator.request_luoxi_collectible_refresh(2)
	var rejected_refresh_state := _get_offer_state(coordinator, 1)
	_expect(
		int(rejected_refresh_state.get("offer_revision", 0)) == 3
		and int(rejected_refresh_state.get("refresh_result_code", -1))
		== MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
		and int(rejected_refresh_state.get("current_xirang", -1))
		== player.current_xirang,
		"刷新失败也必须提交新的完整快照 revision，不能改写既有报价版本。"
	)

	_expect(
		coordinator.supports_luoxi_special_game(),
		"The typed adapter must expose supported Luoxi special-game capability."
	)
	coordinator.request_luoxi_special_game_start()
	coordinator.request_luoxi_special_game_card_reveal(61, 2)
	coordinator.request_luoxi_special_game_finish(61)
	_expect(
		adapter.special_calls.size() == 3
		and adapter.special_calls[0].get("method") == &"start"
		and adapter.special_calls[1].get("method") == &"reveal"
		and adapter.special_calls[2].get("method") == &"finish"
		and adapter.local_special_methods == [&"start", &"reveal", &"finish"]
		and broadcast_methods.has(&"net_luoxi_special_game_started")
		and broadcast_methods.has(&"net_luoxi_special_game_card_revealed")
		and broadcast_methods.has(&"net_luoxi_special_game_finished"),
		"Special-game start, reveal, and finish must keep authoritative order and confirmations."
	)

	var granted_item := load(first_paths[0]) as PickupConfig
	var authoritative_state := RunStateStore.new()
	authoritative_state.begin_new_run(&"weishidaier", false)
	authoritative_state.register_multiplayer_peer_state(1)
	_expect(
		granted_item != null
		and authoritative_state.try_add_item_for_peer(1, granted_item),
		"Debug grant lifecycle fixture must build an authoritative inventory."
	)
	var granted_snapshot := (
		authoritative_state.export_inventory_snapshot_for_peer(1)
	)
	runtime.test_player = null
	coordinator.receive_debug_collectible_granted(
		1,
		first_paths[0],
		true,
		granted_snapshot
	)
	_expect(
		run_state.get_inventory_revision_for_peer(1)
		== int(granted_snapshot.get("revision", -1))
		and run_state.get_inventory_item_total_for_peer(1, granted_item) == 1,
		"Player 节点缺席时，调试收藏品结果仍必须收敛权威背包账本。"
	)
	var outside_item := ResourceLoader.load(OUTSIDE_PICKUP_PATH) as PickupConfig
	LuoxiMerchant.cache_collectible_config(outside_item)
	var revision_before_outside := run_state.get_inventory_revision_for_peer(1)
	var outside_confirmation_snapshot := (
		run_state.export_inventory_snapshot_for_peer(1)
	).duplicate(true)
	_expect(
		RunStateStore.advance_inventory_snapshot_revision(
			outside_confirmation_snapshot,
			revision_before_outside
		)
		and LuoxiMerchant.get_collectible_for_path(OUTSIDE_PICKUP_PATH)
		== outside_item
		and not coordinator.receive_luoxi_collectible_confirmation(
			1,
			0,
			OUTSIDE_PICKUP_PATH,
			MerchantPurchaseResult.CollectibleClaim.SUCCESS,
			0,
			outside_confirmation_snapshot
		)
		and run_state.get_inventory_revision_for_peer(1)
		== revision_before_outside,
		"即使旧商店缓存收录目录外合法物品，显式信任根也必须在首写前拒绝。"
	)
	authoritative_state.free()

	_test_deferred_offer_presentation(
		coordinator,
		adapter,
		net_manager,
		player,
		first_paths
	)

	coordinator.unbind_runtime(runtime)
	net_manager.free()
	adapter.free()
	runtime.free()
	merchant.set_active(false)
	test_root.queue_free()
	for _cleanup_frame in 4:
		await process_frame
		await physics_frame


func _test_deferred_offer_presentation(
	coordinator: MpMerchantTransactionsCoordinator,
	adapter: MerchantAdapter,
	net_manager: HostNetManager,
	player: Player,
	offer_paths: Array[String]
) -> void:
	adapter.merchant = null
	player.set_xirang_balance(1000)
	var accepted_without_merchant := (
		coordinator.receive_luoxi_collectible_offer_state(
			1,
			50,
			PackedStringArray(offer_paths),
			2,
			777,
			MerchantPurchaseResult.OfferRefresh.INSUFFICIENT_XIRANG
		)
	)
	var cached_state := _get_offer_state(coordinator, 1)
	_expect(
		accepted_without_merchant
		and int(cached_state.get("offer_revision", 0)) == 50
		and int(cached_state.get("current_xirang", -1)) == 777
		and int(cached_state.get("refresh_result_code", -1))
		== MerchantPurchaseResult.OfferRefresh.INSUFFICIENT_XIRANG
		and player.current_xirang == 1000,
		"商人缺席时必须原子保留完整报价结果，并推迟 Player/UI 投影。"
	)
	_expect(
		not coordinator.receive_luoxi_collectible_offer_state(
			1,
			49,
			PackedStringArray(offer_paths),
			2,
			777,
			MerchantPurchaseResult.OfferRefresh.INSUFFICIENT_XIRANG
		)
		and not coordinator.receive_luoxi_collectible_offer_state(
			1,
			50,
			PackedStringArray(offer_paths),
			2,
			776,
			MerchantPurchaseResult.OfferRefresh.INSUFFICIENT_XIRANG
		),
		"旧 revision 与同 revision 异载荷都必须被领域缓存拒绝。"
	)

	var tracking_merchant := TrackingLuoxiMerchant.new()
	tracking_merchant.active_player = player
	adapter.merchant = tracking_merchant
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	coordinator.request_luoxi_collectible_offer()
	coordinator.request_luoxi_collectible_offer()
	_expect(
		tracking_merchant.applied_refresh_result_codes
		== [MerchantPurchaseResult.OfferRefresh.INSUFFICIENT_XIRANG, -1]
		and tracking_merchant.applied_xirang_balances == [777, 777]
		and player.current_xirang == 777,
		"商人恢复后开窗必须重放完整快照，但同 revision 的反馈只能消费一次。"
	)
	var duplicate_applied := coordinator.receive_luoxi_collectible_offer_state(
		1,
		50,
		PackedStringArray(offer_paths),
		2,
		777,
		MerchantPurchaseResult.OfferRefresh.INSUFFICIENT_XIRANG
	)
	_expect(
		duplicate_applied
		and tracking_merchant.applied_refresh_result_codes.size() == 2,
		"可靠信封重复到达不得再次投影同一报价或反馈。"
	)
	net_manager.net_role = NetManagerStore.NetRole.HOST
	adapter.merchant = null
	tracking_merchant.free()


func _get_offer_state(
	coordinator: MpMerchantTransactionsCoordinator,
	peer_id: int
) -> Dictionary:
	return (
		coordinator.capture_reconnect_state(peer_id).get(
			"luoxi_offer_state",
			{}
		) as Dictionary
	)


func _get_offer_paths(state: Dictionary) -> Array[String]:
	var paths: Array[String] = []
	for path_variant in state.get("config_paths", []) as Array:
		paths.append(str(path_variant))
	return paths


func _rpc_entry_captures_sender_first(source: String, function_name: String) -> bool:
	var function_offset := source.find("func %s" % function_name)
	if function_offset < 0:
		return false
	var body_offset := source.find(") -> void:\n", function_offset)
	if body_offset < 0:
		return false
	body_offset += ") -> void:\n".length()
	var line_end := source.find("\n", body_offset)
	if line_end < 0:
		return false
	return source.substr(body_offset, line_end - body_offset).strip_edges() == (
		"var sender_id := _get_rpc_sender_id()"
	)


func _rpc_entry_uses_shared_admission_before_delegate(
	source: String,
	function_name: String
) -> bool:
	var function_offset := source.find("func %s" % function_name)
	if function_offset < 0:
		return false
	var next_function := source.find("\nfunc ", function_offset + 1)
	var body := source.substr(
		function_offset,
		(next_function if next_function >= 0 else source.length()) - function_offset
	)
	var admission_offset := body.find(
		"transactions_coordinator.consume_remote_transaction_admission("
	)
	var delegate_offset := body.find(
		"merchant_transactions_coordinator.handle_remote_"
	)
	return admission_offset >= 0 and delegate_offset > admission_offset


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("MP_MERCHANT_TRANSACTIONS_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
