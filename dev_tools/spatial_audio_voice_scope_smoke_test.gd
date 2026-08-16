extends SceneTree

const LIMITER := preload("res://scene/combat/audio/spatial_audio_voice_limiter.gd")
const TEST_STREAM := preload("res://resources/audio/capoo_smg_fire.wav")
const TEST_GROUP := &"spatial_audio_scope_fixture_voices"
const PAUSED_GROUP := &"spatial_audio_scope_fixture_paused_voices"
const EXIT_GROUP := &"spatial_audio_scope_fixture_exit_voices"
const VIEWPORT_GROUP := &"spatial_audio_scope_fixture_viewport_voices"
const MULTI_GROUP_A := &"spatial_audio_scope_fixture_multi_a"
const MULTI_GROUP_B := &"spatial_audio_scope_fixture_multi_b"

var failures: Array[String] = []
var fixture: Node2D = null
var tower_scope: Node2D = null
var rogue_scope: Node2D = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "SpatialAudioVoiceScopeFixture"
	root.add_child(fixture)
	current_scene = fixture

	var camera := Camera2D.new()
	camera.enabled = true
	fixture.add_child(camera)
	tower_scope = Node2D.new()
	tower_scope.name = "TowerWorldScope"
	fixture.add_child(tower_scope)
	# Rogue 运行时真实地嵌在 Tower 树下；仲裁依赖显式参数而非节点名。
	rogue_scope = Node2D.new()
	rogue_scope.name = "NestedRogueWorldScope"
	tower_scope.add_child(rogue_scope)
	await process_frame

	_test_nested_runtime_scope_isolation()
	await _test_paused_voice_is_not_active_or_preempted()
	_test_one_player_has_one_logical_group()
	_test_explicit_release_and_tree_exit()
	await _test_foreign_viewport_scope_isolation()

	_stop_audio_descendants(fixture)
	current_scene = null
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("SPATIAL_AUDIO_VOICE_SCOPE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_nested_runtime_scope_isolation() -> void:
	var tower_far := _create_player(tower_scope, Vector2(420.0, 0.0))
	var rogue_far := _create_player(rogue_scope, Vector2(520.0, 0.0))
	_expect(_claim_and_play(tower_far, tower_scope, TEST_GROUP, 1), "Tower 首个声部必须获准。")
	_expect(_claim_and_play(rogue_far, rogue_scope, TEST_GROUP, 1), "嵌套 Rogue 必须拥有独立声部预算。")
	_expect(
		LIMITER.get_active_voice_count(tower_scope, TEST_GROUP) == 1
		and LIMITER.get_active_voice_count(rogue_scope, TEST_GROUP) == 1,
		"同一 SceneTree/Viewport 内的 Tower 与 Rogue 必须各计一个声部。"
	)

	var tower_near := _create_player(tower_scope, Vector2(20.0, 0.0))
	_expect(_claim_and_play(tower_near, tower_scope, TEST_GROUP, 1), "Tower 近处请求必须获准。")
	_expect(not tower_far.playing, "Tower 近处请求必须只抢占 Tower 最远声部。")
	_expect(rogue_far.playing, "Tower 仲裁不得停止嵌套 Rogue 声部。")

	var rogue_near := _create_player(rogue_scope, Vector2(10.0, 0.0))
	_expect(_claim_and_play(rogue_near, rogue_scope, TEST_GROUP, 1), "Rogue 近处请求必须获准。")
	_expect(not rogue_far.playing, "Rogue 近处请求必须只抢占 Rogue 最远声部。")
	_expect(tower_near.playing, "Rogue 仲裁不得停止外层 Tower 声部。")

	_stop_and_release(tower_near, TEST_GROUP)
	_stop_and_release(rogue_near, TEST_GROUP)


func _test_paused_voice_is_not_active_or_preempted() -> void:
	var paused_voice := _create_player(tower_scope, Vector2(40.0, 12.0))
	var paused_voice_preempted := [false]
	paused_voice.set_meta(
		LIMITER.VOICE_PREEMPTED_CALLBACK_META,
		func() -> void: paused_voice_preempted[0] = true
	)
	_expect(_claim_and_play(paused_voice, tower_scope, PAUSED_GROUP, 1), "暂停用声部必须先获准。")
	# AudioServer 先提交 playback，随后 stream_paused 才代表真实的暂停租约。
	await process_frame
	await physics_frame
	var pause_ready := await _pause_voice_reliably(paused_voice)
	_expect(pause_ready, "测试 playback 必须先进入可观察的 stream_paused 状态。")
	if not pause_ready:
		_stop_and_release(paused_voice, PAUSED_GROUP)
		return
	var replacement := _create_player(tower_scope, Vector2(320.0, 12.0))
	var replacement_preempted := [false]
	replacement.set_meta(
		LIMITER.VOICE_PREEMPTED_CALLBACK_META,
		func() -> void: replacement_preempted[0] = true
	)
	var replacement_claimed := _claim_and_play(replacement, tower_scope, PAUSED_GROUP, 1)
	_expect(
		replacement_claimed,
		"暂停声部不占预算时，即使新请求更远也必须获准。"
	)
	_expect(
		paused_voice.stream_paused and not bool(paused_voice_preempted[0]),
		"暂停声部不得成为抢占目标或被 stop。"
	)
	_expect(
		LIMITER.get_active_voice_count(tower_scope, PAUSED_GROUP) == 1,
		"活动计数必须排除 stream_paused 声部。"
	)

	paused_voice.stream_paused = false
	var resumed := await _wait_until_playing(paused_voice)
	var resumed_active_count := LIMITER.get_active_voice_count(
		tower_scope,
		PAUSED_GROUP
	)
	_expect(
		resumed
		and resumed_active_count == 1
		and paused_voice.playing
		and not replacement.playing
		and bool(replacement_preempted[0]),
		"暂停声部恢复后必须按同 scope 距离立即收敛到硬上限。"
	)
	_stop_and_release(paused_voice, PAUSED_GROUP)
	LIMITER.release_voice(replacement, PAUSED_GROUP)


func _test_one_player_has_one_logical_group() -> void:
	var shared_player := _create_player(tower_scope, Vector2(400.0, 32.0))
	_expect(
		_claim_and_play(shared_player, tower_scope, MULTI_GROUP_A, 1),
		"同播放器多类别测试的首个 group 必须获准。"
	)
	var group_b_blocker := _create_player(tower_scope, Vector2(8.0, 32.0))
	_expect(
		_claim_and_play(group_b_blocker, tower_scope, MULTI_GROUP_B, 1),
		"新 group 的容量阻塞声部必须获准。"
	)
	_expect(
		not _claim_and_play(shared_player, tower_scope, MULTI_GROUP_B, 1),
		"更远的重分类请求必须被目标 group 拒绝。"
	)
	_expect(
		shared_player.playing
		and LIMITER.get_active_voice_count(tower_scope, MULTI_GROUP_A) == 1
		and shared_player.is_in_group(MULTI_GROUP_A)
		and not shared_player.is_in_group(MULTI_GROUP_B),
		"重分类仲裁失败时必须完整保留旧 group 租约。"
	)
	_stop_and_release(group_b_blocker, MULTI_GROUP_B)
	_expect(
		_claim_and_play(shared_player, tower_scope, MULTI_GROUP_B, 1),
		"同一物理播放器必须可原子迁移到新逻辑 group。"
	)
	_expect(
		LIMITER.get_active_voice_count(tower_scope, MULTI_GROUP_A) == 0
		and LIMITER.get_active_voice_count(tower_scope, MULTI_GROUP_B) == 1
		and not shared_player.is_in_group(MULTI_GROUP_A)
		and shared_player.is_in_group(MULTI_GROUP_B),
		"一个 AudioStreamPlayer2D 只能拥有一个逻辑 group，旧账本不得残留。"
	)
	_stop_and_release(shared_player, MULTI_GROUP_B)


func _test_explicit_release_and_tree_exit() -> void:
	var released_voice := _create_player(tower_scope, Vector2.ZERO)
	_expect(_claim_and_play(released_voice, tower_scope, EXIT_GROUP, 1), "释放用声部必须获准。")
	_stop_and_release(released_voice, EXIT_GROUP)
	_expect(
		LIMITER.get_active_voice_count(tower_scope, EXIT_GROUP) == 0
		and not released_voice.is_in_group(EXIT_GROUP),
		"显式 stop/release 必须同步归还 scope 槽位和调试标签。"
	)

	var exiting_voice := _create_player(tower_scope, Vector2.ZERO)
	var preempted := [false]
	exiting_voice.set_meta(
		LIMITER.VOICE_PREEMPTED_CALLBACK_META,
		func() -> void: preempted[0] = true
	)
	_expect(_claim_and_play(exiting_voice, tower_scope, EXIT_GROUP, 1), "退出树用声部必须获准。")
	tower_scope.remove_child(exiting_voice)
	_expect(
		LIMITER.get_active_voice_count(tower_scope, EXIT_GROUP) == 0,
		"已退出树的声部必须在下一次读取时释放槽位。"
	)
	_expect(not bool(preempted[0]), "节点退出只清理租约，不得伪装成距离抢占。")
	exiting_voice.free()


func _test_foreign_viewport_scope_isolation() -> void:
	var sub_viewport := SubViewport.new()
	sub_viewport.size = Vector2i(320, 180)
	fixture.add_child(sub_viewport)
	var foreign_scope := Node2D.new()
	foreign_scope.name = "ForeignViewportScope"
	sub_viewport.add_child(foreign_scope)
	var foreign_voice := _create_player(foreign_scope, Vector2(2.0, 0.0))
	_expect(
		_claim_and_play(foreign_voice, foreign_scope, VIEWPORT_GROUP, 1),
		"独立 Viewport 的显式 scope 必须可持有自己的声部。"
	)

	var tower_far := _create_player(tower_scope, Vector2(400.0, 24.0))
	var tower_near := _create_player(tower_scope, Vector2(12.0, 24.0))
	_expect(_claim_and_play(tower_far, tower_scope, VIEWPORT_GROUP, 1), "Tower Viewport 声部必须获准。")
	_expect(_claim_and_play(tower_near, tower_scope, VIEWPORT_GROUP, 1), "Tower 近处声部必须获准。")
	_expect(not tower_far.playing, "同 Viewport、同 scope 的最远声部必须被抢占。")
	_expect(foreign_voice.playing, "不同 Viewport/scope 的声部不得被 Tower 仲裁 stop。")
	_expect(
		LIMITER.get_active_voice_count(tower_scope, VIEWPORT_GROUP) == 1
		and LIMITER.get_active_voice_count(foreign_scope, VIEWPORT_GROUP) == 1,
		"不同 Viewport/scope 的活动计数必须完全隔离。"
	)

	_stop_and_release(tower_near, VIEWPORT_GROUP)
	_stop_and_release(foreign_voice, VIEWPORT_GROUP)
	sub_viewport.queue_free()
	await process_frame


func _create_player(parent: Node, player_position: Vector2) -> AudioStreamPlayer2D:
	var player := AudioStreamPlayer2D.new()
	# 循环副本避免 0.32 秒夹具在低速 CI 首帧中自然结束，暂停断言只同步
	# AudioServer 状态，不再依赖偶然的帧耗时。
	var loop_stream := TEST_STREAM.duplicate() as AudioStreamWAV
	loop_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	player.stream = loop_stream
	player.max_polyphony = 1
	player.max_distance = 1000.0
	player.position = player_position
	parent.add_child(player)
	return player


func _pause_voice_reliably(player: AudioStreamPlayer2D) -> bool:
	for _attempt in range(8):
		player.stream_paused = true
		await process_frame
		if player.stream_paused:
			return true
	return false


func _wait_until_playing(player: AudioStreamPlayer2D) -> bool:
	for _attempt in range(8):
		if player.playing:
			return true
		await process_frame
	return player.playing


func _claim_and_play(
	player: AudioStreamPlayer2D,
	audio_scope: Node,
	audio_group: StringName,
	voice_cap: int
) -> bool:
	var active_count := LIMITER.claim_voice(
		player,
		audio_scope,
		audio_group,
		voice_cap
	)
	if active_count == LIMITER.REJECTED_ACTIVE_COUNT:
		return false
	player.play()
	if player.playing:
		return true
	LIMITER.release_voice(player, audio_group)
	return false


func _stop_and_release(
	player: AudioStreamPlayer2D,
	audio_group: StringName
) -> void:
	player.stop()
	LIMITER.release_voice(player, audio_group)


func _stop_audio_descendants(node: Node) -> void:
	if node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_descendants(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
