extends StaticBody2D
class_name PlantDefense

enum RemovalMode {
	SILENT,
	ANIMATED,
}

signal health_changed(current_health: int, maximum_health: int)
signal authoritative_health_changed(current_health: int, maximum_health: int, revision: int)
signal damage_applied(
	applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
)
signal healing_applied(applied_healing: int)
signal died
signal modal_ui_visibility_changed(is_open: bool)
signal construction_finished
signal removal_started(mode: RemovalMode)

const CONSTRUCTION_DURATION_SECONDS: float = 0.7
const REMOVAL_DURATION_SECONDS: float = 0.7
const BUILDING_INTERACTION_GROUP := &"plant_building_interaction"

@export_range(0.0, 12.0, 0.5, "or_greater") var enemy_approach_depth: float = 3.0

@export_group("生命周期视觉")
@export var lifecycle_visual_paths: Array[NodePath] = []
@export var lifecycle_effect_top_y: float = -16.0
@export var lifecycle_effect_bottom_y: float = 16.0
@export_range(0.1, 4.0, 0.05, "or_greater") var lifecycle_particle_scale: float = 1.0

var config: PlantDefenseConfig = null
var owner_player: Player = null
var footprint_cells: Array[Vector2i] = []
var current_health: int = 0
var max_health: int = 0
var physical_defense: int = 0
var magic_defense: int = 0
var global_physical_defense_bonus: int = 0
var is_dead: bool = false
var is_multiplayer_proxy: bool = false
var health_revision: int = 0
var is_operational: bool = false
var is_removing: bool = false
var removal_mode: RemovalMode = RemovalMode.SILENT

var _lifecycle_visuals: Array[CanvasItem] = []
var _construction_tween: Tween = null
var _removal_tween: Tween = null
var _construction_progress: float = 1.0
var _construction_visual_active := false
var _pending_physical_damage_number_amount: int = 0
var _pending_magic_damage_number_amount: int = 0
var _pending_healing_number_amount: int = 0
var _pending_physical_damage_number_direction := Vector2.ZERO
var _pending_magic_damage_number_direction := Vector2.ZERO
var _combat_number_flush_queued := false


func _ready() -> void:
	add_to_group(&"plant_defense")


func setup(
	new_config: PlantDefenseConfig,
	new_owner_player: Player,
	new_footprint_cells: Array[Vector2i],
	as_multiplayer_proxy: bool = false,
	initial_health: int = -1,
	initial_health_revision: int = 0,
	initial_maximum_health: int = -1,
	play_placement_effect: bool = false
) -> void:
	if new_config == null or not new_config.is_valid():
		push_error("PlantDefense setup requires a valid config.")
		return

	config = new_config
	owner_player = new_owner_player
	footprint_cells.assign(new_footprint_cells)
	max_health = initial_maximum_health if initial_maximum_health > 0 else config.max_health
	current_health = clampi(initial_health, 0, max_health) if initial_health >= 0 else max_health
	physical_defense = maxi(config.physical_defense, 0)
	magic_defense = clampi(config.magic_defense, 0, 100)
	# Keep the node alive through subclass setup so a zero-health replica can
	# complete its visual initialization and then follow the normal death path.
	is_dead = false
	is_multiplayer_proxy = as_multiplayer_proxy
	health_revision = maxi(initial_health_revision, 0)
	is_operational = false
	is_removing = false
	removal_mode = RemovalMode.SILENT
	_pending_physical_damage_number_amount = 0
	_pending_magic_damage_number_amount = 0
	_pending_healing_number_amount = 0
	_pending_physical_damage_number_direction = Vector2.ZERO
	_pending_magic_damage_number_direction = Vector2.ZERO
	_combat_number_flush_queued = false
	health_changed.emit(current_health, max_health)
	if not is_multiplayer_proxy:
		_bump_health_revision()
	_on_setup_completed()
	_prepare_lifecycle_visuals()
	if current_health <= 0:
		_set_construction_progress(0.0 if play_placement_effect else 1.0)
		_set_lifecycle_parameter(&"construction_front_strength", 0.0)
		_begin_death()
	elif play_placement_effect:
		_start_construction_visual()
	else:
		_finish_construction(false)


func receive_damage(
	amount: int,
	source: Node = null,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> bool:
	if is_multiplayer_proxy or is_dead or is_removing or amount <= 0:
		return false

	var mitigated_damage := _calculate_incoming_damage(amount, damage_type)
	var applied_damage := _apply_damage_to_health(mitigated_damage)
	_report_damage_applied(applied_damage, impact_direction, damage_type)
	_on_damage_received(applied_damage, source, impact_direction, damage_type)
	if current_health <= 0:
		_begin_death()
	return true


## Applies damage without physical or magic mitigation while preserving the
## authoritative health revision, signals and normal death lifecycle.
func receive_unmitigated_damage(amount: int, source: Node = null) -> bool:
	if is_multiplayer_proxy or is_dead or is_removing or amount <= 0:
		return false

	var applied_damage := _apply_damage_to_health(amount)
	_report_damage_applied(
		applied_damage,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL
	)
	_on_unmitigated_damage_received(applied_damage, source)
	if current_health <= 0:
		_begin_death()
	return true


func receive_healing(amount: int, source: Node = null) -> bool:
	if (
		is_multiplayer_proxy
		or is_dead
		or is_removing
		or amount <= 0
		or current_health >= max_health
	):
		return false

	var previous_health := current_health
	current_health = mini(current_health + amount, max_health)
	var applied_healing := current_health - previous_health
	health_changed.emit(current_health, max_health)
	_bump_health_revision()
	healing_applied.emit(applied_healing)
	_pending_healing_number_amount += applied_healing
	_queue_combat_number_flush()
	_on_healing_received(applied_healing, source)
	return true


func get_health_ratio() -> float:
	if max_health <= 0:
		return 0.0
	return float(current_health) / float(max_health)


func get_effective_physical_defense() -> int:
	return maxi(physical_defense + global_physical_defense_bonus, 0)


func set_global_physical_defense_bonus(bonus: int) -> void:
	global_physical_defense_bonus = maxi(bonus, 0)


func get_effective_magic_defense() -> int:
	return clampi(magic_defense, 0, 100)


func get_enemy_approach_depth() -> float:
	# Enemy damage sensing begins at the authored collision boundary, while this
	# visual inset controls how far an attacker may press into that silhouette
	# before movement stops. Individual buildings can tune it without changing
	# their footprint, projectile hitbox or shared enemy navigation code.
	return maxf(enemy_approach_depth, 0.0)


func is_modal_ui_open() -> bool:
	return false


## Every modal building panel uses the same second-press toggle contract.
## Keeping the action set here prevents future interactive buildings from
## silently diverging from the warehouse's F / controller-Y behavior.
static func is_building_modal_close_event(event: InputEvent) -> bool:
	return (
		event != null
		and (
			event.is_action_pressed(&"quit")
			or event.is_action_pressed(&"ui_cancel")
			or event.is_action_pressed(&"bag")
			or event.is_action_pressed(&"interact")
		)
	)


## Interactive plant buildings override these hooks so every building type can
## participate in one nearest-target selection without runtime duck typing.
func get_interaction_player() -> Player:
	return null


func set_interaction_target_selected(_selected: bool) -> void:
	pass


func apply_remote_health(
	new_current_health: int,
	new_maximum_health: int,
	new_revision: int
) -> bool:
	if not is_multiplayer_proxy or is_removing or new_revision <= health_revision:
		return false
	health_revision = new_revision
	max_health = maxi(new_maximum_health, 1)
	current_health = clampi(new_current_health, 0, max_health)
	health_changed.emit(current_health, max_health)
	if current_health <= 0:
		_begin_death()
	return true


func configure_multiplayer_proxy(
	initial_health: int,
	initial_maximum_health: int,
	initial_revision: int
) -> void:
	is_multiplayer_proxy = true
	max_health = maxi(initial_maximum_health, 1)
	current_health = clampi(initial_health, 0, max_health)
	health_revision = maxi(initial_revision, 0)
	health_changed.emit(current_health, max_health)
	_on_multiplayer_proxy_configured()
	if current_health <= 0:
		_begin_death()


func export_multiplayer_runtime_state() -> Dictionary:
	return {}


func apply_multiplayer_runtime_state(
	_state: Dictionary,
	_mapped_sample_time: float
) -> void:
	pass


func _bump_health_revision() -> void:
	health_revision += 1
	authoritative_health_changed.emit(current_health, max_health, health_revision)


func _calculate_incoming_damage(amount: int, damage_type: EnemyConfig.DamageType) -> int:
	match damage_type:
		EnemyConfig.DamageType.MAGIC:
			var defense_ratio := float(100 - get_effective_magic_defense()) / 100.0
			return maxi(floori(float(amount) * defense_ratio), 1)
		_:
			return maxi(amount - get_effective_physical_defense(), 1)


func _apply_damage_to_health(amount: int) -> int:
	var applied_damage := mini(amount, current_health)
	current_health -= applied_damage
	health_changed.emit(current_health, max_health)
	_bump_health_revision()
	return applied_damage


func _report_damage_applied(
	applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> void:
	if applied_damage <= 0:
		return
	var safe_impact_direction := Vector2.ZERO
	if impact_direction.is_finite() and impact_direction.length_squared() > 0.001:
		safe_impact_direction = impact_direction.normalized()
	var safe_damage_type := (
		EnemyConfig.DamageType.MAGIC
		if damage_type == EnemyConfig.DamageType.MAGIC
		else EnemyConfig.DamageType.PHYSICAL
	)
	damage_applied.emit(applied_damage, safe_impact_direction, safe_damage_type)
	if safe_damage_type == EnemyConfig.DamageType.MAGIC:
		_pending_magic_damage_number_amount += applied_damage
		_pending_magic_damage_number_direction = safe_impact_direction
	else:
		_pending_physical_damage_number_amount += applied_damage
		_pending_physical_damage_number_direction = safe_impact_direction
	_queue_combat_number_flush()


func _queue_combat_number_flush() -> void:
	if _combat_number_flush_queued:
		return
	_combat_number_flush_queued = true
	call_deferred("_flush_pending_combat_numbers")


func _flush_pending_combat_numbers() -> void:
	_combat_number_flush_queued = false
	var physical_amount := _pending_physical_damage_number_amount
	var magic_amount := _pending_magic_damage_number_amount
	var damage_amount := physical_amount + magic_amount
	var healing_amount := _pending_healing_number_amount
	var use_magic := magic_amount > physical_amount
	var impact_direction := (
		_pending_magic_damage_number_direction
		if use_magic
		else _pending_physical_damage_number_direction
	)
	var damage_type := (
		EnemyConfig.DamageType.MAGIC
		if use_magic
		else EnemyConfig.DamageType.PHYSICAL
	)
	_pending_physical_damage_number_amount = 0
	_pending_magic_damage_number_amount = 0
	_pending_healing_number_amount = 0
	_pending_physical_damage_number_direction = Vector2.ZERO
	_pending_magic_damage_number_direction = Vector2.ZERO
	if is_multiplayer_proxy:
		return

	var combat_number_owner := get_parent()
	while combat_number_owner != null:
		if combat_number_owner.has_method("show_combat_number"):
			var world_position := get_lifecycle_vfx_global_position()
			if damage_amount > 0:
				combat_number_owner.call(
					"show_combat_number",
					damage_amount,
					world_position,
					DamageNumberPool.CombatNumberKind.DAMAGE,
					impact_direction,
					damage_type,
					DamageNumberPool.DisplayPriority.IMPORTANT
				)
			if healing_amount > 0:
				combat_number_owner.call(
					"show_combat_number",
					healing_amount,
					world_position,
					DamageNumberPool.CombatNumberKind.HEALING,
					Vector2.ZERO,
					EnemyConfig.DamageType.PHYSICAL,
					DamageNumberPool.DisplayPriority.IMPORTANT
				)
			return
		combat_number_owner = combat_number_owner.get_parent()


func _begin_death() -> void:
	if is_dead or is_removing:
		return
	is_dead = true
	current_health = 0
	died.emit()
	begin_removal(RemovalMode.ANIMATED)


func begin_removal(mode: RemovalMode = RemovalMode.ANIMATED) -> void:
	if is_removing:
		if mode == RemovalMode.SILENT and removal_mode != RemovalMode.SILENT:
			removal_mode = RemovalMode.SILENT
			_stop_removal_tween()
			queue_free()
		return

	is_removing = true
	removal_mode = mode
	is_operational = false
	_stop_construction_tween()
	_construction_visual_active = false
	_set_lifecycle_parameter(&"construction_front_strength", 0.0)
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	var player_core_body := get_node_or_null("PlayerCoreBody") as StaticBody2D
	if player_core_body != null:
		player_core_body.set_deferred("collision_layer", 0)
		player_core_body.set_deferred("collision_mask", 0)
	_on_removal_started(mode)
	removal_started.emit(mode)
	if mode == RemovalMode.SILENT:
		queue_free()
		return
	_start_animated_removal()


func get_lifecycle_vfx_global_position() -> Vector2:
	var local_center_y := (lifecycle_effect_top_y + lifecycle_effect_bottom_y) * 0.5
	return to_global(Vector2(0.0, local_center_y))


func get_lifecycle_particle_scale() -> float:
	return lifecycle_particle_scale


func is_construction_visual_active() -> bool:
	return _construction_visual_active


func _prepare_lifecycle_visuals() -> void:
	_lifecycle_visuals.clear()
	for visual_path in lifecycle_visual_paths:
		var visual := get_node_or_null(visual_path) as CanvasItem
		if visual == null:
			push_error("PlantDefense lifecycle visual is missing: %s" % visual_path)
			continue
		_lifecycle_visuals.append(visual)

	var noise_offset := _make_lifecycle_noise_offset()
	var effect_top_world_y := to_global(Vector2(0.0, lifecycle_effect_top_y)).y
	var effect_bottom_world_y := to_global(Vector2(0.0, lifecycle_effect_bottom_y)).y
	_set_lifecycle_parameter(&"effect_top_y", effect_top_world_y)
	_set_lifecycle_parameter(&"effect_bottom_y", effect_bottom_world_y)
	_set_lifecycle_parameter(&"noise_offset", noise_offset)
	_set_lifecycle_parameter(&"removal_enabled", false)
	_set_lifecycle_parameter(&"removal_progress", 0.0)


func _make_lifecycle_noise_offset() -> Vector2:
	var instance_seed := int(get_meta(&"net_id", get_instance_id()))
	return Vector2(
		float((instance_seed * 37 + 17) % 997) / 997.0,
		float((instance_seed * 101 + 53) % 991) / 991.0
	)


func _start_construction_visual() -> void:
	_stop_construction_tween()
	_construction_visual_active = true
	_set_lifecycle_parameter(&"removal_enabled", false)
	_set_lifecycle_parameter(&"removal_progress", 0.0)
	_set_lifecycle_parameter(&"construction_front_strength", 1.0)
	_set_construction_progress(0.0)
	_on_construction_started()

	_construction_tween = create_tween()
	_construction_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_construction_tween.tween_method(
		_set_construction_progress,
		0.0,
		1.0,
		CONSTRUCTION_DURATION_SECONDS
	)
	_construction_tween.finished.connect(_on_construction_tween_finished)


func _on_construction_tween_finished() -> void:
	_construction_tween = null
	_finish_construction(true)


func _finish_construction(was_animated: bool) -> void:
	if is_removing:
		return
	_construction_visual_active = false
	_set_construction_progress(1.0)
	_set_lifecycle_parameter(&"construction_front_strength", 0.0)
	is_operational = true
	_on_construction_finished(was_animated)
	_on_operational_started()
	construction_finished.emit()


func _start_animated_removal() -> void:
	_stop_removal_tween()
	_set_lifecycle_parameter(&"removal_enabled", true)
	_set_removal_progress(0.0)
	_removal_tween = create_tween()
	_removal_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_removal_tween.tween_method(
		_set_removal_progress,
		0.0,
		1.0,
		REMOVAL_DURATION_SECONDS
	)
	_removal_tween.tween_callback(queue_free)


func _set_construction_progress(value: float) -> void:
	_construction_progress = clampf(value, 0.0, 1.0)
	_set_lifecycle_parameter(&"construction_progress", _construction_progress)


func _set_removal_progress(value: float) -> void:
	_set_lifecycle_parameter(&"removal_progress", clampf(value, 0.0, 1.0))


func _set_lifecycle_parameter(parameter_name: StringName, value: Variant) -> void:
	for visual in _lifecycle_visuals:
		visual.set_instance_shader_parameter(parameter_name, value)


func _stop_construction_tween() -> void:
	if _construction_tween != null and _construction_tween.is_valid():
		_construction_tween.kill()
	_construction_tween = null


func _stop_removal_tween() -> void:
	if _removal_tween != null and _removal_tween.is_valid():
		_removal_tween.kill()
	_removal_tween = null


func _on_setup_completed() -> void:
	pass


func _on_construction_started() -> void:
	pass


func _on_construction_finished(_was_animated: bool) -> void:
	pass


func _on_operational_started() -> void:
	pass


func _on_multiplayer_proxy_configured() -> void:
	pass


func _on_damage_received(
	_applied_damage: int,
	_source: Node,
	_impact_direction: Vector2,
	_damage_type: EnemyConfig.DamageType
) -> void:
	pass


func _on_unmitigated_damage_received(_applied_damage: int, _source: Node) -> void:
	pass


func _on_healing_received(_applied_healing: int, _source: Node) -> void:
	pass


func _on_removal_started(_mode: RemovalMode) -> void:
	pass
