extends Node
class_name EnemyCombatServices

const RapidFireSimulationServiceScript := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)
const EnemyDamageableSpatialIndexScript := preload(
	"res://scene/combat/targeting/enemy_damageable_spatial_index.gd"
)
const ImmediateHitscanResolverScript := preload(
	"res://scene/combat/simulation/immediate_hitscan_resolver.gd"
)
const RapidProjectilePresenterScript := preload(
	"res://scene/combat/simulation/rapid_projectile_presenter.gd"
)
const FireSorcererVolleySimulationServiceScript := preload(
	"res://scene/combat/simulation/fire_sorcerer_volley_simulation_service.gd"
)
const FireSorcererVolleyPresenterScript := preload(
	"res://scene/combat/simulation/fire_sorcerer_volley_presenter.gd"
)
const RAPID_PROJECTILE_RESERVED_CAPACITY := 4096
const FIRE_SORCERER_VOLLEY_RESERVED_CAPACITY := 2048

## Authored service boundary owned by EnemySimulationCoordinator. These inert
## rapid-fire, hitscan, and presentation seams do not replace existing combat
## writers until their production callers are migrated explicitly.

var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _teardown_prepared := false
var _teardown_count := 0
var _metric_completion_batches := 0
var _metric_consumed_completions := 0
var _metric_network_finish_notifications := 0
var _metric_hit_presentation_requests := 0
var _metric_fire_completion_batches := 0
var _metric_fire_ball_completions := 0
var _metric_fire_terminal_completions := 0
var _metric_fire_network_finish_notifications := 0


func _init() -> void:
	set_physics_process(false)


func bind_context(
	combat_runtime: CombatRuntimeBase,
	coordinator: EnemySimulationCoordinator
) -> bool:
	if _teardown_prepared:
		return false
	if (
		combat_runtime == null
		or coordinator == null
		or not is_instance_valid(combat_runtime)
		or not is_instance_valid(coordinator)
		or get_parent() != coordinator
		or coordinator.get_parent() != combat_runtime
	):
		return false
	if (
		_combat_runtime != null
		and (
			_combat_runtime != combat_runtime
			or _enemy_simulation_coordinator != coordinator
		)
	):
		return false
	var rapid_fire_service := get_rapid_fire_simulation_service()
	var damageable_spatial_index := get_enemy_damageable_spatial_index()
	var immediate_hitscan_resolver := get_immediate_hitscan_resolver()
	var rapid_projectile_presenter := get_rapid_projectile_presenter()
	var fire_sorcerer_volley_service := (
		get_fire_sorcerer_volley_simulation_service()
	)
	var fire_sorcerer_volley_presenter := (
		get_fire_sorcerer_volley_presenter()
	)
	if (
		rapid_fire_service == null
		or damageable_spatial_index == null
		or immediate_hitscan_resolver == null
		or rapid_projectile_presenter == null
		or fire_sorcerer_volley_service == null
		or fire_sorcerer_volley_presenter == null
		or not damageable_spatial_index.bind_context(combat_runtime, coordinator)
		or not rapid_fire_service.bind_context(combat_runtime, coordinator)
		or not rapid_fire_service.reserve_projectile_capacity(
			RAPID_PROJECTILE_RESERVED_CAPACITY
		)
		or not fire_sorcerer_volley_service.bind_context(
			combat_runtime,
			coordinator,
			damageable_spatial_index
		)
		or not fire_sorcerer_volley_service.reserve_volley_capacity(
			FIRE_SORCERER_VOLLEY_RESERVED_CAPACITY
		)
		or not immediate_hitscan_resolver.bind_combat_runtime(combat_runtime)
		or not rapid_projectile_presenter.bind_service(rapid_fire_service)
		or not fire_sorcerer_volley_presenter.bind_service(
			fire_sorcerer_volley_service
		)
	):
		return false
	_combat_runtime = combat_runtime
	_enemy_simulation_coordinator = coordinator
	if not combat_runtime.cache_enemy_combat_services(self):
		_combat_runtime = null
		_enemy_simulation_coordinator = null
		return false
	set_physics_process(true)
	return true


func _physics_process(_delta: float) -> void:
	var rapid_fire_service := get_rapid_fire_simulation_service()
	var fire_sorcerer_volley_service := (
		get_fire_sorcerer_volley_simulation_service()
	)
	if rapid_fire_service == null and fire_sorcerer_volley_service == null:
		set_physics_process(false)
		return
	var gateway := (
		_combat_runtime.get_multiplayer_gameplay_gateway()
		if is_bound()
		else null
	)
	_consume_rapid_fire_completions(
		rapid_fire_service,
		gateway
	)
	_consume_fire_sorcerer_volley_completions(
		fire_sorcerer_volley_service,
		gateway
	)


func _consume_rapid_fire_completions(
	rapid_fire_service: RapidFireSimulationServiceScript,
	gateway: MultiplayerGameplayGateway
) -> void:
	if rapid_fire_service == null:
		return
	var completion_count := rapid_fire_service.get_completion_count()
	if completion_count <= 0:
		return
	_metric_completion_batches += 1
	var rapid_projectile_presenter := get_rapid_projectile_presenter()
	for completion_index in range(completion_count):
		var mode := rapid_fire_service.get_completion_mode(completion_index)
		if mode != RapidFireSimulationServiceScript.Mode.DATA:
			continue
		_metric_consumed_completions += 1
		var profile := rapid_fire_service.get_completion_profile(completion_index)
		var reason := rapid_fire_service.get_completion_reason(completion_index)
		if (
			(
				reason == RapidFireSimulationServiceScript.CompletionReason.WORLD
				or reason == RapidFireSimulationServiceScript.CompletionReason.TARGET
			)
			and
			rapid_projectile_presenter != null
			and rapid_projectile_presenter.queue_completion_hit(
				mode,
				profile,
				reason,
				rapid_fire_service.get_completion_position(completion_index),
				rapid_fire_service.get_completion_direction(completion_index)
			)
		):
			_metric_hit_presentation_requests += 1
		var projectile_id := rapid_fire_service.get_completion_projectile_id(
			completion_index
		)
		if projectile_id > 0 and gateway != null:
			var completion_position := rapid_fire_service.get_completion_position(
				completion_index
			)
			var completion_direction := rapid_fire_service.get_completion_direction(
				completion_index
			)
			gateway.notify_data_projectile_finished(
				projectile_id,
				rapid_fire_service,
				rapid_fire_service.get_completion_handle(completion_index),
				reason,
				completion_position,
				completion_direction
			)
			_metric_network_finish_notifications += 1
	if gateway != null:
		gateway.flush_enemy_rapid_fire_finish_batch()
	# Completion records are a frame-local transfer buffer. Priority 6 consumes
	# the priority-4 simulation output exactly once before the next physics tick.
	rapid_fire_service.clear_completion_records()


func _consume_fire_sorcerer_volley_completions(
	service: FireSorcererVolleySimulationServiceScript,
	gateway: MultiplayerGameplayGateway
) -> void:
	if service == null:
		return
	var ball_completion_count := service.get_completion_count()
	var terminal_completion_count := service.get_terminal_completion_count()
	if ball_completion_count <= 0 and terminal_completion_count <= 0:
		return
	_metric_fire_completion_batches += 1
	_metric_fire_ball_completions += ball_completion_count
	for terminal_index in range(terminal_completion_count):
		var mode := service.get_terminal_completion_mode(terminal_index)
		if (
			mode != FireSorcererVolleySimulationServiceScript.Mode.DATA
			and mode != FireSorcererVolleySimulationServiceScript.Mode.REPLICA
		):
			continue
		_metric_fire_terminal_completions += 1
		var projectile_id := service.get_terminal_completion_projectile_id(
			terminal_index
		)
		if projectile_id <= 0 or gateway == null:
			continue
		gateway.notify_fire_sorcerer_volley_finished(
			projectile_id,
			service,
			service.get_terminal_completion_handle(terminal_index)
		)
		_metric_fire_network_finish_notifications += 1
	# Per-ball records preserve source/contact signatures for tests and metrics;
	# the presenter reads the packed effect rows directly. The whole-volley
	# terminal is the only ownership hand-off to the multiplayer backend.
	service.clear_completion_records()


func is_bound() -> bool:
	return (
		_combat_runtime != null
		and _enemy_simulation_coordinator != null
		and is_instance_valid(_combat_runtime)
		and is_instance_valid(_enemy_simulation_coordinator)
	)


func is_bound_to(
	combat_runtime: CombatRuntimeBase,
	coordinator: EnemySimulationCoordinator
) -> bool:
	return (
		is_bound()
		and _combat_runtime == combat_runtime
		and _enemy_simulation_coordinator == coordinator
	)


func get_rapid_fire_simulation_service() -> RapidFireSimulationServiceScript:
	return get_node_or_null(
		"RapidFireSimulationService"
	) as RapidFireSimulationServiceScript


func get_enemy_damageable_spatial_index() -> EnemyDamageableSpatialIndexScript:
	return get_node_or_null(
		"EnemyDamageableSpatialIndex"
	) as EnemyDamageableSpatialIndexScript


func get_immediate_hitscan_resolver() -> ImmediateHitscanResolverScript:
	return get_node_or_null(
		"ImmediateHitscanResolver"
	) as ImmediateHitscanResolverScript


func get_rapid_projectile_presenter() -> RapidProjectilePresenterScript:
	return get_node_or_null(
		"RapidProjectilePresenter"
	) as RapidProjectilePresenterScript


func get_fire_sorcerer_volley_simulation_service() -> FireSorcererVolleySimulationServiceScript:
	return get_node_or_null(
		"FireSorcererVolleySimulationService"
	) as FireSorcererVolleySimulationServiceScript


func get_fire_sorcerer_volley_presenter() -> FireSorcererVolleyPresenterScript:
	return get_node_or_null(
		"FireSorcererVolleyPresenter"
	) as FireSorcererVolleyPresenterScript


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	set_physics_process(false)
	var fire_sorcerer_volley_presenter := (
		get_fire_sorcerer_volley_presenter()
	)
	if fire_sorcerer_volley_presenter != null:
		fire_sorcerer_volley_presenter.prepare_for_runtime_teardown()
	var rapid_projectile_presenter := get_rapid_projectile_presenter()
	if rapid_projectile_presenter != null:
		rapid_projectile_presenter.prepare_for_runtime_teardown()
	var immediate_hitscan_resolver := get_immediate_hitscan_resolver()
	if immediate_hitscan_resolver != null:
		immediate_hitscan_resolver.prepare_for_runtime_teardown()
	var fire_sorcerer_volley_service := (
		get_fire_sorcerer_volley_simulation_service()
	)
	if fire_sorcerer_volley_service != null:
		fire_sorcerer_volley_service.prepare_for_runtime_teardown()
	var rapid_fire_service := get_rapid_fire_simulation_service()
	if rapid_fire_service != null:
		rapid_fire_service.prepare_for_runtime_teardown()
	var damageable_spatial_index := get_enemy_damageable_spatial_index()
	if damageable_spatial_index != null:
		damageable_spatial_index.prepare_for_runtime_teardown()
	_combat_runtime = null
	_enemy_simulation_coordinator = null


func get_metrics() -> Dictionary:
	var rapid_fire_service := get_rapid_fire_simulation_service()
	var damageable_spatial_index := get_enemy_damageable_spatial_index()
	var immediate_hitscan_resolver := get_immediate_hitscan_resolver()
	var rapid_projectile_presenter := get_rapid_projectile_presenter()
	var fire_sorcerer_volley_service := (
		get_fire_sorcerer_volley_simulation_service()
	)
	var fire_sorcerer_volley_presenter := (
		get_fire_sorcerer_volley_presenter()
	)
	return {
		"bound": is_bound(),
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
		"completion_batches": _metric_completion_batches,
		"consumed_completions": _metric_consumed_completions,
		"network_finish_notifications": _metric_network_finish_notifications,
		"hit_presentation_requests": _metric_hit_presentation_requests,
		"fire_completion_batches": _metric_fire_completion_batches,
		"fire_ball_completions": _metric_fire_ball_completions,
		"fire_terminal_completions": _metric_fire_terminal_completions,
		"fire_network_finish_notifications": (
			_metric_fire_network_finish_notifications
		),
		"rapid_fire": (
			rapid_fire_service.get_metrics()
			if rapid_fire_service != null
			else {}
		),
		"enemy_damageable_spatial_index": (
			damageable_spatial_index.get_metrics()
			if damageable_spatial_index != null
			else {}
		),
		"immediate_hitscan_resolver": (
			immediate_hitscan_resolver.get_metrics()
			if immediate_hitscan_resolver != null
			else {}
		),
		"rapid_projectile_presenter": (
			rapid_projectile_presenter.get_metrics()
			if rapid_projectile_presenter != null
			else {}
		),
		"fire_sorcerer_volley": (
			fire_sorcerer_volley_service.get_metrics()
			if fire_sorcerer_volley_service != null
			else {}
		),
		"fire_sorcerer_volley_presenter": (
			fire_sorcerer_volley_presenter.get_metrics()
			if fire_sorcerer_volley_presenter != null
			else {}
		),
	}


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
