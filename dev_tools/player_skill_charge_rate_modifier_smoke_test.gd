extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const CHARGED_JADE_PENDANT := preload(
	"res://resources/config/collectibles/collectible_charged_jade_pendant.tres"
)
const FIRST_TOWER_SOURCE := 101
const SECOND_TOWER_SOURCE := 202
const TOWER_BONUS_PER_SECOND := 0.5

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node2D.new()
	test_root.name = "PlayerSkillChargeRateModifierSmokeRoot"
	root.add_child(test_root)
	current_scene = test_root

	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "Player scene must instantiate for skill-charge modifier testing.")
	if player == null:
		await _finish(test_root)
		return
	test_root.add_child(player)
	await process_frame
	await physics_frame
	player.set_physics_process(false)
	_stop_audio_players(player)

	_test_base_and_tower_sources(player)
	await _test_collectible_and_tower_stacking(player, run_state)
	_test_lifecycle_and_snapshot_preservation(player)

	player.queue_free()
	await process_frame
	run_state.begin_new_run(&"weishidaier", false)
	await _finish(test_root)


func _test_base_and_tower_sources(player: Player) -> void:
	_expect(
		is_zero_approx(player.get_skill_charge_rate_modifier_total()),
		"A fresh player must have no dynamic skill-charge source bonus."
	)
	_expect_charge_after_one_second(player, 1.0, "Base skill-charge rate must remain 1.0/s.")

	_expect(
		player.set_skill_charge_rate_modifier(FIRST_TOWER_SOURCE, TOWER_BONUS_PER_SECOND),
		"The first tower source must be registered."
	)
	_expect(
		is_equal_approx(
			player.get_skill_charge_rate_modifier(FIRST_TOWER_SOURCE),
			TOWER_BONUS_PER_SECOND
		),
		"The public getter must return the registered source value."
	)
	_expect_charge_after_one_second(player, 1.5, "One tower must produce 1.5 skill charge/s.")

	_expect(
		player.set_skill_charge_rate_modifier(SECOND_TOWER_SOURCE, TOWER_BONUS_PER_SECOND),
		"A second distinct tower source must be registered."
	)
	_expect(
		is_equal_approx(player.get_skill_charge_rate_modifier_total(), 1.0),
		"Two tower sources must contribute an additive +1.0/s."
	)
	_expect_charge_after_one_second(player, 2.0, "Two towers must produce 2.0 skill charge/s.")

	_expect(
		not player.set_skill_charge_rate_modifier(
			FIRST_TOWER_SOURCE,
			TOWER_BONUS_PER_SECOND
		),
		"Registering the same source and value twice must be idempotent."
	)
	_expect(
		is_equal_approx(player.get_skill_charge_rate_modifier_total(), 1.0),
		"A repeated source must not increase the cached total."
	)
	_expect_charge_after_one_second(player, 2.0, "A repeated source must not double-stack.")

	_expect(
		player.set_skill_charge_rate_modifier(FIRST_TOWER_SOURCE, 0.75),
		"Updating one source must replace its previous value."
	)
	_expect(
		is_equal_approx(player.get_skill_charge_rate_modifier_total(), 1.25),
		"Replacing one source must update the cached total by only the delta."
	)
	_expect(
		player.remove_skill_charge_rate_modifier(FIRST_TOWER_SOURCE),
		"Removing the first source must succeed."
	)
	_expect(
		not player.remove_skill_charge_rate_modifier(FIRST_TOWER_SOURCE),
		"Removing an absent source must be idempotent."
	)
	_expect_charge_after_one_second(player, 1.5, "Removing one tower must leave the other tower active.")


func _test_collectible_and_tower_stacking(player: Player, run_state: RunStateStore) -> void:
	_expect(
		run_state.try_add_item(CHARGED_JADE_PENDANT),
		"The first charged jade pendant must fit in the inventory."
	)
	_expect(
		run_state.try_add_item(CHARGED_JADE_PENDANT),
		"The second charged jade pendant must fit in the inventory."
	)
	await process_frame
	_expect(
		is_equal_approx(player.collectible_skill_charge_bonus_per_second, 1.0),
		"Two charged jade pendants must retain their existing +1.0/s stack."
	)
	_expect(
		is_equal_approx(player.get_skill1_charge_rate_per_second(), 2.5),
		"Base, collectible and remaining tower bonuses must add to 2.5/s."
	)
	_expect_charge_after_one_second(
		player,
		2.5,
		"Collectible and dynamic tower bonuses must charge in the same update."
	)


func _test_lifecycle_and_snapshot_preservation(player: Player) -> void:
	player.apply_multiplayer_death_state()
	_expect(
		is_equal_approx(
			player.get_skill_charge_rate_modifier(SECOND_TOWER_SOURCE),
			TOWER_BONUS_PER_SECOND
		),
		"Death must not clear an external aura source before its owner removes it."
	)
	player.revive_multiplayer(Vector2.ZERO, player.max_health, 0.0)
	_expect(
		is_equal_approx(player.get_skill_charge_rate_modifier_total(), TOWER_BONUS_PER_SECOND),
		"Revival must preserve dynamic skill-charge sources."
	)

	player.apply_multiplayer_realtime_state(
		player.current_health,
		player.max_health,
		player.current_xirang,
		false,
		0.0,
		true,
		3.0,
		player.skill1_charge_duration,
		PickupConfig.PlayerFormMode.NORMAL,
		PickupConfig.ShotPattern.NORMAL
	)
	_expect(
		is_equal_approx(player.get_skill_charge_rate_modifier_total(), TOWER_BONUS_PER_SECOND),
		"Applying a multiplayer realtime snapshot must not clear local source registration."
	)
	_expect(
		player.remove_skill_charge_rate_modifier(SECOND_TOWER_SOURCE),
		"The remaining source must still be removable after lifecycle and snapshot updates."
	)
	_expect(
		is_zero_approx(player.get_skill_charge_rate_modifier_total()),
		"Removing the final source must reset the cached total exactly to zero."
	)


func _expect_charge_after_one_second(player: Player, expected: float, message: String) -> void:
	player.skill1_charge = 0.0
	player.call("_update_skill1_charge", 1.0)
	_expect(is_equal_approx(player.skill1_charge, expected), message)


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _finish(test_root: Node) -> void:
	test_root.queue_free()
	await process_frame
	current_scene = null
	if failures.is_empty():
		print("PLAYER_SKILL_CHARGE_RATE_MODIFIER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
