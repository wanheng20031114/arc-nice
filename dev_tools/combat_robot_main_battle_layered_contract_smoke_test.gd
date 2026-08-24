extends SceneTree

const MAIN_BATTLE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_main_battle_elite.tscn"
)
const UNKNOWN_DERIVED_SCRIPT := preload(
	"res://dev_tools/fixtures/combat_robot_main_battle_unmigrated_derived_fixture.gd"
)

var failures: Array[String] = []


func _init() -> void:
	var enemy := MAIN_BATTLE_SCENE.instantiate() as CombatRobotMainBattleElite
	_expect(enemy != null, "主战机甲场景必须实例化为专属 runner。")
	if enemy != null:
		_expect(
			enemy.supports_centralized_authoritative_simulation()
			and enemy.supports_layered_area_authoritative_simulation()
			and not enemy.supports_layered_contact_authoritative_simulation()
			and enemy.uses_layered_area_physics_phase_decisions()
			and enemy.uses_trusted_layered_phase_entrypoints(),
			"主战机甲必须显式接入分层调度，同时保留未验证的专属 Area 接触。"
		)
		_expect(
			enemy.get_layered_area_decision_interval_frames()
			== enemy.combat_sense_update_interval_frames,
			"主战机甲感知频率必须继续使用原有 combat-sense cadence。"
		)
		enemy.free()

	var unknown := UNKNOWN_DERIVED_SCRIPT.new() as CombatRobotMainBattleElite
	_expect(unknown != null, "未知派生夹具必须可实例化。")
	if unknown != null:
		_expect(
			unknown.supports_centralized_authoritative_simulation()
			and not unknown.supports_layered_area_authoritative_simulation()
			and not unknown.supports_layered_contact_authoritative_simulation(),
			"未知主战机甲派生类必须 fail-close，不得静默继承未验收相位拆分。"
		)
		unknown.free()

	if failures.is_empty():
		print("COMBAT_ROBOT_MAIN_BATTLE_LAYERED_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
