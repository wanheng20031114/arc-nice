extends PlantDefense
class_name OrangeChargingTower

const PLAYER_CHARGE_SOURCE_NAMESPACE := 6_400_000_000
const PLAYER_RECONCILE_SECONDS := 0.10
const VISUAL_CYCLE_DURATION_SECONDS := 2.4

@onready var orange_layers: Sprite2D = $VisualRoot/OrangeLayers
@onready var glass_cycle_glow: Sprite2D = $VisualRoot/GlassCycleGlow
@onready var chamber_night_light: NightPointLight2D = $ChamberNightLight
@onready var ground_rings: NightSelfEmissionParticles2D = $GroundRings
@onready var player_aura_area: Area2D = $PlayerAuraArea
@onready var player_aura_shape: CollisionShape2D = (
	$PlayerAuraArea/CollisionShape2D
)
@onready var player_reconcile_timer: Timer = $PlayerReconcileTimer
@onready var health_bar: PlantHealthBar = $HealthBar

var orange_config: OrangeChargingTowerConfig = null
var plant_system: PlantSystem = null
var player_charge_source_id := 0
var player_candidates: Dictionary[Player, bool] = {}
var buffed_players: Dictionary[Player, bool] = {}


func _ready() -> void:
	super._ready()
	chamber_night_light.set_emission_allowed(false)


func _exit_tree() -> void:
	_clear_all_player_charge_bonuses()
	super._exit_tree()


func _on_setup_completed() -> void:
	orange_config = config as OrangeChargingTowerConfig
	if orange_config == null:
		push_error("OrangeChargingTower requires OrangeChargingTowerConfig.")
		return
	player_charge_source_id = _make_player_charge_source_id()
	var cycle_offset := (
		float(posmod(player_charge_source_id, 997))
		/ 997.0
		* VISUAL_CYCLE_DURATION_SECONDS
	)
	orange_layers.set_instance_shader_parameter(
		&"cycle_offset_seconds",
		cycle_offset
	)
	glass_cycle_glow.set_instance_shader_parameter(
		&"cycle_offset_seconds",
		cycle_offset
	)
	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)


func set_plant_system(new_plant_system: PlantSystem) -> void:
	if plant_system == new_plant_system:
		_seed_overlapping_player_candidates()
		_reconcile_player_candidates()
		return
	_clear_all_player_charge_bonuses()
	plant_system = new_plant_system
	_configure_player_aura_shape()
	_seed_overlapping_player_candidates()
	_reconcile_player_candidates()


func get_aura_cell_rect() -> Rect2i:
	if orange_config == null or footprint_cells.is_empty():
		return Rect2i()
	var minimum_cell := footprint_cells[0]
	var maximum_cell := footprint_cells[0]
	for cell in footprint_cells:
		minimum_cell.x = mini(minimum_cell.x, cell.x)
		minimum_cell.y = mini(minimum_cell.y, cell.y)
		maximum_cell.x = maxi(maximum_cell.x, cell.x)
		maximum_cell.y = maxi(maximum_cell.y, cell.y)
	var margin := maxi(orange_config.aura_margin_cells, 0)
	return Rect2i(
		minimum_cell - Vector2i.ONE * margin,
		maximum_cell - minimum_cell + Vector2i.ONE * (margin * 2 + 1)
	)


func get_support_source_id() -> int:
	return player_charge_source_id


func _on_construction_started() -> void:
	chamber_night_light.set_emission_allowed(false)
	_stop_ground_rings()
	_clear_all_player_charge_bonuses()


func _on_construction_finished(_was_animated: bool) -> void:
	chamber_night_light.set_emission_allowed(true)
	_start_ground_rings()


func _on_operational_started() -> void:
	_seed_overlapping_player_candidates()
	_reconcile_player_candidates()


func _on_removal_started(_mode: RemovalMode) -> void:
	player_reconcile_timer.stop()
	player_aura_area.set_deferred("monitoring", false)
	chamber_night_light.set_emission_allowed(false)
	_stop_ground_rings()
	_clear_all_player_charge_bonuses()
	player_candidates.clear()
	health_bar.hide()


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)


func _on_player_aura_body_entered(body: Node2D) -> void:
	var candidate := body as Player
	if candidate == null:
		return
	player_candidates[candidate] = true
	_reconcile_player(candidate)
	_refresh_player_reconcile_timer()


func _on_player_aura_body_exited(body: Node2D) -> void:
	var candidate := body as Player
	if candidate == null:
		return
	_remove_player_charge_bonus(candidate)
	player_candidates.erase(candidate)
	_refresh_player_reconcile_timer()


func _on_player_reconcile_timer_timeout() -> void:
	_reconcile_player_candidates()


func _configure_player_aura_shape() -> void:
	if plant_system == null or plant_system.ground_tile_map == null:
		return
	var rectangle := player_aura_shape.shape as RectangleShape2D
	if rectangle == null:
		push_error("OrangeChargingTower player aura requires RectangleShape2D.")
		return
	var aura_rect := get_aura_cell_rect()
	if aura_rect.size.x <= 0 or aura_rect.size.y <= 0:
		return
	var tile_size := Vector2(
		plant_system.ground_tile_map.tile_set.tile_size
	).abs()
	rectangle.size = tile_size * Vector2(aura_rect.size)


func _seed_overlapping_player_candidates() -> void:
	if not player_aura_area.monitoring:
		return
	for body in player_aura_area.get_overlapping_bodies():
		var candidate := body as Player
		if candidate != null:
			player_candidates[candidate] = true
	_refresh_player_reconcile_timer()


func _reconcile_player_candidates() -> void:
	var stale_candidates: Array[Player] = []
	for candidate in player_candidates:
		if candidate == null or not is_instance_valid(candidate):
			stale_candidates.append(candidate)
			continue
		_reconcile_player(candidate)
	for candidate in stale_candidates:
		buffed_players.erase(candidate)
		player_candidates.erase(candidate)
	_refresh_player_reconcile_timer()


func _reconcile_player(candidate: Player) -> void:
	if _should_buff_player(candidate):
		candidate.set_skill_charge_rate_modifier(
			player_charge_source_id,
			orange_config.player_skill_charge_bonus_per_second
		)
		buffed_players[candidate] = true
		return
	_remove_player_charge_bonus(candidate)


func _should_buff_player(candidate: Player) -> bool:
	if (
		candidate == null
		or not is_instance_valid(candidate)
		or orange_config == null
		or plant_system == null
		or plant_system.ground_tile_map == null
		or player_charge_source_id <= 0
		or not is_operational
		or is_dead
		or is_removing
	):
		return false
	var ground_tile_map := plant_system.ground_tile_map
	var player_cell := ground_tile_map.local_to_map(
		ground_tile_map.to_local(candidate.global_position)
	)
	return get_aura_cell_rect().has_point(player_cell)


func _remove_player_charge_bonus(candidate: Player) -> void:
	if candidate != null and is_instance_valid(candidate) and player_charge_source_id > 0:
		candidate.remove_skill_charge_rate_modifier(player_charge_source_id)
	buffed_players.erase(candidate)


func _clear_all_player_charge_bonuses() -> void:
	for candidate in buffed_players:
		if candidate != null and is_instance_valid(candidate):
			candidate.remove_skill_charge_rate_modifier(player_charge_source_id)
	buffed_players.clear()


func _refresh_player_reconcile_timer() -> void:
	if player_candidates.is_empty() or is_removing:
		player_reconcile_timer.stop()
		return
	if player_reconcile_timer.is_stopped():
		player_reconcile_timer.start(PLAYER_RECONCILE_SECONDS)


func _start_ground_rings() -> void:
	if not is_operational or is_dead or is_removing:
		return
	if not ground_rings.emitting:
		ground_rings.restart()
		ground_rings.emitting = true


func _stop_ground_rings() -> void:
	ground_rings.emitting = false


func _make_player_charge_source_id() -> int:
	var stable_id := int(get_meta(&"net_id", 0))
	if stable_id <= 0:
		stable_id = int(get_instance_id())
	return PLAYER_CHARGE_SOURCE_NAMESPACE + absi(stable_id)
