extends Node2D

const ENEMY_SPAWN_EFFECT_SCENE := preload("res://scene/yuanshi_insect_spawn_effect.tscn")
const COUNTDOWN_FINAL_SECONDS := 3

enum WaveState {
	PRE_WAVE,
	WAVE_ACTIVE,
	INTERMISSION,
	VICTORY,
	DEFEAT,
}

@export_group("波次资源")
@export var enemy_scene: PackedScene = preload("res://scene/yuanshi_insect.tscn")
@export var waves: Array[WaveConfig] = [
	preload("res://resources/config/waves/wave_01.tres"),
	preload("res://resources/config/waves/wave_02.tres"),
	preload("res://resources/config/waves/wave_03.tres"),
	preload("res://resources/config/waves/wave_04.tres"),
	preload("res://resources/config/waves/wave_05.tres"),
]

@export_group("波次流程")
@export_range(0.0, 60.0, 1.0, "or_greater") var pre_wave_duration: float = 5.0
@export var auto_start_waves: bool = true

@onready var player: Player = $Player
@onready var enemy_container: Node2D = $EnemyContainer
@onready var enemy_spawn_points_root: Node2D = $EnemySpawnPoints
@onready var enemy_spawn_timer: Timer = $EnemySpawnTimer
@onready var state_timer: Timer = $StateTimer
@onready var grid_pathfinder: Node = $GridPathfinder
@onready var music_player: AudioStreamPlayer = $MusicPlayer
@onready var enemy_spawn_audio: AudioStreamPlayer = $EnemySpawnAudio
@onready var countdown_audio: AudioStreamPlayer = $CountdownAudio
@onready var wave_start_audio: AudioStreamPlayer = $WaveStartAudio
@onready var currency_hud: CurrencyHUD = $CurrencyHUD
@onready var wave_hud: WaveHUD = $WaveHUD
@onready var player_profile_panel: PlayerProfilePanel = $PlayerProfilePanel
@onready var merchant: ZhuangfangyiMerchant = $ZhuangfangyiMerchant
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var random_generator := RandomNumberGenerator.new()
var enemy_spawn_points: Array[Marker2D] = []
var pending_enemy_configs: Array[EnemyConfig] = []
var active_wave_enemy_ids: Dictionary = {}

var wave_state: WaveState = WaveState.PRE_WAVE
var current_wave_index: int = 0
var current_wave_total: int = 0
var current_wave_spawned: int = 0
var current_wave_defeated: int = 0
var countdown_seconds: int = 0


func _ready() -> void:
	random_generator.randomize()
	run_state.ensure_run_started()
	_collect_enemy_spawn_points()
	_configure_timers()
	currency_hud.bind_player(player)
	player_profile_panel.bind_player(player)
	currency_hud.profile_requested.connect(player_profile_panel.open)
	player.died.connect(_on_player_died)
	merchant.set_active(false)

	if auto_start_waves and _is_wave_system_ready():
		_enter_pre_wave(0)
	else:
		wave_hud.hide_all()


func _collect_enemy_spawn_points() -> void:
	enemy_spawn_points.clear()
	for child in enemy_spawn_points_root.get_children():
		var spawn_point := child as Marker2D
		if spawn_point != null:
			enemy_spawn_points.append(spawn_point)

	if enemy_spawn_points.is_empty():
		push_warning("EnemySpawnPoints 下没有可用的 Marker2D 刷新点。")


func _configure_timers() -> void:
	enemy_spawn_timer.one_shot = false
	if not enemy_spawn_timer.timeout.is_connected(_on_enemy_spawn_timer_timeout):
		enemy_spawn_timer.timeout.connect(_on_enemy_spawn_timer_timeout)

	state_timer.one_shot = false
	state_timer.wait_time = 1.0
	if not state_timer.timeout.is_connected(_on_state_timer_timeout):
		state_timer.timeout.connect(_on_state_timer_timeout)


func _enter_pre_wave(wave_index: int) -> void:
	if wave_index < 0 or wave_index >= waves.size():
		_enter_victory()
		return

	wave_state = WaveState.PRE_WAVE
	current_wave_index = wave_index
	enemy_spawn_timer.stop()
	merchant.set_active(false)
	countdown_seconds = maxi(ceili(pre_wave_duration), 0)
	wave_hud.show_countdown(countdown_seconds)

	if countdown_seconds <= 0:
		_begin_wave(current_wave_index)
		return

	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_play_countdown_tick()
	state_timer.start(1.0)


func _enter_intermission() -> void:
	wave_state = WaveState.INTERMISSION
	enemy_spawn_timer.stop()
	merchant.set_active(true)

	var wave_config := _get_current_wave()
	countdown_seconds = (
		maxi(ceili(wave_config.rest_duration_after_wave), 0)
		if wave_config != null
		else 0
	)
	wave_hud.show_countdown(countdown_seconds)

	if countdown_seconds <= 0:
		_begin_wave(current_wave_index + 1)
		return

	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_play_countdown_tick()
	state_timer.start(1.0)


func _begin_wave(wave_index: int) -> void:
	if wave_index < 0 or wave_index >= waves.size():
		_enter_victory()
		return

	var wave_config := waves[wave_index]
	if wave_config == null:
		push_error("波次 %d 缺少 WaveConfig。" % (wave_index + 1))
		_enter_defeat()
		return

	wave_state = WaveState.WAVE_ACTIVE
	current_wave_index = wave_index
	state_timer.stop()
	merchant.set_active(false)
	current_wave_spawned = 0
	current_wave_defeated = 0
	active_wave_enemy_ids.clear()
	_build_wave_spawn_queue(wave_config)
	current_wave_total = pending_enemy_configs.size()
	_update_wave_music(wave_config)
	wave_hud.show_wave_progress(
		current_wave_index + 1,
		current_wave_defeated,
		current_wave_total
	)
	wave_start_audio.play()

	if current_wave_total <= 0:
		_check_wave_completion()
		return

	_spawn_wave_batch()
	if not pending_enemy_configs.is_empty():
		enemy_spawn_timer.start(maxf(wave_config.spawn_interval, 0.05))


func _build_wave_spawn_queue(wave_config: WaveConfig) -> void:
	pending_enemy_configs.clear()
	for entry in wave_config.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		for _enemy_index in range(maxi(entry.count, 0)):
			pending_enemy_configs.append(entry.enemy_config)

	for source_index in range(pending_enemy_configs.size() - 1, 0, -1):
		var target_index := random_generator.randi_range(0, source_index)
		var temporary := pending_enemy_configs[source_index]
		pending_enemy_configs[source_index] = pending_enemy_configs[target_index]
		pending_enemy_configs[target_index] = temporary


func _on_state_timer_timeout() -> void:
	if wave_state != WaveState.PRE_WAVE and wave_state != WaveState.INTERMISSION:
		state_timer.stop()
		return

	countdown_seconds = maxi(countdown_seconds - 1, 0)
	if countdown_seconds > 0:
		wave_hud.show_countdown(countdown_seconds)
		if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
			_play_countdown_tick()
		return

	state_timer.stop()
	if wave_state == WaveState.PRE_WAVE:
		_begin_wave(current_wave_index)
	else:
		_begin_wave(current_wave_index + 1)


func _on_enemy_spawn_timer_timeout() -> void:
	_spawn_wave_batch()


func _spawn_wave_batch() -> void:
	if wave_state != WaveState.WAVE_ACTIVE:
		enemy_spawn_timer.stop()
		return

	var wave_config := _get_current_wave()
	if wave_config == null:
		enemy_spawn_timer.stop()
		return

	for _spawn_index in range(maxi(wave_config.spawn_count_per_tick, 1)):
		if pending_enemy_configs.is_empty():
			break
		if active_wave_enemy_ids.size() >= maxi(wave_config.max_alive_enemies, 1):
			break

		var enemy_config := pending_enemy_configs[0]
		if not _try_spawn_enemy(enemy_config):
			break

		pending_enemy_configs.remove_at(0)
		current_wave_spawned += 1

	if pending_enemy_configs.is_empty():
		enemy_spawn_timer.stop()

	_check_wave_completion()


func _try_spawn_enemy(enemy_config: EnemyConfig) -> bool:
	if not _is_spawn_system_ready() or enemy_config == null:
		return false

	var spawn_point := _pick_spawn_point()
	if spawn_point == null:
		return false

	var spawn_scene := (
		enemy_config.enemy_scene_override
		if enemy_config.enemy_scene_override != null
		else enemy_scene
	)
	var enemy_instance := spawn_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("敌人场景实例化失败，请检查波次中的敌人配置。")
		return false

	enemy_container.add_child(enemy_instance)
	enemy_instance.global_position = spawn_point.global_position
	enemy_instance.setup(enemy_config, player, grid_pathfinder)
	var enemy_id := enemy_instance.get_instance_id()
	active_wave_enemy_ids[enemy_id] = true
	enemy_instance.defeated.connect(_on_wave_enemy_defeated)
	enemy_instance.tree_exited.connect(_on_wave_enemy_tree_exited.bind(enemy_id))
	_spawn_enemy_spawn_effect(spawn_point.global_position)
	enemy_spawn_audio.play()
	return true


func _on_wave_enemy_defeated(enemy: Enemy) -> void:
	if wave_state != WaveState.WAVE_ACTIVE:
		return
	if enemy == null or not active_wave_enemy_ids.has(enemy.get_instance_id()):
		return

	current_wave_defeated = mini(current_wave_defeated + 1, current_wave_total)
	wave_hud.show_wave_progress(
		current_wave_index + 1,
		current_wave_defeated,
		current_wave_total
	)
	_check_wave_completion()


func _on_wave_enemy_tree_exited(enemy_id: int) -> void:
	active_wave_enemy_ids.erase(enemy_id)
	_check_wave_completion()


func _check_wave_completion() -> void:
	if wave_state != WaveState.WAVE_ACTIVE:
		return
	if not pending_enemy_configs.is_empty():
		return
	if current_wave_spawned < current_wave_total:
		return
	if current_wave_defeated < current_wave_total:
		return
	if not active_wave_enemy_ids.is_empty():
		return

	enemy_spawn_timer.stop()
	if current_wave_index >= waves.size() - 1:
		_enter_victory()
	else:
		_enter_intermission()


func _enter_victory() -> void:
	wave_state = WaveState.VICTORY
	enemy_spawn_timer.stop()
	state_timer.stop()
	merchant.set_active(false)
	wave_hud.show_victory()


func _enter_defeat() -> void:
	if wave_state == WaveState.DEFEAT:
		return
	wave_state = WaveState.DEFEAT
	enemy_spawn_timer.stop()
	state_timer.stop()
	merchant.set_active(false)
	wave_hud.show_defeat()


func _on_player_died() -> void:
	if wave_state == WaveState.VICTORY:
		return
	_enter_defeat()


func _is_wave_system_ready() -> bool:
	if not _is_spawn_system_ready():
		return false
	if waves.is_empty():
		push_warning("Game 场景没有配置任何波次资源。")
		return false
	for wave_config in waves:
		if wave_config == null:
			push_warning("Game 场景的波次数组包含空资源。")
			return false
	return true


func _is_spawn_system_ready() -> bool:
	return (
		player != null
		and enemy_scene != null
		and grid_pathfinder != null
		and grid_pathfinder.get("is_built")
		and not enemy_spawn_points.is_empty()
	)


func _get_current_wave() -> WaveConfig:
	if current_wave_index < 0 or current_wave_index >= waves.size():
		return null
	return waves[current_wave_index]


func _pick_spawn_point() -> Marker2D:
	if enemy_spawn_points.is_empty():
		return null
	return enemy_spawn_points[
		random_generator.randi_range(0, enemy_spawn_points.size() - 1)
	]


func _spawn_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	var effect := ENEMY_SPAWN_EFFECT_SCENE.instantiate() as Node2D
	if effect == null:
		return
	add_child(effect)
	effect.global_position = spawn_global_position


func _play_countdown_tick() -> void:
	countdown_audio.pitch_scale = 1.0
	countdown_audio.play()


func _update_wave_music(wave_config: WaveConfig) -> void:
	if wave_config.music == null:
		return
	if music_player.stream == wave_config.music and music_player.playing:
		return
	music_player.stream = wave_config.music
	music_player.play()
