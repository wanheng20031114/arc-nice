extends Node
class_name StandardPrewarmerCoordinator

# 普通模式专属预热边界：共享波次实体池仍由 WaveCombatRuntimeBase 注册。
const TANGO_LASER_BULLET_POOL_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const LINGLAN_SKILL1_BULLET_POOL_SCENE := preload(
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
)
const LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE := preload(
	"res://scene/boss/linglan/linglan_sakura_hit_effect.tscn"
)
const LINGLAN_ENRAGE_SNIPER_CONFIG_PATH := (
	"res://resources/config/enemies/capoo_sniper.tres"
)

var runtime_scene_loads_requested: bool = false
var linglan_enrage_sniper_config: EnemyConfig = null
var runtime_resources_by_path: Dictionary[String, Resource] = {}

var _session_object_pool: SessionObjectPool = null
var _boss_coordinator: StandardBossCoordinator = null
var _boss_flow_enabled: bool = true
var _bound := false


func bind_dependencies(
	object_pool: SessionObjectPool,
	boss: StandardBossCoordinator,
	boss_flow_enabled: bool
) -> void:
	_session_object_pool = object_pool
	_boss_coordinator = boss
	_boss_flow_enabled = boss_flow_enabled
	_bound = _session_object_pool != null and _boss_coordinator != null


func is_bound() -> bool:
	return _bound


func configure_boss_flow_enabled(enabled: bool) -> void:
	_boss_flow_enabled = enabled


func replace_runtime_scene_loads_requested(requested: bool) -> void:
	runtime_scene_loads_requested = requested


func replace_linglan_enrage_sniper_config(config: EnemyConfig) -> void:
	linglan_enrage_sniper_config = config


func replace_runtime_resources_by_path(
	resources_by_path: Dictionary[String, Resource]
) -> void:
	runtime_resources_by_path = resources_by_path


func register_mode_object_pools() -> void:
	if _session_object_pool == null:
		push_error("StandardPrewarmerCoordinator: 对象池依赖尚未绑定。")
		return
	_session_object_pool.register_scene(TANGO_LASER_BULLET_POOL_SCENE, 64, 768)
	_session_object_pool.register_scene(LINGLAN_SKILL1_BULLET_POOL_SCENE, 64, 768)
	_session_object_pool.register_scene(LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE, 16, 96)


func schedule_boss_runtime_scene_loads() -> void:
	call_deferred("request_boss_runtime_scene_loads_deferred")


func request_boss_runtime_scene_loads() -> void:
	if runtime_scene_loads_requested:
		return
	if not _boss_flow_enabled:
		return
	runtime_scene_loads_requested = true
	for resource_path in get_boss_runtime_resource_paths():
		ResourceLoader.load_threaded_request(resource_path)


func get_boss_runtime_resource_paths() -> Array[String]:
	var paths := _boss_coordinator.get_runtime_resource_paths()
	paths.append(LINGLAN_ENRAGE_SNIPER_CONFIG_PATH)
	return paths


func prewarm_boss_runtime_resources() -> void:
	if not _boss_flow_enabled:
		return
	request_boss_runtime_scene_loads()
	for resource_path in get_boss_runtime_resource_paths():
		if runtime_resources_by_path.has(resource_path):
			continue
		var status := ResourceLoader.load_threaded_get_status(resource_path)
		while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
			if _should_abort_prewarm_after_frame():
				return
			status = ResourceLoader.load_threaded_get_status(resource_path)
		var runtime_resource := (
			ResourceLoader.load_threaded_get(resource_path)
			if status == ResourceLoader.THREAD_LOAD_LOADED
			else load(resource_path)
		)
		if runtime_resource != null:
			runtime_resources_by_path[resource_path] = runtime_resource


func get_linglan_enrage_sniper_config() -> EnemyConfig:
	if linglan_enrage_sniper_config == null:
		linglan_enrage_sniper_config = (
			load_threaded_or_direct(LINGLAN_ENRAGE_SNIPER_CONFIG_PATH) as EnemyConfig
		)
	return linglan_enrage_sniper_config


func load_threaded_or_direct(path: String) -> Resource:
	if path.is_empty():
		return null
	var retained_resource := runtime_resources_by_path.get(path) as Resource
	if retained_resource != null:
		return retained_resource
	var status := ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		return ResourceLoader.load_threaded_get(path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return ResourceLoader.load_threaded_get(path)
	return load(path)


func _should_abort_prewarm_after_frame() -> bool:
	return not is_inside_tree()


func request_boss_runtime_scene_loads_deferred() -> void:
	if DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return
	request_boss_runtime_scene_loads()
