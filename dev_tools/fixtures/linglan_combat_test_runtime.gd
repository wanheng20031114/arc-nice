extends CombatRuntimeBase
class_name LinglanCombatTestRuntime

## Focused Linglan fixture that exercises the same explicit runtime, gateway,
## and mode-port boundaries as production. Individual smoke-test hosts inherit
## this runtime and override only the behavior they need to record.

const CAPOO_PROJECTILE_MOTION_SYSTEM_SCENE := preload(
	"res://scene/enemy/capoo/capoo_projectile_motion_system.tscn"
)
const COMBAT_ROBOT_DRONE_MOTION_SYSTEM_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_drone_motion_system.tscn"
)
const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)


class LinglanTestGameplayGateway:
	extends MultiplayerGameplayGateway

	func register_local_projectile(
		projectile: Node,
		projectile_type: StringName,
		owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		speed: float,
		lifetime: float,
		pierces_enemies: bool = false,
		target_peer_id: int = 0,
		target_enemy_net_id: int = 0
	) -> void:
		var test_runtime := runtime as LinglanCombatTestRuntime
		if test_runtime == null:
			return
		test_runtime.register_local_projectile(
			projectile,
			projectile_type,
			owner_peer_id,
			spawn_position,
			direction,
			damage,
			speed,
			lifetime,
			pierces_enemies,
			target_peer_id,
			target_enemy_net_id
		)

	func register_local_linglan_skill1_ring(
		projectiles: Array[Node],
		spawn_positions: PackedVector2Array,
		directions: PackedVector2Array,
		owner_peer_id: int,
		damage: int,
		speed: float,
		lifetime: float
	) -> void:
		var test_runtime := runtime as LinglanCombatTestRuntime
		if test_runtime != null:
			test_runtime.register_local_linglan_skill1_ring(
				projectiles,
				spawn_positions,
				directions,
				owner_peer_id,
				damage,
				speed,
				lifetime
			)

	func request_player_damage(
		source_id: int,
		target_peer_id: int,
		damage: int,
		source_type: StringName,
		damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		source_direction: Vector2 = Vector2.ZERO,
		is_ranged: bool = false,
		contact_preconsumed: bool = false
	) -> bool:
		var test_runtime := runtime as LinglanCombatTestRuntime
		return (
			test_runtime != null
			and test_runtime.request_multiplayer_player_damage(
				source_id,
				target_peer_id,
				damage,
				source_type,
				damage_type,
				source_direction,
				is_ranged,
				contact_preconsumed
			)
		)

	func broadcast_enemy_action(
		net_id: int,
		action_name: StringName,
		direction: Vector2,
		action_position: Vector2,
		action_id: int
	) -> void:
		var test_runtime := runtime as LinglanCombatTestRuntime
		if test_runtime != null:
			test_runtime.broadcast_enemy_action(
				net_id,
				action_name,
				direction,
				action_position,
				action_id
			)


class LinglanTestRuntimePort:
	extends LinglanBossRuntimePort

	func _test_runtime() -> LinglanCombatTestRuntime:
		return combat_runtime as LinglanCombatTestRuntime

	func uses_tower_defense_rules() -> bool:
		var test_runtime := _test_runtime()
		return test_runtime != null and test_runtime.linglan_tower_defense_rules

	func is_terminal_combat_state() -> bool:
		return false

	func pause_background_music() -> void:
		var test_runtime := _test_runtime()
		if test_runtime != null:
			test_runtime.pause_background_music()

	func get_home_objective_target(from_position: Vector2) -> Node2D:
		var test_runtime := _test_runtime()
		return (
			test_runtime.get_linglan_home_objective_target(from_position)
			if test_runtime != null
			else null
		)

	func spawn_random_slime(spawn_position: Vector2) -> void:
		var test_runtime := _test_runtime()
		if test_runtime != null:
			test_runtime.spawn_linglan_random_slime(spawn_position)

	func get_enrage_sniper_config() -> EnemyConfig:
		var test_runtime := _test_runtime()
		return (
			test_runtime.get_linglan_enrage_sniper_config()
			if test_runtime != null
			else null
		)

	func spawn_airdrop_sniper(
		enemy_config: EnemyConfig,
		warning_scene: PackedScene,
		warning_duration: float,
		drop_height: float,
		drop_duration: float
	) -> void:
		var test_runtime := _test_runtime()
		if test_runtime != null:
			test_runtime.spawn_linglan_airdrop_sniper(
				enemy_config,
				warning_scene,
				warning_duration,
				drop_height,
				drop_duration
			)

	func get_skill2_target_player(from_position: Vector2) -> Player:
		var test_runtime := _test_runtime()
		return (
			test_runtime.get_linglan_skill2_target_player(from_position)
			if test_runtime != null
			else null
		)

	func spawn_skill2_enemies(
		enemy_config: EnemyConfig,
		marker_names: Array[StringName]
	) -> void:
		var test_runtime := _test_runtime()
		if test_runtime != null:
			test_runtime.spawn_linglan_skill2_enemies(
				enemy_config,
				marker_names
			)

	func get_skill2_target_global_position(target_cell: Vector2i) -> Vector2:
		var test_runtime := _test_runtime()
		return (
			test_runtime.get_linglan_skill2_target_global_position(target_cell)
			if test_runtime != null
			else Vector2.ZERO
		)

	func get_skill3_target_global_position(target_cell: Vector2i) -> Vector2:
		var test_runtime := _test_runtime()
		return (
			test_runtime.get_linglan_skill3_target_global_position(target_cell)
			if test_runtime != null
			else Vector2.ZERO
		)

	func get_skill4_target_global_position(
		target_cell_a: Vector2i,
		target_cell_b: Vector2i
	) -> Vector2:
		var test_runtime := _test_runtime()
		return (
			test_runtime.get_linglan_skill4_target_global_position(
				target_cell_a,
				target_cell_b
			)
			if test_runtime != null
			else Vector2.ZERO
		)

	func get_skill4_laser_bounds(
		left_cell_x: int,
		right_cell_x: int,
		top_cell_y: int,
		bottom_cell_y: int,
		inward_cell_distance: int
	) -> Dictionary:
		var test_runtime := _test_runtime()
		return (
			test_runtime.get_linglan_skill4_laser_bounds(
				left_cell_x,
				right_cell_x,
				top_cell_y,
				bottom_cell_y,
				inward_cell_distance
			)
			if test_runtime != null
			else {}
		)

	func get_skill4_orb_spawn_global_position(
		x_cell: int,
		y_cell: int
	) -> Vector2:
		var test_runtime := _test_runtime()
		return (
			test_runtime.get_linglan_skill4_orb_spawn_global_position(
				x_cell,
				y_cell
			)
			if test_runtime != null
			else Vector2.ZERO
		)


var linglan_tower_defense_rules := false
var linglan_boss_runtime_port: LinglanBossRuntimePort = null
var session_object_pool: SessionObjectPool = null


func _init() -> void:
	_install_runtime_nodes()


func _install_runtime_nodes() -> void:
	var enemies := Node2D.new()
	enemies.name = "EnemyContainer"
	add_child(enemies)
	var pathfinder := Node.new()
	pathfinder.name = "GridPathfinder"
	add_child(pathfinder)
	add_child(CAPOO_PROJECTILE_MOTION_SYSTEM_SCENE.instantiate())
	add_child(COMBAT_ROBOT_DRONE_MOTION_SYSTEM_SCENE.instantiate())
	add_child(DAY_NIGHT_CONTROLLER_SCENE.instantiate())
	var gateway := LinglanTestGameplayGateway.new()
	gateway.name = "MultiplayerGameplayGateway"
	add_child(gateway)
	var mode_adapter := MultiplayerModeAdapter.new()
	mode_adapter.name = "MultiplayerModeAdapter"
	add_child(mode_adapter)
	linglan_boss_runtime_port = LinglanTestRuntimePort.new()
	linglan_boss_runtime_port.name = "LinglanBossRuntimePort"
	add_child(linglan_boss_runtime_port)
	session_object_pool = SessionObjectPool.new()
	session_object_pool.name = "SessionObjectPool"
	add_child(session_object_pool)


func bind_linglan_node(node: Node) -> void:
	var gateway := get_multiplayer_gameplay_gateway()
	if node is LinglanBoss:
		var boss := node as LinglanBoss
		boss.bind_combat_runtime(self)
		boss.bind_linglan_runtime_port(linglan_boss_runtime_port)
	elif node is LinglanSakuraBullet:
		(node as LinglanSakuraBullet).bind_gameplay_context(self, gateway)
	elif node is LinglanSkill2SakuraRocket:
		(node as LinglanSkill2SakuraRocket).bind_gameplay_context(self, gateway)
	elif node is LinglanSkill3LightOrb:
		(node as LinglanSkill3LightOrb).bind_gameplay_context(self, gateway)
	elif node is LinglanSkill4LightOrb:
		(node as LinglanSkill4LightOrb).bind_gameplay_context(self, gateway)
	elif node is LinglanSkill4LaserField:
		(node as LinglanSkill4LaserField).bind_gameplay_context(self, gateway)


func configure_multiplayer(
	_mode: int,
	_local_peer_id: int,
	_player_names: Dictionary,
	_player_character_ids: Dictionary = {}
) -> void:
	pass


func get_player_for_peer(peer_id: int) -> Player:
	return peer_players.get(peer_id) as Player


func get_enemy_for_net_id(net_id: int) -> Enemy:
	return multiplayer_enemies_by_net_id.get(net_id) as Enemy


func get_pickup_for_net_id(net_id: int) -> Pickup:
	return multiplayer_pickups.get(net_id) as Pickup


func remove_multiplayer_player(peer_id: int) -> void:
	peer_players.erase(peer_id)


func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
	return []


func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	return []


func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
	pass


func pause_background_music() -> void:
	pass


func get_linglan_home_objective_target(_from_position: Vector2) -> Node2D:
	return null


func spawn_linglan_random_slime(_spawn_position: Vector2) -> void:
	pass


func get_linglan_enrage_sniper_config() -> EnemyConfig:
	return null


func spawn_linglan_airdrop_sniper(
	_enemy_config: EnemyConfig,
	_warning_scene: PackedScene,
	_warning_duration: float,
	_drop_height: float,
	_drop_duration: float
) -> void:
	pass


func get_linglan_skill2_target_player(_from_position: Vector2) -> Player:
	return null


func spawn_linglan_skill2_enemies(
	_enemy_config: EnemyConfig,
	_marker_names: Array[StringName]
) -> void:
	pass


func get_linglan_skill2_target_global_position(_target_cell: Vector2i) -> Vector2:
	return Vector2.ZERO


func get_linglan_skill3_target_global_position(_target_cell: Vector2i) -> Vector2:
	return Vector2.ZERO


func get_linglan_skill4_target_global_position(
	_target_cell_a: Vector2i,
	_target_cell_b: Vector2i
) -> Vector2:
	return Vector2.ZERO


func get_linglan_skill4_laser_bounds(
	_left_cell_x: int,
	_right_cell_x: int,
	_top_cell_y: int,
	_bottom_cell_y: int,
	_inward_cell_distance: int
) -> Dictionary:
	return {}


func get_linglan_skill4_orb_spawn_global_position(
	_x_cell: int,
	_y_cell: int
) -> Vector2:
	return Vector2.ZERO


func register_local_projectile(
	_projectile: Node,
	_projectile_type: StringName,
	_owner_peer_id: int,
	_spawn_position: Vector2,
	_direction: Vector2,
	_damage: int,
	_speed: float,
	_lifetime: float,
	_pierces_enemies: bool = false,
	_target_peer_id: int = 0,
	_target_enemy_net_id: int = 0
) -> void:
	pass


func register_local_linglan_skill1_ring(
	_projectiles: Array[Node],
	_spawn_positions: PackedVector2Array,
	_directions: PackedVector2Array,
	_owner_peer_id: int,
	_damage: int,
	_speed: float,
	_lifetime: float
) -> void:
	pass


func request_multiplayer_player_damage(
	_source_id: int,
	_target_peer_id: int,
	_damage: int,
	_source_type: StringName,
	_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	_source_direction: Vector2 = Vector2.ZERO,
	_is_ranged: bool = false,
	_contact_preconsumed: bool = false
) -> bool:
	return false


func broadcast_enemy_action(
	_net_id: int,
	_action_name: StringName,
	_direction: Vector2,
	_action_position: Vector2,
	_action_id: int
) -> void:
	pass
