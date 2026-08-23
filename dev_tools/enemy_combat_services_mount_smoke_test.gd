extends SceneTree

const COORDINATOR_SCENE_PATH := (
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)
const CONTACT_SERVICE_SCENE_PATH := (
	"res://scene/combat/contact/enemy_contact_service.tscn"
)
const COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)
const COORDINATOR_SCRIPT := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.gd"
)
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
const CapooRPGRocketSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)
const CapooMageFireballSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_mage_fireball_simulation_service.gd"
)
const CapooMageFireballPresenterScript := preload(
	"res://scene/combat/presentation/capoo_mage_fireball_presenter.gd"
)
const FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const AUTHORED_RUNTIME_SCENE_PATHS := [
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn",
	"res://scene/game_modes/standard/standard_game.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_03.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_04.tscn",
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_all_runtime_scenes_mount_the_shared_coordinator()
	_test_authored_coordinator_service_tree_defaults_to_idle()
	_test_direct_coordinator_without_authored_child_is_safe()
	await _test_fixture_binding_and_idempotent_teardown()
	_finish()


func _test_all_runtime_scenes_mount_the_shared_coordinator() -> void:
	for scene_path in AUTHORED_RUNTIME_SCENE_PATHS:
		_expect(
			FileAccess.file_exists(scene_path),
			"Unable to find authored runtime: %s" % scene_path
		)
		if not FileAccess.file_exists(scene_path):
			continue
		var scene_source := FileAccess.get_file_as_string(scene_path)
		var coordinator_count := scene_source.count(
			'[node name="EnemySimulationCoordinator"'
		)
		_expect(
			coordinator_count == 1,
			"Runtime must author exactly one EnemySimulationCoordinator: %s"
			% scene_path
		)
		_expect(
			scene_source.contains(COORDINATOR_SCENE_PATH),
			"Runtime must instance the shared coordinator PackedScene: %s"
			% scene_path
		)
		_expect(
			scene_source.count(
				'[node name="EnemyContactService" parent="."'
			) == 1
			and scene_source.contains(CONTACT_SERVICE_SCENE_PATH),
			(
				"Runtime must retain exactly one root EnemyContactService beside the "
				+ "coordinator: %s" % scene_path
			)
		)
		if not scene_path.begins_with("res://dev_tools/"):
			_expect(
				scene_source.count('[node name="CapooProjectileMotionSystem"') == 0
				and not scene_source.contains(
					"res://scene/enemy/capoo/capoo_projectile_motion_system.tscn"
				),
				"Production runtime must not mount the retired Capoo motion system: %s"
				% scene_path
			)


func _test_authored_coordinator_service_tree_defaults_to_idle() -> void:
	var coordinator := COORDINATOR_SCENE.instantiate() as EnemySimulationCoordinator
	_expect(coordinator != null, "The authored coordinator scene must instantiate.")
	if coordinator == null:
		return
	var combat_services := coordinator.get_combat_services()
	_expect(
		combat_services != null,
		"The authored coordinator must contain EnemyCombatServices."
	)
	if combat_services != null:
		_expect(
			combat_services.process_physics_priority == 6,
			"EnemyCombatServices must consume priority-4 completions at authored priority 6."
		)
		var rapid_fire_service := (
			combat_services.get_rapid_fire_simulation_service()
		)
		var damageable_spatial_index: EnemyDamageableSpatialIndexScript = (
			combat_services.get_enemy_damageable_spatial_index()
		)
		var immediate_hitscan_resolver: ImmediateHitscanResolverScript = (
			combat_services.get_immediate_hitscan_resolver()
		)
		var rapid_projectile_presenter: RapidProjectilePresenterScript = (
			combat_services.get_rapid_projectile_presenter()
		)
		var fire_sorcerer_volley_service: FireSorcererVolleySimulationServiceScript = (
			combat_services.get_fire_sorcerer_volley_simulation_service()
		)
		var fire_sorcerer_volley_presenter: FireSorcererVolleyPresenterScript = (
			combat_services.get_fire_sorcerer_volley_presenter()
		)
		var rpg_rocket_service: CapooRPGRocketSimulationServiceScript = (
			combat_services.get_capoo_rpg_rocket_simulation_service()
		)
		var explosion_resolution := combat_services.get_explosion_resolution_service()
		var rpg_presenter := combat_services.get_capoo_rpg_rocket_presenter()
		var explosion_presentation := (
			combat_services.get_explosion_presentation_service()
		)
		var mage_fireball_service: CapooMageFireballSimulationServiceScript = (
			combat_services.get_capoo_mage_fireball_simulation_service()
		)
		var mage_fireball_presenter: CapooMageFireballPresenterScript = (
			combat_services.get_capoo_mage_fireball_presenter()
		)
		_expect(
			rapid_fire_service != null,
			"EnemyCombatServices must author RapidFireSimulationService."
		)
		if rapid_fire_service != null:
			var metrics := rapid_fire_service.get_metrics()
			_expect(
				StringName(metrics["profile"])
				== RapidFireSimulationServiceScript.PROFILE_AK,
				"The first rapid-fire profile must be AK."
			)
			_expect(
				int(metrics["mode"])
				== RapidFireSimulationServiceScript.Mode.DISABLED,
				"The authored rapid-fire service must default to DISABLED."
			)
			_expect(
				int(metrics["active_slots"]) == 0,
				"The authored rapid-fire service must start with zero slots."
			)
			_expect(
				not rapid_fire_service.is_physics_processing(),
				"The authored rapid-fire service must start physics-disabled."
			)
		_expect(
			damageable_spatial_index != null,
			"EnemyCombatServices must author EnemyDamageableSpatialIndex."
		)
		if damageable_spatial_index != null:
			var index_metrics := damageable_spatial_index.get_metrics()
			_expect(
				int(index_metrics["registered_count"]) == 0
				and int(index_metrics["membership_count"]) == 0,
				"The authored damageable index must start empty."
			)
		_expect(
			immediate_hitscan_resolver != null,
			"EnemyCombatServices must author ImmediateHitscanResolver."
		)
		if immediate_hitscan_resolver != null:
			var hitscan_metrics := immediate_hitscan_resolver.get_metrics()
			_expect(
				not bool(hitscan_metrics["bound"])
				and int(hitscan_metrics["resolution_count"]) == 0
				and int(hitscan_metrics["query_count"]) == 0
				and not immediate_hitscan_resolver.is_physics_processing(),
				"The authored hitscan resolver must start unbound and idle."
			)
		_expect(
			rapid_projectile_presenter != null,
			"EnemyCombatServices must author RapidProjectilePresenter."
		)
		if rapid_projectile_presenter != null:
			var presenter_metrics := rapid_projectile_presenter.get_metrics()
			_expect(
				int(presenter_metrics["fixed_capacity"])
				== RapidProjectilePresenterScript.FIXED_INSTANCE_CAPACITY
				and int(presenter_metrics["allocated_instances"]) == 0
				and int(presenter_metrics["visible_instances"]) == 0
				and int(presenter_metrics["sync_executions"]) == 0
				and not rapid_projectile_presenter.is_physics_processing(),
				"The authored presenter must start unallocated and idle."
			)
		_expect(
			fire_sorcerer_volley_service != null,
			"EnemyCombatServices must author FireSorcererVolleySimulationService."
		)
		if fire_sorcerer_volley_service != null:
			var volley_metrics := fire_sorcerer_volley_service.get_metrics()
			_expect(
				int(volley_metrics["dense_records"]) == 0
				and int(volley_metrics["active_slots"]) == 0
				and not bool(volley_metrics["bound"])
				and not fire_sorcerer_volley_service.is_physics_processing(),
				"The authored fire-sorcerer volley service must start empty and idle."
			)
		_expect(
			fire_sorcerer_volley_presenter != null,
			"EnemyCombatServices must author FireSorcererVolleyPresenter."
		)
		if fire_sorcerer_volley_presenter != null:
			var volley_presenter_metrics := (
				fire_sorcerer_volley_presenter.get_metrics()
			)
			_expect(
				int(volley_presenter_metrics["fixed_capacity_per_family"])
				== FireSorcererVolleyPresenterScript.FIXED_INSTANCE_CAPACITY
				and int(volley_presenter_metrics["allocated_normal_instances"]) == 0
				and int(volley_presenter_metrics["allocated_elite_instances"]) == 0
				and int(volley_presenter_metrics["last_visible_count"]) == 0
				and not fire_sorcerer_volley_presenter.is_processing(),
				"The authored fire-sorcerer volley presenter must start unallocated and idle."
			)
		_expect(
			rpg_rocket_service != null
			and explosion_resolution != null
			and rpg_presenter != null
			and explosion_presentation != null,
			"EnemyCombatServices must statically author all four RPG runtime services."
		)
		if rpg_rocket_service != null:
			var rpg_metrics := rpg_rocket_service.get_metrics()
			_expect(
				int(rpg_metrics["live_count"]) == 0
				and not bool(rpg_metrics["bound"])
				and not rpg_rocket_service.is_physics_processing(),
				"The authored RPG data kernel must start empty and idle."
			)
		_expect(
			mage_fireball_service != null
			and mage_fireball_presenter != null,
			"EnemyCombatServices must statically author Mage simulation and presentation."
		)
		if mage_fireball_service != null:
			var mage_metrics := mage_fireball_service.get_metrics()
			_expect(
				int(mage_metrics["live_count"]) == 0
				and not bool(mage_metrics["bound"])
				and not mage_fireball_service.is_physics_processing(),
				"The authored Mage data kernel must start empty and idle."
			)
	coordinator.free()


func _test_direct_coordinator_without_authored_child_is_safe() -> void:
	var coordinator := COORDINATOR_SCRIPT.new() as EnemySimulationCoordinator
	_expect(coordinator != null, "A direct coordinator instance must be valid.")
	if coordinator == null:
		return
	coordinator._ready()
	_expect(
		coordinator.get_combat_services() == null,
		"A direct coordinator instance must tolerate the optional child being absent."
	)
	coordinator.prepare_combat_services_for_runtime_teardown()
	coordinator.prepare_combat_services_for_runtime_teardown()
	_expect(
		not coordinator.is_physics_processing(),
		"A childless direct coordinator must remain physics-idle."
	)
	coordinator.free()


func _test_fixture_binding_and_idempotent_teardown() -> void:
	var runtime := FIXTURE_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "The gateway fixture must instantiate.")
	if runtime == null:
		return
	root.add_child(runtime)
	await process_frame

	var coordinator := runtime.get_enemy_simulation_coordinator()
	var combat_services := runtime.get_enemy_combat_services()
	var contact_service := runtime.get_enemy_contact_service()
	_expect(coordinator != null, "The gateway fixture must expose its coordinator.")
	_expect(
		combat_services != null,
		"The gateway fixture must expose bound enemy combat services."
	)
	_expect(
		contact_service != null
		and contact_service.get_parent() == runtime
		and (
			combat_services == null
			or combat_services.get_node_or_null("EnemyContactService") == null
		),
		(
			"EnemyContactService must remain a distinct runtime-root service, not a "
			+ "child of EnemyCombatServices."
		)
	)
	if coordinator != null and combat_services != null:
		var rapid_fire_service := (
			combat_services.get_rapid_fire_simulation_service()
		)
		var damageable_spatial_index: EnemyDamageableSpatialIndexScript = (
			combat_services.get_enemy_damageable_spatial_index()
		)
		var immediate_hitscan_resolver: ImmediateHitscanResolverScript = (
			combat_services.get_immediate_hitscan_resolver()
		)
		var rapid_projectile_presenter: RapidProjectilePresenterScript = (
			combat_services.get_rapid_projectile_presenter()
		)
		var fire_sorcerer_volley_service: FireSorcererVolleySimulationServiceScript = (
			combat_services.get_fire_sorcerer_volley_simulation_service()
		)
		var fire_sorcerer_volley_presenter: FireSorcererVolleyPresenterScript = (
			combat_services.get_fire_sorcerer_volley_presenter()
		)
		var rpg_rocket_service: CapooRPGRocketSimulationServiceScript = (
			combat_services.get_capoo_rpg_rocket_simulation_service()
		)
		var explosion_resolution := combat_services.get_explosion_resolution_service()
		var rpg_presenter := combat_services.get_capoo_rpg_rocket_presenter()
		var explosion_presentation := (
			combat_services.get_explosion_presentation_service()
		)
		var mage_fireball_service: CapooMageFireballSimulationServiceScript = (
			combat_services.get_capoo_mage_fireball_simulation_service()
		)
		var mage_fireball_presenter: CapooMageFireballPresenterScript = (
			combat_services.get_capoo_mage_fireball_presenter()
		)
		_expect(
			combat_services.is_bound_to(runtime, coordinator),
			"EnemyCombatServices must bind to its authored runtime and coordinator."
		)
		_expect(
			runtime.get_enemy_combat_services() == combat_services
			and combat_services.is_physics_processing(),
			"CombatRuntimeBase must cache the bound typed services and enable its completion consumer."
		)
		_expect(
			rapid_fire_service != null
			and rapid_fire_service.is_bound_to(runtime, coordinator)
			and rapid_fire_service.get_reserved_capacity()
			>= combat_services.RAPID_PROJECTILE_RESERVED_CAPACITY,
			"Rapid-fire binding must follow the damageable index and reserve 4096 records."
		)
		_expect(
			damageable_spatial_index != null
			and damageable_spatial_index.is_bound_to(runtime, coordinator),
			"EnemyDamageableSpatialIndex must inherit the same bound context."
		)
		_expect(
			immediate_hitscan_resolver != null
			and immediate_hitscan_resolver.is_bound_to(runtime),
			"ImmediateHitscanResolver must bind to the same combat runtime."
		)
		_expect(
			rapid_projectile_presenter != null
			and rapid_projectile_presenter.is_bound_to(rapid_fire_service),
			"The bound service tree must bind RapidProjectilePresenter to the data kernel."
		)
		_expect(
			fire_sorcerer_volley_service != null
			and fire_sorcerer_volley_service.is_bound()
			and fire_sorcerer_volley_service.get_reserved_capacity()
			>= combat_services.FIRE_SORCERER_VOLLEY_RESERVED_CAPACITY,
			"Fire-sorcerer volley binding must share the damageable index and reserve 2048 volleys."
		)
		_expect(
			fire_sorcerer_volley_presenter != null
			and fire_sorcerer_volley_presenter.is_bound_to(
				fire_sorcerer_volley_service
			),
			"The bound service tree must bind FireSorcererVolleyPresenter to its data kernel."
		)
		_expect(
			rpg_rocket_service != null
			and rpg_rocket_service.is_bound()
			and int(rpg_rocket_service.get_metrics()["reserved_capacity"])
				>= combat_services.CAPOO_RPG_ROCKET_RESERVED_CAPACITY,
			"The RPG data kernel must bind and reserve its fixed shared capacity."
		)
		_expect(
			explosion_resolution != null
			and explosion_resolution.is_bound_to(runtime, coordinator)
			and rpg_presenter != null
			and rpg_presenter.is_bound()
			and explosion_presentation != null
			and explosion_presentation.is_bound(),
			"RPG resolution and both presentation systems must share the authored runtime context."
		)
		_expect(
			mage_fireball_service != null
			and mage_fireball_service.is_bound()
			and mage_fireball_service.get_reserved_capacity()
				>= combat_services.CAPOO_MAGE_FIREBALL_RESERVED_CAPACITY
			and mage_fireball_presenter != null
			and mage_fireball_presenter.is_bound(),
			"Mage simulation and presenter must bind with 2048 reserved records."
		)
		if rapid_projectile_presenter != null:
			var mounted_presenter_metrics := rapid_projectile_presenter.get_metrics()
			_expect(
				bool(mounted_presenter_metrics["headless_disabled"])
				and int(mounted_presenter_metrics["allocated_instances"]) == 0
				and int(mounted_presenter_metrics["visible_instances"]) == 0
				and int(mounted_presenter_metrics["sync_executions"]) == 0
				and int(mounted_presenter_metrics["last_scanned_count"]) == 0,
				"A mounted headless presenter must allocate, scan, and upload nothing."
			)
		if fire_sorcerer_volley_presenter != null:
			var mounted_volley_presenter_metrics := (
				fire_sorcerer_volley_presenter.get_metrics()
			)
			_expect(
				bool(mounted_volley_presenter_metrics["headless_disabled"])
				and int(mounted_volley_presenter_metrics["allocated_normal_instances"]) == 0
				and int(mounted_volley_presenter_metrics["allocated_elite_instances"]) == 0
				and int(mounted_volley_presenter_metrics["visible_normal_instances"]) == 0
				and int(mounted_volley_presenter_metrics["visible_elite_instances"]) == 0
				and int(mounted_volley_presenter_metrics["sync_executions"]) == 0
				and int(mounted_volley_presenter_metrics["render_sync_executions"]) == 0
				and int(mounted_volley_presenter_metrics["last_scanned_record_count"]) == 0,
				"A mounted headless fire-sorcerer volley presenter must allocate, scan, and upload nothing."
			)
		if mage_fireball_presenter != null:
			var mounted_mage_presenter_metrics := mage_fireball_presenter.get_metrics()
			_expect(
				bool(mounted_mage_presenter_metrics["headless_disabled"])
				and int(mounted_mage_presenter_metrics["allocated_base_instances"]) == 0
				and int(mounted_mage_presenter_metrics["allocated_emission_instances"]) == 0
				and int(mounted_mage_presenter_metrics["allocated_halo_instances"]) == 0
				and int(mounted_mage_presenter_metrics["visible_fireballs"]) == 0,
				"A mounted headless Mage presenter must allocate and upload nothing."
			)
		if damageable_spatial_index != null:
			var initial_index_metrics := damageable_spatial_index.get_metrics()
			_expect(
				int(initial_index_metrics["registered_count"]) == 0,
				"A non-tower runtime must keep the damageable index empty."
			)
		if mage_fireball_service != null:
			var source_snapshot := DamageSourceSnapshot.create(
				CombatRelationService.HOSTILE_WAVE,
				0,
				731,
				0,
				CapooMageFireballSimulationServiceScript.SOURCE_TYPE
			)
			var data_handle := mage_fireball_service.spawn_authoritative(
				Vector2(80_000.0, 80_000.0),
				Vector2.RIGHT,
				1,
				1.0,
				0.01,
				CapooMageFireballSimulationServiceScript.DEFAULT_RADIUS,
				null,
				0.0,
				source_snapshot
			)
			var replica_handle := mage_fireball_service.spawn_replica(
				771,
				Vector2(80_000.0, 80_010.0),
				Vector2.RIGHT,
				1.0,
				0.01,
				CapooMageFireballSimulationServiceScript.DEFAULT_RADIUS,
				null,
				0.0,
				0.0
			)
			_expect(
				data_handle > 0 and replica_handle > 0,
				"Mounted Mage service must accept DATA and REPLICA records."
			)
			for _completion_frame in range(3):
				await physics_frame
			var completion_metrics := combat_services.get_metrics()
			var completed_mage_metrics := (
				completion_metrics["capoo_mage_fireball_simulation"]
				as Dictionary
			)
			var completed_impact_metrics := (
				completion_metrics["explosion_presentation"] as Dictionary
			)
			var completed_resolution_metrics := (
				completion_metrics["explosion_resolution"] as Dictionary
			)
			_expect(
				int(completion_metrics["mage_completion_batches"]) == 1
				and int(completion_metrics["mage_completions"]) == 2
				and int(completion_metrics["mage_presentation_requests"]) == 2
				and int(completed_resolution_metrics["resolution_count"]) == 1
				and int(completed_mage_metrics["live_count"]) == 0
				and int(completed_mage_metrics["pending_completions"]) == 0
				and int(completed_impact_metrics["queue_requests"]) == 2,
				"EnemyCombatServices must resolve only DATA while consuming DATA/REPLICA Mage completions and queueing both impacts in the same frame."
			)
		runtime.prepare_for_scene_teardown()
		runtime.prepare_for_scene_teardown()
		var service_metrics := combat_services.get_metrics()
		var rapid_fire_metrics: Dictionary = service_metrics["rapid_fire"]
		var damageable_index_metrics: Dictionary = (
			service_metrics["enemy_damageable_spatial_index"]
		)
		var hitscan_metrics: Dictionary = (
			service_metrics["immediate_hitscan_resolver"]
		)
		var presenter_metrics: Dictionary = (
			service_metrics["rapid_projectile_presenter"]
		)
		var volley_metrics: Dictionary = service_metrics["fire_sorcerer_volley"]
		var volley_presenter_metrics: Dictionary = (
			service_metrics["fire_sorcerer_volley_presenter"]
		)
		var rpg_metrics: Dictionary = service_metrics["capoo_rpg_rocket_simulation"]
		var explosion_resolution_metrics: Dictionary = (
			service_metrics["explosion_resolution"]
		)
		var rpg_presenter_metrics: Dictionary = (
			service_metrics["capoo_rpg_rocket_presenter"]
		)
		var explosion_presentation_metrics: Dictionary = (
			service_metrics["explosion_presentation"]
		)
		var mage_metrics: Dictionary = (
			service_metrics["capoo_mage_fireball_simulation"]
		)
		var mage_presenter_metrics: Dictionary = (
			service_metrics["capoo_mage_fireball_presenter"]
		)
		_expect(
			int(service_metrics["teardown_count"]) == 1,
			"EnemyCombatServices teardown must be idempotent."
		)
		_expect(
			int(rapid_fire_metrics["teardown_count"]) == 1,
			"RapidFireSimulationService teardown must be idempotent."
		)
		_expect(
			int(damageable_index_metrics["teardown_count"]) == 1,
			"EnemyDamageableSpatialIndex teardown must be idempotent."
		)
		_expect(
			int(hitscan_metrics["teardown_count"]) == 1,
			"ImmediateHitscanResolver teardown must be idempotent."
		)
		_expect(
			int(presenter_metrics["teardown_count"]) == 1,
			"RapidProjectilePresenter teardown must be idempotent."
		)
		_expect(
			int(volley_metrics["teardown_count"]) == 1,
			"FireSorcererVolleySimulationService teardown must be idempotent."
		)
		_expect(
			int(volley_presenter_metrics["teardown_count"]) == 1,
			"FireSorcererVolleyPresenter teardown must be idempotent."
		)
		_expect(
			int(rpg_metrics["teardowns"]) == 1
			and int(rpg_metrics["live_count"]) == 0
			and int(explosion_resolution_metrics["teardown_count"]) == 1
			and int(rpg_presenter_metrics["teardown_count"]) == 1
			and int(explosion_presentation_metrics["teardown_count"]) == 1,
			"All RPG shared services must teardown exactly once with no live handles."
		)
		_expect(
			int(mage_metrics["teardowns"]) == 1
			and int(mage_metrics["live_count"]) == 0
			and int(mage_metrics["pending_completions"]) == 0
			and int(mage_presenter_metrics["teardown_count"]) == 1
			and int(mage_presenter_metrics["visible_fireballs"]) == 0,
			"Mage shared simulation and presenter must teardown once with no live handles."
		)
		_expect(
			not bool(service_metrics["bound"])
			and not bool(rapid_fire_metrics["bound"])
			and not bool(damageable_index_metrics["bound"])
			and not bool(hitscan_metrics["bound"])
			and not bool(volley_metrics["bound"])
			and not bool(volley_presenter_metrics["bound"]),
			"Teardown must release all runtime and coordinator references."
		)
		_expect(
			int(damageable_index_metrics["registered_count"]) == 0
			and int(damageable_index_metrics["membership_count"]) == 0,
			"Teardown must leave the damageable index structurally empty."
		)
		_expect(
			int(rapid_fire_metrics["active_slots"]) == 0
			and not bool(rapid_fire_metrics["physics_processing"]),
			"Teardown must leave zero rapid-fire slots and physics disabled."
		)
		_expect(
			int(presenter_metrics["allocated_instances"]) == 0
			and int(presenter_metrics["visible_instances"]) == 0
			and int(presenter_metrics["sync_executions"]) == 0
			and int(presenter_metrics["last_scanned_count"]) == 0,
			"Teardown must retain the headless presenter's zero-work state."
		)
		_expect(
			int(volley_metrics["dense_records"]) == 0
			and int(volley_metrics["active_slots"]) == 0
			and int(volley_metrics["tombstones"]) == 0
			and int(volley_metrics["completion_records"]) == 0
			and int(volley_metrics["terminal_records"]) == 0
			and not bool(volley_metrics["physics_processing"]),
			"Teardown must leave zero live fire-sorcerer volleys and physics disabled."
		)
		_expect(
			int(volley_presenter_metrics["allocated_normal_instances"]) == 0
			and int(volley_presenter_metrics["allocated_elite_instances"]) == 0
			and int(volley_presenter_metrics["visible_normal_instances"]) == 0
			and int(volley_presenter_metrics["visible_elite_instances"]) == 0
			and int(volley_presenter_metrics["last_visible_count"]) == 0,
			"Teardown must leave the fire-sorcerer volley presenter with zero live instances."
		)
		_expect(
			contact_service != null
			and runtime.get_enemy_contact_service() == contact_service
			and contact_service.get_parent() == runtime,
			"Combat-service teardown must not consume the distinct contact service."
		)
		_expect(
			runtime.get_enemy_combat_services() == null,
			"Runtime getter must not rebind or expose services after teardown."
		)
		_expect(
			not combat_services.bind_context(runtime, coordinator),
			"EnemyCombatServices must reject explicit rebind after teardown."
		)
		if rapid_fire_service != null:
			_expect(
				not rapid_fire_service.bind_context(runtime, coordinator),
				"RapidFireSimulationService must reject rebind after teardown."
			)
		if damageable_spatial_index != null:
			_expect(
				not damageable_spatial_index.bind_context(runtime, coordinator),
				"EnemyDamageableSpatialIndex must reject rebind after teardown."
			)
		if immediate_hitscan_resolver != null:
			_expect(
				not immediate_hitscan_resolver.bind_combat_runtime(runtime),
				"ImmediateHitscanResolver must reject rebind after teardown."
			)
		if fire_sorcerer_volley_service != null:
			_expect(
				not fire_sorcerer_volley_service.bind_context(
					runtime,
					coordinator,
					damageable_spatial_index
				),
				"FireSorcererVolleySimulationService must reject rebind after teardown."
			)
		if fire_sorcerer_volley_presenter != null:
			_expect(
				not fire_sorcerer_volley_presenter.bind_service(
					fire_sorcerer_volley_service
				),
				"FireSorcererVolleyPresenter must reject rebind after teardown."
			)
		if mage_fireball_service != null:
			_expect(
				not mage_fireball_service.bind_context(runtime, coordinator),
				"Mage simulation service must reject rebind after teardown."
			)
		if mage_fireball_presenter != null:
			_expect(
				not mage_fireball_presenter.bind_simulation_service(
					mage_fireball_service
				),
				"Mage presenter must reject rebind after teardown."
			)

	runtime.queue_free()
	await process_frame
	await physics_frame


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("ENEMY_COMBAT_SERVICES_MOUNT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_COMBAT_SERVICES_MOUNT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
