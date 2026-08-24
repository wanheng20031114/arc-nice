extends SceneTree

## Structural contract for the reusable simple-chase layered runner. Detailed
## gameplay parity remains covered by the ShieldBearer and fire-ranged Yuanshi
## semantic regressions; this guard prevents either family from copying or
## silently bypassing the shared phase/rollback contract again.

const SIMPLE_CHASE_SCRIPT := preload(
	"res://scene/enemy/simple_chase_layered_enemy.gd"
)
const SHIELD_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_shield_bearer.tres"
)
const SHIELD_ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_shield_bearer_elite.tres"
)
const YUANSHI_BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const YUANSHI_FIRE_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"
)
const YUANSHI_GUARDIAN_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_guardian.tres"
)
const YUANSHI_GREEN_SHELL_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_green_shell.tres"
)
const STONE_YUANSHI_GUARDIAN_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_yuanshi_insect_guardian.tres"
)
const STONE_YUANSHI_GREEN_SHELL_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_yuanshi_insect_green_shell.tres"
)

const REQUIRED_PHASE_METHODS: Array[StringName] = [
	&"simulate_layered_area_event_phase",
	&"simulate_trusted_layered_area_event_phase",
	&"simulate_layered_area_decision_phase",
	&"simulate_trusted_layered_area_decision_phase",
	&"simulate_layered_area_motion_phase",
	&"simulate_trusted_layered_area_motion_phase",
	&"get_next_layered_area_decision_physics_frame",
	&"get_layered_area_planned_displacement",
	&"prepare_layered_area_authoritative_simulation",
	&"request_layered_area_urgent_decision",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_expect(
		SIMPLE_CHASE_SCRIPT != null,
		"The reusable simple-chase layered script must preload."
	)
	for config in [
		SHIELD_CONFIG,
		SHIELD_ELITE_CONFIG,
		YUANSHI_BASIC_CONFIG,
		YUANSHI_FIRE_CONFIG,
		YUANSHI_GUARDIAN_CONFIG,
		YUANSHI_GREEN_SHELL_CONFIG,
		STONE_YUANSHI_GUARDIAN_CONFIG,
		STONE_YUANSHI_GREEN_SHELL_CONFIG,
	]:
		_verify_layered_runner(config)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"layered_configs": 8,
		"failures": failures.duplicate(),
	}
	print(
		"SIMPLE_CHASE_LAYERED_ENEMY_CONTRACT_JSON %s"
		% JSON.stringify(result)
	)
	if failures.is_empty():
		print("SIMPLE_CHASE_LAYERED_ENEMY_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_layered_runner(config: EnemyConfig) -> void:
	var enemy := config.enemy_scene.instantiate() as Enemy
	var label := config.resource_path
	_expect(enemy != null, "%s must instantiate its authored enemy scene." % label)
	if enemy == null:
		return
	_expect(
		_inherits_script(enemy.get_script() as Script, SIMPLE_CHASE_SCRIPT),
		"%s must inherit the shared simple-chase runner." % label
	)
	_expect(
		enemy.supports_centralized_authoritative_simulation()
		and enemy.supports_layered_area_authoritative_simulation()
		and enemy.supports_dynamic_enemy_targeting()
		and enemy.supports_indexed_touch_authority()
		and enemy.uses_layered_area_physics_phase_decisions()
		and enemy.uses_trusted_layered_phase_entrypoints(),
		"%s must expose the complete shared layered capability contract." % label
	)
	for method_name in REQUIRED_PHASE_METHODS:
		_expect(
			enemy.has_method(method_name),
			"%s is missing shared phase method %s." % [label, method_name]
		)
	_verify_rollback_reset(enemy, label)
	_verify_navigation_deadline(enemy, label)
	enemy.free()


func _verify_rollback_reset(enemy: Enemy, label: String) -> void:
	if not _inherits_script(enemy.get_script() as Script, SIMPLE_CHASE_SCRIPT):
		return
	var chase_enemy: Variant = enemy
	var preserved_target := Node2D.new()
	chase_enemy.objective_target = preserved_target
	chase_enemy.layered_area_planned_move_direction = Vector2(3.0, -4.0)
	chase_enemy.layered_area_last_can_move = true
	chase_enemy.layered_area_motion_state_known = true
	chase_enemy.layered_area_decision_urgent = false
	chase_enemy.layered_area_last_event_tick = 91
	chase_enemy.layered_area_event_phase_sleeping = true
	chase_enemy.layered_area_event_sleep_until_physics_frame = 123
	chase_enemy.layered_touch_damage_projected_ticks_since_event = 7
	chase_enemy.layered_area_motion_phase_due = true

	chase_enemy.prepare_layered_area_authoritative_simulation()
	_expect(
		chase_enemy.objective_target == preserved_target
		and chase_enemy.layered_area_planned_move_direction == Vector2.ZERO
		and not chase_enemy.layered_area_last_can_move
		and not chase_enemy.layered_area_motion_state_known
		and chase_enemy.layered_area_decision_urgent
		and chase_enemy.layered_area_last_event_tick == -1
		and not chase_enemy.layered_area_event_phase_sleeping
		and chase_enemy.layered_area_event_sleep_until_physics_frame == -1
		and chase_enemy.layered_touch_damage_projected_ticks_since_event == 0
		and not chase_enemy.layered_area_motion_phase_due,
		"%s rollback preparation must reset phase state without discarding the dynamic target."
		% label
	)
	preserved_target.free()
	chase_enemy.objective_target = null


func _verify_navigation_deadline(enemy: Enemy, label: String) -> void:
	if not _inherits_script(enemy.get_script() as Script, SIMPLE_CHASE_SCRIPT):
		return
	var chase_enemy: Variant = enemy
	var target := Node2D.new()
	var after_frame := Engine.get_physics_frames() + 20
	chase_enemy.objective_target = target
	chase_enemy.layered_area_decision_interval_frames = 6
	chase_enemy.layered_area_motion_state_known = true
	chase_enemy.layered_area_last_can_move = true
	chase_enemy.navigation_refresh_deferred = false
	chase_enemy.cached_navigation_move_direction = Vector2.RIGHT
	chase_enemy.navigation_next_refresh_physics_frame = after_frame + 2
	chase_enemy.touch_damage_cooldown_left = 0.5
	_expect(
		not bool(chase_enemy.call(&"_can_enter_layered_area_event_sleep")),
		"%s must not freeze an observable touch cooldown after contact exits."
		% label
	)
	var full_decision_frame := _next_cadence_frame(
		after_frame,
		chase_enemy.get_layered_area_decision_interval_frames(),
		chase_enemy.get_layered_area_decision_phase_offset()
	)
	_expect(
		chase_enemy.get_next_layered_area_decision_physics_frame(after_frame)
		== mini(full_decision_frame, after_frame + 2),
		"%s must wake at the cached navigation deadline before its full decision cadence."
		% label
	)
	chase_enemy.navigation_refresh_deferred = true
	_expect(
		chase_enemy.get_next_layered_area_decision_physics_frame(after_frame)
		== mini(full_decision_frame, after_frame + 1),
		"%s must retry a deferred navigation decision on the next physics frame."
		% label
	)
	target.free()
	chase_enemy.objective_target = null


func _inherits_script(instance_script: Script, expected_script: Script) -> bool:
	var current_script := instance_script
	while current_script != null:
		if current_script == expected_script:
			return true
		current_script = current_script.get_base_script()
	return false


func _next_cadence_frame(after_frame: int, interval: int, offset: int) -> int:
	var next_frame := after_frame + 1
	var safe_interval := maxi(interval, 1)
	if safe_interval <= 1:
		return next_frame
	var remainder := posmod(next_frame + offset, safe_interval)
	if remainder != 0:
		next_frame += safe_interval - remainder
	return next_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
