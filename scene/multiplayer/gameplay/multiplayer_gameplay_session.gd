@abstract
extends Node2D
class_name MultiplayerGameplaySession

signal embedded_runtime_prepared

@export_group("内嵌战斗运行时")
@export_file("*.tscn") var runtime_scene_path_override := ""
@export var embedded_runtime := false


## Freezes the participant roster before an embedded combat session enters the
## scene tree. Route spectators remain connected to the enclosing multiplayer
## session but are deliberately excluded from this combat runtime.
@abstract
func configure_embedded_participant_roster(
	peer_ids: PackedInt32Array
) -> bool


## Activates a prepared embedded combat runtime after the route transition and
## multiplayer preparation barrier have both completed.
@abstract
func activate_embedded_runtime() -> bool


## Removes one participant from the current embedded combat without disconnecting
## the peer from the enclosing route session.
@abstract
func suspend_embedded_participant_for_current_combat(
	peer_id: int,
	previous_peer_id: int = -1
) -> bool


## Returns the concrete combat runtime owned by this multiplayer session.
@abstract
func get_game_runtime() -> CombatRuntimeBase


@abstract
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
) -> void


@abstract
func request_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> void


@abstract
func request_multiplayer_player_damage(
	source_id: int,
	target_peer_id: int,
	damage: int,
	source_type: StringName,
	damage_type_or_source_direction: Variant = EnemyConfig.DamageType.PHYSICAL,
	source_direction_or_is_ranged: Variant = Vector2.ZERO,
	is_ranged: bool = false,
	contact_preconsumed: bool = false
) -> bool


@abstract
func broadcast_enemy_action(
	net_id: int,
	action_name: StringName,
	direction: Vector2,
	action_position: Vector2,
	action_id: int
) -> void


@abstract
func broadcast_enemy_target_action(
	net_id: int,
	action_name: StringName,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int
) -> void


@abstract
func broadcast_enemy_lightning_chain(points: PackedVector2Array) -> void


@abstract
func register_local_tango_laser_volley(
	projectiles: Array[Node],
	spawn_positions: PackedVector2Array,
	direction: Vector2,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float,
	charge_ratio: float,
	barrage_remaining_seconds: float
) -> bool


@abstract
func register_local_linglan_skill1_ring(
	projectiles: Array[Node],
	spawn_positions: PackedVector2Array,
	directions: PackedVector2Array,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float
) -> void


@abstract
func request_multiplayer_player_burn_tick(
	player_peer_id: int,
	source_family: StringName
) -> bool


@abstract
func request_multiplayer_player_damage_over_time_tick(
	player_peer_id: int,
	status_id: StringName,
	source_family: StringName,
	tick_damage: int
) -> bool


@abstract
func request_player_hit_report(
	source_id: int,
	player_peer_id: int,
	source_type: StringName,
	impact_direction: Vector2,
	damage_flags: int
) -> void


@abstract
func try_consume_fire_sorcerer_fireball_contact(
	projectile_id: int,
	source_type: StringName
) -> bool


@abstract
func try_consume_frost_sorcerer_ice_spike_contact(
	projectile_id: int,
	source_type: StringName
) -> bool


@abstract
func apply_multiplayer_collectible_enemy_damage(
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.MAGIC,
	show_hit_particles: bool = true
) -> bool


@abstract
func apply_multiplayer_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool


@abstract
func apply_multiplayer_collectible_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool


@abstract
func report_multiplayer_player_healing(
	target_player: Player,
	confirmed_healing: int
) -> void


@abstract
func notify_local_player_dash_started(
	direction: Vector2,
	start_move_input: Vector2
) -> void


@abstract
func request_hoe_primary_attack(direction: Vector2) -> bool


@abstract
func request_hoe_whirlwind() -> bool


@abstract
func request_tango_electric_surge() -> bool


@abstract
func spawn_authoritative_tango_electric_surge_field(
	owner_player: Player,
	activation_id: int,
	origin: Vector2
) -> bool


@abstract
func spawn_remote_tango_electric_surge_visual_field(
	activation_id: int,
	origin: Vector2,
	remaining_seconds: float
) -> bool


@abstract
func request_tango_charge_started(direction: Vector2) -> bool


@abstract
func request_tango_charge_released(direction: Vector2) -> bool


@abstract
func request_tango_charge_cancelled() -> bool


@abstract
func request_tiyi_high_noon() -> bool


@abstract
func notify_tiyi_high_noon_targets_changed(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void


@abstract
func resolve_tiyi_high_noon(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array,
	hit_positions: PackedVector2Array
) -> void


@abstract
func cancel_tiyi_high_noon(peer_id: int, activation_id: int) -> void


@abstract
func broadcast_collectible_visual_effect(
	effect_type: StringName,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void


@abstract
func broadcast_collectible_follow_visual_effect(
	effect_type: StringName,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void


@abstract
func request_multiplayer_cheat_xirang() -> void


@abstract
func request_debug_collectible(config_path: String) -> void


@abstract
func request_multiplayer_start_wave() -> void


@abstract
func broadcast_plant_projectile_visual(
	plant_net_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void


@abstract
func queue_bamboo_mortar_visual(
	plant_net_id: int,
	action_id: int,
	stage: int,
	spawn_position: Vector2,
	landing_position: Vector2,
	committed_windup_duration_seconds: float
) -> void


@abstract
func queue_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	action_elapsed_seconds: float
) -> void


@abstract
func queue_corn_machine_gun_burst_visual(
	plant_net_id: int,
	action_id: int,
	direction: Vector2
) -> void


@abstract
func apply_authoritative_plant_enemy_damage(
	damage_source_id: int,
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool


@abstract
func apply_authoritative_plant_enemy_damage_batch(
	damage_source_id: int,
	enemy: Enemy,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool


@abstract
func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool


@abstract
func cancel_bamboo_mortar_target_request(owner: Node) -> void


@abstract
func select_bamboo_mortar_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy


@abstract
func queue_bamboo_mortar_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool


@abstract
func get_bamboo_mortar_combat_metrics() -> Dictionary


@abstract
func apply_luoxi_direct_health_loss(
	target_player: Player,
	amount: int,
	minimum_health: int = 0
) -> int


@abstract
func request_multiplayer_skill1_purchase() -> void


@abstract
func uses_authoritative_luoxi_offers() -> bool


@abstract
func request_luoxi_collectible_offer() -> void


@abstract
func request_luoxi_collectible_choice(
	choice_index: int,
	legacy_config_path: String = "",
	offer_revision: int = 0
) -> void


@abstract
func request_luoxi_collectible_refresh(offer_revision: int = 0) -> void


@abstract
func has_luoxi_collectible_claimed(peer_id: int) -> bool


@abstract
func supports_luoxi_special_game() -> bool


@abstract
func request_luoxi_special_game_start() -> void


@abstract
func request_luoxi_special_game_card_reveal(
	session_revision: int,
	card_index: int
) -> void


@abstract
func request_luoxi_special_game_finish(session_revision: int) -> void
