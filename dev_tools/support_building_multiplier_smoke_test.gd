extends SceneTree

# Bootstrap the gameplay graph before standalone combat scenes to avoid the
# Enemy -> game runtime -> registry preload cycle used by projectile scripts.
const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const AGAVE_SCENE := preload("res://scene/plant_defense/agave_cannon.tscn")
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const CORN_SCENE := preload(
	"res://scene/plant_defense/corn_machine_gun.tscn"
)
const CORN_CONFIG := preload(
	"res://resources/config/plant_defense/corn_machine_gun.tres"
)
const GRAPE_SCENE := preload(
	"res://scene/plant_defense/grape_arc_tower.tscn"
)
const GRAPE_CONFIG := preload(
	"res://resources/config/plant_defense/grape_arc_tower.tres"
)
const STATION_SCENE := preload(
	"res://scene/plant_defense/wood_processing_station.tscn"
)
const STATION_CONFIG := preload(
	"res://resources/config/plant_defense/wood_processing_station.tres"
)

const SUPPORT_MULTIPLIER := 0.8
const TIMER_TOLERANCE_SECONDS := 0.035

var failures: Array[String] = []
var fixture: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "SupportBuildingMultiplierSmokeFixture"
	root.add_child(fixture)
	current_scene = fixture
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	await process_frame

	_test_source_aggregates()
	_test_repeat_attack_cycle_consumers()
	_test_grape_cycle_retry_and_charge_isolation()
	_test_production_duration_consumer()

	fixture.queue_free()
	await process_frame
	if failures.is_empty():
		print("SUPPORT_BUILDING_MULTIPLIER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_source_aggregates() -> void:
	var plant := PlantDefense.new()
	var changes: Array[Vector2] = []
	plant.attack_interval_multiplier_changed.connect(
		func(previous: float, current: float) -> void:
			changes.append(Vector2(previous, current))
	)
	_expect(
		not plant.add_attack_interval_multiplier_modifier(0, SUPPORT_MULTIPLIER)
		and not plant.add_attack_interval_multiplier_modifier(1, NAN),
		"攻击间隔倍率必须拒绝无来源与非有限输入。"
	)
	_expect(
		plant.add_attack_interval_multiplier_modifier(11, SUPPORT_MULTIPLIER)
		and is_equal_approx(plant.get_attack_interval_multiplier(), 0.8)
		and is_equal_approx(plant.get_effective_attack_interval(4.0), 3.2),
		"单个支援来源必须把4秒攻击周期变为3.2秒。"
	)
	_expect(
		plant.add_attack_interval_multiplier_modifier(12, 0.9)
		and is_equal_approx(plant.get_attack_interval_multiplier(), 0.8)
		and changes.size() == 1,
		"多个攻击来源必须取最短倍率且不得为无效变化重复发信号。"
	)
	_expect(
		plant.add_attack_interval_multiplier_modifier(12, 0.7)
		and is_equal_approx(plant.get_attack_interval_multiplier(), 0.7)
		and plant.remove_attack_interval_multiplier_modifier(12)
		and is_equal_approx(plant.get_attack_interval_multiplier(), 0.8)
		and plant.remove_attack_interval_multiplier_modifier(11)
		and is_equal_approx(plant.get_attack_interval_multiplier(), 1.0)
		and changes.size() == 4,
		"攻击倍率来源更新与移除必须按当前最强来源平滑回退。"
	)
	plant.free()


func _test_repeat_attack_cycle_consumers() -> void:
	var agave := AGAVE_SCENE.instantiate() as AgaveCannon
	var corn := CORN_SCENE.instantiate() as CornMachineGun
	fixture.add_child(agave)
	fixture.add_child(corn)
	agave.setup(AGAVE_CONFIG, null, [])
	corn.setup(CORN_CONFIG, null, [])
	agave.idle_aim_timer.stop()
	corn.idle_aim_timer.stop()
	corn.aim_return_timer.stop()

	var agave_base := AGAVE_CONFIG.get_attack_interval()
	agave.attack_timer.stop()
	agave.attack_timer.start(agave_base)
	var agave_before := agave.attack_timer.time_left
	agave.add_attack_interval_multiplier_modifier(101, SUPPORT_MULTIPLIER)
	_expect(
		_is_close(
			agave.attack_timer.time_left,
			agave_before * SUPPORT_MULTIPLIER
		)
		and is_equal_approx(
			agave.attack_timer.wait_time,
			agave_base * SUPPORT_MULTIPLIER
		),
		"龙舌兰塔进入支援范围时必须保留已完成攻击周期比例。"
	)
	var agave_short_before := agave.attack_timer.time_left
	agave.remove_attack_interval_multiplier_modifier(101)
	_expect(
		_is_close(
			agave.attack_timer.time_left,
			agave_short_before / SUPPORT_MULTIPLIER
		)
		and is_equal_approx(agave.attack_timer.wait_time, agave_base),
		"龙舌兰塔离开支援范围时必须按相同比例恢复剩余周期。"
	)

	var corn_base := CORN_CONFIG.get_attack_interval()
	var burst_interval_before := corn.configured_burst_shot_interval
	corn.attack_timer.stop()
	corn.attack_timer.start(corn_base)
	var corn_before := corn.attack_timer.time_left
	corn.add_attack_interval_multiplier_modifier(102, SUPPORT_MULTIPLIER)
	_expect(
		_is_close(
			corn.attack_timer.time_left,
			corn_before * SUPPORT_MULTIPLIER
		)
		and is_equal_approx(
			corn.attack_timer.wait_time,
			corn_base * SUPPORT_MULTIPLIER
		)
		and is_equal_approx(
			corn.configured_burst_shot_interval,
			burst_interval_before
		),
		"玉米塔只能缩短轮次间隔，六连发内部间隔必须保持原值。"
	)

	agave.queue_free()
	corn.queue_free()


func _test_grape_cycle_retry_and_charge_isolation() -> void:
	var grape := GRAPE_SCENE.instantiate() as GrapeArcTower
	fixture.add_child(grape)
	grape.setup(GRAPE_CONFIG, null, [])
	grape.idle_scan_timer.stop()
	var base_interval := GRAPE_CONFIG.get_attack_interval()
	grape.attack_timer.stop()
	grape.attack_timer_mode = GrapeArcTower.AttackTimerMode.ATTACK_CYCLE
	grape.attack_timer.start(base_interval)
	grape.release_timer.start(GRAPE_CONFIG.charge_seconds)
	var cycle_before := grape.attack_timer.time_left
	var release_before := grape.release_timer.time_left
	grape.add_attack_interval_multiplier_modifier(103, SUPPORT_MULTIPLIER)
	_expect(
		_is_close(
			grape.attack_timer.time_left,
			cycle_before * SUPPORT_MULTIPLIER
		)
		and is_equal_approx(
			grape.attack_timer.wait_time,
			base_interval * SUPPORT_MULTIPLIER
		)
		and _is_close(grape.release_timer.time_left, release_before),
		"葡萄塔必须只等比例缩短攻击轮次，蓄能释放计时不能被支援改写。"
	)

	grape.attack_timer_mode = GrapeArcTower.AttackTimerMode.TARGET_RETRY
	grape.attack_timer.start(GrapeArcTower.TARGET_RETRY_SECONDS)
	var retry_before := grape.attack_timer.time_left
	grape.remove_attack_interval_multiplier_modifier(103)
	_expect(
		_is_close(grape.attack_timer.time_left, retry_before)
		and is_equal_approx(
			grape.attack_timer.wait_time,
			GrapeArcTower.TARGET_RETRY_SECONDS
		)
		and _is_close(grape.release_timer.time_left, release_before),
		"葡萄塔的无目标重试与已提交蓄能必须保持固定时长。"
	)
	grape.queue_free()


func _test_production_duration_consumer() -> void:
	var station := STATION_SCENE.instantiate() as ProductionBuilding
	fixture.add_child(station)
	station.setup(STATION_CONFIG, null, [])
	station.select_recipe(&"wood_to_plank")
	var recipe := station.get_active_recipe()
	_expect(recipe != null and is_equal_approx(recipe.duration_seconds, 10.0),
		"生产倍率测试必须取得木材锯切的10秒配方。")
	if recipe == null:
		station.queue_free()
		return

	station.progress_elapsed_seconds = 2.0
	station.production_revision = 40
	station.call("_sync_visual_progress_clock")
	var revision_before_modifier := station.production_revision
	station.add_production_duration_multiplier_modifier(201, SUPPORT_MULTIPLIER)
	_expect(
		station.production_revision == revision_before_modifier
		and is_equal_approx(
			station.get_production_duration_multiplier(),
			SUPPORT_MULTIPLIER
		)
		and is_equal_approx(
			station.get_effective_production_duration_seconds(recipe),
			8.0
		)
		and is_equal_approx(station.get_remaining_seconds(), 6.4),
		"生产支援必须缩短实际剩余墙钟时间，且倍率变化不能伪造生产revision。"
	)
	station.add_production_duration_multiplier_modifier(202, 0.9)
	_expect(
		is_equal_approx(
			station.get_production_duration_multiplier(),
			SUPPORT_MULTIPLIER
		)
		and station.production_revision == revision_before_modifier,
		"多个生产支援来源必须取最短时长倍率而不可叠乘。"
	)
	station.advance_shared_production_tick(4.0)
	_expect(
		is_equal_approx(station.progress_elapsed_seconds, 7.0)
		and station.production_revision == revision_before_modifier + 1
		and is_equal_approx(station.get_remaining_seconds(), 2.4),
		"0.8倍生产时长下4秒必须推进5个配方工作秒，并报告一致的2.4秒剩余时间。"
	)
	var visual_progress := station.get_visual_progress_elapsed_seconds()
	_expect(
		_is_close(
			station.get_visual_remaining_seconds(),
			(recipe.duration_seconds - visual_progress) * SUPPORT_MULTIPLIER
		),
		"生产面板投影进度与显示剩余时间必须使用同一生产倍率。"
	)
	var revision_before_removal := station.production_revision
	station.remove_production_duration_multiplier_modifier(201)
	_expect(
		is_equal_approx(station.get_production_duration_multiplier(), 0.9)
		and station.production_revision == revision_before_removal
		and is_equal_approx(station.get_remaining_seconds(), 2.7),
		"移除最强生产来源后必须回退到次强来源且不增加生产revision。"
	)
	station.remove_production_duration_multiplier_modifier(202)
	_expect(
		is_equal_approx(station.get_production_duration_multiplier(), 1.0)
		and station.production_revision == revision_before_removal
		and is_equal_approx(station.get_remaining_seconds(), 3.0),
		"移除最后一个生产来源后必须恢复原速且保持权威生产revision。"
	)
	station.queue_free()


func _is_close(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= TIMER_TOLERANCE_SECONDS


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
