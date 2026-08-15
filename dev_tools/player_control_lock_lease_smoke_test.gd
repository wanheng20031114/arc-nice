extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const MODAL_OWNER := &"smoke_modal"
const SECOND_MODAL_OWNER := &"smoke_second_modal"
const FATE_OWNER := &"smoke_fate"

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	var fixture := Node2D.new()
	root.add_child(fixture)
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	await process_frame

	_test_overlapping_control_owners(player)
	_test_death_and_modal_owners(player)
	_test_world_movement_and_fate_owners(player)
	_test_legacy_api_is_isolated_owner(player)

	fixture.queue_free()
	await process_frame
	if failures.is_empty():
		print("PLAYER_CONTROL_LOCK_LEASE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_overlapping_control_owners(player: Player) -> void:
	player.set_control_lock(MODAL_OWNER, true)
	player.set_control_lock(SECOND_MODAL_OWNER, true)
	player.set_control_lock(MODAL_OWNER, true)
	_expect(player.controls_locked, "重复获取控制锁必须幂等并保持锁定。")
	player.set_control_lock(MODAL_OWNER, false)
	_expect(
		player.controls_locked,
		"一个 modal 释放控制锁时，不得解除另一个 modal 的锁。"
	)
	player.set_control_lock(SECOND_MODAL_OWNER, false)
	_expect(not player.controls_locked, "最后一个控制锁 owner 释放后才允许移动。")


func _test_death_and_modal_owners(player: Player) -> void:
	player.set_control_lock(MODAL_OWNER, true)
	player.apply_multiplayer_death_state()
	player.set_control_lock(MODAL_OWNER, false)
	_expect(
		player.controls_locked and player.is_dead,
		"玩家死亡后关闭 modal 不得清除死亡控制锁。"
	)
	player.revive_multiplayer(Vector2.ZERO)
	_expect(
		not player.controls_locked and not player.is_dead,
		"复活只能释放死亡 owner；没有其他 owner 时应恢复移动。"
	)


func _test_world_movement_and_fate_owners(player: Player) -> void:
	player.set_world_movement_mode(true, false)
	player.set_combat_action_lock(FATE_OWNER, true)
	player.set_world_movement_mode(false, false)
	_expect(
		player.are_combat_actions_locked(),
		"退出 world movement 时不得清除仍生效的 Fate 战斗锁。"
	)
	player.set_combat_action_lock(FATE_OWNER, false)
	_expect(
		not player.are_combat_actions_locked(),
		"最后一个战斗锁 owner 释放后才允许战斗输入。"
	)


func _test_legacy_api_is_isolated_owner(player: Player) -> void:
	player.set_control_lock(MODAL_OWNER, true)
	player.set_controls_locked(true)
	player.set_controls_locked(false)
	_expect(
		player.controls_locked,
		"旧 set_controls_locked API 只能释放自己的兼容 owner。"
	)
	player.set_control_lock(MODAL_OWNER, false)
	_expect(not player.controls_locked, "兼容 owner 测试结束后不得残留控制锁。")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
