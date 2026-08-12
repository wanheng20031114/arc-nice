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
	_expect(music.stream_paused, "只有作战 lease 必须暂停路线音乐。")
	route.call(
		&"_set_route_presentation_lease",
		RogueRouteGame.RoutePresentationLease.COMBAT,
		false
	)
	_expect(
		not music.stream_paused and music.playing,
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
	loader.set("_state", original_loader_state)
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
