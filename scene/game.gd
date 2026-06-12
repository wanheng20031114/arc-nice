extends Node2D

const OVERWORLD_MUSIC := preload("res://resources/audio/1-27 Journey of the Prairie King (Overworld).mp3")
const OUTLAW_MUSIC := preload("res://resources/audio/1-28 Journey of the Prairie King (The Outlaw).mp3")
const FINAL_MUSIC := preload("res://resources/audio/1-29 Journey of the Prairie King (Final Boss & Ending).mp3")
const ENEMY_SPAWN_EFFECT_SCENE := preload("res://scene/enemy_spawn_effect.tscn")

@export_group("刷怪资源")
@export var enemy_scene: PackedScene = preload("res://scene/enemy.tscn")
@export var enemy_configs: Array[EnemyConfig] = [
	preload("res://resources/config/enemy_basic.tres"),
	preload("res://resources/config/enemy_shell.tres"),
	preload("res://resources/config/enemy_fast.tres"),
	preload("res://resources/config/enemy_bomber.tres"),
	preload("res://resources/config/enemy_purple_bomber.tres"),
	preload("res://resources/config/enemy_green_shell.tres"),
	preload("res://resources/config/enemy_fire_ranged.tres"),
]


@export_group("刷怪节奏")
# 开局立即刷出的敌人数，用于快速验证系统是否正常工作。
@export_range(0, 100, 1, "or_greater") var initial_spawn_count: int = 1
# 每次计时器触发时生成的敌人数。
@export_range(1, 20, 1, "or_greater") var spawn_count_per_tick: int = 1
# 开局时的刷怪间隔。
@export_range(0.1, 60.0, 0.1, "or_greater") var spawn_interval: float = 1.5
# 关卡后期允许缩短到的最小刷怪间隔。
@export_range(0.1, 60.0, 0.1, "or_greater") var min_spawn_interval: float = 0.6
# 场上允许同时存在的最大敌人数，避免无限堆积。
@export_range(1, 200, 1, "or_greater") var max_alive_enemies: int = 100

# 测试用：刷怪间隔从初始值过渡到最小值所需的时间。
@export_range(1.0, 3600.0, 1.0, "or_greater") var spawn_acceleration_duration: float = 60.0

@onready var player: Player = $Player
@onready var enemy_container: Node2D = $EnemyContainer
@onready var enemy_spawn_points_root: Node2D = $EnemySpawnPoints
@onready var enemy_spawn_timer: Timer = $EnemySpawnTimer
@onready var grid_pathfinder: Node = $GridPathfinder
@onready var music_player: AudioStreamPlayer = $MusicPlayer
@onready var enemy_spawn_audio: AudioStreamPlayer = $EnemySpawnAudio
@onready var currency_hud: CurrencyHUD = $CurrencyHUD
@onready var player_profile_panel: PlayerProfilePanel = $PlayerProfilePanel
@onready var run_state: Node = get_node("/root/RunState")

# 随机数生成器，专门用于挑选出生点和敌人配置。
var random_generator: RandomNumberGenerator = RandomNumberGenerator.new()

# 缓存出生点，避免每次刷怪都重新遍历场景树。
var enemy_spawn_points: Array[Marker2D] = []

# 缓存有效的敌人配置资源，自动忽略空条目。
var available_enemy_configs: Array[EnemyConfig] = []

# 当前游戏已经运行的时间，用于逐渐加快刷怪节奏。
var game_time_elapsed: float = 0.0
var current_music_stage: int = -1


# 初始化刷怪系统：缓存出生点、缓存配置、刷出初始敌人并启动定时器。
func _ready() -> void:
	random_generator.randomize()
	run_state.call("ensure_run_started")
	_collect_enemy_spawn_points()
	_collect_enemy_configs()
	_configure_enemy_spawn_timer()
	currency_hud.bind_player(player)
	player_profile_panel.bind_player(player)
	currency_hud.profile_requested.connect(player_profile_panel.open)
	_update_music()
	_spawn_initial_enemies()
	_start_enemy_spawn_timer()
	
# 每帧更新逻辑，处理时间流逝、刷怪频率调整以及背景音乐阶段的切换
func _process(delta: float) -> void:
	game_time_elapsed += delta
	_update_spawn_interval()
	_update_music()


# 从 EnemySpawnPoints 节点下收集所有 Marker2D 作为可选出生点。
func _collect_enemy_spawn_points() -> void:
	enemy_spawn_points.clear()

	for child in enemy_spawn_points_root.get_children():
		var spawn_point := child as Marker2D
		if spawn_point != null:
			enemy_spawn_points.append(spawn_point)

	if enemy_spawn_points.is_empty():
		push_warning("EnemySpawnPoints 下没有可用的 Marker2D 刷新点。")


# 缓存有效的敌人配置资源，便于后续随机挑选。
func _collect_enemy_configs() -> void:
	available_enemy_configs.clear()

	for enemy_config in enemy_configs:
		if enemy_config != null:
			available_enemy_configs.append(enemy_config)

	if available_enemy_configs.is_empty():
		push_warning("Game 场景没有可用的敌人配置资源。")

func _configure_enemy_spawn_timer() -> void:
	enemy_spawn_timer.one_shot = false
	enemy_spawn_timer.wait_time = _get_current_spawn_interval()

	if not enemy_spawn_timer.timeout.is_connected(_on_enemy_spawn_timer_timeout):
		enemy_spawn_timer.timeout.connect(_on_enemy_spawn_timer_timeout)


# 根据游戏运行时间逐渐缩短刷怪间隔，让后期节奏自然加快。
func _update_spawn_interval() -> void:
	var current_interval := _get_current_spawn_interval()

	if is_equal_approx(enemy_spawn_timer.wait_time, current_interval):
		return

	enemy_spawn_timer.wait_time = current_interval

	# 如果当前这一轮倒计时比新的间隔还长，就立刻切到更快的节奏。
	if enemy_spawn_timer.is_stopped():
		return
	if enemy_spawn_timer.time_left <= current_interval:
		return

	enemy_spawn_timer.start(current_interval)

# 通过游戏运行时间计算当前刷怪间隔。
func _get_current_spawn_interval() -> float:
	var start_interval := maxf(spawn_interval, 0.1)
	var end_interval := minf(maxf(min_spawn_interval, 0.1), start_interval)

	if spawn_acceleration_duration <= 0.0:
		return end_interval

	var difficulty_ratio := clampf(game_time_elapsed / spawn_acceleration_duration, 0.0, 1.0)
	return lerpf(start_interval, end_interval, difficulty_ratio)


# 开局先刷出一小批敌人，方便立即看到运行效果。
func _spawn_initial_enemies() -> void:
	for _spawn_index in range(initial_spawn_count):
		if not _try_spawn_enemy():
			break


# 当前刷怪系统准备完成后再启动定时器。
func _start_enemy_spawn_timer() -> void:
	if not _is_spawn_system_ready():
		return
	enemy_spawn_timer.start(_get_current_spawn_interval())


func _on_enemy_spawn_timer_timeout() -> void:
	for _spawn_index in range(spawn_count_per_tick):
		if not _try_spawn_enemy():
			break

# 尝试生成一个敌人，并自动完成位置和玩家目标初始化。
func _try_spawn_enemy() -> bool:
	if not _is_spawn_system_ready():
		return false

	if _get_alive_enemy_count() >= max_alive_enemies:
		return false

	var spawn_point := _pick_spawn_point()
	if spawn_point == null:
		return false

	var enemy_config := _pick_enemy_config()
	if enemy_config == null:
		return false

	var enemy_instance := enemy_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("敌人场景实例化失败，请检查 enemy_scene 设置。")
		return false

	enemy_container.add_child(enemy_instance)
	enemy_instance.global_position = spawn_point.global_position
	enemy_instance.setup(enemy_config, player, grid_pathfinder)
	_spawn_enemy_spawn_effect(spawn_point.global_position)
	enemy_spawn_audio.play()

	return true
	
# 只要玩家、敌人场景、配置和出生点都有效，就允许继续刷怪。
func _is_spawn_system_ready() -> bool:
	return (
		player != null
		and enemy_scene != null
		and grid_pathfinder != null
		and grid_pathfinder.get("is_built")
		and not enemy_spawn_points.is_empty()
		and not available_enemy_configs.is_empty()
	)


# 随机挑选一个出生点。
func _pick_spawn_point() -> Marker2D:
	if enemy_spawn_points.is_empty():
		return null

	var random_index := random_generator.randi_range(0, enemy_spawn_points.size() - 1)
	return enemy_spawn_points[random_index]


# 随机挑选一个敌人配置。
func _pick_enemy_config() -> EnemyConfig:
	if available_enemy_configs.is_empty():
		return null

	var random_index := random_generator.randi_range(0, available_enemy_configs.size() - 1)
	return available_enemy_configs[random_index]

# 获取当前场景中存活（尚未被销毁）的敌人数
func _get_alive_enemy_count() -> int:
	var alive_enemy_count := 0
	for child in enemy_container.get_children():
		if child is Enemy:
			alive_enemy_count += 1
			
	return alive_enemy_count


# 在指定的出生点位置生成敌人出现时的视觉特效
func _spawn_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	var effect := ENEMY_SPAWN_EFFECT_SCENE.instantiate() as Node2D
	if effect == null:
		return

	add_child(effect)
	effect.global_position = spawn_global_position


# 根据当前的游戏难度（时间进度）更新背景音乐阶段
func _update_music() -> void:
	var difficulty_ratio := _get_difficulty_ratio()
	var next_music_stage := 0
	var next_stream: AudioStream = OVERWORLD_MUSIC

	if difficulty_ratio >= 0.9:
		next_music_stage = 2
		next_stream = FINAL_MUSIC
	elif difficulty_ratio >= 0.5:
		next_music_stage = 1
		next_stream = OUTLAW_MUSIC

	if current_music_stage == next_music_stage:
		return

	current_music_stage = next_music_stage
	music_player.stream = next_stream
	music_player.play()


# 计算当前游戏时间的难度比例（0.0 ~ 1.0），用于控制音乐阶段和刷怪频率
func _get_difficulty_ratio() -> float:
	if spawn_acceleration_duration <= 0.0:
		return 1.0

	return clampf(game_time_elapsed / spawn_acceleration_duration, 0.0, 1.0)
	
	
