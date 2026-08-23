extends SceneTree

const FIRE_SORCERER_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer.tscn"
)
const FIRE_SORCERER_ELITE_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_elite.tscn"
)
const FIRE_SORCERER_CONFIG := preload(
	"res://resources/config/enemies/fire_sorcerer.tres"
)
const ENEMY_SIMULATION_COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)

var _failures: Array[String] = []
var _runtime: PlayerTestCombatRuntime = null
var _gateway: RejectingFireVolleyGateway = null


class RejectingFireVolleyGateway:
	extends MultiplayerGameplayGateway

	var fire_volley_registration_calls := 0
	var last_service: FireSorcererVolleySimulationService = null
	var last_handle := FireSorcererVolleySimulationService.INVALID_HANDLE
	var last_spawn_position := Vector2.ZERO
	var last_direction := Vector2.ZERO
	var last_damage := 0
	var last_snapshot: DamageSourceSnapshot = null

	func register_local_fire_sorcerer_volley_data(
		service: FireSorcererVolleySimulationService,
		handle: int,
		_projectile_type: StringName,
		_owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		_speed: float,
		_lifetime: float,
		_target_peer_id: int,
		_target_enemy_net_id: int,
		damage_source_snapshot: DamageSourceSnapshot
	) -> int:
		fire_volley_registration_calls += 1
		last_service = service
		last_handle = handle
		last_spawn_position = spawn_position
		last_direction = direction
		last_damage = damage
		last_snapshot = damage_source_snapshot
		return 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_runtime = PlayerTestCombatRuntime.new()
	_gateway = RejectingFireVolleyGateway.new()
	var default_gateway := _runtime.get_node("MultiplayerGameplayGateway")
	_runtime.remove_child(default_gateway)
	default_gateway.free()
	_gateway.name = &"MultiplayerGameplayGateway"
	_runtime.add_child(_gateway)
	_runtime.add_child(ENEMY_SIMULATION_COORDINATOR_SCENE.instantiate())
	root.add_child(_runtime)
	current_scene = _runtime
	await process_frame

	await _test_singleplayer_data_registration()
	await _test_host_registration_failure_releases_handle()
	_test_elite_profile_selection()

	var coordinator := _runtime.get_enemy_simulation_coordinator()
	if coordinator != null:
		coordinator.prepare_combat_services_for_runtime_teardown()
	current_scene = null
	_runtime.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame
	_finish()


func _test_singleplayer_data_registration() -> void:
	_runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var service := _get_service()
	var enemy := _spawn_sorcerer(FIRE_SORCERER_SCENE)
	enemy.global_position = Vector2(120.0, 80.0)
	enemy.summon_direction = Vector2.UP
	enemy.summon_pivot.rotation = enemy.summon_direction.angle()
	var expected_positions := PackedVector2Array()
	for marker in enemy.summon_markers:
		expected_positions.append(marker.global_position)
	var node_count_before := _count_retired_volley_nodes(_runtime)
	var fired := bool(enemy.call(
		"_spawn_fireball_volley",
		FIRE_SORCERER_CONFIG
	))
	_expect(
		fired,
		"Singleplayer DATA must not depend on the legacy volley scene."
	)
	_expect(
		_count_retired_volley_nodes(_runtime) == node_count_before,
		"DATA authority must not create a FireSorcererFireballVolley Node."
	)
	_expect(
		service.get_active_slot_count() == 1,
		"Singleplayer DATA must remain directly owned by the simulation service."
	)
	var handle := _find_live_handle(service)
	_expect(
		handle > FireSorcererVolleySimulationService.INVALID_HANDLE
		and service.get_slot_mode(handle)
			== FireSorcererVolleySimulationService.Mode.DATA
		and service.get_slot_profile(handle)
			== FireSorcererVolleySimulationService.Profile.NORMAL
		and service.get_slot_state(handle)
			== FireSorcererVolleySimulationService.SlotState.PENDING_ACTIVATION,
		"DATA row must be NORMAL and remain pending until the next physics tick."
	)
	for ball_index in range(FireSorcererVolleySimulationService.BALL_COUNT):
		_expect(
			service.get_ball_position(handle, ball_index).is_equal_approx(
				expected_positions[ball_index]
			)
			and service.get_ball_direction(handle, ball_index).is_equal_approx(
				Vector2.UP
			),
			"DATA ball %d must start at its authored marker with the shared direction."
			% ball_index
		)
	await physics_frame
	await process_frame
	_expect(
		service.get_slot_state(handle)
		== FireSorcererVolleySimulationService.SlotState.ACTIVE,
		"A newly registered DATA row must activate on the next physics tick."
	)
	service.release_volley(handle)
	enemy.queue_free()
	await process_frame


func _test_host_registration_failure_releases_handle() -> void:
	_runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var service := _get_service()
	var enemy := _spawn_sorcerer(FIRE_SORCERER_SCENE)
	enemy.summon_direction = Vector2.RIGHT
	var node_count_before := _count_retired_volley_nodes(_runtime)
	var calls_before := _gateway.fire_volley_registration_calls
	var fired := bool(enemy.call(
		"_spawn_fireball_volley",
		FIRE_SORCERER_CONFIG
	))
	_expect(
		not fired
		and _gateway.fire_volley_registration_calls == calls_before + 1,
		"Host DATA must report a rejected gateway registration."
	)
	_expect(
		_gateway.last_service == service
		and not service.is_handle_live(_gateway.last_handle)
		and service.get_active_slot_count() == 0,
		"Rejected Host identity must release the pending service handle."
	)
	_expect(
		_gateway.last_spawn_position.is_equal_approx(
			enemy.summon_pivot.global_position
		)
		and _gateway.last_direction.is_equal_approx(enemy.summon_direction)
		and _gateway.last_damage
			== enemy.get_effective_attack_damage(
				FIRE_SORCERER_CONFIG.attack_damage
			)
		and _gateway.last_snapshot != null
		and _gateway.last_snapshot.is_valid(),
		"Host registration must forward pivot, direction, damage and a valid snapshot."
	)
	_expect(
		_count_retired_volley_nodes(_runtime) == node_count_before,
		"Rejected Host DATA must never fall back to a projectile Node."
	)
	enemy.queue_free()
	await process_frame


func _test_elite_profile_selection() -> void:
	var elite := FIRE_SORCERER_ELITE_SCENE.instantiate() as FireSorcerer
	_expect(
		elite != null
		and elite.projectile_source_type
			== FireSorcerer.ELITE_PROJECTILE_SOURCE_TYPE
		and elite.call("_get_fire_sorcerer_volley_profile")
			== FireSorcererVolleySimulationService.Profile.ELITE,
		"Elite profile selection must use the elite projectile source constant."
	)
	if elite != null:
		elite.free()


func _spawn_sorcerer(scene: PackedScene) -> FireSorcerer:
	var enemy := scene.instantiate() as FireSorcerer
	_runtime.add_child(enemy)
	enemy.setup(FIRE_SORCERER_CONFIG, null, null, _runtime)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	return enemy


func _get_service() -> FireSorcererVolleySimulationService:
	return (
		_runtime.get_enemy_combat_services()
		.get_fire_sorcerer_volley_simulation_service()
	)


func _find_live_handle(
	service: FireSorcererVolleySimulationService
) -> int:
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if service.is_handle_live(handle):
			return handle
	return FireSorcererVolleySimulationService.INVALID_HANDLE


func _count_retired_volley_nodes(parent: Node) -> int:
	return _collect_retired_volley_nodes(parent).size()


func _collect_retired_volley_nodes(
	parent: Node
) -> Array[FireSorcererFireballVolley]:
	var volleys: Array[FireSorcererFireballVolley] = []
	for child in parent.get_children():
		var volley := child as FireSorcererFireballVolley
		if volley != null:
			volleys.append(volley)
		volleys.append_array(_collect_retired_volley_nodes(child))
	return volleys


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("FIRE_SORCERER_DATA_BACKEND_SMOKE_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
