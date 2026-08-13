extends SceneTree

const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const LOADER_IDLE_STATE := 0
const LOADER_WAITING_FOR_MULTIPLAYER_STATE := 3

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var loader := root.get_node_or_null("GameLoadCoordinator")
	_expect(loader != null, "路线音乐测试必须取得 GameLoadCoordinator。")
	if loader == null:
		_finish()
		return
	var original_loader_state := int(loader.get("_state"))
	# WAITING 不推进加载器内部流程，但仍精确代表现有 is_loading 门禁。
	loader.set("_state", LOADER_WAITING_FOR_MULTIPLAYER_STATE)

	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	route.auto_initialize = false
	route.manage_return_locally = false
	root.add_child(route)
	await process_frame
	await process_frame

	var music := route.route_music_player
	var ogg_stream := music.stream as AudioStreamOggVorbis
	_expect(
		music != null
		and music.bus == &"Music"
		and is_equal_approx(music.volume_db, -6.0)
		and not music.autoplay,
		"路线场景必须 authored -6 dB、Music 总线且不自动播放的独立 BGM。"
	)
	_expect(ogg_stream != null, "路线音乐必须使用项目约定的 Ogg Vorbis 格式。")
	if ogg_stream != null:
		_expect(ogg_stream.loop, "路线 OGG 必须启用原生循环。")
		_expect(
			is_zero_approx(ogg_stream.loop_offset),
			"完整路线 BGM 必须从曲首开始下一轮播放。"
		)
		_expect(
			absf(ogg_stream.get_length() - 153.16) <= 0.01,
			"路线 OGG 的处理后总时长必须约为 153.16 秒。"
		)
	_expect(
		route.start_authoritative_session(0xCA7E, false),
		"路线音乐测试必须先建立完整且有效的路线运行态。"
	)
	route.activate_runtime()
	await process_frame
	_expect(
		not music.playing,
		"加载门禁尚未完成时，显式 runtime 激活也不得提前播放路线音乐。"
	)

	loader.set("_state", LOADER_IDLE_STATE)
	route.call(&"_on_loading_finished", false)
	await process_frame
	_expect(music.playing, "加载完成且路线就绪后必须开始播放路线音乐。")
	music.seek(12.0)
	await process_frame
	var playback_before_reactivation := music.get_stream_playback()
	route.activate_runtime()
	await process_frame
	_expect(
		music.playing
		and music.get_stream_playback() == playback_before_reactivation,
		"重复 runtime 激活必须保持现有播放头，不得重启路线音乐。"
	)

	route.call(
		&"_set_route_presentation_lease",
		RogueRouteGame.RoutePresentationLease.MAGICAL_ENCOUNTER,
		true
	)
	_expect(not music.stream_paused, "神奇遭遇不得暂停路线音乐。")
	route.call(
		&"_set_route_presentation_lease",
		RogueRouteGame.RoutePresentationLease.UNDERGROUND_SHOP,
		true
	)
	_expect(not music.stream_paused, "地下商店不得暂停路线音乐。")
	route.call(
		&"_set_route_presentation_lease",
		RogueRouteGame.RoutePresentationLease.COMBAT,
		true
	)
	await process_frame
	var playback_during_combat := music.get_stream_playback()
	var paused_position := music.get_playback_position()
	_expect(
		music.has_stream_playback()
		and music.stream_paused
		and playback_during_combat == playback_before_reactivation
		and paused_position >= 10.0,
		"作战 lease 必须暂停既有 playback，并保留非零播放头。"
	)
	route.activate_runtime()
	route.call(&"_on_loading_finished", false)
	await process_frame
	_expect(
		music.has_stream_playback()
		and music.stream_paused
		and music.get_stream_playback() == playback_during_combat
		and absf(music.get_playback_position() - paused_position) <= 0.05,
		"作战暂停期间重复激活必须保持 playback 身份与播放位置。"
	)
	route.call(
		&"_set_route_presentation_lease",
		RogueRouteGame.RoutePresentationLease.COMBAT,
		false
	)
	await process_frame
	_expect(
		not music.stream_paused
		and music.playing
		and music.get_stream_playback() == playback_during_combat
		and music.get_playback_position() >= paused_position - 0.05,
		"作战结束后即使商店与遭遇 lease 仍交叠，也必须从原播放头恢复音乐。"
	)
	route.call(
		&"_set_route_presentation_lease",
		RogueRouteGame.RoutePresentationLease.MAGICAL_ENCOUNTER,
		false
	)
	route.call(
		&"_set_route_presentation_lease",
		RogueRouteGame.RoutePresentationLease.UNDERGROUND_SHOP,
		false
	)
	_expect(not music.stream_paused, "全部路线 lease 释放后音乐必须保持播放。")

	music.stop()
	route.queue_free()
	await process_frame

	# 晚加入/完整同步可能先恢复作战 lease，再完成路线首次音乐启动。
	loader.set("_state", LOADER_WAITING_FOR_MULTIPLAYER_STATE)
	var leased_route := ROUTE_SCENE.instantiate() as RogueRouteGame
	leased_route.auto_initialize = false
	leased_route.manage_return_locally = false
	root.add_child(leased_route)
	await process_frame
	await process_frame
	_expect(
		leased_route.start_authoritative_session(0xCA7F, false),
		"先恢复 lease 的音乐测试必须建立有效路线运行态。"
	)
	leased_route.call(
		&"_set_route_presentation_lease",
		RogueRouteGame.RoutePresentationLease.COMBAT,
		true
	)
	leased_route.activate_runtime()
	await process_frame
	var leased_music := leased_route.route_music_player
	_expect(
		not leased_music.has_stream_playback(),
		"加载门禁期间即使已有作战 lease，也不得提前创建 playback。"
	)

	loader.set("_state", LOADER_IDLE_STATE)
	leased_route.call(&"_on_loading_finished", true)
	await process_frame
	var initially_paused_playback := leased_music.get_stream_playback()
	_expect(
		leased_music.has_stream_playback()
		and leased_music.stream_paused
		and initially_paused_playback != null,
		"首次启动发生在作战 lease 下时，必须创建一次 playback 并立即保持暂停。"
	)
	leased_route.activate_runtime()
	await process_frame
	_expect(
		leased_music.stream_paused
		and leased_music.get_stream_playback() == initially_paused_playback,
		"先 lease 后启动的路线音乐重复激活时也不得重建 playback。"
	)
	leased_route.call(
		&"_set_route_presentation_lease",
		RogueRouteGame.RoutePresentationLease.COMBAT,
		false
	)
	await process_frame
	_expect(
		leased_music.playing
		and not leased_music.stream_paused
		and leased_music.get_stream_playback() == initially_paused_playback,
		"首次启动后释放作战 lease 必须续播同一个 playback。"
	)
	leased_music.stop()
	leased_route.queue_free()
	loader.set("_state", original_loader_state)
	await process_frame
	await process_frame
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_ROUTE_MUSIC_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
