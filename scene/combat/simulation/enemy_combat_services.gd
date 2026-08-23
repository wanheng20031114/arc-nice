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
const EnemyWarningPresentationSystemScript := preload(
	"res://scene/combat/presentation/enemy_warning_presentation_system.gd"
)
const CapooRPGRocketSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)
const ExplosionResolutionServiceScript := preload(
	"res://scene/combat/simulation/explosion_resolution_service.gd"
)
const CapooRPGRocketPresenterScript := preload(
	"res://scene/combat/presentation/capoo_rpg_rocket_presenter.gd"
)
const ExplosionPresentationServiceScript := preload(
	"res://scene/combat/presentation/explosion_presentation_service.gd"
)
const RAPID_PROJECTILE_RESERVED_CAPACITY := 4096
const FIRE_SORCERER_VOLLEY_RESERVED_CAPACITY := 2048
const CAPOO_RPG_ROCKET_RESERVED_CAPACITY := 2048

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
var _metric_rpg_completion_batches := 0
var _metric_rpg_completions := 0
var _metric_rpg_damage_accepts := 0
var _metric_rpg_presentation_requests := 0
var _metric_rpg_backend_finish_notifications := 0


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
	var warning_presentation_system := get_enemy_warning_presentation_system()
	var rpg_rocket_service := get_capoo_rpg_rocket_simulation_service()
	var explosion_resolution_service := get_explosion_resolution_service()
	var rpg_rocket_presenter := get_capoo_rpg_rocket_presenter()
	var explosion_presentation_service := get_explosion_presentation_service()
	if (
		rapid_fire_service == null
		or damageable_spatial_index == null
		or immediate_hitscan_resolver == null
		or rapid_projectile_presenter == null
		or fire_sorcerer_volley_service == null
		or fire_sorcerer_volley_presenter == null
		or warning_presentation_system == null
		or rpg_rocket_service == null
		or explosion_resolution_service == null
		or rpg_rocket_presenter == null
		or explosion_presentation_service == null
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
		or not warning_presentation_system.bind_context(
			combat_runtime,
			coordinator
		)
		or not rpg_rocket_service.bind_context(combat_runtime, coordinator)
		or not rpg_rocket_service.reserve(CAPOO_RPG_ROCKET_RESERVED_CAPACITY)
		or not explosion_resolution_service.bind_context(
			combat_runtime,
			coordinator
		)
		or not rpg_rocket_presenter.bind_simulation_service(rpg_rocket_service)
		or not explosion_presentation_service.bind_context(
			combat_runtime,
			coordinator
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


func _physics_process(delta: float) -> void:
	var rapid_fire_service := get_rapid_fire_simulation_service()
	var fire_sorcerer_volley_service := (
		get_fire_sorcerer_volley_simulation_service()
	)
	var rpg_rocket_service := get_capoo_rpg_rocket_simulation_service()
	if (
		rapid_fire_service == null
		and fire_sorcerer_volley_service == null
		and rpg_rocket_service == null
	):
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
	_consume_capoo_rpg_rocket_completions(rpg_rocket_service, gateway)
	var rpg_rocket_presenter := get_capoo_rpg_rocket_presenter()
	if rpg_rocket_presenter != null:
		rpg_rocket_presenter.flush_presenter()
	var explosion_presentation_service := get_explosion_presentation_service()
	if explosion_presentation_service != null:
		explosion_presentation_service.flush_presenter(delta)
	var warning_presentation_system := get_enemy_warning_presentation_system()
	if warning_presentation_system != null:
		warning_presentation_system.flush_presenter()


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


func _consume_capoo_rpg_rocket_completions(
	service: CapooRPGRocketSimulationServiceScript,
	gateway: MultiplayerGameplayGateway
) -> void:
	if service == null:
		return
	var completion_count := service.get_completion_count()
	if completion_count <= 0:
		return
	_metric_rpg_completion_batches += 1
	var resolver := get_explosion_resolution_service()
	var presentation := get_explosion_presentation_service()
	for completion_index in range(completion_count):
		_metric_rpg_completions += 1
		var mode := service.get_completion_mode(completion_index)
		var snapshot := service.get_completion_damage_source_snapshot(
			completion_index
		)
		var source_enemy_id := (
			snapshot.instigator_entity_id if snapshot != null else 0
		)
		var source_type := (
			snapshot.source_type
			if snapshot != null and snapshot.source_type != &""
			else &"capoo_rpg_rocket"
		)
		if (
			mode == CapooRPGRocketSimulationServiceScript.Mode.DATA
			and resolver != null
		):
			_metric_rpg_damage_accepts += resolver.resolve_hostile_explosion(
				service.get_completion_position(completion_index),
				service.get_completion_radius(completion_index),
				service.get_completion_damage(completion_index),
				service.get_completion_direct_hit(completion_index),
				snapshot,
				source_enemy_id,
				service.get_completion_projectile_id(completion_index),
				source_type,
				EnemyConfig.DamageType.PHYSICAL
			)
		if (
			presentation != null
			and presentation.queue_explosion(
				ExplosionPresentationServiceScript.Profile.CAPOO_RPG,
				service.get_completion_position(completion_index)
			)
		):
			_metric_rpg_presentation_requests += 1
		var projectile_id := service.get_completion_projectile_id(
			completion_index
		)
		if projectile_id > 0 and gateway != null:
			gateway.notify_capoo_rpg_data_finished(
				projectile_id,
				service,
				service.get_completion_handle(completion_index)
			)
			_metric_rpg_backend_finish_notifications += 1
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


func get_enemy_warning_presentation_system() -> EnemyWarningPresentationSystemScript:
	return get_node_or_null(
		"EnemyWarningPresentationSystem"
	) as EnemyWarningPresentationSystemScript


func get_capoo_rpg_rocket_simulation_service() -> CapooRPGRocketSimulationServiceScript:
	return get_node_or_null(
		"CapooRPGRocketSimulationService"
	) as CapooRPGRocketSimulationServiceScript


func get_explosion_resolution_service() -> ExplosionResolutionServiceScript:
	return get_node_or_null(
		"ExplosionResolutionService"
	) as ExplosionResolutionServiceScript


func get_capoo_rpg_rocket_presenter() -> CapooRPGRocketPresenterScript:
	return get_node_or_null(
		"CapooRPGRocketPresenter"
	) as CapooRPGRocketPresenterScript


func get_explosion_presentation_service() -> ExplosionPresentationServiceScript:
	return get_node_or_null(
		"ExplosionPresentationService"
	) as ExplosionPresentationServiceScript


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	set_physics_process(false)
	var explosion_presentation_service := get_explosion_presentation_service()
	if explosion_presentation_service != null:
		explosion_presentation_service.prepare_for_runtime_teardown()
	var rpg_rocket_presenter := get_capoo_rpg_rocket_presenter()
	if rpg_rocket_presenter != null:
		rpg_rocket_presenter.prepare_for_runtime_teardown()
	var warning_presentation_system := get_enemy_warning_presentation_system()
	if warning_presentation_system != null:
		warning_presentation_system.prepare_for_runtime_teardown()
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
	var rpg_rocket_service := get_capoo_rpg_rocket_simulation_service()
	if rpg_rocket_service != null:
		rpg_rocket_service.teardown()
	var explosion_resolution_service := get_explosion_resolution_service()
	if explosion_resolution_service != null:
		explosion_resolution_service.prepare_for_runtime_teardown()
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
	var warning_presentation_system := get_enemy_warning_presentation_system()
	var rpg_rocket_service := get_capoo_rpg_rocket_simulation_service()
	var explosion_resolution_service := get_explosion_resolution_service()
	var rpg_rocket_presenter := get_capoo_rpg_rocket_presenter()
	var explosion_presentation_service := get_explosion_presentation_service()
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
		"rpg_completion_batches": _metric_rpg_completion_batches,
		"rpg_completions": _metric_rpg_completions,
		"rpg_damage_accepts": _metric_rpg_damage_accepts,
		"rpg_presentation_requests": _metric_rpg_presentation_requests,
		"rpg_backend_finish_notifications": (
			_metric_rpg_backend_finish_notifications
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
		"enemy_warning_presentation_system": (
			warning_presentation_system.get_metrics()
			if warning_presentation_system != null
			else {}
		),
		"capoo_rpg_rocket_simulation": (
			rpg_rocket_service.get_metrics()
			if rpg_rocket_service != null
			else {}
		),
		"explosion_resolution": (
			explosion_resolution_service.get_metrics()
			if explosion_resolution_service != null
			else {}
		),
		"capoo_rpg_rocket_presenter": (
			rpg_rocket_presenter.get_metrics()
			if rpg_rocket_presenter != null
			else {}
		),
		"explosion_presentation": (
			explosion_presentation_service.get_metrics()
			if explosion_presentation_service != null
			else {}
		),
	}


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
