extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const ATTACK_SPEED_TOWER_SCENE := preload(
	"res://scene/plant_defense/attack_speed_tower.tscn"
)
const ATTACK_SPEED_TOWER_CONFIG := preload(
	"res://resources/config/plant_defense/attack_speed_tower.tres"
)
const COORDINATOR_SCRIPT := preload(
	"res://scene/game_modes/tower_defense/plant/support/attack_speed_tower_coordinator.gd"
)

var failures: Array[String] = []


class RosterProbe:
	extends TowerDefensePlayerRosterCoordinator

	var players: Array[Player] = []

	func get_all_players() -> Array[Player]:
		return players


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "Attack Speed Tower smoke test requires RunState.")
	if run_state == null:
		_finish(null)
		return
	run_state.begin_new_run(&"weishidaier", false)

	var fixture := Node2D.new()
	fixture.name = "AttackSpeedTowerBonusSmokeTest"
	root.add_child(fixture)
	current_scene = fixture

	var plant_system := PlantSystem.new()
	var roster := RosterProbe.new()
	fixture.add_child(plant_system)
	fixture.add_child(roster)

	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	await process_frame
	var base_attacks_per_second := player.get_attacks_per_second()
	roster.local_player = player
	roster.players.append(player)

	var coordinator := COORDINATOR_SCRIPT.new() as AttackSpeedTowerCoordinator
	coordinator.plant_system = plant_system
	coordinator.player_roster_coordinator = roster
	fixture.add_child(coordinator)
	await process_frame
	_expect(coordinator.get_active_source_count() == 0, "No source must mean no bonus.")
	_expect(
		is_equal_approx(player.get_attacks_per_second(), base_attacks_per_second),
		"No source must preserve base attack speed."
	)

	var first := _make_tower(fixture, Vector2i.ZERO, false)
	plant_system.plant_placed.emit(first)
	_expect(coordinator.get_active_source_count() == 1, "First completed tower must register.")
	_expect(
		is_equal_approx(coordinator.get_total_bonus_ratio(), 0.03),
		"One tower must publish an absolute 3% ratio."
	)
	_expect(
		is_equal_approx(
			player.get_attacks_per_second(),
			base_attacks_per_second * 1.03
		),
		"One tower must multiply final attack speed by 1.03."
	)

	plant_system.plant_placed.emit(first)
	_expect(
		coordinator.get_active_source_count() == 1
		and is_equal_approx(
			player.get_attacks_per_second(),
			base_attacks_per_second * 1.03
		),
		"Duplicate placement events must be idempotent."
	)

	var second := _make_tower(fixture, Vector2i(2, 0), true)
	plant_system.plant_placed.emit(second)
	_expect(
		coordinator.get_active_source_count() == 1
		and is_equal_approx(
			player.get_attacks_per_second(),
			base_attacks_per_second * 1.03
		),
		"A tower under construction must not grant its bonus."
	)
	second.call("_finish_construction", true)
	_expect(coordinator.get_active_source_count() == 2, "Construction completion must register.")
	_expect(
		is_equal_approx(coordinator.get_total_bonus_ratio(), 0.06),
		"Two towers must publish 6%, never 1.03 multiplied by 1.03."
	)
	_expect(
		is_equal_approx(
			player.get_attacks_per_second(),
			base_attacks_per_second * 1.06
		),
		"Two towers must multiply final attack speed by 1.06."
	)

	player.potion_fire_rate_multiplier = 1.25
	player.call("_refresh_shooting_timer_wait_time")
	_expect(
		is_equal_approx(
			player.get_attacks_per_second(),
			base_attacks_per_second * 1.25 * 1.06
		),
		"Tower ratio must multiply the final speed after existing rate modifiers."
	)
	player.potion_fire_rate_multiplier = 1.0
	player.call("_refresh_shooting_timer_wait_time")

	plant_system.plant_removed.emit(first)
	_expect(
		coordinator.get_active_source_count() == 1
		and is_equal_approx(coordinator.get_total_bonus_ratio(), 0.03)
		and is_equal_approx(
			player.get_attacks_per_second(),
			base_attacks_per_second * 1.03
		),
		"Removal must immediately subtract exactly one tower."
	)

	var late_player := PLAYER_SCENE.instantiate() as Player
	roster.player_runtime_binding_requested.emit(late_player)
	_expect(
		is_equal_approx(
			late_player.get_tower_defense_attack_speed_tower_bonus_ratio(),
			0.03
		),
		"A late player must receive the current ratio before entering the tree."
	)
	fixture.add_child(late_player)
	await process_frame
	_expect(
		is_equal_approx(
			late_player.get_attacks_per_second(),
			base_attacks_per_second * 1.03
		),
		"A late player must initialize with the active tower bonus."
	)
	roster.players.append(late_player)

	plant_system.plant_removed.emit(second)
	_expect(
		coordinator.get_active_source_count() == 0
		and is_zero_approx(coordinator.get_total_bonus_ratio())
		and is_zero_approx(
			player.get_tower_defense_attack_speed_tower_bonus_ratio()
		)
		and is_zero_approx(
			late_player.get_tower_defense_attack_speed_tower_bonus_ratio()
		)
		and is_equal_approx(
			player.get_attacks_per_second(),
			base_attacks_per_second
		),
		"Removing the final tower must clear every player's bonus immediately."
	)

	player.set_tower_defense_attack_speed_tower_bonus_ratio(NAN)
	_expect(
		is_zero_approx(
			player.get_tower_defense_attack_speed_tower_bonus_ratio()
		),
		"Non-finite ratios must clamp to zero."
	)
	player.set_tower_defense_attack_speed_tower_bonus_ratio(-1.0)
	_expect(
		is_zero_approx(
			player.get_tower_defense_attack_speed_tower_bonus_ratio()
		),
		"Negative ratios must clamp to zero."
	)

	_finish(fixture)


func _make_tower(
	parent: Node,
	top_left: Vector2i,
	play_construction: bool
) -> AttackSpeedTower:
	var tower := ATTACK_SPEED_TOWER_SCENE.instantiate() as AttackSpeedTower
	parent.add_child(tower)
	tower.setup(
		ATTACK_SPEED_TOWER_CONFIG,
		null,
		[
			top_left,
			top_left + Vector2i.RIGHT,
			top_left + Vector2i.DOWN,
			top_left + Vector2i.ONE,
		],
		false,
		-1,
		0,
		-1,
		play_construction
	)
	return tower


func _finish(fixture: Node) -> void:
	if fixture != null:
		fixture.queue_free()
	current_scene = null
	if failures.is_empty():
		print("ATTACK_SPEED_TOWER_BONUS_SMOKE_TEST_OK")
		print("event_driven=true")
		print("persistent_scan=false")
		print("two_tower_ratio=0.06")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
