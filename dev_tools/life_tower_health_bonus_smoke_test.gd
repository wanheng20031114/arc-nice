extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const LIFE_TOWER_SCENE := preload(
	"res://scene/plant_defense/life_tower.tscn"
)
const LIFE_TOWER_CONFIG := preload(
	"res://resources/config/plant_defense/life_tower.tres"
)
const COORDINATOR_SCRIPT := preload(
	"res://scene/game_modes/tower_defense/plant/support/life_tower_health_coordinator.gd"
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
	_expect(run_state != null, "Life Tower smoke test requires RunState.")
	if run_state == null:
		_finish(null)
		return
	run_state.begin_new_run(&"weishidaier", false)

	var fixture := Node2D.new()
	fixture.name = "LifeTowerHealthBonusSmokeTest"
	root.add_child(fixture)
	current_scene = fixture

	var plant_system := PlantSystem.new()
	var roster := RosterProbe.new()
	fixture.add_child(plant_system)
	fixture.add_child(roster)

	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	await process_frame
	player.set("_base_max_health", 100)
	player.current_health = 80
	player.refresh_collectible_stats()
	roster.local_player = player
	roster.players.append(player)

	var coordinator := COORDINATOR_SCRIPT.new() as LifeTowerHealthCoordinator
	coordinator.plant_system = plant_system
	coordinator.player_roster_coordinator = roster
	fixture.add_child(coordinator)
	await process_frame
	_expect(coordinator.get_active_source_count() == 0, "No source must mean no bonus.")
	_expect(player.max_health == 100, "No source must preserve base max health.")

	var first := _make_tower(fixture, Vector2i.ZERO, false)
	plant_system.plant_placed.emit(first)
	_expect(coordinator.get_active_source_count() == 1, "First completed tower must register.")
	_expect(
		is_equal_approx(coordinator.get_total_bonus_ratio(), 0.10),
		"One tower must publish an absolute 10% ratio."
	)
	_expect(player.max_health == 110, "One tower must raise base 100 health to 110.")
	_expect(player.current_health == 80, "Max-health gain must not heal current health.")

	plant_system.plant_placed.emit(first)
	_expect(
		coordinator.get_active_source_count() == 1
		and player.max_health == 110,
		"Duplicate placement events must be idempotent."
	)

	var second := _make_tower(fixture, Vector2i(2, 0), true)
	plant_system.plant_placed.emit(second)
	_expect(
		coordinator.get_active_source_count() == 1
		and player.max_health == 110,
		"A tower under construction must not grant its bonus."
	)
	second.call("_finish_construction", true)
	_expect(coordinator.get_active_source_count() == 2, "Construction completion must register.")
	_expect(
		is_equal_approx(coordinator.get_total_bonus_ratio(), 0.20),
		"Two towers must publish 20%, never 1.1 multiplied by 1.1."
	)
	_expect(player.max_health == 120, "Two towers must raise base 100 health to 120.")
	player.configure_run_stat_bonuses({"max_health": 50})
	_expect(
		player.max_health == 180,
		"Two towers must raise the full 150 max-health total by 20%."
	)
	player.configure_run_stat_bonuses({})
	_expect(player.max_health == 120, "Clearing the run bonus must restore 120 health.")

	plant_system.plant_removed.emit(first)
	_expect(
		coordinator.get_active_source_count() == 1
		and is_equal_approx(coordinator.get_total_bonus_ratio(), 0.10)
		and player.max_health == 110,
		"Removal must immediately subtract exactly one tower."
	)

	var late_player := PLAYER_SCENE.instantiate() as Player
	roster.player_runtime_binding_requested.emit(late_player)
	_expect(
		is_equal_approx(
			late_player.get_tower_defense_life_tower_bonus_ratio(),
			0.10
		),
		"A late player must receive the current absolute ratio before entering the tree."
	)
	fixture.add_child(late_player)
	await process_frame
	var late_base := int(late_player.get("_base_max_health"))
	_expect(
		late_player.max_health == roundi(float(late_base) * 1.10),
		"A late player must initialize with the active tower bonus."
	)
	roster.players.append(late_player)

	plant_system.plant_removed.emit(second)
	_expect(
		coordinator.get_active_source_count() == 0
		and is_zero_approx(coordinator.get_total_bonus_ratio())
		and player.max_health == 100
		and late_player.max_health == late_base,
		"Removing the final tower must clear every player's bonus immediately."
	)

	_finish(fixture)


func _make_tower(
	parent: Node,
	top_left: Vector2i,
	play_construction: bool
) -> LifeTower:
	var tower := LIFE_TOWER_SCENE.instantiate() as LifeTower
	parent.add_child(tower)
	tower.setup(
		LIFE_TOWER_CONFIG,
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
		print("LIFE_TOWER_HEALTH_BONUS_SMOKE_TEST_OK")
		print("event_driven=true")
		print("persistent_scan=false")
		print("two_tower_ratio=0.20")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
