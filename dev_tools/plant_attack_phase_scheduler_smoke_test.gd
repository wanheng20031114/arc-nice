extends SceneTree

# Match the production class bootstrap before loading the standalone towers.
const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const PHASE_SCHEDULER := preload(
	"res://scene/plant_defense/plant_attack_phase_scheduler.gd"
)
const AGAVE_SCENE := preload("res://scene/plant_defense/agave_cannon.tscn")
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const BAMBOO_SCENE := preload("res://scene/plant_defense/bamboo_mortar.tscn")
const BAMBOO_CONFIG := preload(
	"res://resources/config/plant_defense/bamboo_mortar.tres"
)

const TOWER_COUNT := 100
const PHYSICS_FPS := 60.0
const TIMER_EPSILON_SECONDS := 0.003

var failures: Array[String] = []


class TargetRequestPort:
	extends TowerPlantGameplayTestPort

	var request_count := 0
	var cancel_count := 0

	func request_bamboo_mortar_target(
		_owner: Node2D,
		_minimum_range: float,
		_maximum_range: float,
		_callback: Callable
	) -> bool:
		request_count += 1
		return true

	func cancel_bamboo_mortar_target_request(_owner: Node) -> void:
		cancel_count += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_pure_phase_distribution()
	_test_stable_identity_resolution()
	await _test_runtime_first_cycle_and_proxy_guards()

	if failures.is_empty():
		print("PLANT_ATTACK_PHASE_SCHEDULER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_pure_phase_distribution() -> void:
	_expect(TOWER_SCENE != null, "塔防主场景必须可加载。")
	var agave_buckets: Dictionary[int, int] = {}
	var bamboo_buckets: Dictionary[int, int] = {}
	var agave_peak := 0
	var bamboo_peak := 0
	for phase_identity in range(1, TOWER_COUNT + 1):
		var agave_delay := AgaveCannon.calculate_initial_attack_delay_seconds(
			AgaveCannon.DEFAULT_ATTACK_INTERVAL,
			phase_identity
		)
		var bamboo_delay := BambooMortar.calculate_initial_attack_delay_seconds(
			BambooMortar.WINDUP_DURATION_SECONDS,
			phase_identity
		)
		_expect(
			is_equal_approx(
				agave_delay,
				PHASE_SCHEDULER.calculate_initial_delay_seconds(
					AgaveCannon.DEFAULT_ATTACK_INTERVAL,
					phase_identity,
					AgaveCannon.INITIAL_ATTACK_DELAY_MIN_SECONDS
				)
			),
			"Agave 必须委托共享攻击相位调度器。"
		)
		var agave_bucket := floori(agave_delay * PHYSICS_FPS)
		var bamboo_bucket := floori(bamboo_delay * PHYSICS_FPS)
		agave_buckets[agave_bucket] = agave_buckets.get(agave_bucket, 0) + 1
		bamboo_buckets[bamboo_bucket] = bamboo_buckets.get(bamboo_bucket, 0) + 1

	for count in agave_buckets.values():
		agave_peak = maxi(agave_peak, int(count))
	for count in bamboo_buckets.values():
		bamboo_peak = maxi(bamboo_peak, int(count))
	_expect(
		agave_buckets.size() >= 85 and agave_peak <= 2,
		(
			"100座 Agave 必须分散到至少85个60Hz帧且单帧峰值不超过2；"
			+ "实际为%d帧/峰值%d。"
		) % [agave_buckets.size(), agave_peak]
	)
	_expect(
		bamboo_buckets.size() >= 90 and bamboo_peak <= 2,
		(
			"100座 Bamboo 必须分散到至少90个60Hz帧且单帧峰值不超过2；"
			+ "实际为%d帧/峰值%d。"
		) % [bamboo_buckets.size(), bamboo_peak]
	)

	var stable_a := PHASE_SCHEDULER.calculate_initial_delay_seconds(2.0, 7123, 0.05)
	var stable_b := PHASE_SCHEDULER.calculate_initial_delay_seconds(2.0, 7123, 0.05)
	var distinct := PHASE_SCHEDULER.calculate_initial_delay_seconds(2.0, 7124, 0.05)
	_expect(
		is_equal_approx(stable_a, stable_b) and not is_equal_approx(stable_a, distinct),
		"相同 net_id 必须得到相同相位，不同连续 ID 必须被分散。"
	)

	var boosted_agave_interval := (
		AgaveCannon.DEFAULT_ATTACK_INTERVAL
		* PlantDefense.MIN_ATTACK_INTERVAL_MULTIPLIER
	)
	var boosted_bamboo_interval := (
		BambooMortar.WINDUP_DURATION_SECONDS
		* PlantDefense.MIN_ATTACK_INTERVAL_MULTIPLIER
	)
	var boosted_agave_delay := AgaveCannon.calculate_initial_attack_delay_seconds(
		boosted_agave_interval,
		99
	)
	var boosted_bamboo_delay := BambooMortar.calculate_initial_attack_delay_seconds(
		boosted_bamboo_interval,
		99
	)
	_expect(
		boosted_agave_delay >= AgaveCannon.INITIAL_ATTACK_DELAY_MIN_SECONDS
		and boosted_agave_delay <= boosted_agave_interval
		and boosted_bamboo_delay >= BambooMortar.INITIAL_ATTACK_DELAY_MIN_SECONDS
		and boosted_bamboo_delay <= boosted_bamboo_interval,
		"最高射速边界下，首次延迟必须仍落在对应的有效攻击间隔内。"
	)
	_expect(
		is_equal_approx(
			PHASE_SCHEDULER.calculate_initial_delay_seconds(0.01, 7, 0.05),
			0.01
		),
		"有效间隔短于最小错峰延迟时必须收敛到完整间隔。"
	)


func _test_stable_identity_resolution() -> void:
	var first := Node2D.new()
	var second := Node2D.new()
	first.position = Vector2(128.2, 63.7)
	second.position = Vector2(-512.0, 400.0)
	first.set_meta(&"net_id", 81234)
	second.set_meta(&"net_id", 81234)
	_expect(
		PHASE_SCHEDULER.resolve_plant_identity(first)
		== PHASE_SCHEDULER.resolve_plant_identity(second),
		"正 net_id 必须覆盖本地坐标，保证房主、代理与存档恢复相位一致。"
	)
	first.remove_meta(&"net_id")
	second.remove_meta(&"net_id")
	second.position = first.position
	var position_identity := PHASE_SCHEDULER.resolve_plant_identity(first)
	_expect(
		position_identity == PHASE_SCHEDULER.resolve_plant_identity(second),
		"无 net_id 的单机建筑必须按稳定落位坐标得到相同身份。"
	)
	second.position += Vector2(32.0, 0.0)
	_expect(
		position_identity != PHASE_SCHEDULER.resolve_plant_identity(second),
		"不同网格位置必须形成不同的单机攻击相位身份。"
	)
	first.free()
	second.free()


func _test_runtime_first_cycle_and_proxy_guards() -> void:
	var fixture := Node2D.new()
	fixture.name = "PlantAttackPhaseSchedulerFixture"
	root.add_child(fixture)
	var request_port := TargetRequestPort.new()
	request_port.name = "TargetRequestPort"
	fixture.add_child(request_port)

	var agave_authority := AGAVE_SCENE.instantiate() as AgaveCannon
	var agave_proxy := AGAVE_SCENE.instantiate() as AgaveCannon
	var bamboo_authority := BAMBOO_SCENE.instantiate() as BambooMortar
	var bamboo_proxy := BAMBOO_SCENE.instantiate() as BambooMortar
	for tower in [agave_authority, agave_proxy, bamboo_authority, bamboo_proxy]:
		fixture.add_child(tower)

	agave_authority.set_meta(&"net_id", 91001)
	agave_proxy.set_meta(&"net_id", 91001)
	bamboo_authority.set_meta(&"net_id", 92001)
	bamboo_proxy.set_meta(&"net_id", 92001)
	bamboo_authority.bind_gameplay_context(null, request_port)
	bamboo_proxy.bind_gameplay_context(null, request_port)
	agave_authority.setup(AGAVE_CONFIG, null, [], false)
	agave_proxy.setup(AGAVE_CONFIG, null, [], true)
	bamboo_authority.setup(BAMBOO_CONFIG, null, [], false)
	bamboo_proxy.setup(BAMBOO_CONFIG, null, [], true)

	_expect(
		not agave_authority.attack_timer.is_stopped()
		and absf(
			agave_authority.attack_timer.time_left
			- agave_authority.get_initial_attack_delay_seconds()
		) < TIMER_EPSILON_SECONDS
		and is_equal_approx(
			agave_authority.attack_timer.wait_time,
			AgaveCannon.DEFAULT_ATTACK_INTERVAL
		),
		"Agave 权威实例仅首次错峰，后续 repeating 周期必须仍为完整2秒。"
	)
	_expect(
		agave_proxy.attack_timer.is_stopped(),
		"Agave 多人代理禁止启动本地攻击计时器。"
	)
	_expect(
		request_port.request_count == 0
		and bamboo_authority._initial_attack_phase_pending
		and not bamboo_authority.attack_timer.is_stopped()
		and absf(
			bamboo_authority.attack_timer.time_left
			- bamboo_authority.get_initial_attack_delay_seconds()
		) < TIMER_EPSILON_SECONDS
		and is_equal_approx(
			bamboo_authority.attack_timer.wait_time,
			BambooMortar.TARGET_RETRY_INTERVAL_SECONDS
		),
		"Bamboo 权威实例必须先错峰，期间不得同步请求目标且不得改写2秒重试配置。"
	)
	bamboo_authority.call("_try_begin_windup")
	_expect(
		request_port.request_count == 0,
		"Bamboo 初始相位未到期时必须拒绝旁路目标请求。"
	)
	_expect(
		bamboo_proxy.attack_timer.is_stopped()
		and not bamboo_proxy._initial_attack_phase_pending,
		"Bamboo 多人代理禁止启动攻击相位或目标请求。"
	)
	bamboo_proxy.call("_on_attack_timer_timeout")
	_expect(
		request_port.request_count == 0,
		"即使代理收到错误的本地 timeout，也不得执行目标请求。"
	)

	var agave_time_left_before_boost := agave_authority.attack_timer.time_left
	agave_authority.add_attack_interval_multiplier_modifier(7001, 0.05)
	_expect(
		absf(
			agave_authority.attack_timer.time_left
			- agave_time_left_before_boost * 0.05
		) < TIMER_EPSILON_SECONDS
		and is_equal_approx(
			agave_authority.attack_timer.wait_time,
			AgaveCannon.DEFAULT_ATTACK_INTERVAL * 0.05
		),
		"Agave 首次错峰遇到最高射速强化时必须保留已完成比例，并更新后续完整周期。"
	)

	var bamboo_time_left_before_boost := bamboo_authority.attack_timer.time_left
	bamboo_authority.add_attack_interval_multiplier_modifier(7002, 0.05)
	_expect(
		absf(
			bamboo_authority.attack_timer.time_left
			- bamboo_time_left_before_boost * 0.05
		) < TIMER_EPSILON_SECONDS
		and is_equal_approx(
			bamboo_authority.attack_timer.wait_time,
			BambooMortar.TARGET_RETRY_INTERVAL_SECONDS
		),
		"Bamboo 只可重定时尚未触发的首次相位，固定2秒重试配置不得被强化污染。"
	)
	bamboo_authority.attack_timer.stop()
	bamboo_authority.call("_on_attack_timer_timeout")
	_expect(
		request_port.request_count == 1
		and not bamboo_authority._initial_attack_phase_pending
		and bamboo_authority._target_request_pending
		and bamboo_authority.attack_timer.is_stopped(),
		"Bamboo 首次相位到期后必须立即进入原目标请求链，不添加额外攻击间隔。"
	)

	fixture.queue_free()
	for _cleanup_frame in range(3):
		await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
