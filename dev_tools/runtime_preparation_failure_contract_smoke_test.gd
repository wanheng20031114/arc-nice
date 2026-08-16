extends SceneTree

const MALFORMED_STANDARD_SCENE := preload(
	"res://dev_tools/fixtures/malformed_standard_game_prewarmer_probe.tscn"
)
const STANDARD_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const EXPECTED_MALFORMED_REASON := "波次模式场景内容校验失败。"
const RECONNECT_CONFLICT_PORT := 29_323

var failures: Array[String] = []


class CountingUnknownScene extends Node2D:
	var process_ticks := 0
	var physics_ticks := 0


	func _process(_delta: float) -> void:
		process_ticks += 1


	func _physics_process(_delta: float) -> void:
		physics_ticks += 1


class ReconnectConflictWrapperProbe extends MpRogueRoute:
	var lobby_change_requested := false


	func _ready() -> void:
		_preparation_generation = begin_runtime_preparation("重连能力冲突", 1)
		_net_manager = NetManagerStore.get_autoload_instance()
		if not _connect_net_manager_signals():
			mark_runtime_preparation_failed(
				_preparation_generation,
				"P3 多人网络信号契约绑定失败。"
			)
			_defer_lobby_return_without_active_loader()


	func _change_to_lobby() -> void:
		lobby_change_requested = true


class StandaloneReturnProbe extends MpRogueRoute:
	var lobby_change_requested := false
	var transport_active_when_lobby_changed := true


	func _change_to_lobby() -> void:
		lobby_change_requested = true
		transport_active_when_lobby_changed = (
			_net_manager != null and _net_manager.is_multiplayer_active()
		)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := root.get_node_or_null("GameLoadCoordinator")
	_expect(coordinator != null, "聚焦冒烟必须取得 GameLoadCoordinator。")
	if coordinator == null:
		_finish()
		return
	await _test_missing_preparation_capability(coordinator)
	await _test_reconnect_preparer_conflict_cleanup(coordinator)
	await _test_malformed_runtime_fails_within_frames(coordinator)
	_test_threaded_wait_boundaries()
	await _test_normal_runtime_reaches_ready(coordinator)
	_finish()


func _test_missing_preparation_capability(coordinator: Node) -> void:
	_reset_coordinator(coordinator)
	var no_capability := CountingUnknownScene.new()
	root.add_child(no_capability)
	await process_frame
	await physics_frame
	var expected_path := "res://dev_tools/fixtures/no_runtime_capability.tscn"
	var ready := bool(coordinator.call(
		"_poll_runtime_preparation_capability",
		no_capability,
		expected_path
	))
	var detail := coordinator.get_node(
		"Overlay/Layout/Stack/Content/Detail"
	) as Label
	_expect(
		not ready
		and int(coordinator.get("_state")) == 5
		and detail.text == "目标场景缺少强类型运行时准备能力：%s" % expected_path,
		"缺少强类型准备能力的场景必须立即 fail-close，并显示精确路径。"
	)
	var process_ticks_after_failure := no_capability.process_ticks
	var physics_ticks_after_failure := no_capability.physics_ticks
	for _frame in range(2):
		await process_frame
		await physics_frame
	_expect(
		no_capability.process_mode == Node.PROCESS_MODE_DISABLED
		and no_capability.process_ticks == process_ticks_after_failure
		and no_capability.physics_ticks == physics_ticks_after_failure,
		"缺少 Provider 的入树场景必须在错误遮罩出现时同步冻结 process/physics。"
	)
	no_capability.queue_free()
	await process_frame


func _test_reconnect_preparer_conflict_cleanup(coordinator: Node) -> void:
	_reset_coordinator(coordinator)
	coordinator.set_process(false)
	var net_manager := root.get_node_or_null("NetManager") as NetManagerStore
	_expect(net_manager != null, "重连 preparer 冲突夹具必须取得 NetManager。")
	if net_manager == null:
		coordinator.set_process(true)
		return
	net_manager.disconnect_from_game()
	var conflict_preparer := Callable(self, "_fixture_reconnect_preparer")
	_expect(
		net_manager.register_reconnect_delivery_preparer(conflict_preparer),
		"冲突夹具必须先占有唯一 reconnect delivery preparer。"
	)
	coordinator.call(
		"_begin_load",
		"res://scene/multiplayer/mp_rogue_route.tscn",
		["res://scene/multiplayer/mp_rogue_route.tscn"] as Array[String],
		true
	)
	var wrapper := ReconnectConflictWrapperProbe.new()
	_expect(wrapper != null, "冲突夹具必须实例化 MpRogueRoute 生产分支探针。")
	if wrapper != null:
		root.add_child(wrapper)
		current_scene = wrapper
		var preparation := wrapper.get_runtime_preparation_snapshot()
		var loader_observed_failure := bool(coordinator.call(
			"_poll_runtime_preparation_capability",
			wrapper,
			"res://scene/multiplayer/mp_rogue_route.tscn"
		))
		for _frame in range(4):
			await process_frame
		var detail := coordinator.get_node(
			"Overlay/Layout/Stack/Content/Detail"
		) as Label
		_expect(
			preparation.state
			== RuntimePreparationProvider.PreparationState.FAILED
			and preparation.failure_reason == "P3 多人网络信号契约绑定失败。"
			and not loader_observed_failure
			and int(coordinator.get("_state")) == 5
			and detail.text == preparation.failure_reason,
			"preparer 冲突必须只发布 generation-scoped FAILED，并由活跃加载器观察。"
		)
		_expect(
			current_scene == wrapper
			and is_instance_valid(wrapper)
			and not wrapper.lobby_change_requested,
			"活跃加载器收口失败时，MpRogueRoute 不得抢先切回大厅。"
		)
		current_scene = null
		wrapper.free()
		await process_frame
	_expect(
		net_manager.unregister_reconnect_delivery_preparer(conflict_preparer),
		"冲突夹具必须释放自己占有的 reconnect preparer。"
	)
	_reset_coordinator(coordinator)

	# 无加载器的 standalone 返回仍走同一清理门，且切场前必须先断 transport。
	net_manager.local_player_name = "Preparation Conflict Host"
	net_manager.set_local_character_id(&"weishidaier", true)
	var host_error := net_manager.host_create_lan_server(RECONNECT_CONFLICT_PORT)
	_expect(host_error == OK, "standalone 返回夹具必须创建活跃 LAN transport。")
	if host_error == OK:
		net_manager.host_start_game()
	var return_probe := StandaloneReturnProbe.new()
	return_probe.auto_bind_scene_runtime = false
	root.add_child(return_probe)
	return_probe.set("_net_manager", net_manager)
	var transport_was_active := net_manager.is_multiplayer_active()
	return_probe.call("_return_to_lobby")
	for _frame in range(4):
		if return_probe.lobby_change_requested:
			break
		await process_frame
	_expect(
		transport_was_active
		and return_probe.lobby_change_requested
		and not return_probe.transport_active_when_lobby_changed
		and not net_manager.is_multiplayer_active(),
		"standalone MpRogueRoute 必须在请求切回大厅前先断开多人 transport。"
	)
	return_probe.free()
	net_manager.disconnect_from_game()
	coordinator.set_process(true)
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame


func _fixture_reconnect_preparer(
	_old_peer_id: int,
	_new_peer_id: int,
	_outcome: Variant,
	_membership_revision: int
) -> bool:
	return true


func _test_malformed_runtime_fails_within_frames(coordinator: Node) -> void:
	_reset_coordinator(coordinator)
	var runtime := MALFORMED_STANDARD_SCENE.instantiate() as StandardGame
	_expect(runtime != null, "malformed Standard fixture 必须可实例化。")
	if runtime == null:
		return
	var start_frame := Engine.get_process_frames()
	root.add_child(runtime)
	for _frame in range(4):
		if runtime.is_runtime_preparation_failed():
			break
		await process_frame
	var preparation := runtime.get_runtime_preparation_snapshot()
	var failed_generation := preparation.generation
	_expect(
		preparation.state
		== RuntimePreparationProvider.PreparationState.FAILED
		and failed_generation > 0
		and preparation.failure_reason == EXPECTED_MALFORMED_REASON
		and Engine.get_process_frames() - start_frame <= 4,
		"malformed runtime 必须在四帧内给出精确 FAILED，而不是等待 120 秒。"
	)
	runtime.mark_runtime_preparation_complete(failed_generation)
	_expect(
		runtime.is_runtime_preparation_failed(),
		"FAILED 必须是不可逆终态，迟到的完成回调不得重新发布 READY。"
	)
	var ready := bool(coordinator.call(
		"_poll_runtime_preparation_capability",
		runtime,
		"res://dev_tools/fixtures/malformed_standard_game_prewarmer_probe.tscn"
	))
	var detail := coordinator.get_node(
		"Overlay/Layout/Stack/Content/Detail"
	) as Label
	_expect(
		not ready
		and int(coordinator.get("_state")) == 5
		and detail.text == EXPECTED_MALFORMED_REASON,
		"GameLoadCoordinator 必须原样展示运行时的精确失败原因。"
	)
	var observed_generations: Array[int] = []
	runtime.runtime_preparation_state_changed.connect(
		func(snapshot: RuntimePreparationProvider.RuntimePreparationSnapshot) -> void:
			observed_generations.append(snapshot.generation)
	)
	var second_generation := runtime.begin_runtime_preparation("第二准备周期", 3)
	var signals_after_second_begin := observed_generations.size()
	runtime.update_runtime_preparation_progress(
		failed_generation,
		"旧周期迟到进度",
		3,
		3
	)
	runtime.mark_runtime_preparation_complete(failed_generation)
	runtime.mark_runtime_preparation_failed(failed_generation, "旧周期迟到失败")
	preparation = runtime.get_runtime_preparation_snapshot()
	_expect(
		second_generation > failed_generation
		and preparation.generation == second_generation
		and preparation.state == RuntimePreparationProvider.PreparationState.PREPARING
		and preparation.stage == "第二准备周期"
		and observed_generations.size() == signals_after_second_begin,
		"旧 generation 的 update/complete/fail 都不得写入新准备周期。"
	)
	runtime.update_runtime_preparation_progress(
		second_generation,
		"第二周期有效进度",
		2,
		3
	)
	runtime.mark_runtime_preparation_complete(second_generation)
	runtime.mark_runtime_preparation_failed(second_generation, "同代迟到失败")
	preparation = runtime.get_runtime_preparation_snapshot()
	_expect(
		preparation.generation == second_generation
		and preparation.state == RuntimePreparationProvider.PreparationState.READY,
		"同 generation 的 READY 终态必须不可逆。"
	)
	var third_generation := runtime.begin_runtime_preparation("第三准备周期", 1)
	runtime.mark_runtime_preparation_complete(second_generation)
	runtime.mark_runtime_preparation_failed(second_generation, "第二代迟到失败")
	runtime.mark_runtime_preparation_failed(third_generation, "第三周期失败")
	runtime.mark_runtime_preparation_complete(third_generation)
	preparation = runtime.get_runtime_preparation_snapshot()
	_expect(
		third_generation > second_generation
		and preparation.generation == third_generation
		and preparation.state == RuntimePreparationProvider.PreparationState.FAILED
		and preparation.failure_reason == "第三周期失败"
		and observed_generations.has(second_generation)
		and observed_generations.has(third_generation),
		"READY 可用新 generation 重开；新代 FAILED 仍须保持同代不可逆并随快照发出。"
	)
	runtime.queue_free()
	await process_frame


func _test_threaded_wait_boundaries() -> void:
	for source_path in [
		"res://scene/game_modes/standard/prewarm/standard_prewarmer_coordinator.gd",
		"res://scene/game_modes/tower_defense/boss/tower_defense_boss_coordinator.gd",
		"res://scene/game_modes/tower_defense/fate/fate_coordinator.gd",
	]:
		var source := FileAccess.get_file_as_string(source_path)
		_expect(
			source.contains("var error := ResourceLoader.load_threaded_request(")
			and source.contains("if error != OK:")
			and source.contains("RUNTIME_RESOURCE_WAIT_TIMEOUT_MSEC")
			and source.contains("Time.get_ticks_msec() >= deadline_msec")
			and source.contains(
				"if status != ResourceLoader.THREAD_LOAD_LOADED:"
			),
			"线程预热必须检查请求 Error、设置 deadline 并拒绝非 LOADED：%s"
			% source_path
		)


func _test_normal_runtime_reaches_ready(coordinator: Node) -> void:
	_reset_coordinator(coordinator)
	var runtime := STANDARD_SCENE.instantiate() as StandardGame
	_expect(runtime != null, "正常 Standard runtime 必须可实例化。")
	if runtime == null:
		return
	runtime.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		1,
		{1: "Preparation Contract Host"},
		{1: &"weishidaier"}
	)
	runtime.auto_start_waves = false
	runtime.defer_runtime_activation()
	root.add_child(runtime)
	var deadline_msec := Time.get_ticks_msec() + 15_000
	while (
		runtime.get_runtime_preparation_state()
		== RuntimePreparationProvider.PreparationState.PREPARING
		and Time.get_ticks_msec() < deadline_msec
	):
		await process_frame
	var preparation := runtime.get_runtime_preparation_snapshot()
	_expect(
		preparation.state
		== RuntimePreparationProvider.PreparationState.READY
		and preparation.generation > 0
		and preparation.failure_reason.is_empty(),
		"正常 Standard runtime 必须在有界时间内进入 READY。"
	)
	_expect(
		bool(coordinator.call(
			"_poll_runtime_preparation_capability",
			runtime,
			"res://scene/game_modes/standard/standard_game.tscn"
		)),
		"加载器必须接受正常运行时的强类型 READY。"
	)
	runtime.activate_runtime()
	_expect(runtime.runtime_activated, "READY 运行时必须可显式激活。")
	runtime.queue_free()
	await process_frame


func _reset_coordinator(coordinator: Node) -> void:
	coordinator.call("_invalidate_and_release_active_attempt", &"fixture_reset")
	coordinator.call("_clear_failed_retry_request")
	coordinator.set("_state", 0)
	coordinator.set("_is_multiplayer_load", false)
	coordinator.get_node("Overlay").hide()


func _finish() -> void:
	if failures.is_empty():
		print("RUNTIME_PREPARATION_FAILURE_CONTRACT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
