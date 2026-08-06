extends Node
class_name StandardMusicCoordinator

const DEFAULT_MUSIC_VOLUME_DB := -6.0
const MUSIC_FADE_IN_SECONDS := 3.0
const MUSIC_FADE_IN_START_VOLUME_DB := -12.0

var music_fade_tween: Tween = null

var _music_player: AudioStreamPlayer = null
var _background_scope: Node = null
var _bound := false


func bind_dependencies(
	music_player: AudioStreamPlayer,
	background_scope: Node
) -> void:
	_music_player = music_player
	_background_scope = background_scope
	_bound = _music_player != null and _background_scope != null


func is_bound() -> bool:
	return _bound


func get_music_player() -> AudioStreamPlayer:
	return _music_player


func replace_music_fade_tween(fade_tween: Tween) -> void:
	music_fade_tween = fade_tween


func update_wave_music(wave_config: WaveConfig) -> void:
	if wave_config.music == null:
		return
	play_music_stream(
		wave_config.music,
		DEFAULT_MUSIC_VOLUME_DB,
		0.0,
		true
	)


func update_post_wave_music(flow_step: FlowStepConfig) -> void:
	var wave_config := flow_step as WaveConfig
	if wave_config == null or wave_config.post_wave_music == null:
		return
	play_music_stream(
		wave_config.post_wave_music,
		DEFAULT_MUSIC_VOLUME_DB,
		0.0,
		true
	)


func update_boss_music(boss_config: BossConfig) -> void:
	if boss_config == null or boss_config.music == null:
		return
	play_music_stream(
		boss_config.music,
		boss_config.music_volume_db,
		boss_config.music_loop_offset,
		false
	)


func pause_all_background_music() -> void:
	stop_music_fade_tween()
	pause_background_music_players(_background_scope)


func play_music_stream(
	stream: AudioStream,
	volume_db: float,
	loop_offset: float = 0.0,
	fade_in: bool = false
) -> void:
	if stream == null:
		return
	configure_music_loop(stream, loop_offset)
	_music_player.stream_paused = false
	if _music_player.stream == stream and _music_player.playing:
		return
	stop_music_fade_tween()
	_music_player.stream = stream
	_music_player.volume_db = (
		MUSIC_FADE_IN_START_VOLUME_DB if fade_in else volume_db
	)
	_music_player.play()
	if fade_in:
		var fade_tween := create_tween()
		music_fade_tween = fade_tween
		fade_tween.tween_property(
			_music_player,
			"volume_db",
			volume_db,
			MUSIC_FADE_IN_SECONDS
		)
		fade_tween.finished.connect(
			func() -> void:
				if music_fade_tween == fade_tween:
					music_fade_tween = null
		)


func stop_music_fade_tween() -> void:
	if music_fade_tween == null:
		return
	music_fade_tween.kill()
	music_fade_tween = null


func configure_music_loop(stream: AudioStream, loop_offset: float) -> void:
	if stream == null:
		return
	if audio_stream_has_property(stream, &"loop"):
		stream.set(&"loop", true)
	if audio_stream_has_property(stream, &"loop_offset"):
		stream.set(&"loop_offset", maxf(loop_offset, 0.0))


func audio_stream_has_property(
	stream: AudioStream,
	property_name: StringName
) -> bool:
	for property in stream.get_property_list():
		if property.get("name") == property_name:
			return true
	return false


func pause_background_music_players(root_node: Node) -> void:
	if root_node == null:
		return
	if is_background_music_player(root_node):
		root_node.set(&"stream_paused", true)
	for child in root_node.get_children():
		pause_background_music_players(child)


func is_background_music_player(node: Node) -> bool:
	if not (
		node is AudioStreamPlayer
		or node is AudioStreamPlayer2D
		or node is AudioStreamPlayer3D
	):
		return false
	if not bool(node.get(&"playing")):
		return false
	var bus_name := String(node.get(&"bus")).to_lower()
	var node_name := String(node.name).to_lower()
	return (
		bus_name == "music"
		or node_name.contains("music")
		or node_name.contains("bgm")
	)
