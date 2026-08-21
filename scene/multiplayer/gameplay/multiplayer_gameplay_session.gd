@abstract
extends RuntimePreparationProvider
class_name MultiplayerGameplaySession

const MultiplayerReconnectTypesScript := preload(
	"res://scene/multiplayer/reconnect/multiplayer_reconnect_types.gd"
)

## 保留既有公开名称，实际枚举由重连领域统一定义，避免 NetManager 与各游戏
## 运行时各自维护一套数值契约。
const ReconnectedPlayerProjectionOutcome := (
	MultiplayerReconnectTypesScript.RuntimeProjectionOutcome
)

signal embedded_runtime_prepared
## 内嵌战斗的重连 Player 投影必须给外层流程一个明确终态。外层只组合
## 该结果与路线身份提交，不再读取某一帧里是否恰好存在 Player 来猜监听顺序。
signal reconnected_player_projection_resolved(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerReconnectTypesScript.RuntimeProjectionOutcome
)

@export_group("内嵌战斗运行时")
@export_file("*.tscn") var runtime_scene_path_override := ""
@export var embedded_runtime := false
var player_persistent_modifier_projector: PlayerPersistentModifierProjector = null


func configure_player_persistent_modifier_projector(
	projector: PlayerPersistentModifierProjector
) -> void:
	player_persistent_modifier_projector = projector


## Host 在成员仍为 RECONNECTING 时同步调用；实现必须在返回 true 前把该成员
## 首帧所需快照全部排入传输。这里是可失败命令，不得改由 ready 通知承载。
@abstract
func prepare_reconnected_member_delivery(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerReconnectTypesScript.RuntimeProjectionOutcome,
	membership_revision: int
) -> bool


## 内嵌战斗入树前冻结参战 roster；路线旁观者仍属于外层会话，但不会获得
## 本战斗的 Player、快照、事务或结算状态。
@abstract
func configure_embedded_participant_roster(
	peer_ids: PackedInt32Array
) -> bool


## 仅在路线转场与多人准备屏障都完成后激活已预热的内嵌战斗。
@abstract
func activate_embedded_runtime() -> bool


## 只暂停当前内嵌战斗参与权，不断开其外层路线会话身份。
@abstract
func suspend_embedded_participant_for_current_combat(
	peer_id: int,
	previous_peer_id: int = -1
) -> bool


## 返回本多人会话唯一拥有的具体战斗运行时。
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
func begin_authoritative_tango_snow_wolf_auto_fire(
	owner_player: Player,
	direction: Vector2
) -> int


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
	direction: Vector2,
	shot_count: int
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
