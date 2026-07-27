extends SceneTree

## Contact-only fence combat is intentionally verified as a black-box physics
## contract.  Every damage assertion below follows a real Area2D/StaticBody2D
## overlap and the authored enemy state machine; this script never calls an
## enemy attack or a PlantDefense damage method directly.

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const SIMPLE_FENCE_SCENE := preload(
	"res://scene/plant_defense/simple_fence.tscn"
)
const SIMPLE_FENCE_CONFIG := preload(
	"res://resources/config/plant_defense/simple_fence.tres"
)
const PROACTIVE_OBJECTIVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)

const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const KNIGHT_CONFIG := preload(
	"res://resources/config/enemies/capoo_knight.tres"
)
const SWORDSMAN_CONFIG := preload(
	"res://resources/config/enemies/capoo_swordsman.tres"
)
const AK47_CONFIG := preload(
	"res://resources/config/enemies/capoo_ak47.tres"
)
const SMG_CONFIG := preload(
	"res://resources/config/enemies/capoo_smg.tres"
)
const RPG_CONFIG := preload(
	"res://resources/config/enemies/capoo_rpg.tres"
)
const MAGE_CONFIG := preload(
	"res://resources/config/enemies/capoo_mage.tres"
)
const SNIPER_CONFIG := preload(
	"res://resources/config/enemies/capoo_sniper.tres"
)
const FIRE_RANGED_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"
)
const FIRE_SORCERER_CONFIG := preload(
	"res://resources/config/enemies/fire_sorcerer.tres"
)
const FROST_SORCERER_CONFIG := preload(
	"res://resources/config/enemies/frost_sorcerer.tres"
)
const LIGHTNING_SORCERER_CONFIG := preload(
	"res://resources/config/enemies/lightning_sorcerer.tres"
)
const STONE_GOLEM_CONFIG := preload(
	"res://resources/config/enemies/stone_golem.tres"
)

const OBJECTIVE_OFFSET := Vector2(1600.0, 0.0)
const PLAYER_OFFSET := Vector2(0.0, 4000.0)
const FENCE_OFFSET := Vector2(64.0, 0.0)
const TEST_MOVE_SPEED := 160.0
const TEST_ATTACK_DAMAGE := 100
const CONTACT_TIMEOUT_FRAMES := 150
const DAMAGE_TIMEOUT_FRAMES := 480
const RESUME_TIMEOUT_FRAMES := 120
const ZERO_VELOCITY_EPSILON_SQUARED := 0.0001


class StraightPathfinder:
	extends Node

	var is_built: bool = true
	var query_count: int = 0


	func try_get_safe_navigation_step(
		from_global_position: Vector2,
		to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO,
		_traversal_types: int = DualGridTilemap.TraversalType.LAND
	) -> Dictionary:
		query_count += 1
		var direction := from_global_position.direction_to(to_global_position)
		return {
			"status": GridPathfinder.NavigationStepStatus.READY,
			"waypoint": from_global_position + direction * 64.0,
			"is_complete_route": true,
			"resolved_from_cell": Vector2i.ZERO,
			"next_cell": Vector2i.RIGHT,
			"used_start_recovery": false,
		}


var failures: Array[String] = []
var test_root: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "SimpleFenceContactCombatMatrixSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	var requested_case_filter := ""
	var user_arguments := OS.get_cmdline_user_args()
	if not user_arguments.is_empty():
		requested_case_filter = str(user_arguments[0])
	if requested_case_filter != "aux":
		await _verify_attack_family_matrix(requested_case_filter)
	if requested_case_filter.is_empty() or requested_case_filter == "aux":
		await _verify_stable_multi_fence_selection_and_removal_switch()
		await _verify_committed_target_is_pinned()
		await _verify_windup_removal_cancels_without_damage()
		await _verify_repeated_contact_signal_cleanup()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("SIMPLE_FENCE_CONTACT_COMBAT_MATRIX_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_attack_family_matrix(case_filter: String = "") -> void:
	var cases: Array[Dictionary] = [
		{
			"label": "基础原石虫",
			"config": BASIC_CONFIG,
			"uses_inherited_touch": true,
			"overrides": {},
		},
		{
			"label": "Knight",
			"config": KNIGHT_CONFIG,
			"uses_inherited_touch": false,
			"overrides": _melee_overrides(),
		},
		{
			"label": "Swordsman",
			"config": SWORDSMAN_CONFIG,
			"uses_inherited_touch": false,
			"overrides": _melee_overrides(),
		},
		{
			"label": "AK47",
			"config": AK47_CONFIG,
			"uses_inherited_touch": false,
			"overrides": {
				&"attack_range": 200.0,
				&"attack_windup": 0.05,
				&"burst_count": 1,
				&"burst_fire_interval": 0.01,
				&"attack_interval": 0.05,
				&"projectile_speed": 420.0,
				&"projectile_lifetime": 1.0,
				&"projectile_spawn_distance": 10.0,
			},
		},
		{
			"label": "SMG",
			"config": SMG_CONFIG,
			"uses_inherited_touch": false,
			"overrides": {
				&"fire_interval": 0.05,
				&"attack_range": 64.0,
				&"spread_angle_degrees": 0.0,
				&"projectile_speed": 420.0,
				&"projectile_lifetime": 1.0,
			},
		},
		{
			"label": "RPG",
			"config": RPG_CONFIG,
			"uses_inherited_touch": false,
			"overrides": {
				&"attack_range": 200.0,
				&"attack_windup": 0.05,
				&"attack_interval": 0.05,
				&"projectile_speed": 420.0,
				&"projectile_lifetime": 1.0,
				&"projectile_spawn_distance": 10.0,
				&"explosion_radius": 44.0,
			},
		},
		{
			"label": "Mage",
			"config": MAGE_CONFIG,
			"uses_inherited_touch": false,
			"overrides": {
				&"attack_range": 200.0,
				&"attack_windup": 0.05,
				&"attack_interval": 0.05,
				&"projectile_speed": 420.0,
				&"projectile_lifetime": 1.0,
				&"projectile_spawn_distance": 10.0,
				&"fireball_homing_turn_rate": 12.0,
			},
		},
		{
			"label": "Sniper",
			"config": SNIPER_CONFIG,
			"uses_inherited_touch": false,
			"overrides": {
				&"attack_range": 200.0,
				&"lock_duration": 0.05,
				&"attack_interval": 0.05,
			},
		},
		{
			"label": "Yuanshi FireRanged",
			"config": FIRE_RANGED_CONFIG,
			"uses_inherited_touch": false,
			"overrides": {
				&"attack_range": 200.0,
				&"attack_interval": 0.05,
				&"projectile_speed": 420.0,
				&"projectile_lifetime": 1.0,
				&"projectile_spawn_distance": 10.0,
			},
		},
		{
			"label": "Fire Sorcerer",
			"config": FIRE_SORCERER_CONFIG,
			"uses_inherited_touch": false,
			"overrides": {
				&"attack_range": 200.0,
				&"summon_duration": 0.05,
				&"attack_interval": 0.05,
				&"initial_attack_stagger_window": 0.0,
				&"projectile_speed": 420.0,
				&"projectile_lifetime": 1.0,
			},
		},
		{
			"label": "Frost Sorcerer",
			"config": FROST_SORCERER_CONFIG,
			"uses_inherited_touch": false,
			"overrides": {
				&"attack_range": 200.0,
				&"summon_duration": 0.05,
				&"attack_interval": 0.05,
				&"initial_attack_stagger_window": 0.0,
				&"projectile_speed": 420.0,
				&"projectile_lifetime": 1.0,
			},
		},
		{
			"label": "Lightning Sorcerer",
			"config": LIGHTNING_SORCERER_CONFIG,
			"uses_inherited_touch": false,
			"overrides": {
				&"attack_range": 200.0,
				&"chain_range": 32.0,
				&"max_chain_bounces": 0,
				&"windup_duration": 0.05,
				&"attack_interval": 0.05,
				&"initial_attack_stagger_window": 0.0,
			},
		},
		{
			"label": "Stone Golem",
			"config": STONE_GOLEM_CONFIG,
			"uses_inherited_touch": false,
			"overrides": _melee_overrides(),
		},
	]

	for case_index in range(cases.size()):
		if (
			not case_filter.is_empty()
			and not str(cases[case_index]["label"]).containsn(case_filter)
		):
			continue
		await _verify_attack_family_case(cases[case_index], case_index)


func _verify_attack_family_case(case_data: Dictionary, case_index: int) -> void:
	var label := str(case_data["label"])
	print("SIMPLE_FENCE_CONTACT_MATRIX_CASE ", label)
	var base_config := case_data["config"] as EnemyConfig
	var enemy_config := _make_test_enemy_config(
		base_config,
		case_data["overrides"] as Dictionary
	)
	_expect(enemy_config != null, "%s 测试配置必须可复制。" % label)
	if enemy_config == null:
		return

	var fixture := Node2D.new()
	fixture.name = "Family_%02d_%s" % [case_index, label]
	test_root.add_child(fixture)
	var origin := Vector2(0.0, float(case_index) * 256.0)
	var pathfinder := StraightPathfinder.new()
	fixture.add_child(pathfinder)
	var player := _spawn_player(fixture, origin + PLAYER_OFFSET)
	var objective := _spawn_proactive_objective(
		fixture,
		origin + OBJECTIVE_OFFSET
	)
	var fence := _spawn_fence(
		fixture,
		origin + FENCE_OFFSET,
		1000 + case_index
	)
	var enemy := _spawn_enemy(
		fixture,
		enemy_config,
		player,
		objective,
		pathfinder,
		origin
	)
	if player == null or objective == null or fence == null or enemy == null:
		_expect(false, "%s 必须完整实例化真实玩家、目标、围栏与敌人场景。" % label)
		await _dispose_fixture(fixture)
		return

	var expected_inherited_touch := bool(case_data["uses_inherited_touch"])
	_expect(
		bool(enemy.call("_uses_inherited_touch_damage"))
			== expected_inherited_touch,
		"%s 的接触伤害/独立武器归属必须符合生产实现。" % label
	)
	_expect(
		enemy.objective_target == objective,
		"%s 接触前必须保留远端主动 objective。" % label
	)

	var initial_position := enemy.global_position
	await _wait_physics_frames(5)
	_expect(
		enemy.global_position.distance_to(initial_position) > 0.25,
		"%s 接触前必须沿远端主动 objective 移动。" % label
	)
	_expect(
		enemy.objective_target == objective
		and enemy.objective_target != fence,
		"%s 接触前 objective 不得被 contact-only 围栏替换。" % label
	)

	var contacted := await _wait_for_real_fence_contact(
		enemy,
		fence,
		CONTACT_TIMEOUT_FRAMES
	)
	_expect(
		contacted,
		"%s 必须通过真实 TouchDamageArea/StaticBody2D overlap 接触围栏。" % label
	)
	if not contacted:
		await _dispose_fixture(fixture)
		return

	var fence_health_before := fence.current_health
	var zero_velocity_frames := 0
	var objective_was_stable := true
	var damage_seen := fence.current_health < fence.max_health
	var removal_seen := fence.is_removing or fence.is_dead
	for _frame_index in range(DAMAGE_TIMEOUT_FRAMES):
		await physics_frame
		if enemy.objective_target != objective or enemy.objective_target == fence:
			objective_was_stable = false
		if fence.is_removing or fence.is_dead:
			removal_seen = true
			break
		if enemy._has_player_contact():
			if enemy.velocity.length_squared() <= ZERO_VELOCITY_EPSILON_SQUARED:
				zero_velocity_frames += 1
			else:
				zero_velocity_frames = 0
		if fence.current_health < fence_health_before:
			damage_seen = true

	_expect(
		objective_was_stable,
		"%s 接触交战全程不得把围栏写入 objective_target。" % label
	)
	_expect(
		zero_velocity_frames >= 2,
		"%s 接触围栏后必须持续保持零速度，而非只停一个采样帧。" % label
	)
	_expect(
		damage_seen,
		"%s 必须经自身生产攻击状态机使围栏掉血。" % label
	)
	_expect(
		removal_seen,
		"%s 必须能经自身生产攻击状态机摧毁 500HP 围栏。" % label
	)

	var fence_instance_id := fence.get_instance_id()
	_expect(
		not enemy.touching_plant_removal_callbacks.has(fence_instance_id),
		"%s 摧毁围栏后必须立即释放 removal_started callback。" % label
	)
	var resume_origin := enemy.global_position
	var resumed := false
	for _resume_frame in range(RESUME_TIMEOUT_FRAMES):
		await physics_frame
		if enemy.objective_target != objective or enemy.objective_target == fence:
			objective_was_stable = false
		if (
			enemy.global_position.distance_to(resume_origin) > 0.5
			and enemy.velocity.length_squared()
				> ZERO_VELOCITY_EPSILON_SQUARED
		):
			resumed = true
			break
	_expect(
		resumed,
		"%s 摧毁接触围栏后必须恢复原 objective 路线。" % label
	)
	_expect(
		objective_was_stable and enemy.objective_target == objective,
		"%s 恢复移动后仍必须保留原主动 objective。" % label
	)

	await _dispose_fixture(fixture)


func _verify_stable_multi_fence_selection_and_removal_switch() -> void:
	var fixture := Node2D.new()
	fixture.name = "StableMultiFenceSelection"
	test_root.add_child(fixture)
	var origin := Vector2(0.0, 3800.0)
	var pathfinder := StraightPathfinder.new()
	fixture.add_child(pathfinder)
	var player := _spawn_player(fixture, origin + PLAYER_OFFSET)
	var objective := _spawn_proactive_objective(fixture, origin + OBJECTIVE_OFFSET)
	var knight_config := _make_test_enemy_config(
		KNIGHT_CONFIG,
		_melee_overrides()
	)
	knight_config.attack_damage = 1
	var enemy := _spawn_enemy(
		fixture,
		knight_config,
		player,
		objective,
		pathfinder,
		origin
	) as CapooKnight
	enemy.set_physics_process(false)
	var first := _spawn_fence(fixture, origin + Vector2(2.0, 0.0), 100)
	var second := _spawn_fence(fixture, origin + Vector2(5.0, 0.0), 1)
	var first_contact := await _wait_for_real_fence_contact(enemy, first, 20)
	var second_contact := await _wait_for_real_fence_contact(enemy, second, 20)
	_expect(
		first_contact and second_contact,
		"多围栏稳定选靶必须由两个真实物理 overlap 驱动。"
	)
	if not first_contact or not second_contact:
		await _dispose_fixture(fixture)
		return

	_expect(
		enemy.get_contact_combat_target() == first,
		"多围栏选择必须先按中心距离排序，不能让较小 net_id 越级。"
	)

	first.global_position = origin + Vector2(4.0, 0.0)
	second.global_position = origin + Vector2(-4.0, 0.0)
	first.set_meta(&"net_id", 20)
	second.set_meta(&"net_id", 10)
	await _wait_physics_frames(2)
	_expect(
		enemy.get_contact_combat_target() == second,
		"距离相同时必须选择较小的权威 net_id。"
	)

	first.set_meta(&"net_id", 30)
	second.set_meta(&"net_id", 30)
	var lower_instance := (
		first
		if first.get_instance_id() < second.get_instance_id()
		else second
	)
	var higher_instance := second if lower_instance == first else first
	_expect(
		enemy.get_contact_combat_target() == lower_instance,
		"距离和 net_id 相同时必须选择较小 instance_id。"
	)

	var removed_id := lower_instance.get_instance_id()
	var removed_callback: Callable = (
		enemy.touching_plant_removal_callbacks.get(removed_id, Callable())
	)
	lower_instance.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	_expect(
		enemy.get_contact_combat_target() == higher_instance,
		"当前 contact target 移除后必须稳定切换到剩余围栏。"
	)
	_expect(
		not enemy.touching_plants.has(removed_id)
		and not enemy.touching_plant_entry_distances.has(removed_id)
		and not enemy.touching_plant_removal_callbacks.has(removed_id),
		"当前 contact target 移除必须成对清理全部追踪字典。"
	)
	_expect(
		not removed_callback.is_valid()
		or not lower_instance.removal_started.is_connected(removed_callback),
		"当前 contact target 移除必须断开 removal_started。"
	)
	_expect(
		enemy.objective_target == objective
		and enemy.objective_target != first
		and enemy.objective_target != second,
		"多围栏选择和切换不得污染 objective_target。"
	)

	await _dispose_fixture(fixture)


func _verify_committed_target_is_pinned() -> void:
	var fixture := Node2D.new()
	fixture.name = "CommittedFenceTargetPinned"
	test_root.add_child(fixture)
	var origin := Vector2(0.0, 4100.0)
	var pathfinder := StraightPathfinder.new()
	fixture.add_child(pathfinder)
	var player := _spawn_player(fixture, origin + PLAYER_OFFSET)
	var objective := _spawn_proactive_objective(fixture, origin + OBJECTIVE_OFFSET)
	var knight_config := _make_test_enemy_config(
		KNIGHT_CONFIG,
		{
			&"attack_range": 64.0,
			&"attack_windup": 0.35,
			&"attack_interval": 0.05,
			&"slash_outer_radius": 64.0,
			&"slash_inner_radius": 0.0,
			&"slash_angle_degrees": 360.0,
			&"slash_damage_delay": 0.01,
			&"slash_duration": 0.05,
		}
	)
	var enemy := _spawn_enemy(
		fixture,
		knight_config,
		player,
		objective,
		pathfinder,
		origin
	) as CapooKnight
	var first := _spawn_fence(fixture, origin + Vector2(7.0, 0.0), 20)
	var second := _spawn_fence(fixture, origin + Vector2(-7.0, 0.0), 10)
	_expect(
		await _wait_for_real_fence_contact(enemy, first, 20),
		"固定攻击目标测试必须先真实接触第一面围栏。"
	)
	_expect(
		await _wait_for_real_fence_contact(enemy, second, 20),
		"固定攻击目标测试必须同时真实接触第二面围栏。"
	)
	var began_windup := false
	for _frame_index in range(30):
		await physics_frame
		if (
			enemy.combat_state == CapooKnight.CombatState.WINDUP
			and enemy.committed_attack_target == first
		):
			began_windup = true
			break
	_expect(began_windup, "Knight 必须对第一面接触围栏进入真实前摇。")
	if not began_windup:
		await _dispose_fixture(fixture)
		return

	# The enemy entered from the left, so the +7 fence was closer at commit.
	# Teleporting the real Area2D owner back to the exact midpoint leaves both
	# overlaps active and makes net_id the deterministic next-target tiebreaker.
	enemy.global_position = origin
	await _wait_physics_frames(2)
	_expect(
		enemy.get_contact_combat_target() == second,
		"新增更近围栏后，下一次 contact 解析必须选择第二面围栏。"
	)
	_expect(
		enemy.committed_attack_target == first,
		"已开始攻击的 committed target 必须固定，不能在前摇中改打新围栏。"
	)
	_expect(
		enemy.objective_target == objective,
		"固定 committed target 期间不得修改主动 objective。"
	)

	await _dispose_fixture(fixture)


func _verify_windup_removal_cancels_without_damage() -> void:
	var fixture := Node2D.new()
	fixture.name = "WindupRemovalCancellation"
	test_root.add_child(fixture)
	var origin := Vector2(0.0, 4400.0)
	var pathfinder := StraightPathfinder.new()
	fixture.add_child(pathfinder)
	var player := _spawn_player(fixture, origin + PLAYER_OFFSET)
	var objective := _spawn_proactive_objective(fixture, origin + OBJECTIVE_OFFSET)
	var knight_config := _make_test_enemy_config(
		KNIGHT_CONFIG,
		{
			&"attack_range": 64.0,
			&"attack_windup": 0.4,
			&"attack_interval": 0.05,
			&"slash_outer_radius": 64.0,
			&"slash_inner_radius": 0.0,
			&"slash_angle_degrees": 360.0,
			&"slash_damage_delay": 0.01,
			&"slash_duration": 0.05,
		}
	)
	var enemy := _spawn_enemy(
		fixture,
		knight_config,
		player,
		objective,
		pathfinder,
		origin
	) as CapooKnight
	var fence := _spawn_fence(fixture, origin + Vector2(7.0, 0.0), 42)
	_expect(
		await _wait_for_real_fence_contact(enemy, fence, 20),
		"前摇移除测试必须由真实物理接触开始。"
	)
	var began_windup := false
	for _frame_index in range(30):
		await physics_frame
		if (
			enemy.combat_state == CapooKnight.CombatState.WINDUP
			and enemy.committed_attack_target == fence
		):
			began_windup = true
			break
	_expect(began_windup, "前摇移除测试必须进入 Knight 生产 WINDUP 状态。")
	if not began_windup:
		await _dispose_fixture(fixture)
		return

	var health_before := fence.current_health
	var fence_id := fence.get_instance_id()
	var callback: Callable = enemy.touching_plant_removal_callbacks.get(
		fence_id,
		Callable()
	)
	fence.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	await _wait_physics_frames(2)
	_expect(
		enemy.committed_attack_target == null
		and enemy.combat_state == CapooKnight.CombatState.CHASE,
		"围栏在攻击前摇中移除时必须取消 committed attack。"
	)
	_expect(
		fence.current_health == health_before,
		"前摇中移除的围栏不得收到延迟或隐形伤害。"
	)
	_expect(
		not enemy.touching_plants.has(fence_id)
		and not enemy.touching_plant_removal_callbacks.has(fence_id)
		and (
			not callback.is_valid()
			or not fence.removal_started.is_connected(callback)
		),
		"前摇中移除必须同步解除接触记录与 removal_started 连接。"
	)
	_expect(
		enemy.objective_target == objective,
		"前摇取消后必须继续保留原主动 objective。"
	)

	await _dispose_fixture(fixture)


func _verify_repeated_contact_signal_cleanup() -> void:
	var fixture := Node2D.new()
	fixture.name = "RepeatedFenceContactCleanup"
	test_root.add_child(fixture)
	var origin := Vector2(0.0, 4700.0)
	var pathfinder := StraightPathfinder.new()
	fixture.add_child(pathfinder)
	var player := _spawn_player(fixture, origin + PLAYER_OFFSET)
	var objective := _spawn_proactive_objective(fixture, origin + OBJECTIVE_OFFSET)
	var knight_config := _make_test_enemy_config(
		KNIGHT_CONFIG,
		_melee_overrides()
	)
	knight_config.attack_damage = 1
	var enemy := _spawn_enemy(
		fixture,
		knight_config,
		player,
		objective,
		pathfinder,
		origin + Vector2(256.0, 0.0)
	) as CapooKnight
	enemy.set_physics_process(false)
	var fence := _spawn_fence(fixture, origin + Vector2(4.0, 0.0), 99)
	var fence_id := fence.get_instance_id()
	await _wait_physics_frames(2)

	for cycle in range(12):
		enemy.global_position = origin
		var entered := await _wait_for_real_fence_contact(enemy, fence, 20)
		_expect(entered, "第 %d 次进入必须产生真实 Area2D overlap。" % cycle)
		if not entered:
			break
		var callback: Callable = enemy.touching_plant_removal_callbacks.get(
			fence_id,
			Callable()
		)
		_expect(
			callback.is_valid()
			and fence.removal_started.is_connected(callback),
			"第 %d 次进入必须恰好登记有效 removal_started callback。" % cycle
		)

		enemy.global_position = origin + Vector2(256.0, 0.0)
		var exited := await _wait_for_real_fence_exit(enemy, fence, 20)
		_expect(exited, "第 %d 次离开必须产生真实 Area2D body_exited。" % cycle)
		_expect(
			not enemy.touching_plants.has(fence_id)
			and not enemy.touching_plant_entry_distances.has(fence_id)
			and not enemy.touching_plant_removal_callbacks.has(fence_id),
			"第 %d 次离开后全部接触字典必须清零。" % cycle
		)
		_expect(
			not callback.is_valid()
			or not fence.removal_started.is_connected(callback),
			"第 %d 次离开后 removal_started callback 必须断开。" % cycle
		)

	_expect(
		enemy.touching_plants.is_empty()
		and enemy.touching_plant_entry_distances.is_empty()
		and enemy.touching_plant_removal_callbacks.is_empty()
		and enemy.get_contact_combat_target() == null,
		"反复进入/离开后接触状态和 callback 字典必须完全为空。"
	)
	_expect(
		enemy.objective_target == objective,
		"反复接触测试不得改变主动 objective。"
	)

	await _dispose_fixture(fixture)


func _make_test_enemy_config(
	base_config: EnemyConfig,
	overrides: Dictionary
) -> EnemyConfig:
	if base_config == null:
		return null
	var test_config := base_config.duplicate(true) as EnemyConfig
	if test_config == null:
		return null
	test_config.move_speed = TEST_MOVE_SPEED
	test_config.attack_damage = TEST_ATTACK_DAMAGE
	for property_name in overrides:
		test_config.set(property_name, overrides[property_name])
	return test_config


func _melee_overrides() -> Dictionary:
	return {
		&"attack_range": 64.0,
		&"attack_windup": 0.05,
		&"attack_interval": 0.05,
		&"slash_outer_radius": 64.0,
		&"slash_inner_radius": 0.0,
		&"slash_angle_degrees": 360.0,
		&"slash_damage_delay": 0.01,
		&"slash_duration": 0.05,
	}


func _spawn_enemy(
	parent: Node2D,
	enemy_config: EnemyConfig,
	player: Player,
	objective: PlantDefense,
	pathfinder: Node,
	position: Vector2
) -> Enemy:
	if enemy_config == null or enemy_config.enemy_scene == null:
		return null
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	if enemy == null:
		return null
	parent.add_child(enemy)
	enemy.global_position = position
	enemy.setup(enemy_config, player, pathfinder)
	enemy.set_objective_target(objective)
	enemy.touch_damage_interval = 0.05
	enemy.navigation_update_interval_frames = 1
	enemy.combat_sense_update_interval_frames = 1
	if enemy.animated_sprite != null:
		enemy.animated_sprite.speed_scale = 4.0
	return enemy


func _spawn_player(parent: Node2D, position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	if player == null:
		return null
	parent.add_child(player)
	player.global_position = position
	player.set_physics_process(false)
	player.set_process(false)
	return player


func _spawn_proactive_objective(
	parent: Node2D,
	position: Vector2
) -> PlantDefense:
	var objective := PlantDefense.new()
	parent.add_child(objective)
	objective.global_position = position
	objective.setup(
		PROACTIVE_OBJECTIVE_CONFIG,
		null,
		[Vector2i(100, 100)]
	)
	return objective


func _spawn_fence(
	parent: Node2D,
	position: Vector2,
	net_id: int
) -> PlantDefense:
	var fence := SIMPLE_FENCE_SCENE.instantiate() as PlantDefense
	if fence == null:
		return null
	fence.position = parent.to_local(position)
	parent.add_child(fence)
	fence.global_position = position
	fence.set_meta(&"net_id", net_id)
	fence.setup(
		SIMPLE_FENCE_CONFIG,
		null,
		[Vector2i(net_id, 0)]
	)
	return fence


func _wait_for_real_fence_contact(
	enemy: Enemy,
	fence: PlantDefense,
	maximum_frames: int
) -> bool:
	if enemy == null or fence == null:
		return false
	var fence_id := fence.get_instance_id()
	for _frame_index in range(maximum_frames):
		await physics_frame
		if (
			enemy.touching_plants.has(fence_id)
			and enemy.touch_damage_area.overlaps_body(fence)
		):
			return true
	return false


func _wait_for_real_fence_exit(
	enemy: Enemy,
	fence: PlantDefense,
	maximum_frames: int
) -> bool:
	if enemy == null or fence == null:
		return false
	var fence_id := fence.get_instance_id()
	for _frame_index in range(maximum_frames):
		await physics_frame
		if (
			not enemy.touching_plants.has(fence_id)
			and not enemy.touch_damage_area.overlaps_body(fence)
		):
			return true
	return false


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(maxi(frame_count, 0)):
		await physics_frame


func _dispose_fixture(fixture: Node) -> void:
	if fixture == null or not is_instance_valid(fixture):
		return
	_disable_fixture_enemy_processing(fixture)
	# Authored projectiles are added to current_scene, not the fixture.  Retire
	# them before freeing their typed target reference so teardown cannot create
	# a false dangling-target error between physics ticks.
	for world_child in test_root.get_children():
		if world_child == fixture:
			continue
		world_child.set_physics_process(false)
		world_child.set_process(false)
		world_child.queue_free()
	await process_frame
	await physics_frame
	fixture.queue_free()
	await physics_frame
	await process_frame


func _disable_fixture_enemy_processing(node: Node) -> void:
	var enemy := node as Enemy
	if enemy != null:
		enemy.set_physics_process(false)
		enemy.set_process(false)
		enemy.set_objective_target(null)
	for child in node.get_children():
		_disable_fixture_enemy_processing(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
